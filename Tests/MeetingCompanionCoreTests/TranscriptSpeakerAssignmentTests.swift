import Foundation
import Testing
import CryptoKit
@testable import MeetingCompanionCore

@Suite final class TranscriptSpeakerAssignmentTests {
    private var cleanup: [URL] = []

    deinit {
        for url in cleanup {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/transcript-document")

    private func fixture(_ name: String) -> URL {
        fixtures.appendingPathComponent(name + ".json")
    }

    private func temporaryDirectory(_ prefix: String = "TranscriptSpeakerAssignmentTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            prefix + "-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        return directory
    }

    private func computeSHA256(for fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Creates a synthetic recording with a document that has:
    /// - Host speaker `spk_h1` (source: host, localID: 1, displayNumber: 1) with `turn_1` and `turn_3`
    /// - Remote speaker `spk_r1` (source: remote, localID: 1, displayNumber: 2) with `turn_2`
    /// This allows testing group operations (>= 2 turns) and independent host/remote local IDs.
    private func createSyntheticRecordingWithMultiTurns(
        in root: URL,
        resultID: String = "res_test_turns"
    ) throws -> (resultURL: URL, versionDir: URL, audioURLs: [URL]) {
        let rawDir = root.appendingPathComponent("raw")
        let transcriptsDir = rawDir.appendingPathComponent("transcripts")
        let versionDir = transcriptsDir.appendingPathComponent(resultID)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let fixtureData = try Data(contentsOf: fixture("valid_parakeet_off"))
        var docJson = try #require(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        docJson["resultID"] = resultID

        if var pb = docJson["playback"] as? [String: Any] {
            pb["mixPath"] = "raw/transcripts/\(resultID)/mix.m4a"
            docJson["playback"] = pb
        }

        // Add words for turn_3
        var words = try #require(docJson["words"] as? [[String: Any]])
        words.append([
            "id": "w_4",
            "speakerID": "spk_h1",
            "start": 3.0,
            "end": 3.5,
            "text": "Ещё"
        ])
        words.append([
            "id": "w_5",
            "speakerID": "spk_h1",
            "start": 3.6,
            "end": 4.0,
            "text": "реплика"
        ])
        docJson["words"] = words

        var baselineWords = try #require(docJson["baselineWords"] as? [[String: Any]])
        baselineWords.append([
            "id": "bw_4",
            "speakerID": "spk_h1",
            "start": 3.0,
            "end": 3.5,
            "text": "Ещё"
        ])
        baselineWords.append([
            "id": "bw_5",
            "speakerID": "spk_h1",
            "start": 3.6,
            "end": 4.0,
            "text": "реплика"
        ])
        docJson["baselineWords"] = baselineWords

        // Add turn_3 for spk_h1 (so spk_h1 has turn_1 and turn_3)
        var turns = try #require(docJson["turns"] as? [[String: Any]])
        turns.append([
            "id": "turn_3",
            "speakerID": "spk_h1",
            "start": 3.0,
            "end": 4.0,
            "wordIDs": ["w_4", "w_5"]
        ])
        docJson["turns"] = turns

        let resultData = try JSONSerialization.data(withJSONObject: docJson, options: [.sortedKeys])
        let resultURL = versionDir.appendingPathComponent("result.json")
        try resultData.write(to: resultURL)

        // Write synthetic audio files
        let hostAudio = rawDir.appendingPathComponent("meeting.host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("meeting.remote_record.wav")
        let mixAudio = versionDir.appendingPathComponent("mix.m4a")
        let dummyBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        try dummyBytes.write(to: hostAudio)
        try dummyBytes.write(to: remoteAudio)
        try dummyBytes.write(to: mixAudio)

        // Validate that production reader accepts this document
        _ = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)

        return (resultURL, versionDir, [hostAudio, remoteAudio, mixAudio])
    }

    @Test func workspaceSameEffectiveNameIsNoOp() throws {
        let root = try temporaryDirectory()
        let (_, version, _) = try createSyntheticRecordingWithMultiTurns(in: root)
        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)
        let edits = try service.assignSpeakerName(resultID: "res_test_turns", turnID: "turn_1", displayName: "Speaker 1")
        #expect(edits.revision == 0)
        #expect(!FileManager.default.fileExists(atPath: version.appendingPathComponent("edits.json").path))
    }

    @Test func workspaceRemainingPreviewSkipsEarlierAndSameName() throws {
        let root = try temporaryDirectory()
        _ = try createSyntheticRecordingWithMultiTurns(in: root)
        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)
        _ = try service.assignSpeakerName(resultID: "res_test_turns", turnID: "turn_3", displayName: "Ручное")
        let preview = try service.previewRemainingAssignment(resultID: "res_test_turns", anchorTurnID: "turn_3", displayName: "Аня")
        #expect(preview.targetTurnIDs == ["turn_3"])
        #expect(preview.affectedTurnsCount == 1)
        #expect(preview.replacedManualAssignmentsCount == 1)
        let saved = try service.assignSpeakerName(preview: preview, displayName: "Аня")
        #expect(saved.overrides["turn_1"] == nil)
        #expect(saved.overrides["turn_2"] == nil)
        #expect(saved.overrides["turn_3"]?.displayName == "Аня")
        let noop = try service.previewRemainingAssignment(resultID: "res_test_turns", anchorTurnID: "turn_3", displayName: "Аня")
        #expect(noop.affectedTurnsCount == 0)
        #expect(noop.replacedManualAssignmentsCount == 0)
        #expect(throws: Error.self) { try service.assignSpeakerName(preview: noop, displayName: "Другое") }
    }

    // MARK: - 1. Single Turn Assignment Only

    @Test func testSingleTurnAssignmentOnly() throws {
        let root = try temporaryDirectory()
        let resultID = "res_single_turn"
        let (_, _, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // Assign to turn_1 only
        let edits = try service.assignSpeakerName(resultID: resultID, turnID: "turn_1", displayName: "Алиса")

        #expect(edits.revision == 1)
        #expect(edits.overrides["turn_1"]?.displayName == "Алиса")
        #expect(edits.overrides["turn_2"] == nil || edits.overrides["turn_2"]?.displayName == nil)
        #expect(edits.overrides["turn_3"] == nil || edits.overrides["turn_3"]?.displayName == nil)

        // Reopen from disk to verify durable persistence
        let reopened = try TranscriptEditsRepository(recordingDirectory: root).loadEdits(resultID: resultID)
        #expect(reopened.revision == 1)
        #expect(reopened.overrides["turn_1"]?.displayName == "Алиса")
        #expect(reopened.overrides["turn_2"]?.displayName == nil)
        #expect(reopened.overrides["turn_3"]?.displayName == nil)
    }

    // MARK: - 2. Group >= 2 / Host and Remote Equal LocalID Unaffected

    @Test func testGroupAssignmentHostAndRemoteEqualLocalIDUnaffected() throws {
        let root = try temporaryDirectory()
        let resultID = "res_group_assign"
        let (_, _, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // spk_h1 is host localID 1 (turns: turn_1, turn_3)
        // spk_r1 is remote localID 1 (turn: turn_2)
        let voiceHost1 = TranscriptVoiceKey(sourceID: .host, localID: 1)
        let edits = try service.assignSpeakerName(
            resultID: resultID,
            voice: voiceHost1,
            displayName: "Хост Голос 1",
            replaceManuallyAssigned: false
        )

        // Both turn_1 and turn_3 belong to spk_h1 and must have the new displayName
        #expect(edits.overrides["turn_1"]?.displayName == "Хост Голос 1")
        #expect(edits.overrides["turn_3"]?.displayName == "Хост Голос 1")

        // turn_2 belongs to remote localID 1 and must remain unaffected
        #expect(edits.overrides["turn_2"]?.displayName == nil)

        // Verify disk state
        let reopened = try TranscriptEditsRepository(recordingDirectory: root).loadEdits(resultID: resultID)
        #expect(reopened.overrides["turn_1"]?.displayName == "Хост Голос 1")
        #expect(reopened.overrides["turn_3"]?.displayName == "Хост Голос 1")
        #expect(reopened.overrides["turn_2"]?.displayName == nil)
    }

    // MARK: - 3. Manual Replacement Count + Text Preservation

    @Test func testManualReplacementCountAndTextPreservation() throws {
        let root = try temporaryDirectory()
        let resultID = "res_manual_replace"
        let (_, _, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // Precondition: turn_1 has manual name "Ручное Имя" AND corrected text "Исправленный текст 1"
        // turn_3 has corrected text "Исправленный текст 3" but NO manual name
        _ = try repo.saveEdits(resultID: resultID, overrides: [
            "turn_1": TranscriptTurnOverride(text: "Исправленный текст 1", displayName: "Ручное Имя"),
            "turn_3": TranscriptTurnOverride(text: "Исправленный текст 3", displayName: nil)
        ])

        // Preview checks
        let previewNoReplace = try service.previewGroupAssignment(
            resultID: resultID,
            speakerID: "spk_h1",
            replaceManuallyAssigned: false
        )
        #expect(previewNoReplace.sourceID == .host)
        #expect(previewNoReplace.localID == 1)
        #expect(previewNoReplace.speakerID == "spk_h1")
        #expect(previewNoReplace.totalTurnsInGroup == 2)
        #expect(previewNoReplace.replacedManualAssignmentsCount == 0)
        #expect(previewNoReplace.affectedTurnsCount == 1) // Only turn_3 affected

        let previewWithReplace = try service.previewGroupAssignment(
            resultID: resultID,
            speakerID: "spk_h1",
            replaceManuallyAssigned: true
        )
        #expect(previewWithReplace.totalTurnsInGroup == 2)
        #expect(previewWithReplace.replacedManualAssignmentsCount == 1)
        #expect(previewWithReplace.affectedTurnsCount == 2) // Both turn_1 and turn_3 affected

        // 1. Group assign with replaceManuallyAssigned: false
        let edits1 = try service.assignSpeakerName(
            resultID: resultID,
            speakerID: "spk_h1",
            displayName: "Группа А",
            replaceManuallyAssigned: false
        )

        // turn_1 must retain its manual name AND corrected text
        #expect(edits1.overrides["turn_1"]?.displayName == "Ручное Имя")
        #expect(edits1.overrides["turn_1"]?.text == "Исправленный текст 1")

        // turn_3 gets the group name AND retains its corrected text
        #expect(edits1.overrides["turn_3"]?.displayName == "Группа А")
        #expect(edits1.overrides["turn_3"]?.text == "Исправленный текст 3")

        // 2. Group assign with replaceManuallyAssigned: true
        let edits2 = try service.assignSpeakerName(
            resultID: resultID,
            speakerID: "spk_h1",
            displayName: "Новая Группа",
            replaceManuallyAssigned: true
        )

        // turn_1 gets the new group name AND still preserves corrected text
        #expect(edits2.overrides["turn_1"]?.displayName == "Новая Группа")
        #expect(edits2.overrides["turn_1"]?.text == "Исправленный текст 1")

        // turn_3 gets the new group name AND still preserves corrected text
        #expect(edits2.overrides["turn_3"]?.displayName == "Новая Группа")
        #expect(edits2.overrides["turn_3"]?.text == "Исправленный текст 3")
    }

    // MARK: - 4. Group Undo One Operation Restores Full Prior State (Disk + Reopen)

    @Test func testGroupUndoOneOperationRestoresFullPriorStateActualDiskAndReopen() throws {
        let root = try temporaryDirectory()
        let resultID = "res_group_undo"
        let (_, _, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // Set initial state
        _ = try repo.saveEdits(resultID: resultID, overrides: [
            "turn_1": TranscriptTurnOverride(text: "Текст 1", displayName: "Автор Исходный"),
            "turn_3": TranscriptTurnOverride(text: "Текст 3", displayName: nil)
        ])

        #expect(repo.canUndo(resultID: resultID))

        // Bulk assign to spk_h1 (replaces all in group)
        let modified = try service.assignSpeakerName(
            resultID: resultID,
            speakerID: "spk_h1",
            displayName: "Массовое Имя",
            replaceManuallyAssigned: true
        )
        #expect(modified.overrides["turn_1"]?.displayName == "Массовое Имя")
        #expect(modified.overrides["turn_3"]?.displayName == "Массовое Имя")

        // Perform single undo
        let undone = try repo.undo(resultID: resultID)
        #expect(undone.overrides["turn_1"]?.displayName == "Автор Исходный")
        #expect(undone.overrides["turn_1"]?.text == "Текст 1")
        #expect(undone.overrides["turn_3"]?.displayName == nil)
        #expect(undone.overrides["turn_3"]?.text == "Текст 3")

        // Reopen from disk to prove disk matches
        let diskEdits = try TranscriptEditsRepository(recordingDirectory: root).loadEdits(resultID: resultID)
        #expect(diskEdits.overrides["turn_1"]?.displayName == "Автор Исходный")
        #expect(diskEdits.overrides["turn_1"]?.text == "Текст 1")
        #expect(diskEdits.overrides["turn_3"]?.displayName == nil)
        #expect(diskEdits.overrides["turn_3"]?.text == "Текст 3")
    }

    // MARK: - 5. All Result and Audio Bytes Preserved

    @Test func testAllResultAndAudioBytesPreserved() throws {
        let root = try temporaryDirectory()
        let resultID = "res_bytes_preserve"
        let (resultURL, _, audioURLs) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let resultHashBefore = try computeSHA256(for: resultURL)
        var audioHashesBefore: [URL: String] = [:]
        for audioURL in audioURLs {
            audioHashesBefore[audioURL] = try computeSHA256(for: audioURL)
        }

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // Multiple operations: single assign, group assign, unassign, undo
        _ = try service.assignSpeakerName(resultID: resultID, turnID: "turn_1", displayName: "Имя 1")
        _ = try service.assignSpeakerName(resultID: resultID, speakerID: "spk_h1", displayName: "Группа", replaceManuallyAssigned: true)
        _ = try service.unassignSpeakerName(resultID: resultID, turnID: "turn_3")
        _ = try repo.undo(resultID: resultID)

        // Re-verify hashes
        let resultHashAfter = try computeSHA256(for: resultURL)
        #expect(resultHashAfter == resultHashBefore)

        for audioURL in audioURLs {
            let hashAfter = try computeSHA256(for: audioURL)
            #expect(hashAfter == audioHashesBefore[audioURL])
        }
    }

    // MARK: - 6. Unknown IDs / Names Error No History / File Mutation

    @Test func testUnknownIDsAndInvalidNamesThrowErrorNoHistoryOrFileMutation() throws {
        let root = try temporaryDirectory()
        let resultID = "res_error_checks"
        let (_, versionDir, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let editsFile = versionDir.appendingPathComponent("edits.json")
        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // 1. Unknown turnID
        #expect {
            try service.assignSpeakerName(resultID: resultID, turnID: "unknown_turn", displayName: "Алиса")
        } throws: { error in
            if case .invalidReference = (error as? TranscriptEditsError) { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))
        #expect(!repo.canUndo(resultID: resultID))

        // 2. Unknown speakerID
        #expect {
            try service.assignSpeakerName(resultID: resultID, speakerID: "unknown_spk", displayName: "Алиса", replaceManuallyAssigned: false)
        } throws: { error in
            if case .invalidReference = (error as? TranscriptEditsError) { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))
        #expect(!repo.canUndo(resultID: resultID))

        // 3. Unknown voice key
        #expect {
            try service.assignSpeakerName(resultID: resultID, voice: TranscriptVoiceKey(sourceID: .host, localID: 99), displayName: "Алиса", replaceManuallyAssigned: false)
        } throws: { error in
            if case .invalidReference = (error as? TranscriptEditsError) { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // 4. Empty displayName
        #expect {
            try service.assignSpeakerName(resultID: resultID, turnID: "turn_1", displayName: "")
        } throws: { error in
            if case .malformed = (error as? TranscriptEditsError) { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // 5. Blank whitespace displayName
        #expect {
            try service.assignSpeakerName(resultID: resultID, turnID: "turn_1", displayName: "   \t\n  ")
        } throws: { error in
            if case .malformed = (error as? TranscriptEditsError) { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // 6. Unknown turnID on unassign
        #expect {
            try service.unassignSpeakerName(resultID: resultID, turnID: "unknown_turn")
        } throws: { error in
            if case .invalidReference = (error as? TranscriptEditsError) { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // 7. Unknown speakerID on preview
        #expect {
            try service.previewGroupAssignment(resultID: resultID, speakerID: "unknown_spk", replaceManuallyAssigned: false)
        } throws: { error in
            if case .invalidReference = (error as? TranscriptEditsError) { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))
    }

    // MARK: - 7. Unassign Name Removes DisplayName, Keeps Corrected Text

    @Test func testUnassignNameRemovesDisplayNameKeepsCorrectedText() throws {
        let root = try temporaryDirectory()
        let resultID = "res_unassign"
        let (_, _, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // Setup turn_1 with both text override and manual name
        _ = try repo.saveEdits(resultID: resultID, overrides: [
            "turn_1": TranscriptTurnOverride(text: "Исправленный текст", displayName: "Алиса")
        ])

        // Unassign single turn
        let unassigned = try service.unassignSpeakerName(resultID: resultID, turnID: "turn_1")
        #expect(unassigned.overrides["turn_1"]?.displayName == nil)
        #expect(unassigned.overrides["turn_1"]?.text == "Исправленный текст")

        // Unassign group
        _ = try service.assignSpeakerName(resultID: resultID, speakerID: "spk_h1", displayName: "Группа", replaceManuallyAssigned: true)
        let groupUnassigned = try service.unassignSpeakerName(resultID: resultID, speakerID: "spk_h1")
        #expect(groupUnassigned.overrides["turn_1"]?.displayName == nil)
        #expect(groupUnassigned.overrides["turn_1"]?.text == "Исправленный текст")
        #expect(groupUnassigned.overrides["turn_3"]?.displayName == nil)
    }

    // MARK: - 8. Session Controller API and Closed Lifecycle Safety

    @Test @MainActor func testSessionControllerAPIAndClosedLifecycleSafety() throws {
        let root = try temporaryDirectory()
        let resultID = "res_session_safety"
        let (_, _, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let session = try #require(try TranscriptReviewSession.open(recordingDirectory: root))
        #expect(session.activeResultID == resultID)

        // Normal operation through session API (controller hook)
        let edits = try session.assignSpeakerName(turnID: "turn_1", displayName: "Имя Сессии")
        #expect(edits.overrides["turn_1"]?.displayName == "Имя Сессии")

        // Close session
        session.close()
        #expect(session.isClosed)

        // All subsequent calls must throw TranscriptReviewSessionError.closed
        #expect(throws: TranscriptReviewSessionError.closed) {
            try session.assignSpeakerName(turnID: "turn_1", displayName: "Новое Имя")
        }
        #expect(throws: TranscriptReviewSessionError.closed) {
            try session.assignSpeakerName(speakerID: "spk_h1", displayName: "Группа", replaceManuallyAssigned: false)
        }
        #expect(throws: TranscriptReviewSessionError.closed) {
            try session.assignSpeakerName(voice: TranscriptVoiceKey(sourceID: .host, localID: 1), displayName: "Группа", replaceManuallyAssigned: false)
        }
        #expect(throws: TranscriptReviewSessionError.closed) {
            try session.unassignSpeakerName(turnID: "turn_1")
        }
        #expect(throws: TranscriptReviewSessionError.closed) {
            try session.unassignSpeakerName(speakerID: "spk_h1")
        }
        #expect(throws: TranscriptReviewSessionError.closed) {
            try session.previewGroupAssignment(speakerID: "spk_h1", replaceManuallyAssigned: false)
        }
        #expect(throws: TranscriptReviewSessionError.closed) {
            try session.undo()
        }
    }

    // MARK: - 9. External Revision 50 Throws Conflict And Preserves Undo

    @Test func testExternalRevision50ThrowsConflictAndPreservesUndo() throws {
        let root = try temporaryDirectory()
        let resultID = "res_ext_rev50"
        let (_, versionDir, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // 1. Initial local save: revision 1 with turn_1
        let initialEdits = try service.assignSpeakerName(resultID: resultID, turnID: "turn_1", displayName: "Локальный Автор")
        #expect(initialEdits.revision == 1)
        #expect(repo.canUndo(resultID: resultID))

        // 2. External writer modifies edits.json on disk to revision 50 with external name
        let editsFile = versionDir.appendingPathComponent("edits.json")
        let externalJSON = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 50,
            "overrides": {
                "turn_1": {
                    "text": "Внешний текст",
                    "displayName": "Внешний Автор 50"
                }
            }
        }
        """
        try Data(externalJSON.utf8).write(to: editsFile)

        // 3. Service attempts assignment using existing snapshot
        // Must detect external modification and throw conflict, NOT silently adopt revision 50 or clear undo!
        #expect {
            try service.assignSpeakerName(resultID: resultID, turnID: "turn_1", displayName: "Перезапись")
        } throws: { error in
            if case .conflict = (error as? TranscriptEditsError) { return true }
            return false
        }

        // 4. Verify disk bytes were NOT overwritten
        let diskEdits = try JSONDecoder().decode(TranscriptEdits.self, from: Data(contentsOf: editsFile))
        #expect(diskEdits.revision == 50)
        #expect(diskEdits.overrides["turn_1"]?.displayName == "Внешний Автор 50")

        // 5. Undo history was preserved
        #expect(repo.canUndo(resultID: resultID))
    }

    // MARK: - 10. Preview Apply Stale Conflict When Intermediate Assignment Changes

    @Test func testPreviewApplyStaleConflictWhenIntermediateAssignmentChanges() throws {
        let root = try temporaryDirectory()
        let resultID = "res_preview_stale"
        let (_, _, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // Generate preview for spk_h1 (turns: turn_1, turn_3) with replaceManuallyAssigned: false
        let preview = try service.previewGroupAssignment(
            resultID: resultID,
            speakerID: "spk_h1",
            replaceManuallyAssigned: false
        )
        #expect(preview.affectedTurnsCount == 2)
        #expect(preview.replacedManualAssignmentsCount == 0)

        // Intermediate manual assignment made to turn_3
        _ = try service.assignSpeakerName(resultID: resultID, turnID: "turn_3", displayName: "Промежуточный Автор")

        // Attempting to apply stale preview must throw conflict
        #expect {
            try service.assignSpeakerName(preview: preview, displayName: "Групповое Имя")
        } throws: { error in
            if case .conflict = (error as? TranscriptEditsError) { return true }
            return false
        }

        // Verify turn_3 was NOT overwritten
        let currentEdits = try repo.loadEdits(resultID: resultID)
        #expect(currentEdits.overrides["turn_3"]?.displayName == "Промежуточный Автор")
    }

    // MARK: - 11. Deterministic Concurrent Text And Speaker Assignment Preserves Latest Text

    @Test func testDeterministicConcurrentTextAndSpeakerAssignmentPreservesLatestText() throws {
        let root = try temporaryDirectory()
        let resultID = "res_concurrent_gate"
        let (_, _, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        final class HookBox: @unchecked Sendable {
            var shouldPause = false
        }
        let hookBox = HookBox()
        let inHook = DispatchSemaphore(value: 0)
        let allowCommit = DispatchSemaphore(value: 0)

        let repo = TranscriptEditsRepository(
            recordingDirectory: root,
            atomicReplaceHook: { _, _ in
                if hookBox.shouldPause {
                    hookBox.shouldPause = false
                    inHook.signal()
                    _ = allowCommit.wait(timeout: .now() + 5.0)
                }
            }
        )
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // Precondition: turn_1 has Initial Text
        _ = try repo.saveTurnOverride(resultID: resultID, turnID: "turn_1", text: "Text V0", displayName: nil)

        // Arm hook for text update operation
        hookBox.shouldPause = true

        final class ThreadResult: @unchecked Sendable {
            var error: Error?
            var edits: TranscriptEdits?
        }
        let textThreadResult = ThreadResult()
        let speakerThreadResult = ThreadResult()

        let textDone = DispatchSemaphore(value: 0)
        let speakerDone = DispatchSemaphore(value: 0)

        // Thread 1: updates text to "Text V1" (pauses in hook)
        let t1 = Thread {
            do {
                textThreadResult.edits = try repo.saveTurnOverride(
                    resultID: resultID,
                    turnID: "turn_1",
                    text: "Text V1",
                    displayName: nil
                )
            } catch {
                textThreadResult.error = error
            }
            textDone.signal()
        }
        t1.start()

        // Wait until Thread 1 is in hook holding the gate/staging
        #expect(inHook.wait(timeout: .now() + 5.0) == .success)

        // Thread 2: queues speaker assignment on turn_1
        let t2 = Thread {
            do {
                speakerThreadResult.edits = try service.assignSpeakerName(
                    resultID: resultID,
                    turnID: "turn_1",
                    displayName: "Алиса"
                )
            } catch {
                speakerThreadResult.error = error
            }
            speakerDone.signal()
        }
        t2.start()

        // Let Thread 1 complete its commit
        allowCommit.signal()

        #expect(textDone.wait(timeout: .now() + 5.0) == .success)
        #expect(speakerDone.wait(timeout: .now() + 5.0) == .success)

        #expect(textThreadResult.error == nil)
        #expect(speakerThreadResult.error == nil)

        // Verify that turn_1 has displayName "Алиса" AND preserved latest text "Text V1"
        let finalEdits = try repo.loadEdits(resultID: resultID)
        #expect(finalEdits.overrides["turn_1"]?.displayName == "Алиса")
        #expect(finalEdits.overrides["turn_1"]?.text == "Text V1")
    }

    // MARK: - 12. Session Preview Apply Rejects Inactive ResultID After Switch

    @Test @MainActor func testSessionPreviewApplyRejectsPriorResultAfterReopen() async throws {
        let root = try temporaryDirectory()
        let resultIDA = "res_switch_a"
        let resultIDB = "res_switch_b"

        let rawDir = root.appendingPathComponent("raw")
        let transcriptsDir = rawDir.appendingPathComponent("transcripts")
        let versionDirA = transcriptsDir.appendingPathComponent(resultIDA)
        let versionDirB = transcriptsDir.appendingPathComponent(resultIDB)
        try FileManager.default.createDirectory(at: versionDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: versionDirB, withIntermediateDirectories: true)

        let fixtureData = try Data(contentsOf: fixture("valid_parakeet_off"))
        var docJsonA = try #require(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        docJsonA["resultID"] = resultIDA
        docJsonA["createdAt"] = "2026-10-29T10:00:00+03:00"
        if var pbA = docJsonA["playback"] as? [String: Any] {
            pbA["mixPath"] = "raw/transcripts/\(resultIDA)/mix.m4a"
            docJsonA["playback"] = pbA
        }
        let resultAData = try JSONSerialization.data(withJSONObject: docJsonA, options: [.sortedKeys])
        try resultAData.write(to: versionDirA.appendingPathComponent("result.json"))

        var docJsonB = try #require(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        docJsonB["resultID"] = resultIDB
        docJsonB["createdAt"] = "2026-10-29T12:00:00+03:00"
        if var pbB = docJsonB["playback"] as? [String: Any] {
            pbB["mixPath"] = "raw/transcripts/\(resultIDB)/mix.m4a"
            docJsonB["playback"] = pbB
        }
        let resultBData = try JSONSerialization.data(withJSONObject: docJsonB, options: [.sortedKeys])
        try resultBData.write(to: versionDirB.appendingPathComponent("result.json"))

        let hostAudio = rawDir.appendingPathComponent("meeting.host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("meeting.remote_record.wav")
        let mixAudioA = versionDirA.appendingPathComponent("mix.m4a")
        let mixAudioB = versionDirB.appendingPathComponent("mix.m4a")
        let dummy = Data([0x01, 0x02, 0x03, 0x04])
        try dummy.write(to: hostAudio)
        try dummy.write(to: remoteAudio)
        try dummy.write(to: mixAudioA)
        try dummy.write(to: mixAudioB)

        let metadataURL = rawDir.appendingPathComponent("\(root.lastPathComponent).processing.json")
        try Data("{}".utf8).write(to: metadataURL)

        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: versionDirB.path)
        let sessionA = try #require(try TranscriptReviewSession.open(recordingDirectory: root))
        let session = sessionA
        #expect(session.activeResultID == resultIDA)

        // Generate preview for version A
        let previewA = try session.previewGroupAssignment(speakerID: "spk_h1", replaceManuallyAssigned: false)
        #expect(previewA.resultID == resultIDA)

        // Switch active version to B
        session.close()
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: versionDirA.path)
        let reopened = try #require(try TranscriptReviewSession.open(recordingDirectory: root))
        #expect(reopened.activeResultID == resultIDB)

        // Attempting to apply preview for inactive version A must be rejected
        #expect {
            try reopened.assignSpeakerName(preview: previewA, displayName: "Группа А")
        } throws: { error in
            if case .conflict = (error as? TranscriptEditsError) { return true }
            return false
        }

        // Verify version A was not mutated on disk
        let editsAFile = versionDirA.appendingPathComponent("edits.json")
        #expect(!FileManager.default.fileExists(atPath: editsAFile.path))
    }

    // MARK: - 13. Cross-Recording Preview Apply Is Rejected

    @Test func testCrossRecordingPreviewApplyIsRejected() throws {
        let root1 = try temporaryDirectory("root1")
        let root2 = try temporaryDirectory("root2")
        let resultID = "res_cross_rec"

        let (_, _, _) = try createSyntheticRecordingWithMultiTurns(in: root1, resultID: resultID)
        let (_, versionDir2, _) = try createSyntheticRecordingWithMultiTurns(in: root2, resultID: resultID)

        let service1 = TranscriptSpeakerAssignmentService(editsRepository: TranscriptEditsRepository(recordingDirectory: root1))
        let service2 = TranscriptSpeakerAssignmentService(editsRepository: TranscriptEditsRepository(recordingDirectory: root2))

        let preview1 = try service1.previewGroupAssignment(resultID: resultID, speakerID: "spk_h1", replaceManuallyAssigned: false)

        // Applying recording 1's preview to recording 2's service must be rejected
        #expect {
            try service2.assignSpeakerName(preview: preview1, displayName: "Чужая Запись")
        } throws: { error in
            if case .conflict = (error as? TranscriptEditsError) { return true }
            return false
        }

        let edits2File = versionDir2.appendingPathComponent("edits.json")
        #expect(!FileManager.default.fileExists(atPath: edits2File.path))
    }

    // MARK: - 14. Same-Revision External Rename After Explicit Reload Rejects Stale Preview

    @Test func testSameRevisionExternalRenameAfterExplicitReloadRejectsStalePreview() throws {
        let root = try temporaryDirectory()
        let resultID = "res_same_rev_rename"
        let (_, versionDir, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // Initial save: revision 1 with turn_1 = "Автор V1"
        _ = try service.assignSpeakerName(resultID: resultID, turnID: "turn_1", displayName: "Автор V1")

        // Generate preview at revision 1
        let preview = try service.previewGroupAssignment(resultID: resultID, speakerID: "spk_h1", replaceManuallyAssigned: true)
        #expect(preview.revision == 1)

        // External rename happens on disk, keeping revision 1 (same revision, different content)
        let editsFile = versionDir.appendingPathComponent("edits.json")
        let externalJSON = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 1,
            "overrides": {
                "turn_1": {
                    "displayName": "Внешний Переименованный Автор"
                }
            }
        }
        """
        try Data(externalJSON.utf8).write(to: editsFile)

        // Explicit reload
        _ = try repo.loadEdits(resultID: resultID)

        // Applying old preview must reject because content/snapshot changed despite same revision
        #expect {
            try service.assignSpeakerName(preview: preview, displayName: "Новое Имя")
        } throws: { error in
            if case .conflict = (error as? TranscriptEditsError) { return true }
            return false
        }

        // Verify disk still has external author
        let loaded = try repo.loadEdits(resultID: resultID)
        #expect(loaded.overrides["turn_1"]?.displayName == "Внешний Переименованный Автор")
    }

    // MARK: - 15. Fabricated Preview Mismatched Targets Rejected

    @Test func testFabricatedPreviewMismatchedTargetsRejected() throws {
        let root = try temporaryDirectory()
        let resultID = "res_fabricated_preview"
        let (_, versionDir, _) = try createSyntheticRecordingWithMultiTurns(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // Valid preview
        let validPreview = try service.previewGroupAssignment(resultID: resultID, speakerID: "spk_h1", replaceManuallyAssigned: false)

        // Fabricated preview: wrong sourceID or zero affected turns when turns exist
        let fakePreview = TranscriptBulkAssignmentPreview(
            recordingDirectory: root,
            resultID: resultID,
            sourceID: .remote, // False source (spk_h1 is host!)
            localID: 1,
            speakerID: "spk_h1",
            revision: validPreview.revision,
            replaceManuallyAssigned: false,
            totalTurnsInGroup: 0, // False count
            affectedTurnsCount: 0,
            replacedManualAssignmentsCount: 0,
            targetTurnIDs: [],
            affectedTurnIDs: [],
            replacedTurnIDs: [],
            snapshotOverrides: [:]
        )

        #expect {
            try service.assignSpeakerName(preview: fakePreview, displayName: "Подделка")
        } throws: { error in
            if case .conflict = (error as? TranscriptEditsError) { return true }
            return false
        }

        let editsFile = versionDir.appendingPathComponent("edits.json")
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))
    }

    // MARK: - 4.3 Diarization Warnings & 16 Independent Groups Tests

    private func createSynthetic8Plus8VoiceRecording(
        in root: URL,
        resultID: String = "res_diar_8_8",
        hostVoiceCount: Int? = 8,
        remoteVoiceCount: Int? = 8,
        attendees: [String]? = nil,
        existingWarnings: [[String: Any]] = []
    ) throws -> (resultURL: URL, versionDir: URL) {
        let rawDir = root.appendingPathComponent("raw")
        let transcriptsDir = rawDir.appendingPathComponent("transcripts")
        let versionDir = transcriptsDir.appendingPathComponent(resultID)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        var speakers: [[String: Any]] = []
        var words: [[String: Any]] = []
        var baselineWords: [[String: Any]] = []
        var turns: [[String: Any]] = []

        // 8 host speakers
        for i in 1...8 {
            let spkID = "spk_h\(i)"
            speakers.append([
                "id": spkID,
                "sourceID": "host",
                "localID": i,
                "displayNumber": i
            ])
            let wID = "w_h\(i)"
            words.append(["id": wID, "speakerID": spkID, "start": Double(i), "end": Double(i) + 0.5, "text": "Слово \(i)"])
            baselineWords.append(["id": "b\(wID)", "speakerID": spkID, "start": Double(i), "end": Double(i) + 0.5, "text": "Слово \(i)"])
            turns.append(["id": "turn_h\(i)", "speakerID": spkID, "start": Double(i), "end": Double(i) + 0.5, "wordIDs": [wID]])
        }

        // 8 remote speakers (display numbers 9..16)
        for i in 1...8 {
            let spkID = "spk_r\(i)"
            let displayNum = 8 + i
            speakers.append([
                "id": spkID,
                "sourceID": "remote",
                "localID": i,
                "displayNumber": displayNum
            ])
            let wID = "w_r\(i)"
            words.append(["id": wID, "speakerID": spkID, "start": Double(displayNum), "end": Double(displayNum) + 0.5, "text": "Слово \(displayNum)"])
            baselineWords.append(["id": "b\(wID)", "speakerID": spkID, "start": Double(displayNum), "end": Double(displayNum) + 0.5, "text": "Слово \(displayNum)"])
            turns.append(["id": "turn_r\(i)", "speakerID": spkID, "start": Double(displayNum), "end": Double(displayNum) + 0.5, "wordIDs": [wID]])
        }

        // Extra turn 17 on spk_h1 and turn 18 on spk_r1 (for 18 turns across 16 voices)
        words.append(["id": "w_h1_extra", "speakerID": "spk_h1", "start": 20.0, "end": 20.5, "text": "Экстра 17"])
        baselineWords.append(["id": "bw_h1_extra", "speakerID": "spk_h1", "start": 20.0, "end": 20.5, "text": "Экстра 17"])
        turns.append(["id": "turn_extra_17", "speakerID": "spk_h1", "start": 20.0, "end": 20.5, "wordIDs": ["w_h1_extra"]])

        words.append(["id": "w_r1_extra", "speakerID": "spk_r1", "start": 21.0, "end": 21.5, "text": "Экстра 18"])
        baselineWords.append(["id": "bw_r1_extra", "speakerID": "spk_r1", "start": 21.0, "end": 21.5, "text": "Экстра 18"])
        turns.append(["id": "turn_extra_18", "speakerID": "spk_r1", "start": 21.0, "end": 21.5, "wordIDs": ["w_r1_extra"]])

        var docJson: [String: Any] = [
            "schemaVersion": 1,
            "resultID": resultID,
            "createdAt": "2026-10-31T12:00:00Z",
            "sources": [
                [
                    "id": "host",
                    "originalAudioPath": "raw/meeting.host_record.wav",
                    "recognitionAudioPath": "raw/meeting.host_record.wav",
                    "diarizationStatus": hostVoiceCount != nil ? "completed" : "disabled",
                    "detectedVoiceCount": hostVoiceCount as Any,
                    "correctionStatus": "disabled"
                ],
                [
                    "id": "remote",
                    "originalAudioPath": "raw/meeting.remote_record.wav",
                    "recognitionAudioPath": "raw/meeting.remote_record.wav",
                    "diarizationStatus": remoteVoiceCount != nil ? "completed" : "disabled",
                    "detectedVoiceCount": remoteVoiceCount as Any,
                    "correctionStatus": "disabled"
                ]
            ],
            "speakers": speakers,
            "words": words,
            "baselineWords": baselineWords,
            "turns": turns,
            "aec": ["requested": false, "outcome": "disabled"],
            "playback": ["status": "ready", "mixPath": "raw/transcripts/\(resultID)/mix.m4a"],
            "warnings": existingWarnings
        ]

        if let attendees {
            docJson["context"] = ["attendees": attendees]
        } else {
            docJson["context"] = NSNull()
        }

        let resultData = try JSONSerialization.data(withJSONObject: docJson, options: [.sortedKeys])
        let resultURL = versionDir.appendingPathComponent("result.json")
        try resultData.write(to: resultURL)

        let hostAudio = rawDir.appendingPathComponent("meeting.host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("meeting.remote_record.wav")
        let mixAudio = versionDir.appendingPathComponent("mix.m4a")
        let dummy = Data([0x01, 0x02, 0x03, 0x04])
        try dummy.write(to: hostAudio)
        try dummy.write(to: remoteAudio)
        try dummy.write(to: mixAudio)

        return (resultURL, versionDir)
    }

    // MARK: - 16. Diarization Warning Per Source Detection (8+8 Voices)

    @Test func testDiarizationWarningPerSourceDetection8Voices() throws {
        let root = try temporaryDirectory()
        let resultID = "res_diar_8_8"
        let (resultURL, _) = try createSynthetic8Plus8VoiceRecording(
            in: root,
            resultID: resultID,
            hostVoiceCount: 8,
            remoteVoiceCount: 8
        )

        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)

        // 16 independent groups with unique display numbers 1..16
        #expect(doc.speakers.count == 16)
        let displayNumbers = Set(doc.speakers.map(\.displayNumber))
        #expect(displayNumbers.count == 16)
        #expect(displayNumbers == Set(1...16))

        // Both host and remote detected 8 voices -> separate warnings with localized labels
        let hostWarning = try #require(doc.diarizationWarning(for: .host))
        #expect(hostWarning.contains("Микрофон"))
        #expect(hostWarning.contains("8"))

        let remoteWarning = try #require(doc.diarizationWarning(for: .remote))
        #expect(remoteWarning.contains("Системный звук"))
        #expect(remoteWarning.contains("8"))

        #expect(doc.presentationWarnings.count == 2)
    }

    // MARK: - 17. Diarization Warning No False Positive On Calendar Or Null Or Fewer

    @Test func testDiarizationWarningNoFalsePositiveOnCalendarOrNullOrFewer() throws {
        let root = try temporaryDirectory()
        let resultID = "res_no_false_warning"
        // 20 calendar attendees, but host has 2 voices, remote has nil (disabled)
        let (resultURL, _) = try createSynthetic8Plus8VoiceRecording(
            in: root,
            resultID: resultID,
            hostVoiceCount: 2,
            remoteVoiceCount: nil,
            attendees: (1...20).map { "Участник \($0)" }
        )

        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)

        // Calendar attendees count (20) must NEVER be used as a proxy for diarization warning
        #expect(doc.diarizationWarning(for: .host) == nil)
        #expect(doc.diarizationWarning(for: .remote) == nil)
        #expect(doc.presentationWarnings.isEmpty)
    }

    // MARK: - 18. More Than 16 Distinct Names Allowed Across Turns

    @Test func testMoreThan16DistinctNamesAllowedAcrossTurns() throws {
        let root = try temporaryDirectory()
        let resultID = "res_18_names"
        let (_, _) = try createSynthetic8Plus8VoiceRecording(
            in: root,
            resultID: resultID,
            hostVoiceCount: 8,
            remoteVoiceCount: 8
        )

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let service = TranscriptSpeakerAssignmentService(editsRepository: repo)

        // Assign 18 distinct human names across 18 turns (even though model only had 16 voices)
        var lastEdits: TranscriptEdits?
        for i in 1...8 {
            _ = try service.assignSpeakerName(resultID: resultID, turnID: "turn_h\(i)", displayName: "Хост Имя \(i)")
            _ = try service.assignSpeakerName(resultID: resultID, turnID: "turn_r\(i)", displayName: "Удалённое Имя \(i)")
        }
        _ = try service.assignSpeakerName(resultID: resultID, turnID: "turn_extra_17", displayName: "Уникальный Гость 17")
        lastEdits = try service.assignSpeakerName(resultID: resultID, turnID: "turn_extra_18", displayName: "Уникальный Гость 18")

        let finalOverrides = try #require(lastEdits?.overrides)
        #expect(finalOverrides.count == 18)
        let uniqueNames = Set(finalOverrides.values.compactMap(\.displayName))
        #expect(uniqueNames.count == 18)
    }

    // MARK: - 19. Existing Document Warnings Not Duplicated

    @Test func testExistingDocumentWarningsNotDuplicated() throws {
        let root = try temporaryDirectory()
        let resultID = "res_no_dup_warning"
        let (resultURL, _) = try createSynthetic8Plus8VoiceRecording(
            in: root,
            resultID: resultID,
            hostVoiceCount: 8,
            remoteVoiceCount: 8,
            existingWarnings: [
                [
                    "code": "diarization_voice_limit",
                    "sourceID": "host",
                    "message": "Существующее предупреждение микрофона"
                ]
            ]
        )

        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)

        // Preexisting host warning is preserved without duplicating
        let hostWarnings = doc.presentationWarnings.filter { $0.sourceID == .host }
        #expect(hostWarnings.count == 1)
        #expect(hostWarnings.first?.message == "Существующее предупреждение микрофона")

        // Remote warning is derived since it was not in existing warnings
        let remoteWarnings = doc.presentationWarnings.filter { $0.sourceID == .remote }
        #expect(remoteWarnings.count == 1)
        #expect(remoteWarnings.first?.message.contains("Системный звук") == true)
        #expect(doc.presentationWarnings.count == 2)
    }

    // MARK: - 20. Exact Canonical Code Deduplication Preserves Unrelated Warnings

    @Test func testDiarizationWarningExactCanonicalCodePreservesUnrelatedVoiceLimitWarnings() throws {
        let root = try temporaryDirectory()
        let resultID = "res_unrelated_warning"
        // Warning with unrelated code containing 'voice_limit' prefix/suffix
        let (resultURL, _) = try createSynthetic8Plus8VoiceRecording(
            in: root,
            resultID: resultID,
            hostVoiceCount: 8,
            remoteVoiceCount: 2,
            existingWarnings: [
                [
                    "code": "recognition_voice_limit_recovery_failed",
                    "sourceID": "host",
                    "message": "Ошибка восстановления лимита распознавания"
                ]
            ]
        )

        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)

        // 1. Unrelated warning must NOT be returned as the diarization warning
        let hostDiarWarning = try #require(doc.diarizationWarning(for: .host))
        #expect(hostDiarWarning.contains("Микрофон"))
        #expect(hostDiarWarning != "Ошибка восстановления лимита распознавания")

        // 2. Both the unrelated warning AND the derived diarization warning must be present in presentationWarnings
        #expect(doc.presentationWarnings.count == 2)
        #expect(doc.presentationWarnings.contains { $0.code == "recognition_voice_limit_recovery_failed" })
        #expect(doc.presentationWarnings.contains { $0.code == "diarization_voice_limit" && $0.sourceID == .host })
    }
}
