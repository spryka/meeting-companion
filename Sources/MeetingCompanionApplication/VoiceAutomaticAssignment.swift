import Foundation
import MeetingCompanionCore

enum VoiceAutomaticAssignment {
    struct Group: Sendable {
        let speakerID: String
        let unsignedTurns: [TranscriptDocument.Turn]
    }

    struct Query: Sendable {
        let turn: TranscriptDocument.Turn
        let candidateFrames: [(start: Int, end: Int)]
        let interval: VoiceAudioInterval
        let window: VoiceEmbeddingProtocol.Window
    }

    struct RescuePlan: Sendable {
        static let empty = RescuePlan(extraWindows: [], windowsByTurn: [:])
        let extraWindows: [VoiceEmbeddingProtocol.Window]
        let windowsByTurn: [String: [VoiceEmbeddingProtocol.Window]]
    }

    private struct WindowKey: Hashable {
        let sourceID: TranscriptDocument.SourceID
        let fingerprint: String
        let startFrame: Int
        let endFrame: Int

        init(_ window: VoiceEmbeddingProtocol.Window) {
            sourceID = window.sourceID
            fingerprint = window.sourceFingerprint
            startFrame = window.startFrame
            endFrame = window.endFrame
        }
    }

    struct Plan: Sendable {
        var groups: [Group] = []
        var queries: [Query] = []
        var refusals: [String: TranscriptVoiceRefusal] = [:]
    }

