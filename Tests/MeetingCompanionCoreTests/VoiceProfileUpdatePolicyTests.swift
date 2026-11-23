import Foundation
import Testing
import MeetingCompanionApplication
@testable import MeetingCompanionCore

struct VoiceProfileUpdatePolicyTests {
    private let person = VoiceProfilePerson(displayName: "Анна")
    private let e1: [Float] = [1] + Array(repeating: 0, count: 255)
    private let e2: [Float] = [0, 1] + Array(repeating: 0, count: 254)

    private func sample(_ meeting: String, index: Int, vector: [Float], assignment: TranscriptNameAssignment? = nil,
                        locator: String? = nil, pcm: String? = nil, recordingFingerprint: String? = nil) -> VoiceProfileSample {
        .init(personID: person.id, embeddingSpaceID: "test-space", embedding: vector,
              recordingLocator: locator ?? "/recordings/\(meeting)", resultID: meeting,
              turnID: "t\(index)", sourceID: .host, start: Double(index * 5), end: Double(index * 5 + 4),
              pcmFingerprint: pcm ?? "\(meeting)-\(index)", assignment: assignment ?? .init(personID: person.id, origin: "manual"),
              policyID: "test", recordingFingerprint: recordingFingerprint ?? meeting)
    }

    @Test func duplicatesAndMovedRecordingsRespectMeetingAndProfileCaps() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8))
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        let initial = (0..<6).map { sample("a", index: $0, vector: e1) }
        policy.apply(initial, to: &catalogue)
        #expect(catalogue.aggregates.first?.activeSampleIDs.count == 4)
        let beforeReplay = catalogue
        let replay = sample("a", index: 0, vector: e1, assignment: initial[0].assignment, locator: "/moved/a", pcm: "changed")
        policy.apply([replay, sample("other", index: 0, vector: e1, pcm: "a-0")], to: &catalogue)
        #expect(catalogue == beforeReplay)
        for meeting in ["b", "c", "d", "e"] {
            policy.apply((0..<4).map { sample(meeting, index: $0, vector: e1) }, to: &catalogue)
        }
        let profile = try #require(catalogue.aggregates.first)
        let active = catalogue.samples.filter { profile.activeSampleIDs.contains($0.id) }
        #expect(active.count == 12)
        #expect(Set(active.map(\.resultID)).count > 1)
        #expect(Dictionary(grouping: active, by: \.resultID).values.allSatisfy { $0.count <= 4 })
    }

    @Test func conflictingSamplesNeedIndependentCorroborationAndCanBeRevoked() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8))
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        policy.apply((0..<3).map { sample("a", index: $0, vector: e1) }, to: &catalogue)
        let old = try #require(catalogue.aggregates.first)
        let outlier = sample("b", index: 0, vector: e2)
        policy.apply([outlier, sample("b", index: 1, vector: e2)], to: &catalogue)
        #expect(catalogue.aggregates.first == old)
        policy.apply([sample("c", index: 0, vector: e2)], to: &catalogue)
        #expect(catalogue.aggregates.first?.activeSampleIDs.contains(outlier.id) == true)
        catalogue.revokeSamples(assignments: [outlier.assignment.assignmentID])
        #expect(catalogue.aggregates.first?.activeSampleIDs.contains(outlier.id) == false)
        #expect(catalogue.samples.contains { $0.id == outlier.id } == false)
    }

    @Test func insufficientSpeechAndZeroCentroidDoNotCreateOrReplaceProfiles() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8))
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        policy.apply((0..<2).map { sample("a", index: $0, vector: e1) }, to: &catalogue)
        #expect(catalogue.aggregates.isEmpty)
        policy.apply([sample("a", index: 2, vector: e1)], to: &catalogue)
        let old = try #require(catalogue.aggregates.first)
        let opposite = e1.map { -$0 }
        policy.apply([sample("b", index: 0, vector: opposite), sample("b", index: 1, vector: opposite),
                      sample("c", index: 0, vector: opposite)], to: &catalogue)
        #expect(catalogue.aggregates.first == old)
    }

    @Test func revokingOneOfThreeWindowsDoesNotActivateUnconfirmedSamples() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8))
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        let initial = (0..<3).map { sample("a", index: $0, vector: e1) }
        policy.apply(initial, to: &catalogue)
        let unconfirmed = sample("b", index: 0, vector: e2)
        policy.apply([unconfirmed], to: &catalogue)
        #expect(catalogue.availableAggregates.count == 1)
        catalogue.revokeSamples(assignments: [initial[0].assignment.assignmentID])
        #expect(catalogue.availableAggregates.isEmpty)
        #expect(catalogue.samples.contains { $0.id == unconfirmed.id })
    }

    @Test func movingAndRetryingCannotMakeOneMeetingItsOwnCorroboration() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8))
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        policy.apply((0..<3).map { sample("a", index: $0, vector: e1) }, to: &catalogue)
        let old = try #require(catalogue.aggregates.first)
        policy.apply((0..<4).map { sample("b", index: $0, vector: e2) }, to: &catalogue)
        policy.apply((0..<4).map { sample("b-retry", index: $0, vector: e2,
            locator: "/moved/renamed", recordingFingerprint: "b") }, to: &catalogue)
        #expect(catalogue.aggregates.first == old)
        #expect(catalogue.samples.filter { $0.recordingFingerprint == "b" }.count == 4)
    }

    @Test func evictedPCMRemainsDeduplicatedAfterCatalogueRoundTrip() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8))
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        policy.apply((0..<3).map { sample("a", index: $0, vector: e1) }, to: &catalogue)
        for index in 0..<12 {
            policy.apply([sample("new-\(index)", index: 0, vector: e1)], to: &catalogue)
        }
        #expect(!catalogue.samples.contains { $0.resultID == "a" })
        let reloaded = try JSONDecoder().decode(VoiceProfileCatalogue.self, from: JSONEncoder().encode(catalogue))
        var updated = reloaded
        policy.apply([sample("a-retry", index: 0, vector: e1, pcm: "a-0", recordingFingerprint: "a")], to: &updated)
        #expect(updated == reloaded)
    }

    @Test func fullMeetingKeepsConflictingCandidateUntilAnotherMeetingConfirmsIt() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8))
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        policy.apply((0..<4).map { sample("b", index: $0, vector: e1) }, to: &catalogue)
        let conflict = sample("b", index: 4, vector: e2)
        policy.apply([conflict], to: &catalogue)
        #expect(catalogue.samples.contains { $0.id == conflict.id })
        #expect(catalogue.aggregates.first?.activeSampleIDs.contains(conflict.id) == false)
        policy.apply([sample("c", index: 0, vector: e2)], to: &catalogue)
        let active = try #require(catalogue.aggregates.first?.activeSampleIDs)
        #expect(active.contains(conflict.id))
        #expect(catalogue.samples.filter { active.contains($0.id) && $0.recordingFingerprint == "b" }.count == 4)
    }

    @Test func initialProfileSelectionIsOrderIndependentWithLeadingOutlierAtAgreement060() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "manual-v1-agreement-0.60", minimumAgreement: 0.6))
        // Good cluster: pairwise cosines ~ 0.64-0.75 (passes 0.60, would fail 0.80).
        // Outlier e2 has cosine <= 0.25 with every good vector.
        let good1: [Float] = [0.95, 0.0, 0.3122499] + Array(repeating: 0, count: 253)
        let good2: [Float] = [0.95, 0.0, -0.3122499] + Array(repeating: 0, count: 253)
        let good3: [Float] = [0.85, 0.2, 0.0, 0.4873397] + Array(repeating: 0, count: 252)
        let outlier: [Float] = [0.0, 1.0] + Array(repeating: 0, count: 254)

        let goodSamples = [
            sample("m1", index: 0, vector: good1),
            sample("m1", index: 1, vector: good2),
            sample("m1", index: 2, vector: good3)
        ]
        let bad = sample("m1", index: 3, vector: outlier)

        var reference = VoiceProfileCatalogue()
        reference.people = [person]
        policy.apply(goodSamples + [bad], to: &reference)
        let expectedIDs = Set(try #require(reference.aggregates.first?.activeSampleIDs))
        #expect(expectedIDs == Set(goodSamples.map(\.id)))

        // Placing the outlier first must still yield the exact same active sample IDs.
        var reordered = VoiceProfileCatalogue()
        reordered.people = [person]
        policy.apply([bad] + goodSamples, to: &reordered)
        #expect(Set(try #require(reordered.aggregates.first?.activeSampleIDs)) == expectedIDs)
    }

    @Test func initialProfileBreaksEqualCliqueSizeTiesBySufficiencyAndPairwiseSimilarity() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.6))
        let vecA1: [Float] = [1.0, 0.0] + Array(repeating: 0, count: 254)
        let vecA2: [Float] = [0.7, 0.71414284] + Array(repeating: 0, count: 254)
        let vecA3: [Float] = [0.7, -0.71414284] + Array(repeating: 0, count: 254) // min sim(A2,A3) = -0.02 -> wait: need >=0.6!
        // Make clique A (pairwise ~ 0.65) and clique B (pairwise ~ 0.90) orthogonal to each other.
        let a1: [Float] = [1, 0, 0, 0] + Array(repeating: 0, count: 252)
        let a2: [Float] = [0.81, 0.58643, 0, 0] + Array(repeating: 0, count: 252) // dot(a1,a2)=0.81
        let a3: [Float] = [0.81, -0.58643, 0, 0] + Array(repeating: 0, count: 252) // dot(a2,a3)=0.6561-0.3439 < 0.6 -> use 3D positive cone!
        _ = (vecA1, vecA2, vecA3, a1, a2, a3)

        // Tight orthogonal cluster B in axes (3,4,5) with pairwise cosine ~ 0.92
        let b1: [Float] = [0, 0, 0, 1, 0, 0] + Array(repeating: 0, count: 250)
        let b2: [Float] = [0, 0, 0, 0.94, 0.3411744, 0] + Array(repeating: 0, count: 250)
        let b3: [Float] = [0, 0, 0, 0.94, 0.12, 0.3193744] + Array(repeating: 0, count: 250) // dot(b2,b3)=0.8836+0.0409=0.9245

        // Looser cluster C in axes (0,1,2) with pairwise cosine ~ 0.72
        let c1: [Float] = [1, 0, 0] + Array(repeating: 0, count: 253)
        let c2: [Float] = [0.84, 0.5425864, 0] + Array(repeating: 0, count: 253)
        let c3: [Float] = [0.84, 0.05, 0.5402777] + Array(repeating: 0, count: 253) // dot(c2,c3)=0.7056+0.0271=0.7327

        // Both cliques size 3, both 12s duration -> tighter clique B must win regardless of order.
        let loose = [sample("a", index: 0, vector: c1), sample("a", index: 1, vector: c2), sample("a", index: 2, vector: c3)]
        let tight = [sample("a", index: 3, vector: b1), sample("a", index: 4, vector: b2), sample("a", index: 5, vector: b3)]
        var cat = VoiceProfileCatalogue()
        cat.people = [person]
        policy.apply(loose + tight, to: &cat)
        #expect(Set(try #require(cat.aggregates.first?.activeSampleIDs)) == Set(tight.map(\.id)))

        // If clique B only has 3s windows (total 9s < 12s) and clique C has 4s windows (total 12s), sufficient C wins!
        let shortTight = (0..<3).map { i in
            VoiceProfileSample(personID: person.id, embeddingSpaceID: "test-space", embedding: [b1, b2, b3][i],
                recordingLocator: "/recordings/a", resultID: "a", turnID: "st\(i)", sourceID: .host,
                start: Double(i * 5), end: Double(i * 5 + 3), pcmFingerprint: "st-\(i)",
                assignment: .init(personID: person.id, origin: "manual"), policyID: "test", recordingFingerprint: "a")
        }
        var catSufficient = VoiceProfileCatalogue()
        catSufficient.people = [person]
        policy.apply(shortTight + loose, to: &catSufficient)
        #expect(Set(try #require(catSufficient.aggregates.first?.activeSampleIDs)) == Set(loose.map(\.id)))
    }

    @Test func initialProfileUsesCanonicalOrderBeforePerMeetingCap() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "manual-v1-agreement-0.60", minimumAgreement: 0.6))
        let fifthVec: [Float] = [0.8, 0.6] + Array(repeating: 0, count: 254)
        let samples = (0..<4).map { sample("m1", index: $0, vector: e1) } + [sample("m1", index: 4, vector: fifthVec)]

        var catOrdered = VoiceProfileCatalogue()
        catOrdered.people = [person]
        policy.apply(samples, to: &catOrdered)

        var catPermuted = VoiceProfileCatalogue()
        catPermuted.people = [person]
        policy.apply([samples[4], samples[0], samples[1], samples[2], samples[3]], to: &catPermuted)

        let aggA = try #require(catOrdered.aggregates.first)
        let aggB = try #require(catPermuted.aggregates.first)
        #expect(Set(aggA.activeSampleIDs) == Set(aggB.activeSampleIDs))
        #expect(aggA.centroid == aggB.centroid)
    }

    @Test func initialProfileExplicitlyRejectsBatchesExceedingExactCliqueBound() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "manual-v1-agreement-0.60", minimumAgreement: 0.6))
        let count = VoiceProfileUpdatePolicy.maximumInitialCandidates + 1
        let batch = (0..<count).map { idx in
            sample("m\(idx / 4)", index: idx % 4, vector: e1, pcm: "pcm-\(idx)")
        }
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        let added = policy.apply(batch, to: &catalogue)
        #expect(added == 0)
        #expect(catalogue.aggregates.isEmpty)
        #expect(catalogue.samples.isEmpty)
    }

    @Test func laterSequentialConfirmationsEvictIncompatiblePendingWindowsAndBuildProfile() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "manual-v1-agreement-0.60", minimumAgreement: 0.6))
        func unitAxis(_ axis: Int) -> [Float] {
            var vector = Array(repeating: Float(0), count: 256)
            vector[axis] = 1
            return vector
        }

        let earlyIncompatible = (0..<4).map { sample("m1", index: $0, vector: unitAxis($0)) }
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        policy.apply(earlyIncompatible, to: &catalogue)
        #expect(catalogue.aggregates.isEmpty)
        #expect(catalogue.samples.count == 4)

        let g1 = sample("m1", index: 4, vector: unitAxis(4))
        let g2 = sample("m1", index: 5, vector: unitAxis(4))
        let g3 = sample("m1", index: 6, vector: unitAxis(4))

        #expect(policy.apply([g1], to: &catalogue) == 1)
        #expect(catalogue.aggregates.isEmpty)
        #expect(policy.apply([g2], to: &catalogue) == 1)
        #expect(catalogue.aggregates.isEmpty)
        #expect(policy.apply([g3], to: &catalogue) == 1)

        let agg = try #require(catalogue.aggregates.first)
        #expect(Set(agg.activeSampleIDs) == Set([g1.id, g2.id, g3.id]))

        let orthogonalBatch = (0..<5).map { sample("m1", index: $0, vector: unitAxis($0)) }
        var forwardCat = VoiceProfileCatalogue()
        forwardCat.people = [person]
        policy.apply(orthogonalBatch, to: &forwardCat)
        var reversedCat = VoiceProfileCatalogue()
        reversedCat.people = [person]
        policy.apply(Array(orthogonalBatch.reversed()), to: &reversedCat)
        #expect(forwardCat.samples.count == 4)
        #expect(Set(forwardCat.samples.map(\.id)) == Set(reversedCat.samples.map(\.id)))
    }

    @Test func initialProfileDurationSumMatchesCliqueSufficiencyForLargeFrameOffsets() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "manual-v1-agreement-0.60", minimumAgreement: 0.6))
        let rate = 16_000.0
        let starts = [4_457_784, 6_485_958, 8_127_763]
        let windows = starts.enumerated().map { idx, startFrame in
            VoiceProfileSample(
                personID: person.id,
                embeddingSpaceID: "test-space",
                embedding: e1,
                recordingLocator: "/recordings/m1",
                resultID: "m1",
                turnID: "t\(idx)",
                sourceID: .host,
                start: Double(startFrame) / rate,
                end: Double(startFrame + 64_000) / rate,
                pcmFingerprint: "m1-frame-\(idx)",
                assignment: .init(personID: person.id, origin: "manual"),
                policyID: "test",
                recordingFingerprint: "m1"
            )
        }
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        let added = policy.apply(windows, to: &catalogue)
        #expect(added == 3)
        let agg = try #require(catalogue.aggregates.first)
        #expect(Set(agg.activeSampleIDs) == Set(windows.map(\.id)))
        #expect(catalogue.availableAggregates.count == 1)
    }

    private func frameSample(meeting: String, startFrame: Int, frameLength: Int, tag: String) -> VoiceProfileSample {
        let rate = Double(VoiceEmbeddingProtocol.sampleRate)
        return VoiceProfileSample(
            personID: person.id,
            embeddingSpaceID: "test-space",
            embedding: e1,
            recordingLocator: "/recordings/\(meeting)",
            resultID: meeting,
            turnID: "t-\(tag)",
            sourceID: .host,
            start: Double(startFrame) / rate,
            end: Double(startFrame + frameLength) / rate,
            pcmFingerprint: "\(meeting)-pcm-\(tag)",
            assignment: .init(personID: person.id, origin: "manual"),
            policyID: "test",
            recordingFingerprint: meeting
        )
    }

    @Test func initialProfileCountsExactTwelveSecondsByFramesDespiteFloatRounding() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "manual-v1-agreement-0.60", minimumAgreement: 0.6))

        let threeByFour = [4_320, 68_480, 198_400].enumerated().map { idx, startFrame in
            frameSample(meeting: "m1", startFrame: startFrame, frameLength: 64_000, tag: "a-\(idx)")
        }
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        #expect(policy.apply(threeByFour, to: &catalogue) == 3)
        let agg = try #require(catalogue.aggregates.first)
        #expect(Set(agg.activeSampleIDs) == Set(threeByFour.map(\.id)))
        #expect(catalogue.availableAggregates.count == 1)

        let boundarySpecs = [(68_480, 48_000), (32_800, 96_000), (198_400, 48_000)]
        let boundaryWindows = boundarySpecs.enumerated().map { idx, spec in
            frameSample(meeting: "m1", startFrame: spec.0, frameLength: spec.1, tag: "b-\(idx)")
        }
        var boundaryCat = VoiceProfileCatalogue()
        boundaryCat.people = [person]
        #expect(policy.apply(boundaryWindows, to: &boundaryCat) == 3)
        let boundaryAgg = try #require(boundaryCat.aggregates.first)
        #expect(Set(boundaryAgg.activeSampleIDs) == Set(boundaryWindows.map(\.id)))
    }

    @Test func revokingFourthSamplePreservesExactTwelveSecondFrameProfile() throws {
        let policy = try #require(VoiceProfileUpdatePolicy(id: "manual-v1-agreement-0.60", minimumAgreement: 0.6))
        let threeWindows = [4_320, 68_480, 198_400].enumerated().map { idx, startFrame in
            frameSample(meeting: "m1", startFrame: startFrame, frameLength: 64_000, tag: "r-\(idx)")
        }
        let fourth = frameSample(meeting: "m2", startFrame: 0, frameLength: 64_000, tag: "r-fourth")

        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        policy.apply(threeWindows + [fourth], to: &catalogue)
        #expect(catalogue.aggregates.first?.activeSampleIDs.count == 4)

        catalogue.revokeSamples(assignments: [fourth.assignment.assignmentID])
        let remaining = try #require(catalogue.aggregates.first)
        #expect(Set(remaining.activeSampleIDs) == Set(threeWindows.map(\.id)))
        #expect(catalogue.availableAggregates.count == 1)

        catalogue.revokeSamples(assignments: [threeWindows[0].assignment.assignmentID])
        #expect(catalogue.aggregates.isEmpty)
        #expect(catalogue.availableAggregates.isEmpty)
    }
}
