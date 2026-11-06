import Foundation
import Testing
import MeetingCompanionCore

@Suite struct TranscriptReadingFocusTests {
    @Test func overlapExpiresWithoutReturningAndSeekIsStateless() {
        let turns = [
            TranscriptDocument.Turn(id: "a", speakerID: "a", start: 10, end: 20),
            TranscriptDocument.Turn(id: "b", speakerID: "b", start: 11, end: 11.5),
            TranscriptDocument.Turn(id: "c", speakerID: "a", start: 12.2, end: 13)
        ]
        let index = TranscriptIntervalIndex(turns: turns)
        #expect(index.activeTurnIDs(at: 11.2) == ["a", "b"])
        #expect(index.activeTurnIDs(at: 14) == ["a"])
        for (time, expected) in [(10.0, "a"), (11.0, "b"), (11.49, "b"), (11.5, nil),
                                 (12.2, "c"), (13.0, nil), (10.5, "a"), (14.0, nil), (9.0, nil)] {
            #expect(index.readingFocusTurnID(at: time) == expected)
        }
        #expect(index.turns == turns)
    }

    @Test func tiesUseDisplayOrderZeroDurationDoesNotStealFocus() {
        let index = TranscriptIntervalIndex(turns: [
            .init(id: "laterStart", speakerID: "a", start: 9, end: 10),
            .init(id: "tie1", speakerID: "a", start: 5, end: 8),
            .init(id: "tie2", speakerID: "b", start: 5, end: 6),
            .init(id: "zero", speakerID: "b", start: 5, end: 5),
            .init(id: "laterZero", speakerID: "a", start: 5.5, end: 5.5),
            .init(id: "nan", speakerID: "a", start: .nan, end: 20),
            .init(id: "infinite", speakerID: "a", start: 5.8, end: .infinity),
            .init(id: "reversed", speakerID: "a", start: 5.9, end: 5)
        ])
        #expect(index.readingFocusTurnID(at: 5) == "tie2")
        #expect(index.readingFocusTurnID(at: 5.75) == "tie2")
        #expect(index.readingFocusTurnID(at: 5.95) == "tie2")
        #expect(index.readingFocusTurnID(at: 6) == nil)
        #expect(index.readingFocusTurnID(at: 9) == "laterStart")
        for invalid in [-1, Double.nan, .infinity, -.infinity] {
            #expect(index.readingFocusTurnID(at: invalid) == nil)
        }
        #expect(TranscriptIntervalIndex(turns: []).readingFocusTurnID(at: 0) == nil)
    }
}