    static func plan(
        document: TranscriptDocument,
        edits: TranscriptEdits,
        quality: VoiceAudioQuality?,
        hasProfiles: Bool,
        sourceFingerprints: [TranscriptDocument.SourceID: String] = [:],
        windowBudget: Int = VoiceEmbeddingProtocol.windowLimit
    ) throws -> Plan {
        try quality?.validate(for: document)
        guard edits.resultID == document.resultID else { throw ProcessingService.VoiceJobError.staleResult }

        let orderedSpeakers = document.speakers.sorted {
            if $0.displayNumber != $1.displayNumber { return $0.displayNumber < $1.displayNumber }
            return $0.id < $1.id
        }
        let speakersByID = Dictionary(uniqueKeysWithValues: orderedSpeakers.map { ($0.id, $0) })
        let sources = Dictionary(uniqueKeysWithValues: document.sources.map { ($0.id, $0) })
        let evidenceBySource = Dictionary(uniqueKeysWithValues: (quality?.sources ?? []).map { ($0.id, $0) })
        let unsignedBySpeaker = Dictionary(
            grouping: document.turns.filter { edits.overrides[$0.id]?.displayName == nil },
            by: \.speakerID
        )

        var plan = Plan()
        plan.groups = orderedSpeakers.compactMap { speaker in
            guard let turns = unsignedBySpeaker[speaker.id], !turns.isEmpty else { return nil }
            return Group(speakerID: speaker.id, unsignedTurns: turns)
        }

        let rate = Double(VoiceEmbeddingProtocol.sampleRate)
        let minimumFrames = 3 * VoiceEmbeddingProtocol.sampleRate
        let maximumFrames = 6 * VoiceEmbeddingProtocol.sampleRate
        var candidates: [(speakerID: String, query: Query)] = []

        for group in plan.groups {
            guard let speaker = speakersByID[group.speakerID],
                  let source = sources[speaker.sourceID] else {
                for turn in group.unsignedTurns {
                    plan.refusals[turn.id] = .unavailable
                }
                continue
            }
            guard source.diarizationStatus == .completed, (source.detectedVoiceCount ?? 0) > 0 else {
                for turn in group.unsignedTurns {
                    plan.refusals[turn.id] = .missingEvidence
                }
                continue
            }
            if !hasProfiles {
                for turn in group.unsignedTurns {
                    plan.refusals[turn.id] = .insufficientProfiles
                }
                continue
            }
            let evidence = evidenceBySource[source.id]
            guard let fingerprint = evidence?.fingerprint ?? sourceFingerprints[source.id],
                  !fingerprint.isEmpty else {
                for turn in group.unsignedTurns {
                    plan.refusals[turn.id] = .missingEvidence
                }
                continue
            }

            for turn in group.unsignedTurns {
                switch VoiceWindowSelector.matchingCandidateFrames(
                    turn: turn, source: source, document: document,
                    evidence: evidence, actualFingerprint: fingerprint
                ) {
                case .failure(let reason):
                    plan.refusals[turn.id] = switch reason {
                    case .sourceMismatch: .unavailable
                    case .missingEvidence: .missingEvidence
                    case .insufficientSpeech: .insufficientSpeech
                    case .overlap: .overlap
                    }
                case .success(let candFrames):
                    guard let bestFrames = VoiceWindowSelector.extractMatchingSubwindows(from: candFrames, maxWindows: 1).first,
                          (minimumFrames...maximumFrames).contains(bestFrames.end - bestFrames.start) else {
                        plan.refusals[turn.id] = .insufficientSpeech
                        continue
                    }
                    let interval = VoiceAudioInterval(start: Double(bestFrames.start) / rate, end: Double(bestFrames.end) / rate)
                    let window = VoiceEmbeddingProtocol.Window(
                        sourceID: source.id,
                        sourceFingerprint: fingerprint,
                        startFrame: bestFrames.start,
                        endFrame: bestFrames.end
                    )
                    candidates.append((speakerID: group.speakerID, query: Query(
                        turn: turn, candidateFrames: candFrames, interval: interval, window: window
                    )))
                }
            }
        }

        var lastEndBySource: [TranscriptDocument.SourceID: Int] = [:]
        var cleanBySpeaker: [String: [Query]] = [:]
        for candidate in candidates.sorted(by: {
            if $0.query.window.startFrame != $1.query.window.startFrame {
                return $0.query.window.startFrame < $1.query.window.startFrame
            }
            return $0.query.turn.id < $1.query.turn.id
        }) {
            let window = candidate.query.window
            if window.startFrame < (lastEndBySource[window.sourceID] ?? 0) {
                plan.refusals[candidate.query.turn.id] = .overlap
                continue
            }
            lastEndBySource[window.sourceID] = window.endFrame
            cleanBySpeaker[candidate.speakerID, default: []].append(candidate.query)
        }

        let buckets = orderedSpeakers.map { speaker -> (dense: [Query], sparse: [Query]) in
            let items = (cleanBySpeaker[speaker.id] ?? []).sorted {
                if $0.window.startFrame != $1.window.startFrame {
                    return $0.window.startFrame < $1.window.startFrame
                }
                return $0.turn.id < $1.turn.id
            }
            var dense: [Query] = [], sparse: [Query] = []
            for query in items {
                if VoiceWindowSelector.isDenseSpeechWindow(
                    start: Double(query.window.startFrame) / rate,
                    end: Double(query.window.endFrame) / rate,
                    speakerID: speaker.id,
                    document: document
                ) {
                    dense.append(query)
                } else {
                    sparse.append(query)
                }
            }
            return (dense, sparse)
        }
        let quotas = allocateQuotas(counts: buckets.map { $0.dense.count + $0.sparse.count }, budget: max(0, windowBudget))
        plan.queries = zip(buckets, quotas)
            .flatMap { bucket, quota in
                let denseCount = min(bucket.dense.count, quota)
                return sampleEvenlyInTime(bucket.dense, count: denseCount)
                    + sampleEvenlyInTime(bucket.sparse, count: quota - denseCount)
            }
            .sorted {
                if $0.window.startFrame != $1.window.startFrame {
                    return $0.window.startFrame < $1.window.startFrame
                }
                return $0.turn.id < $1.turn.id
            }
        return plan
    }

    private struct InitialGroupEvaluation {
        let strongLeaders: Set<UUID>
        let matchedCounts: [UUID: Int]
        let windowRefusalByTurn: [String: TranscriptVoiceRefusal]
        let evaluatedRefusals: [TranscriptVoiceRefusal]

        func passedPersonID(totalWindows: Int, people: [UUID: String]) -> UUID? {
            guard strongLeaders.count == 1, let leader = strongLeaders.first, people[leader] != nil else {
                return nil
            }
            let matched = matchedCounts[leader, default: 0]
            if totalWindows >= 3 {
                return matched >= 3 && 3 * matched >= 2 * totalWindows ? leader : nil
            }
            return matched == totalWindows ? leader : nil
        }
    }

