import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite final class TranscriptIntervalIndexTests {

    // MARK: - 1. Boundary Semantics: Half-Open [start, end)

    @Test func testSingleTurnBoundarySemantics() {
        let turn = TranscriptDocument.Turn(
            id: "t1",
            speakerID: "spk1",
            start: 1.0,
            end: 3.0,
            wordIDs: ["w1"]
        )
        let index = TranscriptIntervalIndex(turns: [turn])

        // Prior to start: inactive
        #expect(index.activeTurns(at: 0.999).isEmpty)
        #expect(index.firstActiveTurn(at: 0.999) == nil)

        // Exact start: active (inclusive)
        #expect(index.activeTurns(at: 1.0) == [turn])
        #expect(index.firstActiveTurn(at: 1.0) == turn)
        #expect(index.activeTurnIDs(at: 1.0) == ["t1"])
        #expect(index.firstActiveTurnID(at: 1.0) == "t1")
        #expect(index.activeTurnIndices(at: 1.0) == [0])

        // Mid-turn: active
        #expect(index.activeTurns(at: 2.0) == [turn])
        #expect(index.firstActiveTurn(at: 2.0) == turn)

        // Just before end: active
        #expect(index.activeTurns(at: 2.999) == [turn])
        #expect(index.firstActiveTurn(at: 2.999) == turn)

        // Exact end: inactive (exclusive)
        #expect(index.activeTurns(at: 3.0).isEmpty)
        #expect(index.firstActiveTurn(at: 3.0) == nil)
        #expect(index.activeTurnIDs(at: 3.0).isEmpty)
        #expect(index.firstActiveTurnID(at: 3.0) == nil)
        #expect(index.activeTurnIndices(at: 3.0).isEmpty)

        // After end: inactive
        #expect(index.activeTurns(at: 3.001).isEmpty)
    }

    // MARK: - 2. Contiguous Turns: Exact Boundary

    @Test func testContiguousTurnsBoundaryTransition() {
        let turnA = TranscriptDocument.Turn(id: "tA", speakerID: "spk1", start: 1.0, end: 2.0)
        let turnB = TranscriptDocument.Turn(id: "tB", speakerID: "spk2", start: 2.0, end: 3.0)
        let index = TranscriptIntervalIndex(turns: [turnA, turnB])

        // Just before boundary: turnA active
        #expect(index.activeTurns(at: 1.999) == [turnA])
        #expect(index.firstActiveTurn(at: 1.999) == turnA)

        // Exactly at boundary 2.0: turnB active, turnA inactive (no double counting)
        #expect(index.activeTurns(at: 2.0) == [turnB])
        #expect(index.firstActiveTurn(at: 2.0) == turnB)
        #expect(index.activeTurnIDs(at: 2.0) == ["tB"])

        // Mid second turn
        #expect(index.activeTurns(at: 2.5) == [turnB])

        // Exactly at end of turnB
        #expect(index.activeTurns(at: 3.0).isEmpty)
    }

    // MARK: - 3. Pauses and Gaps

    @Test func testPausesAndGaps() {
        let turn1 = TranscriptDocument.Turn(id: "t1", speakerID: "spk1", start: 1.0, end: 2.5)
        let turn2 = TranscriptDocument.Turn(id: "t2", speakerID: "spk1", start: 5.0, end: 7.0)
        let index = TranscriptIntervalIndex(turns: [turn1, turn2])

        // Before first turn
        #expect(index.activeTurns(at: 0.0).isEmpty)
        #expect(index.firstActiveTurn(at: 0.0) == nil)

        // In the pause gap between 2.5 and 5.0
        #expect(index.activeTurns(at: 2.5).isEmpty)
        #expect(index.activeTurns(at: 3.75).isEmpty)
        #expect(index.firstActiveTurn(at: 3.75) == nil)
        #expect(index.activeTurns(at: 4.999).isEmpty)

        // Inside second turn
        #expect(index.activeTurns(at: 5.0) == [turn2])

        // After last turn
        #expect(index.activeTurns(at: 7.0).isEmpty)
        #expect(index.activeTurns(at: 100.0).isEmpty)
    }

    // MARK: - 4. Overlapping Turns and Display Order

    @Test func testOverlappingTurnsPreserveDisplayOrder() {
        // Host and remote speaking simultaneously
        let hostTurn = TranscriptDocument.Turn(id: "tHost", speakerID: "spkHost", start: 1.0, end: 5.0)
        let remoteTurn = TranscriptDocument.Turn(id: "tRemote", speakerID: "spkRemote", start: 2.0, end: 4.0)
        let index = TranscriptIntervalIndex(turns: [hostTurn, remoteTurn])

        // At 1.5: only host
        #expect(index.activeTurns(at: 1.5) == [hostTurn])
        #expect(index.firstActiveTurn(at: 1.5) == hostTurn)

        // At 3.0: both are active, order is [hostTurn, remoteTurn] matching display order
        #expect(index.activeTurns(at: 3.0) == [hostTurn, remoteTurn])
        #expect(index.firstActiveTurn(at: 3.0) == hostTurn)
        #expect(index.activeTurnIDs(at: 3.0) == ["tHost", "tRemote"])
        #expect(index.firstActiveTurnID(at: 3.0) == "tHost")
        #expect(index.activeTurnIndices(at: 3.0) == [0, 1])

        // At 4.5: only host
        #expect(index.activeTurns(at: 4.5) == [hostTurn])
        #expect(index.firstActiveTurn(at: 4.5) == hostTurn)
    }

    // MARK: - 5. Nested Turns

    @Test func testNestedTurns() {
        let outer = TranscriptDocument.Turn(id: "outer", speakerID: "spk1", start: 0.0, end: 10.0)
        let inner = TranscriptDocument.Turn(id: "inner", speakerID: "spk2", start: 3.0, end: 6.0)
        let index = TranscriptIntervalIndex(turns: [outer, inner])

        #expect(index.activeTurns(at: 1.0) == [outer])
        #expect(index.activeTurns(at: 3.0) == [outer, inner])
        #expect(index.firstActiveTurn(at: 3.0) == outer)
        #expect(index.activeTurns(at: 5.5) == [outer, inner])
        #expect(index.activeTurns(at: 6.0) == [outer])
        #expect(index.activeTurns(at: 9.999) == [outer])
        #expect(index.activeTurns(at: 10.0).isEmpty)
    }

    // MARK: - 6. Equal Start Times Preserve Display Order

    @Test func testEqualStartTimesPreserveDisplayOrder() {
        let turn1 = TranscriptDocument.Turn(id: "t1", speakerID: "spk1", start: 2.0, end: 6.0)
        let turn2 = TranscriptDocument.Turn(id: "t2", speakerID: "spk2", start: 2.0, end: 4.0)
        let index = TranscriptIntervalIndex(turns: [turn1, turn2])

        // At start time 2.0: both start, turn1 first in display order
        #expect(index.activeTurns(at: 2.0) == [turn1, turn2])
        #expect(index.firstActiveTurn(at: 2.0) == turn1)
        #expect(index.firstActiveTurnID(at: 2.0) == "t1")

        // In reverse input order: turn2 first, turn1 second
        let reversedIndex = TranscriptIntervalIndex(turns: [turn2, turn1])
        #expect(reversedIndex.activeTurns(at: 2.0) == [turn2, turn1])
        #expect(reversedIndex.firstActiveTurn(at: 2.0) == turn2)
        #expect(reversedIndex.firstActiveTurnID(at: 2.0) == "t2")
    }

    // MARK: - 7. Out-of-Order Display Order Preserved

    @Test func testOutOfOrderDisplayTurnsPreserveDisplayOrder() {
        // Turns appear out of chronological order in document
        let turnLaterStart = TranscriptDocument.Turn(id: "tLater", speakerID: "spk1", start: 5.0, end: 8.0)
        let turnEarlierStart = TranscriptDocument.Turn(id: "tEarlier", speakerID: "spk2", start: 2.0, end: 6.0)
        let index = TranscriptIntervalIndex(turns: [turnLaterStart, turnEarlierStart])

        // At 5.5: both are active. Display order in index is [tLater, tEarlier]
        #expect(index.activeTurns(at: 5.5) == [turnLaterStart, turnEarlierStart])
        #expect(index.firstActiveTurn(at: 5.5) == turnLaterStart)
        #expect(index.firstActiveTurnID(at: 5.5) == "tLater")
        #expect(index.activeTurnIndices(at: 5.5) == [0, 1])

        // At 3.0: only tEarlier is active (even though it's at index 1)
        #expect(index.activeTurns(at: 3.0) == [turnEarlierStart])
        #expect(index.firstActiveTurn(at: 3.0) == turnEarlierStart)
        #expect(index.activeTurnIndices(at: 3.0) == [1])
    }

    // MARK: - 8. Zero-Duration Turns Are Never Active

    @Test func testZeroDurationTurnsNeverActive() {
        let zeroTurn = TranscriptDocument.Turn(id: "tZero", speakerID: "spk1", start: 4.0, end: 4.0)
        let normalTurn = TranscriptDocument.Turn(id: "tNormal", speakerID: "spk2", start: 3.0, end: 5.0)
        let index = TranscriptIntervalIndex(turns: [zeroTurn, normalTurn])

        // At exact timestamp 4.0: normalTurn is active, zeroTurn is NOT active
        #expect(index.activeTurns(at: 4.0) == [normalTurn])
        #expect(index.firstActiveTurn(at: 4.0) == normalTurn)

        // Standalone zero turn index
        let standaloneZero = TranscriptIntervalIndex(turns: [zeroTurn])
        #expect(standaloneZero.activeTurns(at: 3.999).isEmpty)
        #expect(standaloneZero.activeTurns(at: 4.0).isEmpty)
        #expect(standaloneZero.activeTurns(at: 4.001).isEmpty)
        #expect(standaloneZero.firstActiveTurn(at: 4.0) == nil)
    }

    // MARK: - 9. Invalid and Non-Finite Queries Return None Without Crashing

    @Test func testInvalidQueriesDoNotCrash() {
        let turn = TranscriptDocument.Turn(id: "t1", speakerID: "spk1", start: 1.0, end: 5.0)
        let index = TranscriptIntervalIndex(turns: [turn])

        // NaN
        #expect(index.activeTurns(at: Double.nan).isEmpty)
        #expect(index.firstActiveTurn(at: Double.nan) == nil)
        #expect(index.activeTurnIDs(at: Double.nan).isEmpty)
        #expect(index.firstActiveTurnID(at: Double.nan) == nil)
        #expect(index.activeTurnIndices(at: Double.nan).isEmpty)

        // Positive Infinity
        #expect(index.activeTurns(at: Double.infinity).isEmpty)
        #expect(index.firstActiveTurn(at: Double.infinity) == nil)

        // Negative Infinity
        #expect(index.activeTurns(at: -Double.infinity).isEmpty)
        #expect(index.firstActiveTurn(at: -Double.infinity) == nil)

        // Negative timestamp
        #expect(index.activeTurns(at: -1.0).isEmpty)
        #expect(index.firstActiveTurn(at: -1.0) == nil)
    }

    // MARK: - 10. Empty Document or Turns

    @Test func testEmptyTurns() {
        let emptyIndex = TranscriptIntervalIndex(turns: [])
        #expect(emptyIndex.activeTurns(at: 0.0).isEmpty)
        #expect(emptyIndex.firstActiveTurn(at: 0.0) == nil)
        #expect(emptyIndex.activeTurnIDs(at: 5.0).isEmpty)
        #expect(emptyIndex.firstActiveTurnID(at: 5.0) == nil)
        #expect(emptyIndex.activeTurnIndices(at: 5.0).isEmpty)
    }

    // MARK: - 11. Seek Arbitrary Access Leaves Shared Timeline Unchanged

    @Test func testSeekStatelessArbitraryTimelineAccess() {
        let t1 = TranscriptDocument.Turn(id: "t1", speakerID: "s1", start: 0.0, end: 10.0)
        let t2 = TranscriptDocument.Turn(id: "t2", speakerID: "s2", start: 20.0, end: 30.0)
        let t3 = TranscriptDocument.Turn(id: "t3", speakerID: "s3", start: 40.0, end: 50.0)
        let index = TranscriptIntervalIndex(turns: [t1, t2, t3])

        // Seek forward to t=25
        #expect(index.activeTurns(at: 25.0) == [t2])

        // Seek forward to t=45
        #expect(index.activeTurns(at: 45.0) == [t3])

        // Seek backward to t=5
        #expect(index.activeTurns(at: 5.0) == [t1])

        // Seek into gap t=15
        #expect(index.activeTurns(at: 15.0).isEmpty)

        // Re-seek backward to t=5 (stateless check)
        #expect(index.activeTurns(at: 5.0) == [t1])

        // Re-seek forward to t=25
        #expect(index.activeTurns(at: 25.0) == [t2])
    }

    // MARK: - 12. Word-Level Interval Lookup

    @Test func testWordLevelIntervalLookup() {
        let w1 = TranscriptDocument.Word(id: "w1", speakerID: "spk1", start: 1.0, end: 1.5, text: "Привет")
        let w2 = TranscriptDocument.Word(id: "w2", speakerID: "spk1", start: 1.5, end: 2.0, text: "мир")
        let index = TranscriptIntervalIndex(turns: [], words: [w1, w2])

        #expect(index.activeWords(at: 1.0) == [w1])
        #expect(index.firstActiveWord(at: 1.0) == w1)

        #expect(index.activeWords(at: 1.499) == [w1])

        // Boundary between words: w1 ends, w2 starts
        #expect(index.activeWords(at: 1.5) == [w2])
        #expect(index.firstActiveWord(at: 1.5) == w2)

        #expect(index.activeWords(at: 2.0).isEmpty)
        #expect(index.firstActiveWord(at: 2.0) == nil)
    }

    // MARK: - 13. Document Initialization & Integration

    @Test func testDocumentInitialization() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/transcript-document/valid_parakeet_off.json")
        let document = try TranscriptDocument.load(from: fixtureURL, recordingDirectory: fixtureURL.deletingLastPathComponent())
        let index = TranscriptIntervalIndex(document: document)

        #expect(index.turns.count == document.turns.count)
        #expect(index.words.count == document.words.count)

        // Query first turn's start time
        if let firstTurn = document.turns.first {
            let active = index.activeTurns(at: firstTurn.start)
            #expect(active.contains(where: { $0.id == firstTurn.id }))
            #expect(index.firstActiveTurn(at: firstTurn.start)?.id == firstTurn.id)
        }
    }
}
