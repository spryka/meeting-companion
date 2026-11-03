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
        ).appendingPathComponent("meeting")
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

    @Test func testOpenNewStructuredReviewWindow() async throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)

        let coordinator = TranscriptWindowCoordinator()
        #expect(!coordinator.isWindowOpen(for: recordingURL))

        let (state, isNew) = try await coordinator.openWindow(for: recordingURL)
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

    @Test func testRepeatOpenFocusesExistingWindow() async throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)

        let coordinator = TranscriptWindowCoordinator()
        let (state1, isNew1) = try await coordinator.openWindow(for: recordingURL)
        #expect(isNew1)
        #expect(state1.focusRequestedCount == 0)

        // Second call for the same recording
        let (state2, isNew2) = try await coordinator.openWindow(for: recordingURL)
        #expect(!isNew2)
        #expect(state2 === state1) // Exact same instance
        #expect(state1.focusRequestedCount == 1) // Focused count incremented
    }

    // MARK: - 3. Symlink-Equivalent URL Focuses Same Window

    @Test func testSymlinkEquivalentURLFocusesSameWindow() async throws {
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
        let (stateReal, isNewReal) = try await coordinator.openWindow(for: recordingURL)
        #expect(isNewReal)

        // Open via symlink path
        let (stateSym, isNewSym) = try await coordinator.openWindow(for: symlinkRecordingURL)
        #expect(!isNewSym)
        #expect(stateSym === stateReal)
        #expect(stateReal.focusRequestedCount == 1)
    }

    // MARK: - 4. Close and Reopen Creates New Distinct Identity

    @Test func testCloseAndReopenCreatesNewDistinctIdentity() async throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)

        let coordinator = TranscriptWindowCoordinator()
        let (state1, isNew1) = try await coordinator.openWindow(for: recordingURL)
        #expect(isNew1)

        // Close window
        state1.close()
        #expect(!coordinator.isWindowOpen(for: recordingURL))
        #expect(coordinator.windowState(for: recordingURL) == nil)

        // Reopen window
        let (state2, isNew2) = try await coordinator.openWindow(for: recordingURL)
        #expect(isNew2)
        #expect(state2 !== state1) // Must NOT reuse closed instance
        #expect(state2.focusRequestedCount == 0)
        #expect(state2.mode == .review(activeResultID: "res_v1"))
    }

    // MARK: - 5. Selected Version Persistence Integration



    @Test func testLegacyRecordingWithOnlyTXTOpensReadOnly() async throws {
        let root = try temporaryDirectory()
        let recordingURL = root.appendingPathComponent("meeting.m4a")
        let legacyTXT = root.appendingPathComponent("meeting.sources.transcript.txt")
        try Data("LEGACY_TRANSCRIPT_CONTENT\n[00:00:01] Говорящий 1: Привет".utf8).write(to: legacyTXT)

        let coordinator = TranscriptWindowCoordinator()
        let (state, isNew) = try await coordinator.openWindow(for: recordingURL)

        #expect(isNew)
        #expect(state.mode == .legacyReadOnly(transcriptURL: legacyTXT))
        #expect(state.isReadOnly)
        #expect(state.session == nil)
        #expect(state.activeResultID == nil)
        #expect(state.legacyTranscriptURL == legacyTXT)


    }

    // MARK: - 7. Corrupt Structured Result with Fallback TXT

    @Test func testCorruptStructuredResultWithFallbackTXT() async throws {
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
        let (state, isNew) = try await coordinator.openWindow(for: recordingURL)

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

    @Test func testCorruptStructuredResultWithoutFallbackTXT() async throws {
        let root = try temporaryDirectory()
        let recordingURL = root.appendingPathComponent("meeting.m4a")

        // Create corrupt structured version without any TXT
        let versionDir = root.appendingPathComponent("raw/transcripts/res_corrupt")
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let corruptResult = versionDir.appendingPathComponent("result.json")
        try Data("{ corrupt json content...".utf8).write(to: corruptResult)

        let coordinator = TranscriptWindowCoordinator()
        let state = try await coordinator.openWindow(for: recordingURL).state
        #expect(state.isReadOnly)
        #expect(state.session == nil)
    }

    // MARK: - 9. Completely Absent Transcript Throws NotFound

    @Test func testCompletelyAbsentTranscriptThrowsNotFound() async throws {
        let root = try temporaryDirectory()
        let recordingURL = root.appendingPathComponent("meeting.m4a")
        let coordinator = TranscriptWindowCoordinator()
        await #expect(throws: TranscriptWindowError.self) { _ = try await coordinator.openWindow(for: recordingURL) }
    }

    // MARK: - 10. Path Escapes Recording Security Check

    @Test func testPathEscapesRecordingSecurityCheck() async throws {
        let root = try temporaryDirectory()
        let outsideDir = try temporaryDirectory("Outside")

        // Create recording URL outside root
        let outsideRecording = outsideDir.appendingPathComponent("meeting.m4a")

        // Symlink pointing to outside recording
        let symlinkOutside = root.appendingPathComponent("meeting_escaped.m4a")
        try FileManager.default.createSymbolicLink(at: symlinkOutside, withDestinationURL: outsideRecording)

        let coordinator = TranscriptWindowCoordinator()
        // If outside recording has no transcripts, it throws transcriptNotFound or pathEscapesRecording
        await #expect(throws: TranscriptWindowError.self) {
            _ = try await coordinator.openWindow(for: symlinkOutside)
        }
    }

    // MARK: - 11. External Legacy TXT Symlink Rejected and Dangling Link Handled

    @Test func testExternalLegacyTXTSymlinkRejectedAndDanglingLinkHandled() async throws {
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
        await #expect(throws: TranscriptWindowError.self) {
            _ = try await coordinator.openWindow(for: recordingURL)
        }

        // 2. Dangling symlink (destination removed)
        try FileManager.default.removeItem(at: outsideTXT)
        await #expect(throws: TranscriptWindowError.self) {
            _ = try await coordinator.openWindow(for: recordingURL)
        }
    }

    // MARK: - 12. Alias-First Opening Through Directory Symlink

    @Test func testAliasFirstOpeningThroughDirectorySymlink() async throws {
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
        let (state, isNew) = try await coordinator.openWindow(for: symlinkRecordingURL)
        #expect(isNew)
        #expect(state.mode == .review(activeResultID: "res_v1"))
        #expect(state.session != nil)
        #expect(state.session?.recordingDirectory == root.resolvingSymlinksInPath().standardizedFileURL)
    }

    // MARK: - 13. Stale Closed State Does Not Remove Reopened Window

    @Test func testStaleClosedStateDoesNotRemoveReopenedWindow() async throws {
        let root = try temporaryDirectory()
        let recordingURL = try setupSingleVersionRecording(in: root)

        let coordinator = TranscriptWindowCoordinator()
        let (state1, _) = try await coordinator.openWindow(for: recordingURL)

        // Close state1
        state1.close()
        #expect(!coordinator.isWindowOpen(for: recordingURL))

        // Open state2 for the same recording
        let (state2, isNew) = try await coordinator.openWindow(for: recordingURL)
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




}