    private static func evaluateInitialGroup(
        queries: [Query],
        responses: [UUID: VoiceEmbeddingProtocol.Feature],
        using state: VoiceProfileMatcher.PreparedProfiles,
        policy: VoiceMatchPolicy
    ) -> InitialGroupEvaluation {
        var strongLeaders = Set<UUID>()
        var matchedCounts: [UUID: Int] = [:]
        var windowRefusalByTurn: [String: TranscriptVoiceRefusal] = [:]
        var evaluatedRefusals: [TranscriptVoiceRefusal] = []

        for query in queries {
            guard let embedding = responses[query.window.id]?.embedding else {
                windowRefusalByTurn[query.turn.id] = .insufficientSpeech
                evaluatedRefusals.append(.insufficientSpeech)
                continue
            }
            let evaluation = VoiceProfileMatcher.evaluate(
                embedding: embedding,
                startFrame: query.window.startFrame,
                endFrame: query.window.endFrame,
                using: state,
                policy: policy
            )
            if let strongLeaderID = evaluation.strongLeaderID {
                strongLeaders.insert(strongLeaderID)
            }
            if let matchedID = evaluation.matchedPersonID {
                matchedCounts[matchedID, default: 0] += 1
                strongLeaders.insert(matchedID)
            } else if let refusal = evaluation.refusal {
                let mapped = mapRefusal(refusal)
                windowRefusalByTurn[query.turn.id] = mapped
                evaluatedRefusals.append(mapped)
            }
        }
        return InitialGroupEvaluation(
            strongLeaders: strongLeaders,
            matchedCounts: matchedCounts,
            windowRefusalByTurn: windowRefusalByTurn,
            evaluatedRefusals: evaluatedRefusals
        )
    }

    private static func strictEvaluationWinner(
        windows: [VoiceEmbeddingProtocol.Window],
        responses: [UUID: VoiceEmbeddingProtocol.Feature],
        using state: VoiceProfileMatcher.PreparedProfiles,
        strictPolicy: VoiceMatchPolicy,
        people: [UUID: String]
    ) -> UUID? {
        guard !windows.isEmpty else { return nil }
        var winners = Set<UUID>()
        var strongs = Set<UUID>()
        for window in windows {
            guard let embedding = responses[window.id]?.embedding else {
                return nil
            }
            let evaluation = VoiceProfileMatcher.evaluate(
                embedding: embedding,
                startFrame: window.startFrame,
                endFrame: window.endFrame,
                using: state,
                policy: strictPolicy
            )
            if let strong = evaluation.strongLeaderID {
                strongs.insert(strong)
            }
            guard let matched = evaluation.matchedPersonID else {
                return nil
            }
            winners.insert(matched)
        }
        guard winners.count == 1, strongs == winners,
              let pid = winners.first, people[pid] != nil else {
            return nil
        }
        return pid
    }

    static func rescuePlan(
        for plan: Plan,
        responses: [UUID: VoiceEmbeddingProtocol.Feature],
        catalogue: VoiceProfileCatalogue,
        edits: TranscriptEdits,
        contacts: [String],
        policy: VoiceMatchPolicy
    ) -> RescuePlan {
        guard let rescuePolicy = policy.mixedClusterRescue,
              let strictPolicy = VoiceMatchPolicy(
                  threshold: rescuePolicy.threshold, margin: rescuePolicy.margin,
                  calendarBonus: 0, maximumAcousticGap: 0
              ) else { return .empty }
        let preparedState = VoiceProfileMatcher.prepare(
            catalogue: catalogue,
            embeddingSpaceID: VoiceEmbeddingProtocol.embeddingSpaceID,
            invitedContacts: contacts
        )
        guard case .ready(let state) = preparedState else { return .empty }

        let people = Dictionary(uniqueKeysWithValues: catalogue.people.map { ($0.id, $0.displayName) })
        let queriesBySpeaker = Dictionary(grouping: plan.queries, by: \.turn.speakerID)
        var scheduledByKey = Dictionary(plan.queries.map { (WindowKey($0.window), $0.window) },
                                        uniquingKeysWith: { first, _ in first })
        var extraWindows: [VoiceEmbeddingProtocol.Window] = []
        var windowsByTurn: [String: [VoiceEmbeddingProtocol.Window]] = [:]

        for group in plan.groups {
            let unsignedTurns = group.unsignedTurns.filter { edits.overrides[$0.id]?.displayName == nil }
            let groupQueries = queriesBySpeaker[group.speakerID] ?? []
            guard !unsignedTurns.isEmpty, !groupQueries.isEmpty else { continue }
            let initial = evaluateInitialGroup(queries: groupQueries, responses: responses, using: state, policy: policy)
            guard initial.strongLeaders.count > 1 else { continue }

            let byTurn = Dictionary(grouping: groupQueries, by: \.turn.id)
            var seenTurns = Set<String>()
            for query in groupQueries where seenTurns.insert(query.turn.id).inserted {
                guard let turnQueries = byTurn[query.turn.id], let first = turnQueries.first else { continue }
                let primaryWindows = turnQueries.map(\.window)
                // If pass-1 primary window already failed strict evaluation (nil, weak, low margin, or conflict),
                // the turn can never pass strict consensus including primary, so skip scheduling pass-2 windows.
                guard strictEvaluationWinner(
                    windows: primaryWindows, responses: responses,
                    using: state, strictPolicy: strictPolicy, people: people
                ) != nil else { continue }

                let subs = VoiceWindowSelector.extractMatchingSubwindows(from: first.candidateFrames, maxWindows: 3)
                guard subs.count > turnQueries.count else { continue }
                let checkWindows = subs.map { startFrame, endFrame in
                    let window = VoiceEmbeddingProtocol.Window(
                        sourceID: first.window.sourceID,
                        sourceFingerprint: first.window.sourceFingerprint,
                        startFrame: startFrame,
                        endFrame: endFrame
                    )
                    let key = WindowKey(window)
                    if let scheduled = scheduledByKey[key] { return scheduled }
                    scheduledByKey[key] = window
                    extraWindows.append(window)
                    return window
                }
                windowsByTurn[query.turn.id] = checkWindows
            }
        }
        return RescuePlan(extraWindows: extraWindows, windowsByTurn: windowsByTurn)
    }

