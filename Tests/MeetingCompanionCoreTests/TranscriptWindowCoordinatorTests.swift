import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite @MainActor final class TranscriptWindowCoordinatorTests {
    private var cleanup: [URL] = []

    deinit {
        for url in cleanup {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("transcription/fixtures/transcript-document")

    private func fixture(_ name: String) -> URL {
        fixtures.appendingPathComponent(name + ".json")
    }

    private func temporaryDirectory(_ prefix: String = "TranscriptWindowCoordinatorTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            prefix + "-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        return directory
    }

    private func createPublishedVersion(
        in root: URL,
        resultID: String,
        createdAt: String
    ) throws -> URL {
        let versionDir = root.appendingPathComponent("raw/transcripts/\(resultID)")
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let resultURL = versionDir.appendingPathComponent("result.json")
        let docData = try Data(contentsOf: fixture("valid_parakeet_off"))
        var docJson = try JSONSerialization.jsonObject(with: docData) as! [String: Any]
        docJson["resultID"] = resultID
        docJson["createdAt"] = createdAt
        if var pb = docJson["playback"] as? [String: Any] {
            pb["mixPath"] = "raw/transcripts/\(resultID)/mix.m4a"
            docJson["playback"] = pb
        }
        let modifiedData = try JSONSerialization.data(withJSONObject: docJson, options: [.sortedKeys])
        try modifiedData.write(to: resultURL)

        let mixAudio = versionDir.appendingPathComponent("mix.m4a")
        try Data("SYNTHETIC_M4A_MIX_PAYLOAD".utf8).write(to: mixAudio)

        _ = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        return versionDir
    }

    private func setupSingleVersionRecording(in root: URL) throws -> URL {
        let rawDir = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

        let hostAudio = rawDir.appendingPathComponent("meeting.host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("meeting.remote_record.wav")
        try Data("SYNTHETIC_PCM_AUDIO_HOST_16KHZ".utf8).write(to: hostAudio)
        try Data("SYNTHETIC_PCM_AUDIO_REMOTE_16KHZ".utf8).write(to: remoteAudio)

        _ = try createPublishedVersion(in: root, resultID: "res_v1", createdAt: "2026-10-30T10:00:00Z")
        return root.appendingPathComponent("meeting.m4a")
    }

    // MARK: - 1. Open New Structured Review Window

    @Test func testOpenNewStructuredReviewWindow() throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)

        let coordinator = TranscriptWindowCoordinator()
        #expect(!coordinator.isWindowOpen(for: recordingURL))

        let (state, isNew) = try coordinator.openWindow(for: recordingURL)
        #expect(isNew)
        #expect(state.mode == .review(activeResultID: "res_v1"))
        #expect(!state.isReadOnly)
        #expect(state.session != nil)
        #expect(state.activeResultID == "res_v1")
        #expect(state.legacyTranscriptURL == nil)
        #expect(state.focusRequestedCount == 0)
        #expect(coordinator.isWindowOpen(for: recordingURL))
        #expect(coordinator.windowState(for: recordingURL) === state)
    }

    // MARK: - 2. Repeat Open Focuses Existing Window

    @Test func testRepeatOpenFocusesExistingWindow() throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)

        let coordinator = TranscriptWindowCoordinator()
        let (state1, isNew1) = try coordinator.openWindow(for: recordingURL)
        #expect(isNew1)
        #expect(state1.focusRequestedCount == 0)

        // Second call for the same recording
        let (state2, isNew2) = try coordinator.openWindow(for: recordingURL)
        #expect(!isNew2)
        #expect(state2 === state1) // Exact same instance
        #expect(state1.focusRequestedCount == 1) // Focused count incremented
    }

    // MARK: - 3. Symlink-Equivalent URL Focuses Same Window

    @Test func testSymlinkEquivalentURLFocusesSameWindow() throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)

        // Create symlink directory pointing to root
        let symlinkDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SymlinkDir-" + UUID().uuidString
        )
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: root)
        cleanup.append(symlinkDir)

        let symlinkRecordingURL = symlinkDir.appendingPathComponent("meeting.m4a")

        let coordinator = TranscriptWindowCoordinator()
        let (stateReal, isNewReal) = try coordinator.openWindow(for: recordingURL)
        #expect(isNewReal)

        // Open via symlink path
        let (stateSym, isNewSym) = try coordinator.openWindow(for: symlinkRecordingURL)
        #expect(!isNewSym)
        #expect(stateSym === stateReal)
        #expect(stateReal.focusRequestedCount == 1)
    }

    // MARK: - 4. Close and Reopen Creates New Distinct Identity

    @Test func testCloseAndReopenCreatesNewDistinctIdentity() throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)

        let coordinator = TranscriptWindowCoordinator()
        let (state1, isNew1) = try coordinator.openWindow(for: recordingURL)
        #expect(isNew1)

        // Close window
        state1.close()
        #expect(!coordinator.isWindowOpen(for: recordingURL))
        #expect(coordinator.windowState(for: recordingURL) == nil)

        // Reopen window
        let (state2, isNew2) = try coordinator.openWindow(for: recordingURL)
        #expect(isNew2)
        #expect(state2 !== state1) // Must NOT reuse closed instance
        #expect(state2.focusRequestedCount == 0)
        #expect(state2.mode == .review(activeResultID: "res_v1"))
    }

    // MARK: - 5. Selected Version Persistence Integration

    @Test func testSelectedVersionPersistenceIntegration() throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)
        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T14:00:00Z")

        var persistedID: String? = nil
        let coordinator = TranscriptWindowCoordinator()
        let (state, _) = try coordinator.openWindow(for: recordingURL) { newID in
            persistedID = newID
        }

        #expect(state.activeResultID == "res_v2") // latest by date

        // Switch to res_v1
        try state.switchVersion(to: "res_v1")
        #expect(persistedID == "res_v1")
        #expect(state.activeResultID == "res_v1")
        #expect(state.mode == .review(activeResultID: "res_v1"))
    }

    @Test(arguments: [false, true])
    func testCloseDuringPersistenceDoesNotCommitClosedSessionOrWindowMode(closeSessionOnly: Bool) throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)
        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T14:00:00Z")
        try Data("{}".utf8).write(to: root.appendingPathComponent("raw/meeting.processing.json"))
        let selector = TranscriptVersionSelector(recordingDirectory: root, recordingURL: recordingURL)
        try selector.persistSelectedResultID("res_v2")

        var callbackCount = 0
        let coordinator = TranscriptWindowCoordinator()
        let (state, _) = try coordinator.openWindow(for: recordingURL) { newID in
            callbackCount += 1
            try selector.persistSelectedResultID(newID)
            if closeSessionOnly {
                coordinator.windowState(for: recordingURL)?.session?.close()
            } else {
                coordinator.closeAll()
            }
        }
        let retainedSession = try #require(state.session)
        let priorMode = state.mode

        #expect(throws: TranscriptReviewSessionError.closed) {
            try state.switchVersion(to: "res_v1")
        }
        #expect(callbackCount == 1)
        #expect(retainedSession.isClosed)
        #expect(retainedSession.onPersistSelection == nil)
        #expect(retainedSession.activeResultID == "res_v2")
        #expect(state.mode == priorMode)
        #expect(state.isClosed == !closeSessionOnly)
        #expect(coordinator.isWindowOpen(for: recordingURL) == closeSessionOnly)

        // Persistence completed before closure: rejecting the switch does not roll history back.
        #expect(try selector.persistedSelectedResultID() == "res_v1")
        #expect(throws: TranscriptReviewSessionError.closed) {
            try retainedSession.switchVersion(to: "res_v1")
        }
        #expect(callbackCount == 1)

        coordinator.closeAll()
        let (reopened, isNew) = try coordinator.openWindow(for: recordingURL)
        #expect(isNew)
        #expect(reopened !== state)
        #expect(reopened.activeResultID == "res_v1")
        state.close()
        #expect(coordinator.windowState(for: recordingURL) === reopened)
    }

    // MARK: - 6. Legacy Recording with Only TXT Opens Read-Only

    @Test func testLegacyRecordingWithOnlyTXTOpensReadOnly() throws {
        let root = try temporaryDirectory()
        let recordingURL = root.appendingPathComponent("meeting.m4a")
        let legacyTXT = root.appendingPathComponent("meeting.sources.transcript.txt")
        try Data("LEGACY_TRANSCRIPT_CONTENT\n[00:00:01] Говорящий 1: Привет".utf8).write(to: legacyTXT)

        let coordinator = TranscriptWindowCoordinator()
        let (state, isNew) = try coordinator.openWindow(for: recordingURL)

        #expect(isNew)
        #expect(state.mode == .legacyReadOnly(transcriptURL: legacyTXT))
        #expect(state.isReadOnly)
        #expect(state.session == nil)
        #expect(state.activeResultID == nil)
        #expect(state.legacyTranscriptURL == legacyTXT)

        // Editing / switching version is disallowed in read-only legacy mode
        #expect(throws: TranscriptWindowError.self) {
            try state.switchVersion(to: "res_v1")
        }
    }

    // MARK: - 7. Corrupt Structured Result with Fallback TXT

    @Test func testCorruptStructuredResultWithFallbackTXT() throws {
        let root = try temporaryDirectory()
        let recordingURL = root.appendingPathComponent("meeting.m4a")

        // Create corrupt structured version
        let versionDir = root.appendingPathComponent("raw/transcripts/res_corrupt")
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let corruptResult = versionDir.appendingPathComponent("result.json")
        try Data("{ corrupt json content...".utf8).write(to: corruptResult)

        // Also create fallback legacy TXT
        let legacyTXT = root.appendingPathComponent("meeting.sources.transcript.txt")
        try Data("FALLBACK_LEGACY_TXT".utf8).write(to: legacyTXT)

        let coordinator = TranscriptWindowCoordinator()
        let (state, isNew) = try coordinator.openWindow(for: recordingURL)

        #expect(isNew)
        #expect(state.isReadOnly)
        #expect(state.session == nil)
        #expect(state.activeResultID == nil)

        // Must NOT silently pretend it is a normal legacy recording
        if case .corrupt(let error, let fallback) = state.mode {
            #expect(!error.isEmpty)
            #expect(fallback == legacyTXT)
        } else {
            Issue.record("Expected .corrupt mode with fallback TXT, got \(state.mode)")
        }
    }

    // MARK: - 8. Corrupt Structured Result Without Fallback TXT

    @Test func testCorruptStructuredResultWithoutFallbackTXT() throws {
        let root = try temporaryDirectory()
        let recordingURL = root.appendingPathComponent("meeting.m4a")

        // Create corrupt structured version without any TXT
        let versionDir = root.appendingPathComponent("raw/transcripts/res_corrupt")
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let corruptResult = versionDir.appendingPathComponent("result.json")
        try Data("{ corrupt json content...".utf8).write(to: corruptResult)

        let coordinator = TranscriptWindowCoordinator()
        #expect(throws: TranscriptWindowError.self) {
            _ = try coordinator.openWindow(for: recordingURL)
        }
    }

    // MARK: - 9. Completely Absent Transcript Throws NotFound

    @Test func testCompletelyAbsentTranscriptThrowsNotFound() throws {
        let root = try temporaryDirectory()
        let recordingURL = root.appendingPathComponent("meeting.m4a")

        let coordinator = TranscriptWindowCoordinator()
        #expect(throws: TranscriptWindowError.self) {
            _ = try coordinator.openWindow(for: recordingURL)
        }
    }

    // MARK: - 10. Path Escapes Recording Security Check

    @Test func testPathEscapesRecordingSecurityCheck() throws {
        let root = try temporaryDirectory()
        let outsideDir = try temporaryDirectory("Outside")

        // Create recording URL outside root
        let outsideRecording = outsideDir.appendingPathComponent("meeting.m4a")

        // Symlink pointing to outside recording
        let symlinkOutside = root.appendingPathComponent("meeting_escaped.m4a")
        try FileManager.default.createSymbolicLink(at: symlinkOutside, withDestinationURL: outsideRecording)

        let coordinator = TranscriptWindowCoordinator()
        // If outside recording has no transcripts, it throws transcriptNotFound or pathEscapesRecording
        #expect(throws: TranscriptWindowError.self) {
            _ = try coordinator.openWindow(for: symlinkOutside)
        }
    }

    // MARK: - 11. External Legacy TXT Symlink Rejected and Dangling Link Handled

    @Test func testExternalLegacyTXTSymlinkRejectedAndDanglingLinkHandled() throws {
        let root = try temporaryDirectory()
        let outsideDir = try temporaryDirectory("OutsideTXT")
        let recordingURL = root.appendingPathComponent("meeting.m4a")

        // 1. Symlink pointing to an outside file
        let outsideTXT = outsideDir.appendingPathComponent("outside_secret.txt")
        try Data("SECRET_OUTSIDE_DATA".utf8).write(to: outsideTXT)

        let legacyTXTSymlink = root.appendingPathComponent("meeting.sources.transcript.txt")
        try FileManager.default.createSymbolicLink(at: legacyTXTSymlink, withDestinationURL: outsideTXT)

        let coordinator = TranscriptWindowCoordinator()
        // Must reject external symlink escape and NOT expose outside text
        #expect(throws: TranscriptWindowError.self) {
            _ = try coordinator.openWindow(for: recordingURL)
        }

        // 2. Dangling symlink (destination removed)
        try FileManager.default.removeItem(at: outsideTXT)
        #expect(throws: TranscriptWindowError.self) {
            _ = try coordinator.openWindow(for: recordingURL)
        }
    }

    // MARK: - 12. Alias-First Opening Through Directory Symlink

    @Test func testAliasFirstOpeningThroughDirectorySymlink() throws {
        let root = try temporaryDirectory()
        _ = try setupSingleVersionRecording(in: root)

        // Create symlink directory pointing to root
        let symlinkDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SymlinkAliasFirst-" + UUID().uuidString
        )
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: root)
        cleanup.append(symlinkDir)

        let symlinkRecordingURL = symlinkDir.appendingPathComponent("meeting.m4a")

        let coordinator = TranscriptWindowCoordinator()
        // Open through symlink directory FIRST (before any call with real root)
        let (state, isNew) = try coordinator.openWindow(for: symlinkRecordingURL)
        #expect(isNew)
        #expect(state.mode == .review(activeResultID: "res_v1"))
        #expect(state.session != nil)
        #expect(state.session?.recordingDirectory == root.resolvingSymlinksInPath().standardizedFileURL)
    }

    // MARK: - 13. Stale Closed State Does Not Remove Reopened Window

    @Test func testStaleClosedStateDoesNotRemoveReopenedWindow() throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)

        let coordinator = TranscriptWindowCoordinator()
        let (state1, _) = try coordinator.openWindow(for: recordingURL)

        // Close state1
        state1.close()
        #expect(!coordinator.isWindowOpen(for: recordingURL))

        // Open state2 for the same recording
        let (state2, isNew) = try coordinator.openWindow(for: recordingURL)
        #expect(isNew)
        #expect(state2 !== state1)
        #expect(coordinator.isWindowOpen(for: recordingURL))
        #expect(coordinator.windowState(for: recordingURL) === state2)

        // Stale close call on retained state1
        state1.close()

        // state2 must STILL be open!
        #expect(coordinator.isWindowOpen(for: recordingURL))
        #expect(coordinator.windowState(for: recordingURL) === state2)
    }

    // MARK: - 14. Missing Saved Selection Preserves Unavailable Classification

    @Test func testMissingSavedSelectionPreservesUnavailableClassification() throws {
        let root = try temporaryDirectory()
        let recordingURL = root.appendingPathComponent("meeting.m4a")
        let rawDir = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

        let metadataURL = rawDir.appendingPathComponent("meeting.processing.json")
        let metadataJson = """
        {
            "recording": "\(recordingURL.absoluteString)",
            "title": "Test",
            "phase": "completed",
            "selectedResultID": "res_missing_version"
        }
        """
        try Data(metadataJson.utf8).write(to: metadataURL)

        let legacyTXT = root.appendingPathComponent("meeting.sources.transcript.txt")
        try Data("LEGACY_TXT_DATA".utf8).write(to: legacyTXT)

        let coordinator = TranscriptWindowCoordinator()

        // Case A: Zero structured candidates, but explicit selectedResultID is missing
        // With legacy TXT present: must NOT silently fall back to .legacyReadOnly!
        let (stateWithTXT, _) = try coordinator.openWindow(for: recordingURL)
        if case .unavailable(let version, let fallback) = stateWithTXT.mode {
            #expect(version == "res_missing_version")
            #expect(fallback == legacyTXT)
        } else {
            Issue.record("Expected .unavailable mode for missing saved selection, got \(stateWithTXT.mode)")
        }

        // Case B: Without legacy TXT, zero candidates, missing saved selection throws selectedVersionUnavailable
        try FileManager.default.removeItem(at: legacyTXT)
        coordinator.closeAll()
        #expect(throws: TranscriptWindowError.self) {
            _ = try coordinator.openWindow(for: recordingURL)
        }

        // Case C: Structured candidate exists (e.g. res_v1), but saved selection res_missing_version is missing
        _ = try createPublishedVersion(in: root, resultID: "res_v1", createdAt: "2026-10-30T10:00:00Z")
        try Data("LEGACY_TXT_DATA".utf8).write(to: legacyTXT)

        let (stateWithCandidateAndTXT, _) = try coordinator.openWindow(for: recordingURL)
        // Must NOT be classified as .corrupt (it is unavailable selection)
        if case .unavailable(let version, let fallback) = stateWithCandidateAndTXT.mode {
            #expect(version == "res_missing_version")
            #expect(fallback == legacyTXT)
        } else {
            Issue.record("Expected .unavailable mode for missing saved selection, got \(stateWithCandidateAndTXT.mode)")
        }

        // Case D: Structured candidate exists, missing saved selection without TXT throws
        try FileManager.default.removeItem(at: legacyTXT)
        coordinator.closeAll()
        do {
            _ = try coordinator.openWindow(for: recordingURL)
            Issue.record("Expected throwing selectedVersionUnavailable")
        } catch let error as TranscriptWindowError {
            #expect(error == .selectedVersionUnavailable("res_missing_version"))
        }
    }

    // MARK: - 15. Malformed Metadata With TXT Opens Corrupt, Not Clean Legacy

    @Test func testMalformedMetadataWithTXTOpensCorruptNotCleanLegacy() throws {
        let root = try temporaryDirectory()
        let recordingURL = root.appendingPathComponent("meeting.m4a")
        let rawDir = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

        // Corrupt processing.json
        let metadataURL = rawDir.appendingPathComponent("meeting.processing.json")
        try Data("{ corrupt metadata json: [".utf8).write(to: metadataURL)

        let legacyTXT = root.appendingPathComponent("meeting.sources.transcript.txt")
        try Data("LEGACY_TXT_FALLBACK".utf8).write(to: legacyTXT)

        let coordinator = TranscriptWindowCoordinator()

        // With TXT present: must be classified as .corrupt, NOT clean .legacyReadOnly
        let (stateWithTXT, _) = try coordinator.openWindow(for: recordingURL)
        if case .corrupt(let error, let fallback) = stateWithTXT.mode {
            #expect(!error.isEmpty)
            #expect(fallback == legacyTXT)
        } else {
            Issue.record("Expected .corrupt mode for malformed metadata with TXT, got \(stateWithTXT.mode)")
        }

        // Without TXT present: must throw corruptStructuredResult
        try FileManager.default.removeItem(at: legacyTXT)
        coordinator.closeAll()
        #expect(throws: TranscriptWindowError.self) {
            _ = try coordinator.openWindow(for: recordingURL)
        }
    }

    // MARK: - 16. Closed State and Captured Session Cannot Switch Or Callback After Close

    @Test func testClosedStateAndSessionCannotSwitchOrInvokeCallbackAfterClose() throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)
        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T14:00:00Z")

        var callbackCount = 0
        let coordinator = TranscriptWindowCoordinator()

        // 1. Test state.close() path
        let (state1, _) = try coordinator.openWindow(for: recordingURL) { _ in
            callbackCount += 1
        }
        guard let session1 = state1.session else {
            Issue.record("Expected active session")
            return
        }

        // Close state1
        state1.close()
        #expect(!coordinator.isWindowOpen(for: recordingURL))

        // Attempting to switch version on closed state1 must throw and NOT invoke callback
        #expect(throws: (any Error).self) {
            try state1.switchVersion(to: "res_v2")
        }
        #expect(callbackCount == 0)

        // Attempting to switch version on captured session1 must throw and NOT invoke callback
        #expect(throws: (any Error).self) {
            try session1.switchVersion(to: "res_v2")
        }
        #expect(callbackCount == 0)

        // 2. Test coordinator.closeWindow(for:) path
        let (state2, isNew) = try coordinator.openWindow(for: recordingURL) { _ in
            callbackCount += 1
        }
        #expect(isNew)
        guard let session2 = state2.session else {
            Issue.record("Expected active session")
            return
        }

        coordinator.closeWindow(for: recordingURL)
        #expect(!coordinator.isWindowOpen(for: recordingURL))

        // Switching on closed state2 must throw and NOT invoke callback
        #expect(throws: (any Error).self) {
            try state2.switchVersion(to: "res_v2")
        }
        #expect(callbackCount == 0)

        // Switching on captured session2 must throw and NOT invoke callback
        #expect(throws: (any Error).self) {
            try session2.switchVersion(to: "res_v2")
        }
        #expect(callbackCount == 0)
    }
}
