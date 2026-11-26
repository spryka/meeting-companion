import Foundation
import MeetingCompanionCore
import Testing
@testable import MeetingCompanionApp

@MainActor
struct TranscriptRowParityTests {
    @Test func onlyAdjacentMatchingNamedRowsContinue() {
        typealias Row = TranscriptReviewWindowModel.Row
        let person = UUID()

        func row(_ id: String, name: String = "Анна", personID: UUID? = nil,
                 origin: String? = "automaticVoiceMatch", voice: String = "speaker-1",
                 source: TranscriptDocument.SourceID = .host, named: Bool = true) -> Row {
            Row(id: id, start: 0, name: name, text: id, speakerID: voice, sourceID: source,
                hasSavedName: named, nameOrigin: origin, personID: personID)
        }

        let rows = [
            row("first", personID: person),
            row("automatic-continuation", personID: person),
            row("manual", personID: person, origin: "manual"),
            row("namesake", personID: UUID(), origin: "manual"),
            row("return", personID: person),
            row("renamed", name: "Анна Л.", personID: person),
            row("other-voice", name: "Анна Л.", personID: person, voice: "speaker-2"),
            row("other-source", name: "Анна Л.", personID: person, voice: "speaker-2", source: .remote),
            row("unknown-identity", name: "Анна Л.", voice: "speaker-2", source: .remote),
            row("unknown-identity-continuation", name: "Анна Л.", voice: "speaker-2", source: .remote),
            row("legacy", origin: nil),
            row("legacy-continuation", origin: nil),
            row("unnamed-first", name: "Speaker 1", origin: nil, named: false),
            row("unnamed-second", name: "Speaker 1", origin: nil, named: false),
            row("after-unnamed", origin: nil)
        ]

        #expect(TranscriptReviewWindowModel.continuationTurnIDs(in: rows) == [
            "automatic-continuation", "unknown-identity-continuation", "legacy-continuation"
        ])
    }

    @Test func editingTheMiddleTurnRecomputesBothBoundaries() async throws {
        let fixture = try SpeakerReviewFixture(voiceCount: 1, turnsPerVoice: 4)
        defer { fixture.close() }
        let edits = TranscriptEditsRepository(recordingDirectory: fixture.root)
        let assignment = TranscriptTurnOverride(displayName: "Анна", assignment: .init(
            personID: UUID(), origin: "automaticVoiceMatch"))
        _ = try edits.saveEdits(resultID: "v1", overrides: ["t0": assignment, "t1": assignment, "t2": assignment])
        let model = try await fixture.open(repository: edits)

        #expect(TranscriptReviewWindowModel.continuationTurnIDs(in: model.rows) == ["t1", "t2"])
        model.openVoiceReview(anchorTurnID: "t1")
        #expect(model.voiceDraft?.anchorTurnID == "t1" && model.voiceDraft?.scope == .single)
        model.updateVoiceName("Мария")
        model.confirmVoiceAssignment(try #require(model.voiceDraft))
        #expect(model.rows.map(\.name) == ["Анна", "Мария", "Анна", "Speaker 1"])
        #expect(TranscriptReviewWindowModel.continuationTurnIDs(in: model.rows).isEmpty)
    }
}
