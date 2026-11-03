import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite final class TranscriptEditsUndoTests {
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

    private func temporaryDirectory(_ prefix: String = "TranscriptEditsUndoTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            prefix + "-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        return directory
    }

    /// Creates a synthetic recording directory containing two valid recognition versions (`res_a` and `res_b`)
    /// sharing common audio files, with both versions verified by the production document reader.
    private func createSyntheticMultiVersionRecording(
        in root: URL,
        resultIDA: String = "res_a",
        resultIDB: String = "res_b"
    ) throws -> (resultAURL: URL, resultBURL: URL, audioURLs: [URL], versionDirA: URL, versionDirB: URL) {
        let rawDir = root.appendingPathComponent("raw")
        let transcriptsDir = rawDir.appendingPathComponent("transcripts")
        let versionDirA = transcriptsDir.appendingPathComponent(resultIDA)
        let versionDirB = transcriptsDir.appendingPathComponent(resultIDB)

        try FileManager.default.createDirectory(at: versionDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: versionDirB, withIntermediateDirectories: true)

        let fixtureData = try Data(contentsOf: fixture("valid_parakeet_off"))
        var docJsonA = try #require(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        docJsonA["resultID"] = resultIDA
        if var pbA = docJsonA["playback"] as? [String: Any] {
            pbA["mixPath"] = "raw/transcripts/\(resultIDA)/mix.m4a"
            docJsonA["playback"] = pbA
        }
        let resultAData = try JSONSerialization.data(withJSONObject: docJsonA, options: [.sortedKeys])
        let resultAURL = versionDirA.appendingPathComponent("result.json")
        try resultAData.write(to: resultAURL)

        var docJsonB = try #require(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        docJsonB["resultID"] = resultIDB
        if var pbB = docJsonB["playback"] as? [String: Any] {
            pbB["mixPath"] = "raw/transcripts/\(resultIDB)/mix.m4a"
            docJsonB["playback"] = pbB
        }
        let resultBData = try JSONSerialization.data(withJSONObject: docJsonB, options: [.sortedKeys])
        let resultBURL = versionDirB.appendingPathComponent("result.json")
        try resultBData.write(to: resultBURL)

        let hostAudio = rawDir.appendingPathComponent("meeting.host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("meeting.remote_record.wav")
        let mixAudioA = versionDirA.appendingPathComponent("mix.m4a")
        let mixAudioB = versionDirB.appendingPathComponent("mix.m4a")

        let hostBytes = Data("SYNTHETIC_PCM_AUDIO_HOST_16KHZ".utf8)
        let remoteBytes = Data("SYNTHETIC_PCM_AUDIO_REMOTE_16KHZ".utf8)
        let mixBytesA = Data("SYNTHETIC_M4A_MIX_AUDIO_VERSION_A".utf8)
        let mixBytesB = Data("SYNTHETIC_M4A_MIX_AUDIO_VERSION_B".utf8)

        try hostBytes.write(to: hostAudio)
        try remoteBytes.write(to: remoteAudio)
        try mixBytesA.write(to: mixAudioA)
        try mixBytesB.write(to: mixAudioB)

        // Validate both documents with production reader
        _ = try TranscriptDocument.load(from: resultAURL, recordingDirectory: root)
        _ = try TranscriptDocument.load(from: resultBURL, recordingDirectory: root)

        return (resultAURL, resultBURL, [hostAudio, remoteAudio, mixAudioA, mixAudioB], versionDirA, versionDirB)
    }

    @Test func testUndoRestoresPreviousSavedStateAsNewRevisionAndDoesNotAffectOtherVersion() throws {
        let root = try temporaryDirectory()
        let resultIDA = "res_a"
        let resultIDB = "res_b"
        let (resultAURL, resultBURL, audioURLs, _, _) = try createSyntheticMultiVersionRecording(
            in: root,
            resultIDA: resultIDA,
            resultIDB: resultIDB
        )

        let initialResultAData = try Data(contentsOf: resultAURL)
        let initialResultBData = try Data(contentsOf: resultBURL)
        let initialAudioData = try audioURLs.map { try Data(contentsOf: $0) }

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let editsAFile = repo.editsURL(for: resultIDA)
        let editsBFile = repo.editsURL(for: resultIDB)

        // Fixture initial valid edits for both versions (revision 1) sharing turn_1
        let initialEditsA = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultIDA,
            revision: 1,
            overrides: [
                "turn_1": TranscriptTurnOverride(text: "Начальный текст А", displayName: "Алиса")
            ]
        )
        let initialEditsB = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultIDB,
            revision: 1,
            overrides: [
                "turn_1": TranscriptTurnOverride(text: "Начальный текст Б", displayName: "Боб")
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(initialEditsA).write(to: editsAFile)
        let initialEditsBData = try encoder.encode(initialEditsB)
        try initialEditsBData.write(to: editsBFile)

        // In RED skeleton, saveTurnOverride throws .notImplemented as prerequisite failure
        let expectedPendingOverridesA: [String: TranscriptTurnOverride] = [
            "turn_1": TranscriptTurnOverride(text: "Правка версии А", displayName: "Алиса Обновлённая")
        ]
        let savedA = try repo.saveTurnOverride(
            resultID: resultIDA,
            turnID: "turn_1",
            text: "Правка версии А",
            displayName: "Алиса Обновлённая"
        )
        #expect(savedA.schemaVersion == 1)
        #expect(savedA.resultID == resultIDA)
        #expect(savedA.revision == 2)
        #expect(savedA.overrides == expectedPendingOverridesA)

        // Verify disk contains FULL pending overrides and revision 2 BEFORE undo
        let diskSavedAData = try Data(contentsOf: editsAFile)
        let diskSavedA = try JSONDecoder().decode(TranscriptEdits.self, from: diskSavedAData)
        #expect(diskSavedA.revision == 2)
        #expect(diskSavedA.overrides == expectedPendingOverridesA)

        // Post-save undo availability in original repository session
        #expect(repo.canUndo(resultID: resultIDA))
        #expect(!repo.canUndo(resultID: resultIDB))

        // Check fresh repository session BEFORE consuming original history:
        // A new session has no undo history even while original repo has undo available
        let repo2 = TranscriptEditsRepository(recordingDirectory: root)
        let loadedAInRepo2 = try repo2.loadEdits(resultID: resultIDA)
        #expect(loadedAInRepo2.revision == 2)
        #expect(loadedAInRepo2.overrides == expectedPendingOverridesA)
        #expect(!repo2.canUndo(resultID: resultIDA))

        let editsABytesBeforeDeniedUndo = try Data(contentsOf: editsAFile)
        let editsBBytesBeforeDeniedUndo = try Data(contentsOf: editsBFile)
        #expect {
            try repo2.undo(resultID: resultIDA)
        } throws: { error in
            guard case .noUndoHistory = error as? TranscriptEditsError else {
                return false
            }
            return true
        }
        #expect(try Data(contentsOf: editsAFile) == editsABytesBeforeDeniedUndo)
        #expect(try Data(contentsOf: editsBFile) == editsBBytesBeforeDeniedUndo)

        // Verify original repository retains its undo capability after repo2 checks
        #expect(repo.canUndo(resultID: resultIDA))

        // Undo the save operation for version A in original session:
        // Must restore previous state as a NEW revision 3 matching initialEditsA.overrides
        let undoneA = try repo.undo(resultID: resultIDA)
        #expect(undoneA.schemaVersion == 1)
        #expect(undoneA.resultID == resultIDA)
        #expect(undoneA.revision == 3)
        #expect(undoneA.overrides == initialEditsA.overrides)

        // 1. On-disk verification for version A: restored state saved as revision 3
        let diskEditsAData = try Data(contentsOf: editsAFile)
        let diskEditsA = try JSONDecoder().decode(TranscriptEdits.self, from: diskEditsAData)
        #expect(diskEditsA.revision == 3)
        #expect(diskEditsA.overrides == initialEditsA.overrides)

        // 2. Strict version isolation: version B edits remain byte-for-byte identical to initialEditsBData
        let diskEditsBData = try Data(contentsOf: editsBFile)
        #expect(diskEditsBData == initialEditsBData)

        // 3. Immutability of recognition results and audio files for both versions
        #expect(try Data(contentsOf: resultAURL) == initialResultAData)
        #expect(try Data(contentsOf: resultBURL) == initialResultBData)
        for (index, audioURL) in audioURLs.enumerated() {
            #expect(try Data(contentsOf: audioURL) == initialAudioData[index])
        }
    }

    @Test func testBatchOverridesUndoAtomicallyRevertsAllTurnTargetsAndLeavesOtherVersionUntouched() throws {
        let root = try temporaryDirectory()
        let resultIDA = "res_a"
        let resultIDB = "res_b"
        let (resultAURL, resultBURL, audioURLs, _, _) = try createSyntheticMultiVersionRecording(
            in: root,
            resultIDA: resultIDA,
            resultIDB: resultIDB
        )

        let initialResultAData = try Data(contentsOf: resultAURL)
        let initialResultBData = try Data(contentsOf: resultBURL)
        let initialAudioData = try audioURLs.map { try Data(contentsOf: $0) }

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let editsAFile = repo.editsURL(for: resultIDA)
        let editsBFile = repo.editsURL(for: resultIDB)

        // Initial valid edits for both versions (revision 1) with turn_1 and turn_2
        let initialEditsA = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultIDA,
            revision: 1,
            overrides: [
                "turn_1": TranscriptTurnOverride(text: "Исходный текст 1", displayName: "Спикер 1"),
                "turn_2": TranscriptTurnOverride(text: "Исходный текст 2", displayName: "Спикер 2")
            ]
        )
        let initialEditsB = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultIDB,
            revision: 1,
            overrides: [
                "turn_1": TranscriptTurnOverride(text: "Версия Б текст 1", displayName: "Боб 1"),
                "turn_2": TranscriptTurnOverride(text: "Версия Б текст 2", displayName: "Боб 2")
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(initialEditsA).write(to: editsAFile)
        let initialEditsBData = try encoder.encode(initialEditsB)
        try initialEditsBData.write(to: editsBFile)

        // Batch override save modifying multiple turns as one operation
        // In RED skeleton, saveEdits throws .notImplemented as prerequisite failure
        let expectedPendingBatchA: [String: TranscriptTurnOverride] = [
            "turn_1": TranscriptTurnOverride(text: "Групповой текст 1", displayName: "Группа А"),
            "turn_2": TranscriptTurnOverride(text: "Групповой текст 2", displayName: "Группа А")
        ]
        let savedA = try repo.saveEdits(
            resultID: resultIDA,
            overrides: expectedPendingBatchA
        )
        #expect(savedA.schemaVersion == 1)
        #expect(savedA.resultID == resultIDA)
        #expect(savedA.revision == 2)
        #expect(savedA.overrides == expectedPendingBatchA)

        // Verify disk contains FULL pending batch overrides and revision 2 BEFORE undo
        let diskSavedAData = try Data(contentsOf: editsAFile)
        let diskSavedA = try JSONDecoder().decode(TranscriptEdits.self, from: diskSavedAData)
        #expect(diskSavedA.revision == 2)
        #expect(diskSavedA.overrides == expectedPendingBatchA)

        #expect(repo.canUndo(resultID: resultIDA))

        // Undo the batch operation: atomically reverts all turn targets in a single undo step
        let undoneA = try repo.undo(resultID: resultIDA)
        #expect(undoneA.schemaVersion == 1)
        #expect(undoneA.resultID == resultIDA)
        #expect(undoneA.revision == 3)
        #expect(undoneA.overrides == initialEditsA.overrides)

        // 1. On-disk check for version A: both turns restored atomically matching initialEditsA.overrides
        let diskEditsAData = try Data(contentsOf: editsAFile)
        let diskEditsA = try JSONDecoder().decode(TranscriptEdits.self, from: diskEditsAData)
        #expect(diskEditsA.revision == 3)
        #expect(diskEditsA.overrides == initialEditsA.overrides)

        // 2. Version B remains byte-for-byte untouched
        let diskEditsBData = try Data(contentsOf: editsBFile)
        #expect(diskEditsBData == initialEditsBData)

        // 3. Immutability of recognition results and audio files
        #expect(try Data(contentsOf: resultAURL) == initialResultAData)
        #expect(try Data(contentsOf: resultBURL) == initialResultBData)
        for (index, audioURL) in audioURLs.enumerated() {
            #expect(try Data(contentsOf: audioURL) == initialAudioData[index])
        }
    }

    @Test func testFailedSaveDoesNotPushUndoHistory() throws {
        let root = try temporaryDirectory()
        let resultIDA = "res_a"
        let (resultAURL, _, _, _, _) = try createSyntheticMultiVersionRecording(in: root, resultIDA: resultIDA)
        _ = try Data(contentsOf: resultAURL)

        struct InjectedSaveError: Error, Equatable {}

        let repo = TranscriptEditsRepository(recordingDirectory: root) { _, _ in
            throw InjectedSaveError()
        }

        #expect {
            try repo.saveTurnOverride(
                resultID: resultIDA,
                turnID: "turn_1",
                text: "Текст",
                displayName: "Автор"
            )
        } throws: { error in
            error is InjectedSaveError
        }

        #expect(!repo.canUndo(resultID: resultIDA))
        #expect {
            try repo.undo(resultID: resultIDA)
        } throws: { error in
            guard case .noUndoHistory = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test func testFailedUndoRetainsHistoryAndCanBeRetried() throws {
        let root = try temporaryDirectory()
        let resultIDA = "res_a"
        let (_, _, _, versionDirA, _) = try createSyntheticMultiVersionRecording(in: root, resultIDA: resultIDA)
        let editsAFile = versionDirA.appendingPathComponent("edits.json")

        struct InjectedUndoError: Error, Equatable {}

        final class FailureControlBox: @unchecked Sendable {
            var failInHook = false
        }
        let failureBox = FailureControlBox()

        let repo = TranscriptEditsRepository(recordingDirectory: root) { _, _ in
            if failureBox.failInHook {
                throw InjectedUndoError()
            }
        }

        // 1. Successful save advances revision to 1 (from initial absent)
        let saved = try repo.saveTurnOverride(
            resultID: resultIDA,
            turnID: "turn_1",
            text: "Первая правка",
            displayName: "Алиса"
        )
        #expect(saved.revision == 1)
        #expect(repo.canUndo(resultID: resultIDA))

        // 2. Undo fails due to injected error
        failureBox.failInHook = true
        #expect {
            try repo.undo(resultID: resultIDA)
        } throws: { error in
            error is InjectedUndoError
        }

        // History must be retained after failed undo
        #expect(repo.canUndo(resultID: resultIDA))

        // Disk state remains revision 1
        let diskEdits1 = try JSONDecoder().decode(TranscriptEdits.self, from: Data(contentsOf: editsAFile))
        #expect(diskEdits1.revision == 1)

        // 3. Retry undo after clearing error succeeds: restores initial empty overrides as revision 2
        failureBox.failInHook = false
        let undone = try repo.undo(resultID: resultIDA)
        #expect(undone.revision == 2)
        #expect(undone.overrides.isEmpty)

        let diskEdits2 = try JSONDecoder().decode(TranscriptEdits.self, from: Data(contentsOf: editsAFile))
        #expect(diskEdits2.revision == 2)
        #expect(diskEdits2.overrides.isEmpty)
    }

    @Test func testConflictDuringUndoThrowsConflictAndRetainsHistory() throws {
        let root = try temporaryDirectory()
        let resultIDA = "res_a"
        let (_, _, _, versionDirA, _) = try createSyntheticMultiVersionRecording(in: root, resultIDA: resultIDA)
        let editsAFile = versionDirA.appendingPathComponent("edits.json")

        let repo = TranscriptEditsRepository(recordingDirectory: root)

        // Save revision 1
        let saved = try repo.saveTurnOverride(
            resultID: resultIDA,
            turnID: "turn_1",
            text: "Правка",
            displayName: "Алиса"
        )
        #expect(saved.revision == 1)
        #expect(repo.canUndo(resultID: resultIDA))

        // External writer modifies edits.json on disk BEFORE undo
        let externalEdits = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultIDA,
            revision: 5,
            overrides: ["turn_1": TranscriptTurnOverride(text: "Внешний текст")]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let externalData = try encoder.encode(externalEdits)
        try externalData.write(to: editsAFile)

        // Undo must detect CAS conflict and reject
        #expect {
            try repo.undo(resultID: resultIDA)
        } throws: { error in
            guard case .conflict = error as? TranscriptEditsError else { return false }
            return true
        }

        // External edits on disk remain intact
        #expect(try Data(contentsOf: editsAFile) == externalData)
        // Undo history is retained for potential resolution/retry
        #expect(repo.canUndo(resultID: resultIDA))
    }

    @Test func testDoubleUndoThrowsNoUndoHistory() throws {
        let root = try temporaryDirectory()
        let resultIDA = "res_a"
        let _ = try createSyntheticMultiVersionRecording(in: root, resultIDA: resultIDA)

        let repo = TranscriptEditsRepository(recordingDirectory: root)

        _ = try repo.saveTurnOverride(
            resultID: resultIDA,
            turnID: "turn_1",
            text: "Правка 1",
            displayName: "Алиса"
        )
        #expect(repo.canUndo(resultID: resultIDA))

        // First undo succeeds
        let undone = try repo.undo(resultID: resultIDA)
        #expect(undone.revision == 2)

        // History is now empty -> second undo throws noUndoHistory
        #expect(!repo.canUndo(resultID: resultIDA))
        #expect {
            try repo.undo(resultID: resultIDA)
        } throws: { error in
            guard case .noUndoHistory = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test func testExternalReloadWithChangedContentClearsUndoHistory() throws {
        let root = try temporaryDirectory()
        let resultIDA = "res_a"
        let (_, _, _, versionDirA, _) = try createSyntheticMultiVersionRecording(in: root, resultIDA: resultIDA)
        let editsAFile = versionDirA.appendingPathComponent("edits.json")

        let repo = TranscriptEditsRepository(recordingDirectory: root)

        _ = try repo.saveTurnOverride(
            resultID: resultIDA,
            turnID: "turn_1",
            text: "Правка 1",
            displayName: "Алиса"
        )
        #expect(repo.canUndo(resultID: resultIDA))

        // External writer modifies edits.json
        let externalEdits = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultIDA,
            revision: 10,
            overrides: ["turn_1": TranscriptTurnOverride(text: "Внешний текст")]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(externalEdits).write(to: editsAFile)

        // Explicit reload detects changed content
        let reloaded = try repo.loadEdits(resultID: resultIDA)
        #expect(reloaded.revision == 10)

        // Undo history must be cleared because disk state diverged externally
        #expect(!repo.canUndo(resultID: resultIDA))
        #expect {
            try repo.undo(resultID: resultIDA)
        } throws: { error in
            guard case .noUndoHistory = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test func testConcurrentSaveThenUndoRespectsQueuedOrderAndRestoresCorrectState() throws {
        let root = try temporaryDirectory()
        let resultIDA = "res_a"
        let (_, _, _, versionDirA, _) = try createSyntheticMultiVersionRecording(in: root, resultIDA: resultIDA)
        let editsAFile = versionDirA.appendingPathComponent("edits.json")

        let saveInHook = DispatchSemaphore(value: 0)
        let allowSaveCommit = DispatchSemaphore(value: 0)
        let undoContended = DispatchSemaphore(value: 0)
        let saveDone = DispatchSemaphore(value: 0)
        let undoDone = DispatchSemaphore(value: 0)

        final class HookBox: @unchecked Sendable {
            var shouldPause = false
        }
        let hookBox = HookBox()

        let repo = TranscriptEditsRepository(
            recordingDirectory: root,
            operationGateObserver: { op in
                if op == .undo || op == .save {
                    undoContended.signal()
                }
            },
            atomicReplaceHook: { _, _ in
                if hookBox.shouldPause {
                    hookBox.shouldPause = false
                    saveInHook.signal()
                    guard allowSaveCommit.wait(timeout: .now() + 5.0) == .success else {
                        struct HookTimeoutError: Error {}
                        throw HookTimeoutError()
                    }
                }
            }
        )

        // Initial save: State A (revision 1)
        let initialSaved = try repo.saveTurnOverride(
            resultID: resultIDA,
            turnID: "turn_1",
            text: "Initial",
            displayName: "Author A"
        )
        #expect(initialSaved.revision == 1)

        final class ThreadResultBox: @unchecked Sendable {
            var saved: TranscriptEdits?
            var error: Error?
        }
        let saveBox = ThreadResultBox()
        let undoBox = ThreadResultBox()

        // Arm hook for save B only
        hookBox.shouldPause = true

        // Start save B in background thread (will pause in atomicReplaceHook)
        let saveThread = Thread {
            do {
                saveBox.saved = try repo.saveTurnOverride(
                    resultID: resultIDA,
                    turnID: "turn_1",
                    text: "SaveB",
                    displayName: "Author B"
                )
            } catch {
                saveBox.error = error
            }
            saveDone.signal()
        }
        saveThread.start()

        #expect(saveInHook.wait(timeout: .now() + 5.0) == .success)

        // While save B is inside hook, launch undo
        let undoThread = Thread {
            do {
                undoBox.saved = try repo.undo(resultID: resultIDA)
            } catch {
                undoBox.error = error
            }
            undoDone.signal()
        }
        undoThread.start()

        // Verify undo attempts gate acquisition and contends
        #expect(undoContended.wait(timeout: .now() + 5.0) == .success)
        #expect(undoDone.wait(timeout: .now() + 0.1) == .timedOut)

        // Release save B to commit (revision 2)
        allowSaveCommit.signal()
        #expect(saveDone.wait(timeout: .now() + 5.0) == .success)
        #expect(undoDone.wait(timeout: .now() + 5.0) == .success)

        #expect(saveBox.error == nil)
        #expect(undoBox.error == nil)
        #expect(saveBox.saved?.revision == 2)
        #expect(undoBox.saved?.revision == 3)
        // Undo must restore State A ("Initial"), NOT empty
        #expect(undoBox.saved?.overrides["turn_1"]?.text == "Initial")
        #expect(undoBox.saved?.overrides["turn_1"]?.displayName == "Author A")

        let diskEdits = try JSONDecoder().decode(TranscriptEdits.self, from: Data(contentsOf: editsAFile))
        #expect(diskEdits.revision == 3)
        #expect(diskEdits.overrides["turn_1"]?.text == "Initial")
    }

    @Test func testConcurrentUndoThenUndoAreSerializedAndPopSequentialHistory() throws {
        let root = try temporaryDirectory()
        let resultIDA = "res_a"
        let (_, _, _, versionDirA, _) = try createSyntheticMultiVersionRecording(in: root, resultIDA: resultIDA)
        let editsAFile = versionDirA.appendingPathComponent("edits.json")

        let undo1InHook = DispatchSemaphore(value: 0)
        let allowUndo1Commit = DispatchSemaphore(value: 0)
        let undo2Contended = DispatchSemaphore(value: 0)
        let undo1Done = DispatchSemaphore(value: 0)
        let undo2Done = DispatchSemaphore(value: 0)

        final class HookBox: @unchecked Sendable {
            var shouldPause = false
        }
        let hookBox = HookBox()

        let repo = TranscriptEditsRepository(
            recordingDirectory: root,
            operationGateObserver: { op in
                if op == .undo || op == .save {
                    undo2Contended.signal()
                }
            },
            atomicReplaceHook: { _, _ in
                if hookBox.shouldPause {
                    hookBox.shouldPause = false
                    undo1InHook.signal()
                    guard allowUndo1Commit.wait(timeout: .now() + 5.0) == .success else {
                        struct HookTimeoutError: Error {}
                        throw HookTimeoutError()
                    }
                }
            }
        )

        // Two saves: rev 1 (State 1), rev 2 (State 2)
        _ = try repo.saveTurnOverride(resultID: resultIDA, turnID: "turn_1", text: "State1", displayName: "A")
        _ = try repo.saveTurnOverride(resultID: resultIDA, turnID: "turn_1", text: "State2", displayName: "A")

        final class ThreadResultBox: @unchecked Sendable {
            var saved: TranscriptEdits?
            var error: Error?
        }
        let u1Box = ThreadResultBox()
        let u2Box = ThreadResultBox()

        // Arm hook for undo 1 only
        hookBox.shouldPause = true

        // Start first undo (will pause in hook)
        let u1Thread = Thread {
            do {
                u1Box.saved = try repo.undo(resultID: resultIDA)
            } catch {
                u1Box.error = error
            }
            undo1Done.signal()
        }
        u1Thread.start()

        #expect(undo1InHook.wait(timeout: .now() + 5.0) == .success)

        // Start second undo while first is in hook
        let u2Thread = Thread {
            do {
                u2Box.saved = try repo.undo(resultID: resultIDA)
            } catch {
                u2Box.error = error
            }
            undo2Done.signal()
        }
        u2Thread.start()

        #expect(undo2Contended.wait(timeout: .now() + 5.0) == .success)
        #expect(undo2Done.wait(timeout: .now() + 0.1) == .timedOut)

        allowUndo1Commit.signal()
        #expect(undo1Done.wait(timeout: .now() + 5.0) == .success)
        #expect(undo2Done.wait(timeout: .now() + 5.0) == .success)

        #expect(u1Box.error == nil)
        #expect(u2Box.error == nil)
        #expect(u1Box.saved?.revision == 3)
        #expect(u1Box.saved?.overrides["turn_1"]?.text == "State1")
        #expect(u2Box.saved?.revision == 4)
        #expect(u2Box.saved?.overrides.isEmpty == true)

        let diskEdits = try JSONDecoder().decode(TranscriptEdits.self, from: Data(contentsOf: editsAFile))
        #expect(diskEdits.revision == 4)
        #expect(diskEdits.overrides.isEmpty)
        #expect(!repo.canUndo(resultID: resultIDA))
    }
}