    static func overrides(
        for plan: Plan,
        rescuePlan: RescuePlan = .empty,
        responses: [UUID: VoiceEmbeddingProtocol.Feature],
        catalogue: VoiceProfileCatalogue,
        edits: TranscriptEdits,
        contacts: [String],
        policy: VoiceMatchPolicy
    ) -> [String: TranscriptTurnOverride] {
        var overrides: [String: TranscriptTurnOverride] = [:]
        let people = Dictionary(uniqueKeysWithValues: catalogue.people.map { ($0.id, $0.displayName) })
        let queriesBySpeaker = Dictionary(grouping: plan.queries, by: \.turn.speakerID)
        let preparedState = VoiceProfileMatcher.prepare(
            catalogue: catalogue,
            embeddingSpaceID: VoiceEmbeddingProtocol.embeddingSpaceID,
            invitedContacts: contacts
        )

        for group in plan.groups {
            let unsignedTurns = group.unsignedTurns.filter { edits.overrides[$0.id]?.displayName == nil }
            guard !unsignedTurns.isEmpty else { continue }
            let groupQueries = queriesBySpeaker[group.speakerID] ?? []

            if groupQueries.isEmpty {
                for turn in unsignedTurns {
                    let refusal = plan.refusals[turn.id] ?? .insufficientSpeech
                    overrides[turn.id] = TranscriptTurnOverride(text: edits.overrides[turn.id]?.text, voiceRefusal: refusal)
                }
                continue
            }

            if case .refused(let prepRefusal) = preparedState {
                let mapped = mapRefusal(prepRefusal)
                for turn in unsignedTurns {
                    overrides[turn.id] = TranscriptTurnOverride(text: edits.overrides[turn.id]?.text, voiceRefusal: mapped)
                }
                continue
            }

            guard case .ready(let state) = preparedState else { continue }
            let initial = evaluateInitialGroup(queries: groupQueries, responses: responses, using: state, policy: policy)

            if let personID = initial.passedPersonID(totalWindows: groupQueries.count, people: people),
               let name = people[personID] {
                for turn in unsignedTurns {
                    overrides[turn.id] = TranscriptTurnOverride(
                        text: edits.overrides[turn.id]?.text,
                        displayName: name,
                        assignment: .init(personID: personID, origin: "automaticVoiceMatch")
                    )
                }
                continue
            }

            if initial.strongLeaders.count > 1 {
                if let rescuePolicy = policy.mixedClusterRescue,
                   let strictPolicy = VoiceMatchPolicy(
                       threshold: rescuePolicy.threshold, margin: rescuePolicy.margin,
                       calendarBonus: 0, maximumAcousticGap: 0
                   ) {
                    let byTurn = Dictionary(grouping: groupQueries, by: \.turn.id)
                    var rescuedByTurn: [String: UUID] = [:]
                    for (turnID, turnQueries) in byTurn {
                        let primaryWindows = turnQueries.map(\.window)
                        var seenIDs = Set(primaryWindows.map(\.id))
                        var checkWindows = primaryWindows
                        for extra in rescuePlan.windowsByTurn[turnID] ?? [] where seenIDs.insert(extra.id).inserted {
                            checkWindows.append(extra)
                        }
                        if let pid = strictEvaluationWinner(
                            windows: checkWindows, responses: responses,
                            using: state, strictPolicy: strictPolicy, people: people
                        ) {
                            rescuedByTurn[turnID] = pid
                        }
                    }
                    for turn in unsignedTurns {
                        if let pid = rescuedByTurn[turn.id], let name = people[pid] {
                            overrides[turn.id] = TranscriptTurnOverride(
                                text: edits.overrides[turn.id]?.text,
                                displayName: name,
                                assignment: .init(personID: pid, origin: "automaticVoiceMatch")
                            )
                        } else {
                            overrides[turn.id] = TranscriptTurnOverride(
                                text: edits.overrides[turn.id]?.text,
                                voiceRefusal: .ambiguous
                            )
                        }
                    }
                    continue
                }
                for turn in unsignedTurns {
                    overrides[turn.id] = TranscriptTurnOverride(
                        text: edits.overrides[turn.id]?.text,
                        voiceRefusal: .ambiguous
                    )
                }
                continue
            }

            let fallbackRefusal: TranscriptVoiceRefusal =
                initial.evaluatedRefusals.contains(.ambiguous) ? .ambiguous :
                initial.evaluatedRefusals.contains(.unknownVoice) ? .unknownVoice :
                initial.evaluatedRefusals.contains(.unavailable) ? .unavailable : .insufficientSpeech

            for turn in unsignedTurns {
                let refusal = initial.windowRefusalByTurn[turn.id] ?? plan.refusals[turn.id] ?? fallbackRefusal
                overrides[turn.id] = TranscriptTurnOverride(
                    text: edits.overrides[turn.id]?.text,
                    voiceRefusal: refusal
                )
            }
        }
        return overrides
    }

