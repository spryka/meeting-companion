import Foundation
import MeetingCompanionApplication
@testable import MeetingCompanionCore
import Testing

@Suite struct VoiceProfileMatcherTests {
    private let guest = VoiceProfilePerson(displayName: "Анна")
    private let invitee = VoiceProfilePerson(displayName: "Анна", calendarBindings: ["invitee@example.invalid"])
    private let compatible = "space"

    private func vector(_ x: Double, _ y: Double) -> [Float] {
        [Float(x), Float(y)] + Array(repeating: 0, count: 254)
    }

    private func catalogue(guestVector: [Float], inviteeVector: [Float], inviteeSpace: String = "space") -> VoiceProfileCatalogue {
        var value = VoiceProfileCatalogue()
        value.people = [guest, invitee]
        value.aggregates = [
            .init(personID: guest.id, embeddingSpaceID: compatible, centroid: guestVector,
                  activeSampleIDs: [UUID()], policyID: "test"),
            .init(personID: invitee.id, embeddingSpaceID: inviteeSpace, centroid: inviteeVector,
                  activeSampleIDs: [UUID()], policyID: "test")
        ]
        return value
    }

    @Test func calendarCannotDisplaceAGuestWithAStrongerAcousticMatch() throws {
        let value = catalogue(guestVector: vector(1, 0), inviteeVector: vector(0.8, 0.6))
        let policy = try #require(VoiceMatchPolicy(threshold: 0.7, margin: 0.02, calendarBonus: 0.3, maximumAcousticGap: 0.05))
        let windows = [VoiceMatchWindow(start: 2, end: 6, embedding: vector(1, 0))]
        #expect(VoiceProfileMatcher.match(turnStart: 2, turnEnd: 6, windows: windows,
            catalogue: value, embeddingSpaceID: compatible, invitedContacts: [], policy: policy) == .matched(guest.id))
        #expect(VoiceProfileMatcher.match(turnStart: 2, turnEnd: 6, windows: windows, catalogue: value,
            embeddingSpaceID: compatible, invitedContacts: ["invitee@example.invalid"], policy: policy) == .refused(.weakMatch))
    }

    @Test func onlyUniqueConfirmedContactCanResolveAcousticTie() throws {
        let value = catalogue(guestVector: vector(1, 0), inviteeVector: vector(1, 0))
        let policy = try #require(VoiceMatchPolicy(threshold: 0.7, margin: 0.05, calendarBonus: 0.08, maximumAcousticGap: 0.04))
        let windows = [VoiceMatchWindow(start: 0, end: 4, embedding: vector(1, 0))]
        #expect(VoiceProfileMatcher.match(turnStart: 0, turnEnd: 4, windows: windows, catalogue: value,
            embeddingSpaceID: compatible, invitedContacts: ["invitee@example.invalid"], policy: policy) == .matched(invitee.id))
        for contacts in [[], ["Анна"], ["invitee@example.invalid", "invitee@example.invalid"]] {
            #expect(VoiceProfileMatcher.match(turnStart: 0, turnEnd: 4, windows: windows, catalogue: value,
                embeddingSpaceID: compatible, invitedContacts: contacts, policy: policy) == .refused(.ambiguous))
        }
    }

    @Test func fullCoverageAndUnanimousProfileAreRequired() throws {
        let value = catalogue(guestVector: vector(1, 0), inviteeVector: vector(0, 1))
        let policy = try #require(VoiceMatchPolicy(threshold: 0.7, margin: 0.05, calendarBonus: 0.04, maximumAcousticGap: 0.04))
        let first = VoiceMatchWindow(start: 2, end: 8, embedding: vector(1, 0))
        let second = VoiceMatchWindow(start: 6, end: 12, embedding: vector(0, 1))
        let agreeing = VoiceMatchWindow(start: 6, end: 12, embedding: vector(1, 0))
        #expect(VoiceProfileMatcher.match(turnStart: 2, turnEnd: 12, windows: [first, second], catalogue: value,
            embeddingSpaceID: compatible, invitedContacts: [], policy: policy) == .refused(.conflictingWindows))
        #expect(VoiceProfileMatcher.match(turnStart: 2, turnEnd: 12, windows: [first], catalogue: value,
            embeddingSpaceID: compatible, invitedContacts: [], policy: policy) == .refused(.incompleteCoverage))
        #expect(VoiceProfileMatcher.match(turnStart: 2, turnEnd: 12, windows: [agreeing, first], catalogue: value,
            embeddingSpaceID: compatible, invitedContacts: [], policy: policy) == .matched(guest.id))
    }

    @Test func anIncompatibleProfileAndInvalidQueryCannotProduceAnAutomaticName() throws {
        let policy = try #require(VoiceMatchPolicy(threshold: 0.7, margin: 0.05, calendarBonus: 0, maximumAcousticGap: 0))
        let value = catalogue(guestVector: vector(1, 0), inviteeVector: vector(0, 1), inviteeSpace: "different")
        let windows = [VoiceMatchWindow(start: 0, end: 4, embedding: vector(1, 0))]
        #expect(VoiceProfileMatcher.match(turnStart: 0, turnEnd: 4, windows: windows, catalogue: value,
            embeddingSpaceID: compatible, invitedContacts: [], policy: policy) == .refused(.insufficientProfiles))
        let invalid = [VoiceMatchWindow(start: 0, end: 4, embedding: vector(0, 0))]
        #expect(VoiceProfileMatcher.match(turnStart: 0, turnEnd: 4, windows: invalid,
            catalogue: catalogue(guestVector: vector(1, 0), inviteeVector: vector(0, 1)),
            embeddingSpaceID: compatible, invitedContacts: [], policy: policy) == .refused(.invalidEmbedding))
    }

    @Test func evaluateWindowExposesStrongLeaderEvenOnAmbiguousOrCalendarRejectedMatches() throws {
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0.3, maximumAcousticGap: 0.05))
        let value = catalogue(guestVector: vector(1, 0), inviteeVector: vector(0.6, 0.8))

        // Ambiguous margin (cos(guest)=0.94, cos(invitee)=0.8369 -> gap 0.103 < 0.15), yet strongLeaderID is guest.
        let close = VoiceProfileMatcher.evaluateWindow(
            VoiceMatchWindow(start: 0, end: 4, embedding: vector(0.94, 0.3411744)),
            catalogue: value, embeddingSpaceID: compatible, invitedContacts: [], policy: policy)
        #expect(close.matchedPersonID == nil)
        #expect(close.refusal == .ambiguous)
        #expect(close.strongLeaderID == guest.id)

        // Calendar bonus lifts invitee past guest in rank, fails maximumAcousticGap (.weakMatch),
        // yet acoustic strongLeaderID still reports guest.
        let displaced = catalogue(guestVector: vector(1, 0), inviteeVector: vector(0.8, 0.6))
        let acousticGapRejected = VoiceProfileMatcher.evaluateWindow(
            VoiceMatchWindow(start: 0, end: 4, embedding: vector(1, 0)),
            catalogue: displaced, embeddingSpaceID: compatible, invitedContacts: ["invitee@example.invalid"], policy: policy)
        #expect(acousticGapRejected.matchedPersonID == nil)
        #expect(acousticGapRejected.refusal == .weakMatch)
        #expect(acousticGapRejected.strongLeaderID == guest.id)

        // Below threshold -> strongLeaderID == nil.
        let unknown = VoiceProfileMatcher.evaluateWindow(
            VoiceMatchWindow(start: 0, end: 4, embedding: [0, 0, 1] + Array(repeating: 0, count: 253)),
            catalogue: value, embeddingSpaceID: compatible, invitedContacts: [], policy: policy)
        #expect(unknown.matchedPersonID == nil)
        #expect(unknown.refusal == .weakMatch)
        #expect(unknown.strongLeaderID == nil)
    }

    @Test func evaluateWindowReturnsAcousticStrongLeaderWhenCalendarBonusWins() throws {
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0.25, maximumAcousticGap: 0.1))
        let vecA: [Float] = [0.65, 0.7599342] + Array(repeating: 0, count: 254)
        let vecB: [Float] = [0.70, -0.71414284] + Array(repeating: 0, count: 254)
        let value = catalogue(guestVector: vecB, inviteeVector: vecA)
        let query = vector(1, 0)
        let evaluation = VoiceProfileMatcher.evaluateWindow(
            VoiceMatchWindow(start: 0, end: 4, embedding: query),
            catalogue: value, embeddingSpaceID: compatible,
            invitedContacts: ["invitee@example.invalid"], policy: policy)
        #expect(evaluation.matchedPersonID == invitee.id)
        #expect(evaluation.refusal == nil)
        #expect(evaluation.strongLeaderID == guest.id)
    }
}
