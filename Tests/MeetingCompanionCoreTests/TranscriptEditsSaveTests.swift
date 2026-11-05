import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite final class TranscriptEditsSaveTests {
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

    private func temporaryDirectory(_ prefix: String = "TranscriptEditsSaveTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            prefix + "-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        return directory
    }

    private func createSyntheticRecording(
        in root: URL,
        resultID: String = "res_valid_parakeet_off"
    ) throws -> (resultURL: URL, versionDir: URL) {
        let versionDir = root
            .appendingPathComponent("raw")
            .appendingPathComponent("transcripts")
            .appendingPathComponent(resultID)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let resultURL = versionDir.appendingPathComponent("result.json")
        let fixtureData = try Data(contentsOf: fixture("valid_parakeet_off"))
        try fixtureData.write(to: resultURL)

        let rawDir = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

        let hostAudio = rawDir.appendingPathComponent("meeting.host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("meeting.remote_record.wav")
        let mixAudio = versionDir.appendingPathComponent("mix.m4a")

        try Data("SYNTHETIC_PCM_AUDIO_HOST_16KHZ".utf8).write(to: hostAudio)
        try Data("SYNTHETIC_PCM_AUDIO_REMOTE_16KHZ".utf8).write(to: remoteAudio)
        try Data("SYNTHETIC_M4A_MIX_AUDIO_PAYLOAD".utf8).write(to: mixAudio)

        _ = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        return (resultURL, versionDir)
    }

    @Test(arguments: [false, true])
    func repairVerbatimCanonicalEquivalentText(existingOverride: Bool) throws {
        for (composed, decomposed) in [("\u{00e9}", "e\u{0301}"), ("\u{0439}", "\u{0438}\u{0306}")] {
            let root = try temporaryDirectory()
            let (result, version) = try createSyntheticRecording(in: root)
            if !existingOverride {
                var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])
                var words = try #require(json["words"] as? [[String: Any]])
                words[0]["text"] = composed
                json["words"] = words
                var baseline = try #require(json["baselineWords"] as? [[String: Any]])
                baseline[0]["text"] = composed
                json["baselineWords"] = baseline
                try JSONSerialization.data(withJSONObject: json).write(to: result)
            }
            let repo = TranscriptEditsRepository(recordingDirectory: root)
            let id = "res_valid_parakeet_off"
            if existingOverride { _ = try repo.saveTurnOverride(resultID: id, turnID: "turn_1", text: composed + " день", displayName: nil) }
            let desired = decomposed + " день"
            let saved = try repo.saveTurnOverride(resultID: id, turnID: "turn_1", text: desired, displayName: nil)
            #expect(saved.revision == (existingOverride ? 2 : 1))
            repo.releaseWriteLock()
            let reopened = TranscriptEditsRepository(recordingDirectory: root)
            let edits = try reopened.loadEdits(resultID: id)
            #expect(Array(edits.overrides["turn_1"]?.text?.utf8 ?? "".utf8) == Array(desired.utf8))
            let doc = try TranscriptDocument.load(from: result, recordingDirectory: root)
            let exported = try TranscriptExportFormatter().format(document: doc, edits: edits, recordingDirectory: root)
            #expect(Data(exported.utf8).range(of: Data(desired.utf8)) != nil)
            let path = version.appendingPathComponent("edits.json")
            let bytes = try Data(contentsOf: path)
            let unchanged = try reopened.saveTurnOverride(resultID: id, turnID: "turn_1", text: desired, displayName: nil)
            #expect(unchanged.revision == saved.revision)
            #expect(try Data(contentsOf: path) == bytes)
        }
    }

    @Test func workspaceUnchangedTextDoesNotCreateRevisionOrFile() throws {
        let root = try temporaryDirectory()
        let (result, version) = try createSyntheticRecording(in: root)
        let doc = try TranscriptDocument.load(from: result, recordingDirectory: root)
        let turn = try #require(doc.turns.first)
        let words = Dictionary(uniqueKeysWithValues: doc.words.map { ($0.id, $0.text) })
        let original = turn.wordIDs.compactMap { words[$0] }.joined(separator: " ")
        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let edits = try repo.saveTurnOverride(resultID: doc.resultID, turnID: turn.id, text: original, displayName: nil)
        #expect(edits.revision == 0)
        #expect(!FileManager.default.fileExists(atPath: version.appendingPathComponent("edits.json").path))
        #expect(throws: Error.self) { try repo.saveTurnOverride(resultID: doc.resultID, turnID: turn.id, text: "  \n", displayName: nil) }
    }

    @Test func testSaveTurnOverrideWithUnknownTurnThrowsInvalidReference() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        _ = try createSyntheticRecording(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.saveTurnOverride(
                resultID: resultID,
                turnID: "nonexistent_turn_999",
                text: "Текст",
                displayName: "Имя"
            )
        } throws: { error in
            guard case .invalidReference = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test func testSaveTurnOverrideWithEmptyDisplayNameThrowsMalformed() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        _ = try createSyntheticRecording(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.saveTurnOverride(
                resultID: resultID,
                turnID: "turn_1",
                text: "Текст",
                displayName: ""
            )
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test func testSaveEditsWithUnknownTurnOrEmptyDisplayNameThrows() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        _ = try createSyntheticRecording(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)

        // 1. Unknown turn in batch
        #expect {
            try repo.saveEdits(
                resultID: resultID,
                overrides: [
                    "turn_1": TranscriptTurnOverride(text: "Текст", displayName: "Имя"),
                    "nonexistent_turn": TranscriptTurnOverride(text: "Текст 2")
                ]
            )
        } throws: { error in
            guard case .invalidReference = error as? TranscriptEditsError else { return false }
            return true
        }

        // 2. Empty displayName in batch
        #expect {
            try repo.saveEdits(
                resultID: resultID,
                overrides: [
                    "turn_1": TranscriptTurnOverride(text: "Текст", displayName: "")
                ]
            )
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test func testSaveTurnOverrideWithInvalidResultIDThrowsResultNotFound() throws {
        let root = try temporaryDirectory()
        let repo = TranscriptEditsRepository(recordingDirectory: root)

        #expect {
            try repo.saveTurnOverride(
                resultID: "../outside",
                turnID: "turn_1",
                text: "Текст",
                displayName: "Имя"
            )
        } throws: { error in
            guard case .resultNotFound = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test func testRevisionOverflowThrowsMalformedWithoutCrashing() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let editsFile = versionDir.appendingPathComponent("edits.json")
        let maxRevJson = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": \(Int.max),
            "overrides": {}
        }
        """
        try Data(maxRevJson.utf8).write(to: editsFile)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        _ = try repo.loadEdits(resultID: resultID)

        #expect {
            try repo.saveTurnOverride(
                resultID: resultID,
                turnID: "turn_1",
                text: "Текст",
                displayName: "Имя"
            )
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test func testConcurrentSavesOnSameRepoAreSerializedAndAccumulateChanges() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)
        let editsFile = versionDir.appendingPathComponent("edits.json")

        let t1EnteredHook = DispatchSemaphore(value: 0)
        let t1AllowCommit = DispatchSemaphore(value: 0)
        let t1Done = DispatchSemaphore(value: 0)
        let t2Done = DispatchSemaphore(value: 0)
        let saveContended = DispatchSemaphore(value: 0)
        defer { t1AllowCommit.signal() }

        final class ThreadResultBox: @unchecked Sendable {
            var saved: TranscriptEdits?
            var error: Error?
        }
        let t1Box = ThreadResultBox()
        let t2Box = ThreadResultBox()

        final class HookBox: @unchecked Sendable {
            private let lock = NSLock()
            private var hookExecuted = false
            func isFirstCall() -> Bool {
                lock.withLock {
                    defer { hookExecuted = true }
                    return !hookExecuted
                }
            }
        }
        let hookBox = HookBox()

        let repo = TranscriptEditsRepository(recordingDirectory: root, operationGateObserver: {
            if $0 == .save { saveContended.signal() }
        }) { _, _ in
            if hookBox.isFirstCall() {
                t1EnteredHook.signal()
                guard t1AllowCommit.wait(timeout: .now() + 5.0) == .success else {
                    struct HookTimeoutError: Error {}
                    throw HookTimeoutError()
                }
            }
        }
        _ = try repo.loadEdits(resultID: resultID)

        // Thread 1 performs first save
        let thread1 = Thread {
            do {
                t1Box.saved = try repo.saveTurnOverride(
                    resultID: resultID,
                    turnID: "turn_1",
                    text: "Текст из потока 1",
                    displayName: "Автор 1"
                )
            } catch {
                t1Box.error = error
            }
            t1Done.signal()
        }
        thread1.start()

        // Independent coordinator: wait until Thread 1 is confirmed inside the hook
        try #require(t1EnteredHook.wait(timeout: .now() + 5.0) == .success)

        // Thread 2 attempts save while Thread 1 is held in hook
        let thread2 = Thread {
            do {
                t2Box.saved = try repo.saveTurnOverride(
                    resultID: resultID,
                    turnID: "turn_2",
                    text: "Текст из потока 2",
                    displayName: "Автор 2"
                )
            } catch {
                t2Box.error = error
            }
            t2Done.signal()
        }
        thread2.start()

        // Positive evidence: Thread 2 actually tried the gate while Thread 1 held it.
        // Timeout is only a failure bound; completion is consumed exactly once below.
        #expect(saveContended.wait(timeout: .now() + 2.0) == .success,
                "Second save never encountered the held operation gate")

        // Allow Thread 1 to commit
        t1AllowCommit.signal()
        try #require(t1Done.wait(timeout: .now() + 5.0) == .success)
        try #require(t2Done.wait(timeout: .now() + 5.0) == .success)

        #expect(t1Box.error == nil, "Thread 1 failed: \(String(describing: t1Box.error))")
        #expect(t2Box.error == nil, "Thread 2 failed: \(String(describing: t2Box.error))")
        #expect(t1Box.saved?.revision == 1)
        #expect(t2Box.saved?.revision == 2)

        let currentEdits = try JSONDecoder().decode(TranscriptEdits.self, from: Data(contentsOf: editsFile))
        #expect(currentEdits.revision == 2)
        #expect(currentEdits.overrides["turn_1"]?.text == "Текст из потока 1")
        #expect(currentEdits.overrides["turn_2"]?.text == "Текст из потока 2")
    }

    @Test func testReleaseLockDuringSaveIsBlockedUntilSaveFinishes() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        _ = try createSyntheticRecording(in: root, resultID: resultID)

        let t1EnteredHook = DispatchSemaphore(value: 0)
        let t1AllowCommit = DispatchSemaphore(value: 0)
        let t1Done = DispatchSemaphore(value: 0)
        let releaseContended = DispatchSemaphore(value: 0)
        let releaseDone = DispatchSemaphore(value: 0)
        defer { t1AllowCommit.signal() }

        final class ThreadResultBox: @unchecked Sendable {
            var error: Error?
        }
        let t1Box = ThreadResultBox()

        let repo1 = TranscriptEditsRepository(recordingDirectory: root, operationGateObserver: {
            if $0 == .release { releaseContended.signal() }
        }) { _, _ in
            t1EnteredHook.signal()
            guard t1AllowCommit.wait(timeout: .now() + 5.0) == .success else {
                struct HookTimeoutError: Error {}
                throw HookTimeoutError()
            }
        }
        _ = try repo1.loadEdits(resultID: resultID)

        let thread1 = Thread {
            do {
                _ = try repo1.saveTurnOverride(
                    resultID: resultID,
                    turnID: "turn_1",
                    text: "Текст 1",
                    displayName: "Автор 1"
                )
            } catch {
                t1Box.error = error
            }
            t1Done.signal()
        }
        thread1.start()

        // Coordinator: wait until thread 1 is confirmed inside the hook
        try #require(t1EnteredHook.wait(timeout: .now() + 5.0) == .success)

        let threadRelease = Thread {
            repo1.releaseWriteLock()
            releaseDone.signal()
        }
        threadRelease.start()

        #expect(releaseContended.wait(timeout: .now() + 2.0) == .success,
                "Release never encountered the held operation gate")

        // While thread 1 is mid-save, contender cannot acquire lock
        let repoContender = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repoContender.acquireWriteLock()
        } throws: { error in
            guard case .lockDenied = error as? TranscriptEditsError else { return false }
            return true
        }

        // Allow thread 1 to finish save
        t1AllowCommit.signal()
        try #require(t1Done.wait(timeout: .now() + 5.0) == .success)
        try #require(releaseDone.wait(timeout: .now() + 5.0) == .success)
        #expect(t1Box.error == nil, "Save in thread 1 failed: \(String(describing: t1Box.error))")

        // Now that release has unblocked and completed, contender can acquire lock
        try repoContender.acquireWriteLock()
        repoContender.releaseWriteLock()
    }

    @Test func testLoadEditsIsBlockedDuringSave() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        _ = try createSyntheticRecording(in: root, resultID: resultID)

        let t1EnteredHook = DispatchSemaphore(value: 0)
        let t1AllowCommit = DispatchSemaphore(value: 0)
        let t1Done = DispatchSemaphore(value: 0)
        let loadDone = DispatchSemaphore(value: 0)
        let loadContended = DispatchSemaphore(value: 0)
        defer { t1AllowCommit.signal() }

        final class ThreadResultBox: @unchecked Sendable {
            var loaded: TranscriptEdits?
            var error: Error?
        }
        let loadBox = ThreadResultBox()
        let saveBox = ThreadResultBox()

        let repo = TranscriptEditsRepository(recordingDirectory: root, operationGateObserver: {
            if $0 == .load { loadContended.signal() }
        }) { _, _ in
            t1EnteredHook.signal()
            guard t1AllowCommit.wait(timeout: .now() + 5.0) == .success else {
                struct HookTimeoutError: Error {}
                throw HookTimeoutError()
            }
        }
        _ = try repo.loadEdits(resultID: resultID)

        let threadSave = Thread {
            do {
                _ = try repo.saveTurnOverride(
                    resultID: resultID,
                    turnID: "turn_1",
                    text: "Текст сохранения",
                    displayName: "Автор"
                )
            } catch {
                saveBox.error = error
            }
            t1Done.signal()
        }
        threadSave.start()

        try #require(t1EnteredHook.wait(timeout: .now() + 5.0) == .success)

        let threadLoad = Thread {
            do {
                loadBox.loaded = try repo.loadEdits(resultID: resultID)
            } catch {
                loadBox.error = error
            }
            loadDone.signal()
        }
        threadLoad.start()

        #expect(loadContended.wait(timeout: .now() + 2.0) == .success,
                "Load never encountered the held operation gate")

        t1AllowCommit.signal()
        try #require(t1Done.wait(timeout: .now() + 5.0) == .success)
        try #require(loadDone.wait(timeout: .now() + 5.0) == .success)

        #expect(loadBox.error == nil)
        #expect(saveBox.error == nil, "Paused save failed: \(String(describing: saveBox.error))")
        #expect(loadBox.loaded?.revision == 1)
        #expect(loadBox.loaded?.overrides["turn_1"]?.text == "Текст сохранения")
    }

    @Test func testDescriptorReuseRegressionNoDoubleClose() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        _ = try createSyntheticRecording(in: root, resultID: resultID)

        struct HookInjectedFailure: Error {}

        final class SentinelBox: @unchecked Sendable {
            var fd: Int32 = -1
        }
        let sentinelBox = SentinelBox()

        let repo = TranscriptEditsRepository(recordingDirectory: root) { _, _ in
            #if canImport(Darwin)
            // Open sentinel descriptor while staging file was closed by writeFully
            sentinelBox.fd = open("/dev/null", O_RDONLY)
            #endif
            throw HookInjectedFailure()
        }
        _ = try repo.loadEdits(resultID: resultID)

        #expect {
            try repo.saveTurnOverride(
                resultID: resultID,
                turnID: "turn_1",
                text: "Тест дескриптора",
                displayName: "Имя"
            )
        } throws: { error in
            error is HookInjectedFailure
        }

        #if canImport(Darwin)
        #expect(sentinelBox.fd >= 0)
        // Verify sentinel descriptor was NOT closed by a double-close in save cleanup
        let flags = fcntl(sentinelBox.fd, F_GETFD)
        #expect(flags != -1, "Sentinel FD was double-closed by save cleanup (errno: \(errno))")
        if sentinelBox.fd >= 0 {
            close(sentinelBox.fd)
        }
        #endif
    }

    @Test func testPartialStagingWriteCleansUpTemporaryFileAndLeavesOldEditsIntact() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)
        let editsFile = versionDir.appendingPathComponent("edits.json")

        // Initial valid edits revision 1
        let initialEdits = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultID,
            revision: 1,
            overrides: [
                "turn_1": TranscriptTurnOverride(text: "Исходный текст", displayName: "Алиса")
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let initialBytes = try encoder.encode(initialEdits)
        try initialBytes.write(to: editsFile)

        struct TestPartialWriteError: Error, Equatable {}

        final class StagingFailureBox: @unchecked Sendable {
            var shouldFail = true
        }
        let failureBox = StagingFailureBox()

        let repo = TranscriptEditsRepository(
            recordingDirectory: root,
            stagingWriteHook: { fd, data in
                if failureBox.shouldFail {
                    // Simulate partial write of 7 bytes followed by an I/O error
                    _ = write(fd, "PARTIAL", 7)
                    throw TestPartialWriteError()
                }
            }
        )
        _ = try repo.loadEdits(resultID: resultID)

        #expect {
            try repo.saveTurnOverride(
                resultID: resultID,
                turnID: "turn_1",
                text: "Новый текст",
                displayName: "Алиса Новая"
            )
        } throws: { error in
            error is TestPartialWriteError
        }

        // 1. Verify no staging temporary files remain leaked in version directory
        let files = try FileManager.default.contentsOfDirectory(atPath: versionDir.path)
        let tempFiles = files.filter { $0.hasPrefix("edits.json.tmp.") }
        #expect(tempFiles.isEmpty, "Found leaked temporary staging files: \(tempFiles)")

        // 2. Old valid edits remain intact
        let currentBytes = try Data(contentsOf: editsFile)
        #expect(currentBytes == initialBytes)

        // 3. Retry after clearing the error succeeds and writes valid non-empty JSON
        failureBox.shouldFail = false
        let saved = try repo.saveTurnOverride(
            resultID: resultID,
            turnID: "turn_1",
            text: "Новый текст",
            displayName: "Алиса Новая"
        )
        #expect(saved.revision == 2)
        #expect(saved.overrides["turn_1"]?.text == "Новый текст")

        let diskBytesAfterRetry = try Data(contentsOf: editsFile)
        #expect(!diskBytesAfterRetry.isEmpty, "edits.json was committed as 0 bytes on retry")
        let decodedDisk = try JSONDecoder().decode(TranscriptEdits.self, from: diskBytesAfterRetry)
        #expect(decodedDisk == saved)

        let reloaded = try repo.loadEdits(resultID: resultID)
        #expect(reloaded == saved)
    }
}