    private static func mapRefusal(_ refusal: VoiceProfileMatcher.Refusal) -> TranscriptVoiceRefusal {
        switch refusal {
        case .insufficientProfiles: .insufficientProfiles
        case .incompleteCoverage, .invalidEmbedding: .unavailable
        case .weakMatch: .unknownVoice
        case .ambiguous, .conflictingWindows: .ambiguous
        }
    }

    private static func allocateQuotas(counts: [Int], budget: Int) -> [Int] {
        let total = counts.reduce(0, +)
        guard total > budget else { return counts }
        var quotas = Array(repeating: 0, count: counts.count)
        var remainingBudget = budget
        var active = counts.enumerated().filter { $0.element > 0 }.map { (idx: $0.offset, count: $0.element) }
        while !active.isEmpty && remainingBudget > 0 {
            let fair = remainingBudget / active.count
            let small = active.filter { $0.count <= fair }
            if small.isEmpty {
                var remainder = remainingBudget % active.count
                for item in active {
                    quotas[item.idx] = fair + (remainder > 0 ? 1 : 0)
                    if remainder > 0 { remainder -= 1 }
                }
                remainingBudget = 0
                break
            }
            for item in small {
                quotas[item.idx] = item.count
                remainingBudget -= item.count
            }
            active.removeAll { $0.count <= fair }
        }
        return quotas
    }

    private static func sampleEvenlyInTime(_ items: [Query], count: Int) -> [Query] {
        guard count > 0, !items.isEmpty else { return [] }
        guard count < items.count else { return items }
        func midpoint(_ query: Query) -> Double {
            (Double(query.window.startFrame) + Double(query.window.endFrame)) * 0.5
        }
        let firstTime = midpoint(items[0])
        let lastTime = midpoint(items[items.count - 1])
        if count == 1 {
            let target = (firstTime + lastTime) * 0.5
            let bestIndex = items.indices.min { lhs, rhs in
                let lhsDist = abs(midpoint(items[lhs]) - target)
                let rhsDist = abs(midpoint(items[rhs]) - target)
                if lhsDist != rhsDist { return lhsDist < rhsDist }
                return lhs < rhs
            } ?? 0
            return [items[bestIndex]]
        }
        guard lastTime > firstTime else {
            return (0..<count).map { index in
                items[(index * (items.count - 1)) / (count - 1)]
            }
        }
        var chosen: Set<Int> = [0, items.count - 1]
        for slot in 1..<(count - 1) {
            let target = firstTime + (lastTime - firstTime) * Double(slot) / Double(count - 1)
            var bestIndex: Int?
            var bestDistance = Double.infinity
            for idx in items.indices where !chosen.contains(idx) {
                let distance = abs(midpoint(items[idx]) - target)
                if distance < bestDistance || (distance == bestDistance && idx < (bestIndex ?? Int.max)) {
                    bestDistance = distance
                    bestIndex = idx
                }
            }
            if let bestIndex {
                chosen.insert(bestIndex)
            }
        }
        return chosen.sorted().map { items[$0] }
    }
}
