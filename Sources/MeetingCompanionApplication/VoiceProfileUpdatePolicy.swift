import Foundation
import MeetingCompanionCore

public struct VoiceProfileUpdatePolicy: Sendable {
    public static let maximumInitialCandidates = 24

    public let id: String
    public let minimumAgreement: Double

    public init?(id: String, minimumAgreement: Double) {
        guard !id.isEmpty, (0...1).contains(minimumAgreement) else { return nil }
        self.id = id
        self.minimumAgreement = minimumAgreement
    }

    @discardableResult
    public func apply(_ candidates: [VoiceProfileSample], to catalogue: inout VoiceProfileCatalogue) -> Int {
        guard let first = candidates.first else { return 0 }
        let person = first.personID
        let space = first.embeddingSpaceID
        let oldProfile = catalogue.aggregates.first { $0.personID == person }
        let oldActiveIDs = Set(oldProfile?.activeSampleIDs ?? [])
        let retained = catalogue.samples.filter { $0.personID == person }
        let active = retained.filter { oldActiveIDs.contains($0.id) }
        let compatibleActive = oldProfile?.embeddingSpaceID == space ? active : []
        var seen = catalogue.seenSamples?[person] ?? .init()
        seen.pcm.formUnion(retained.map(pcmKey))
        seen.assignmentWindows.formUnion(retained.map(windowKey))
        var batchKeys = seen
        var sampleIDs = Set(retained.map(\.id))

        let validCandidates = candidates.filter { sample in
            sample.personID == person && sample.embeddingSpaceID == space &&
                sample.assignment.personID == person &&
                (sample.assignment.origin == "manual" || sample.assignment.origin == "legacyManualImport") &&
                sample.recordingFingerprint?.isEmpty == false &&
                sample.hasValidWindowDuration &&
                !sample.pcmFingerprint.isEmpty && isUnit(sample.embedding)
        }
        let orderedCandidates = compatibleActive.isEmpty ? validCandidates.sorted(by: canonicalPrecedes) : validCandidates
        let incoming = orderedCandidates.filter { sample in
            let window = windowKey(sample)
            let pcm = pcmKey(sample)
            guard !batchKeys.pcm.contains(pcm), !batchKeys.assignmentWindows.contains(window),
                  sampleIDs.insert(sample.id).inserted else { return false }
            batchKeys.pcm.insert(pcm)
            batchKeys.assignmentWindows.insert(window)
            return true
        }
        guard !incoming.isEmpty else { return 0 }

        let priorPending = retained.filter { $0.embeddingSpaceID == space && !oldActiveIDs.contains($0.id) }
        let pending = compatibleActive.isEmpty
            ? (incoming + priorPending).sorted(by: canonicalPrecedes)
            : incoming + priorPending

        if compatibleActive.isEmpty, pending.count > Self.maximumInitialCandidates {
            return 0
        }

        let admitted: [VoiceProfileSample]
        if let anchor = oldProfile?.centroid, !compatibleActive.isEmpty {
            admitted = pending.filter { candidate in
                similarity(candidate.embedding, anchor) >= minimumAgreement ||
                    pending.contains {
                        $0.recordingFingerprint != nil && $0.recordingFingerprint != candidate.recordingFingerprint &&
                            similarity($0.embedding, candidate.embedding) >= minimumAgreement
                    }
            }
        } else {
            admitted = maximumConsistentSubset(from: pending)
        }
        let chosen = balanced(admitted + compatibleActive)
        let sufficient = !compatibleActive.isEmpty || VoiceProfileSample.hasSufficientActiveSpeech(chosen)
        let nextProfile = sufficient && !admitted.isEmpty ? aggregate(for: chosen, person: person, space: space) : nil
        let nextActive = nextProfile == nil ? active : chosen
        let nextActiveIDs = Set(nextActive.map(\.id))
        let unchosenIncoming = incoming.filter { !nextActiveIDs.contains($0.id) }
        let unchosenPrior = (priorPending + retained.filter { $0.embeddingSpaceID != space })
            .filter { !nextActiveIDs.contains($0.id) }
        let nextPending = balanced(unchosenIncoming + unchosenPrior)
        let nextSamples = nextActive + nextPending
        seen.pcm.formUnion(nextSamples.map(pcmKey))
        seen.assignmentWindows.formUnion(nextSamples.map(windowKey))
        if catalogue.seenSamples == nil { catalogue.seenSamples = [:] }
        catalogue.seenSamples?[person] = seen
        catalogue.samples.removeAll { $0.personID == person }
        catalogue.samples.append(contentsOf: nextSamples)
        if let nextProfile {
            catalogue.aggregates.removeAll { $0.personID == person }
            catalogue.aggregates.append(nextProfile)
        }
        let retainedIDs = Set(nextSamples.map(\.id))
        return incoming.filter { retainedIDs.contains($0.id) }.count
    }

