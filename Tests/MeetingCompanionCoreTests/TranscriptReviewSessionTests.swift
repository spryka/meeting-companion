import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite @MainActor final class TranscriptReviewSessionTests {
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

    private func temporaryDirectory(_ prefix: String = "TranscriptReviewSessionTests") throws -> URL {
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
        let versionDir = root
            .appendingPathComponent("raw")
            .appendingPathComponent("transcripts")
            .appendingPathComponent(resultID)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let resultURL = versionDir.appendingPathComponent("result.json")
        let fixtureData = try Data(contentsOf: fixture("valid_parakeet_off"))
        var docJson = try #require(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
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

    @discardableResult
    private func setupInitialRecording(in root: URL, baseName: String = "meeting") throws -> URL {
        let rawDir = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

        let recURL = root.appendingPathComponent("\(baseName).m4a")
        try Data("SYNTHETIC_MASTER_MIX_SENTINEL".utf8).write(to: recURL)
        let metadata = rawDir.appendingPathComponent("\(baseName).processing.json")
        try Data("{\"recording\":\"\(recURL.absoluteString)\"}".utf8).write(to: metadata)

        let hostAudio = rawDir.appendingPathComponent("\(baseName).host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("\(baseName).remote_record.wav")
        try Data("SYNTHETIC_PCM_AUDIO_HOST_16KHZ".utf8).write(to: hostAudio)
        try Data("SYNTHETIC_PCM_AUDIO_REMOTE_16KHZ".utf8).write(to: remoteAudio)

        // Version 1 published initially
        _ = try createPublishedVersion(in: root, resultID: "res_v1", createdAt: "2026-10-30T10:00:00Z")
        return recURL
    }

    @Test func testOpenedSessionPinsActiveResultIDWhenNewVersionIsPublished() throws {
        let root = try temporaryDirectory()
        try setupInitialRecording(in: root)

        let session = try #require(try TranscriptReviewSession.open(recordingDirectory: root))
        #expect(session.activeResultID == "res_v1")

        // Save initial edits on res_v1
        let saved1 = try session.editsRepository.saveTurnOverride(
            resultID: session.activeResultID,
            turnID: "turn_1",
            text: "Правка версии 1",
            displayName: "Алиса"
        )
        #expect(saved1.revision == 1)

        // Simulate background successful retry publishing new version res_v2
        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T14:00:00Z")

        // Available versions now has both versions
        let available = try session.selector.availableVersions()
        #expect(available.count == 2)
        #expect(available.first?.resultID == "res_v2")

        // CRITICAL INVARIANT: The open session MUST remain pinned to res_v1!
        #expect(session.activeResultID == "res_v1")

        // Additional edit on res_v1 still updates res_v1 without touching res_v2
        let saved2 = try session.editsRepository.saveTurnOverride(
            resultID: session.activeResultID,
            turnID: "turn_1",
            text: "Правка 2 версии 1",
            displayName: "Алиса 2"
        )
        #expect(saved2.revision == 2)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("raw/transcripts/res_v2/edits.json").path))
    }

    @Test func testFailedRetryStagingDoesNotAffectSessionOrAvailableVersions() throws {
        let root = try temporaryDirectory()
        try setupInitialRecording(in: root)

        let session = try #require(try TranscriptReviewSession.open(recordingDirectory: root))
        #expect(session.activeResultID == "res_v1")

        // Simulate interrupted/failed retry publication leaving staging
        let stagingDir = root.appendingPathComponent("raw/transcripts/staging-res_failed")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stagingDir.appendingPathComponent("result.json"))

        let available = try session.selector.availableVersions()
        #expect(available.count == 1)
        #expect(available.first?.resultID == "res_v1")
        #expect(session.activeResultID == "res_v1")
    }

    @Test func testExplicitVersionSwitchIsTransactionalAndPersistsToHistory() throws {
        let root = try temporaryDirectory()
        try setupInitialRecording(in: root)

        let recURL = root.appendingPathComponent("meeting.m4a")
        let metadata = root.appendingPathComponent("raw/meeting.processing.json")
        try Data("{\"recording\":\"\(recURL.absoluteString)\"}".utf8).write(to: metadata)

        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T12:00:00Z")

        let session = try #require(try TranscriptReviewSession.open(recordingURL: recURL))
        // Opens latest res_v2 by default
        #expect(session.activeResultID == "res_v2")

        // Explicitly switch to older res_v1
        try session.switchVersion(to: "res_v1")
        #expect(session.activeResultID == "res_v1")
        #expect(try session.selector.persistedSelectedResultID() == "res_v1")

        // Reopening new session resolves persisted selection res_v1
        let sessionReopened = try #require(try TranscriptReviewSession.open(recordingURL: recURL))
        #expect(sessionReopened.activeResultID == "res_v1")
    }

    @Test func testFailedVersionSwitchDoesNotMutateActiveSession() throws {
        let root = try temporaryDirectory()
        try setupInitialRecording(in: root)

        let session = try #require(try TranscriptReviewSession.open(recordingDirectory: root))
        #expect(session.activeResultID == "res_v1")

        // Attempt to switch to nonexistent version
        #expect {
            try session.switchVersion(to: "res_nonexistent")
        } throws: { error in
            guard case .selectedVersionUnavailable = error as? TranscriptVersionSelectionError else { return false }
            return true
        }

        // Active version must NOT be mutated on failure
        #expect(session.activeResultID == "res_v1")
    }

    @Test func testLegacyRecordingWithoutResultsReturnsNil() throws {
        let root = try temporaryDirectory()
        let session = try TranscriptReviewSession.open(recordingDirectory: root)
        #expect(session == nil)
    }

    @Test func testRecordingHistoryIntegrationWithSessionSwitchAndReopen() throws {
        let root = try temporaryDirectory()
        try setupInitialRecording(in: root)
        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T14:00:00Z")

        let probeSource = """
        import Foundation
        import MeetingCompanionCore

        @main struct ProbeSession {
            @MainActor static func main() throws {
                let root = URL(fileURLWithPath: CommandLine.arguments[1])
                let recording = root.appendingPathComponent("meeting_session.m4a")

                let history = RecordingHistory()
                let entry = RecordingEntry(recording: recording, date: Date(), title: "Session Test", phase: .completed)
                history.put(entry)

                // Open session with history persistence adapter
                guard let session = try TranscriptReviewSession.open(
                    recordingURL: recording,
                    onPersistSelection: { resultID in
                        try history.selectResultIDThrowing(resultID, for: recording)
                    }
                ) else {
                    fputs("FAIL: session open returned nil\\n", stderr)
                    exit(1)
                }

                // Initial open resolves latest res_v2
                guard session.activeResultID == "res_v2" else {
                    fputs("FAIL: initial session activeResultID != res_v2\\n", stderr)
                    exit(2)
                }

                // Explicit switch to res_v1 through session
                try session.switchVersion(to: "res_v1")
                guard session.activeResultID == "res_v1" else {
                    fputs("FAIL: activeResultID did not switch to res_v1\\n", stderr)
                    exit(3)
                }
                guard history.entry(recording)?.selectedResultID == "res_v1" else {
                    fputs("FAIL: history live entry not updated on switch\\n", stderr)
                    exit(4)
                }

                // Ordinary lifecycle update retains selection
                history.update(recording) { $0.title = "Renamed Meeting" }
                guard history.entry(recording)?.selectedResultID == "res_v1" else {
                    fputs("FAIL: history lost selection after title update\\n", stderr)
                    exit(5)
                }

                // Reopened session opens res_v1
                guard let session2 = try TranscriptReviewSession.open(recordingURL: recording),
                      session2.activeResultID == "res_v1" else {
                    fputs("FAIL: reopened session did not open res_v1\\n", stderr)
                    exit(6)
                }

                fputs("SESSION_PROBE_SUCCESS\\n", stdout)
            }
        }
        """
        let probeSourceURL = root.appendingPathComponent("ProbeSession.swift")
        try Data(probeSource.utf8).write(to: probeSourceURL)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let historySwift = repoRoot.appendingPathComponent("Sources/MeetingCompanionApp/RecordingHistory.swift")
        let probeBin = root.appendingPathComponent("probe_session_bin")

        let compileProcess = Process()
        compileProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compileProcess.arguments = [
            "-parse-as-library",
            "-I", repoRoot.appendingPathComponent(".build/out/Intermediates.noindex/MeetingCompanion.build/Debug/MeetingCompanionCore-t.build/Objects-normal/arm64").path,
            historySwift.path,
            probeSourceURL.path,
            repoRoot.appendingPathComponent(".build/out/Products/Debug/MeetingCompanionCore.o").path,
            "-framework", "AVFoundation",
            "-framework", "CoreMedia",
            "-framework", "ScreenCaptureKit",
            "-o", probeBin.path
        ]
        let compilePipe = Pipe()
        compileProcess.standardError = compilePipe
        try compileProcess.run()
        compileProcess.waitUntilExit()

        #expect(compileProcess.terminationStatus == 0, "Probe compilation failed: \(String(decoding: compilePipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")

        let runProcess = Process()
        runProcess.executableURL = probeBin
        runProcess.arguments = [root.path]
        let runPipe = Pipe()
        runProcess.standardOutput = runPipe
        runProcess.standardError = runPipe
        try runProcess.run()
        runProcess.waitUntilExit()

        let runOutput = String(decoding: runPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(runProcess.terminationStatus == 0, "Probe failed with output: \(runOutput)")
        #expect(runOutput.contains("SESSION_PROBE_SUCCESS"))
    }

    @Test func testActualAppHistoryMetadataCorruptSwitchThrowsKeepsSessionLiveDiskPrior() throws {
        let root = try temporaryDirectory()
        try setupInitialRecording(in: root)
        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T14:00:00Z")

        let probeSource = """
        import Foundation
        import MeetingCompanionCore

        @main struct ProbeCorruptSwitch {
            @MainActor static func main() throws {
                let root = URL(fileURLWithPath: CommandLine.arguments[1])
                let recording = root.appendingPathComponent("meeting_corrupt.m4a")

                let history = RecordingHistory()
                let entry = RecordingEntry(recording: recording, date: Date(), title: "Corrupt Test", phase: .completed)
                history.put(entry)

                // Initial choice res_v2
                history.selectResultID("res_v2", for: recording)

                guard let session = try TranscriptReviewSession.open(
                    recordingURL: recording,
                    onPersistSelection: { resultID in
                        try history.selectResultIDThrowing(resultID, for: recording)
                    }
                ) else {
                    fputs("FAIL: session open returned nil\\n", stderr)
                    exit(1)
                }

                guard session.activeResultID == "res_v2" else {
                    fputs("FAIL: activeResultID != res_v2\\n", stderr)
                    exit(2)
                }

                // Corrupt metadata on disk
                let metadata = root.appendingPathComponent("raw/meeting_corrupt.processing.json")
                let corruptBytes = Data("{broken".utf8)
                try corruptBytes.write(to: metadata)

                // Attempt switch to res_v1 must throw error because metadata is corrupt!
                var threwExpectedError = false
                do {
                    try session.switchVersion(to: "res_v1")
                } catch {
                    threwExpectedError = true
                }
                guard threwExpectedError else {
                    fputs("FAIL: switch reported success on corrupt metadata\\n", stderr)
                    exit(3)
                }

                // Verify session remains on res_v2
                guard session.activeResultID == "res_v2" else {
                    fputs("FAIL: session activeResultID changed despite error\\n", stderr)
                    exit(4)
                }

                // Verify live history retains res_v2
                guard history.entry(recording)?.selectedResultID == "res_v2" else {
                    fputs("FAIL: live history entry lost prior selectedResultID\\n", stderr)
                    exit(5)
                }

                // Verify corrupt disk bytes were preserved and not overwritten
                guard (try? Data(contentsOf: metadata)) == corruptBytes else {
                    fputs("FAIL: corrupt disk bytes were overwritten\\n", stderr)
                    exit(6)
                }

                fputs("CORRUPT_PROBE_SUCCESS\\n", stdout)
            }
        }
        """
        let probeSourceURL = root.appendingPathComponent("ProbeCorruptSwitch.swift")
        try Data(probeSource.utf8).write(to: probeSourceURL)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let historySwift = repoRoot.appendingPathComponent("Sources/MeetingCompanionApp/RecordingHistory.swift")
        let probeBin = root.appendingPathComponent("probe_corrupt_bin")

        let compileProcess = Process()
        compileProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compileProcess.arguments = [
            "-parse-as-library",
            "-I", repoRoot.appendingPathComponent(".build/out/Intermediates.noindex/MeetingCompanion.build/Debug/MeetingCompanionCore-t.build/Objects-normal/arm64").path,
            historySwift.path,
            probeSourceURL.path,
            repoRoot.appendingPathComponent(".build/out/Products/Debug/MeetingCompanionCore.o").path,
            "-framework", "AVFoundation",
            "-framework", "CoreMedia",
            "-framework", "ScreenCaptureKit",
            "-o", probeBin.path
        ]
        let compilePipe = Pipe()
        compileProcess.standardError = compilePipe
        try compileProcess.run()
        compileProcess.waitUntilExit()

        #expect(compileProcess.terminationStatus == 0, "Probe compilation failed: \(String(decoding: compilePipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")

        let runProcess = Process()
        runProcess.executableURL = probeBin
        runProcess.arguments = [root.path]
        let runPipe = Pipe()
        runProcess.standardOutput = runPipe
        runProcess.standardError = runPipe
        try runProcess.run()
        runProcess.waitUntilExit()

        let runOutput = String(decoding: runPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(runProcess.terminationStatus == 0, "Probe failed with output: \(runOutput)")
        #expect(runOutput.contains("CORRUPT_PROBE_SUCCESS"))
    }

    @Test func testActualAppHistoryNaNDurationSwitchThrowsKeepsSessionLiveDiskPrior() throws {
        let root = try temporaryDirectory()
        try setupInitialRecording(in: root)
        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T14:00:00Z")

        let probeSource = """
        import Foundation
        import MeetingCompanionCore

        @main struct ProbeNaNSwitch {
            @MainActor static func main() throws {
                let root = URL(fileURLWithPath: CommandLine.arguments[1])
                let recording = root.appendingPathComponent("meeting.m4a")

                let history = RecordingHistory()
                var entry = RecordingEntry(recording: recording, date: Date(), title: "NaN Test", phase: .completed)
                entry.selectedResultID = "res_v2"
                history.put(entry)

                let metadata = root.appendingPathComponent("raw/meeting.processing.json")
                let priorDiskBytes = try Data(contentsOf: metadata)

                // Inject unencodable duration using supported persist: false
                entry.duration = .nan
                history.put(entry, persist: false)

                guard let session = try TranscriptReviewSession.open(
                    recordingURL: recording,
                    onPersistSelection: { resultID in
                        try history.selectResultIDThrowing(resultID, for: recording)
                    }
                ) else {
                    fputs("FAIL: session open returned nil\\n", stderr)
                    exit(1)
                }

                guard session.activeResultID == "res_v2" else {
                    fputs("FAIL: activeResultID != res_v2\\n", stderr)
                    exit(2)
                }

                // Attempt switch to res_v1 must throw error because duration is .nan!
                var threwExpectedError = false
                do {
                    try session.switchVersion(to: "res_v1")
                } catch {
                    threwExpectedError = true
                }
                guard threwExpectedError else {
                    fputs("FAIL: switch reported success despite unencodable duration\\n", stderr)
                    exit(3)
                }

                // Verify session remains on res_v2
                guard session.activeResultID == "res_v2" else {
                    fputs("FAIL: session activeResultID changed despite error\\n", stderr)
                    exit(4)
                }

                // Verify live history retains res_v2
                guard history.entry(recording)?.selectedResultID == "res_v2" else {
                    fputs("FAIL: live history entry lost prior selectedResultID\\n", stderr)
                    exit(5)
                }

                // Verify prior disk bytes were preserved and not modified
                guard (try? Data(contentsOf: metadata)) == priorDiskBytes else {
                    fputs("FAIL: prior disk bytes were modified during failed switch\\n", stderr)
                    exit(6)
                }

                // Now restore a valid duration and verify normal successful switch persists once
                history.update(recording) { $0.duration = 42.0 }
                try session.switchVersion(to: "res_v1")

                guard session.activeResultID == "res_v1" else {
                    fputs("FAIL: session activeResultID != res_v1 after valid switch\\n", stderr)
                    exit(7)
                }
                guard history.entry(recording)?.selectedResultID == "res_v1" else {
                    fputs("FAIL: live history entry != res_v1 after valid switch\\n", stderr)
                    exit(8)
                }
                let updatedDisk = try String(decoding: Data(contentsOf: metadata), as: UTF8.self)
                guard updatedDisk.contains("\\"selectedResultID\\" : \\"res_v1\\"") else {
                    fputs("FAIL: disk did not persist res_v1\\n", stderr)
                    exit(9)
                }

                fputs("NAN_PROBE_SUCCESS\\n", stdout)
            }
        }
        """
        let probeSourceURL = root.appendingPathComponent("ProbeNaNSwitch.swift")
        try Data(probeSource.utf8).write(to: probeSourceURL)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let historySwift = repoRoot.appendingPathComponent("Sources/MeetingCompanionApp/RecordingHistory.swift")
        let probeBin = root.appendingPathComponent("probe_nan_bin")

        let compileProcess = Process()
        compileProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compileProcess.arguments = [
            "-parse-as-library",
            "-I", repoRoot.appendingPathComponent(".build/out/Intermediates.noindex/MeetingCompanion.build/Debug/MeetingCompanionCore-t.build/Objects-normal/arm64").path,
            historySwift.path,
            probeSourceURL.path,
            repoRoot.appendingPathComponent(".build/out/Products/Debug/MeetingCompanionCore.o").path,
            "-framework", "AVFoundation",
            "-framework", "CoreMedia",
            "-framework", "ScreenCaptureKit",
            "-o", probeBin.path
        ]
        let compilePipe = Pipe()
        compileProcess.standardError = compilePipe
        try compileProcess.run()
        compileProcess.waitUntilExit()

        #expect(compileProcess.terminationStatus == 0, "Probe compilation failed: \(String(decoding: compilePipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")

        let runProcess = Process()
        runProcess.executableURL = probeBin
        runProcess.arguments = [root.path]
        let runPipe = Pipe()
        runProcess.standardOutput = runPipe
        runProcess.standardError = runPipe
        try runProcess.run()
        runProcess.waitUntilExit()

        let runOutput = String(decoding: runPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(runProcess.terminationStatus == 0, "Probe failed with output: \(runOutput)")
        #expect(runOutput.contains("NAN_PROBE_SUCCESS"))
    }

    @Test func testCallbackReadsActiveIDWithoutDeadlock() throws {
        let root = try temporaryDirectory()
        let recURL = try setupInitialRecording(in: root)
        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T14:00:00Z")

        final class CallbackBox: @unchecked Sendable {
            weak var session: TranscriptReviewSession?
            var readActiveDuringCallback: String?
            var callbackExecuted = false
        }
        let box = CallbackBox()

        let maybeSession = try TranscriptReviewSession.open(
            recordingURL: recURL,
            onPersistSelection: { [weak box] newResultID in
                guard let b = box else { return }
                b.callbackExecuted = true
                // In reentrant callback, read session.activeResultID without deadlock
                b.readActiveDuringCallback = b.session?.activeResultID
                let meta = root.appendingPathComponent("raw/meeting.processing.json")
                try? Data("{\"selectedResultID\":\"\(newResultID)\"}".utf8).write(to: meta)
            }
        )
        let session = try #require(maybeSession)
        box.session = session

        #expect(session.activeResultID == "res_v2")

        try session.switchVersion(to: "res_v1")
        #expect(box.callbackExecuted)
        #expect(box.readActiveDuringCallback == "res_v2")
        #expect(session.activeResultID == "res_v1")
    }

    @Test func testBackgroundCallActorHop() async throws {
        let root = try temporaryDirectory()
        let recURL = try setupInitialRecording(in: root)
        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T14:00:00Z")

        let session = try #require(try TranscriptReviewSession.open(recordingURL: recURL))
        #expect(session.activeResultID == "res_v2")

        // Call switchVersion from background detached task without MainActor.assumeIsolated or SIGTRAP
        try await Task.detached {
            try await session.switchVersion(to: "res_v1")
        }.value

        #expect(session.activeResultID == "res_v1")
    }

    @Test func testDirectBytePreservationBeforeNewPublishFailedStagingAndSwitch() throws {
        let root = try temporaryDirectory()
        let recURL = try setupInitialRecording(in: root)

        // Capture initial byte representations for version 1
        let v1ResultURL = root.appendingPathComponent("raw/transcripts/res_v1/result.json")
        let v1ResultBytes = try Data(contentsOf: v1ResultURL)

        let session = try #require(try TranscriptReviewSession.open(recordingURL: recURL))
        let saved1 = try session.editsRepository.saveTurnOverride(
            resultID: "res_v1",
            turnID: "turn_1",
            text: "Initial Edit",
            displayName: "Alice"
        )
        #expect(saved1.revision == 1)

        let v1EditsURL = session.editsRepository.editsURL(for: "res_v1")
        let v1EditsBytes = try Data(contentsOf: v1EditsURL)

        let hostAudioURL = root.appendingPathComponent("raw/meeting.host_record.wav")
        let remoteAudioURL = root.appendingPathComponent("raw/meeting.remote_record.wav")
        let hostBytes = try Data(contentsOf: hostAudioURL)
        let remoteBytes = try Data(contentsOf: remoteAudioURL)

        let masterMixBytes = try Data(contentsOf: recURL)
        let v1MixURL = root.appendingPathComponent("raw/transcripts/res_v1/mix.m4a")
        let v1MixBytes = try Data(contentsOf: v1MixURL)

        // 1. Synthetic retry: publication of new version res_v2 (simulated artifact layout, NOT actual pipeline)
        _ = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T12:00:00Z")

        // Byte preservation after publication
        #expect(try Data(contentsOf: v1ResultURL) == v1ResultBytes)
        #expect(try Data(contentsOf: v1EditsURL) == v1EditsBytes)
        #expect(try Data(contentsOf: hostAudioURL) == hostBytes)
        #expect(try Data(contentsOf: remoteAudioURL) == remoteBytes)
        #expect(try Data(contentsOf: recURL) == masterMixBytes)
        #expect(try Data(contentsOf: v1MixURL) == v1MixBytes)

        // 2. Synthetic failed retry: creation of staging directory (simulated artifact layout, NOT actual pipeline)
        let stagingDir = root.appendingPathComponent("raw/transcripts/staging-failed")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stagingDir.appendingPathComponent("result.json"))

        // Byte preservation after failed staging
        #expect(try Data(contentsOf: v1ResultURL) == v1ResultBytes)
        #expect(try Data(contentsOf: v1EditsURL) == v1EditsBytes)
        #expect(try Data(contentsOf: hostAudioURL) == hostBytes)
        #expect(try Data(contentsOf: remoteAudioURL) == remoteBytes)
        #expect(try Data(contentsOf: recURL) == masterMixBytes)
        #expect(try Data(contentsOf: v1MixURL) == v1MixBytes)

        // 3. Explicit switch to res_v2
        try session.switchVersion(to: "res_v2")
        #expect(session.activeResultID == "res_v2")

        // Byte preservation of res_v1 after switch
        #expect(try Data(contentsOf: v1ResultURL) == v1ResultBytes)
        #expect(try Data(contentsOf: v1EditsURL) == v1EditsBytes)
        #expect(try Data(contentsOf: hostAudioURL) == hostBytes)
        #expect(try Data(contentsOf: remoteAudioURL) == remoteBytes)
        #expect(try Data(contentsOf: recURL) == masterMixBytes)
        #expect(try Data(contentsOf: v1MixURL) == v1MixBytes)
    }
}