    private func canonicalPrecedes(_ lhs: VoiceProfileSample, _ rhs: VoiceProfileSample) -> Bool {
        let lhsMeeting = meetingKey(lhs), rhsMeeting = meetingKey(rhs)
        if lhsMeeting != rhsMeeting { return lhsMeeting < rhsMeeting }
        if lhs.sourceID.rawValue != rhs.sourceID.rawValue { return lhs.sourceID.rawValue < rhs.sourceID.rawValue }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        if lhs.turnID != rhs.turnID { return lhs.turnID < rhs.turnID }
        if lhs.pcmFingerprint != rhs.pcmFingerprint { return lhs.pcmFingerprint < rhs.pcmFingerprint }
        let lhsAssign = lhs.assignment.assignmentID.uuidString, rhsAssign = rhs.assignment.assignmentID.uuidString
        if lhsAssign != rhsAssign { return lhsAssign < rhsAssign }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func maximumConsistentSubset(from samples: [VoiceProfileSample]) -> [VoiceProfileSample] {
        guard samples.count > 1 else { return samples }
        let count = samples.count
        var similarities = Array(repeating: Array(repeating: 1.0, count: count), count: count)
        var adjacency = Array(repeating: Set<Int>(), count: count)
        for i in 0..<count {
            for j in (i + 1)..<count {
                let sim = similarity(samples[i].embedding, samples[j].embedding)
                similarities[i][j] = sim
                similarities[j][i] = sim
                if sim >= minimumAgreement {
                    adjacency[i].insert(j)
                    adjacency[j].insert(i)
                }
            }
        }

        struct CliqueScore {
            let indices: [Int]
            let sufficient: Bool
            let count: Int
            let minSimilarity: Double
            let sumSimilarity: Double

            func isBetter(than other: CliqueScore) -> Bool {
                if sufficient != other.sufficient { return sufficient }
                if count != other.count { return count > other.count }
                if abs(minSimilarity - other.minSimilarity) > 1e-12 { return minSimilarity > other.minSimilarity }
                if abs(sumSimilarity - other.sumSimilarity) > 1e-12 { return sumSimilarity > other.sumSimilarity }
                return indices.lexicographicallyPrecedes(other.indices)
            }
        }

        func score(_ indices: [Int]) -> CliqueScore {
            let sorted = indices.sorted()
            let chosen = balanced(sorted.map { samples[$0] })
            let sufficient = VoiceProfileSample.hasSufficientActiveSpeech(chosen)
            var minSim = 1.0
            var sumSim = 0.0
            for a in 0..<sorted.count {
                for b in (a + 1)..<sorted.count {
                    let s = similarities[sorted[a]][sorted[b]]
                    if s < minSim { minSim = s }
                    sumSim += s
                }
            }
            return CliqueScore(
                indices: sorted, sufficient: sufficient, count: sorted.count,
                minSimilarity: minSim, sumSimilarity: sumSim
            )
        }

        var best: CliqueScore?

        func bronKerbosch(r: [Int], p: Set<Int>, x: Set<Int>) {
            if p.isEmpty && x.isEmpty {
                let candidate = score(r)
                if let current = best {
                    if candidate.isBetter(than: current) { best = candidate }
                } else {
                    best = candidate
                }
                return
            }
            let unionPX = p.union(x)
            let pivot = unionPX.max { lhs, rhs in
                let lhsDeg = adjacency[lhs].intersection(p).count
                let rhsDeg = adjacency[rhs].intersection(p).count
                if lhsDeg != rhsDeg { return lhsDeg < rhsDeg }
                return lhs > rhs
            }
            let candidates = (pivot.map { p.subtracting(adjacency[$0]) } ?? p).sorted()
            var currentP = p
            var currentX = x
            for v in candidates {
                bronKerbosch(r: r + [v], p: currentP.intersection(adjacency[v]), x: currentX.intersection(adjacency[v]))
                currentP.remove(v)
                currentX.insert(v)
            }
        }

        bronKerbosch(r: [], p: Set(0..<count), x: [])
        return (best?.indices ?? []).map { samples[$0] }
    }

    private func balanced(_ samples: [VoiceProfileSample]) -> [VoiceProfileSample] {
        var byMeeting: [String: [VoiceProfileSample]] = [:]
        var order: [String] = []
        for sample in samples {
            let key = meetingKey(sample)
            if byMeeting[key] == nil { order.append(key) }
            if byMeeting[key, default: []].count < 4 {
                byMeeting[key, default: []].append(sample)
            }
        }
        return Array((0..<4).flatMap { index in
            order.compactMap { key in
                guard let samples = byMeeting[key], index < samples.count else { return nil as VoiceProfileSample? }
                return samples[index]
            }
        }.prefix(12))
    }

    private func meetingKey(_ sample: VoiceProfileSample) -> String {
        sample.recordingFingerprint ?? sample.resultID
    }

    private func windowKey(_ sample: VoiceProfileSample) -> String {
        "\(sample.embeddingSpaceID)/\(sample.assignment.assignmentID)/\(sample.sourceID.rawValue)/\(sample.start.bitPattern)/\(sample.end.bitPattern)"
    }

    private func pcmKey(_ sample: VoiceProfileSample) -> String {
        "\(sample.embeddingSpaceID)/\(sample.pcmFingerprint)"
    }

    private func similarity(_ a: [Float], _ b: [Float]) -> Double {
        zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
    }

    private func isUnit(_ vector: [Float]) -> Bool {
        vector.count == VoiceEmbeddingProtocol.dimensions && abs(similarity(vector, vector) - 1) <= 0.01
    }

    private func aggregate(for samples: [VoiceProfileSample], person: UUID, space: String) -> VoiceProfileAggregate? {
        var sum = Array(repeating: 0.0, count: VoiceEmbeddingProtocol.dimensions)
        for sample in samples {
            for (index, value) in sample.embedding.enumerated() { sum[index] += Double(value) }
        }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm.isFinite, norm > 0 else { return nil }
        return VoiceProfileAggregate(personID: person, embeddingSpaceID: space,
                                     centroid: sum.map { Float($0 / norm) }, activeSampleIDs: samples.map(\.id),
                                     policyID: id)
    }
}
