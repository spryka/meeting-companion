import Foundation
import Testing
import Darwin
@testable import MeetingCompanionCore

@Suite final class TranscriptVersionSelectionTests {
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

    private func temporaryDirectory(_ prefix: String = "TranscriptVersionSelectionTests") throws -> URL {
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

    private func setupMultiVersionRecording(in root: URL) throws -> (v1Dir: URL, v2Dir: URL) {
        let rawDir = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

        let hostAudio = rawDir.appendingPathComponent("meeting.host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("meeting.remote_record.wav")
        try Data("SYNTHETIC_PCM_AUDIO_HOST_16KHZ".utf8).write(to: hostAudio)
        try Data("SYNTHETIC_PCM_AUDIO_REMOTE_16KHZ".utf8).write(to: remoteAudio)

        // Version 1: earlier date
        let v1Dir = try createPublishedVersion(in: root, resultID: "res_v1", createdAt: "2026-10-30T10:00:00Z")
        // Version 2: later date
        let v2Dir = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2026-10-30T14:30:00Z")

        return (v1Dir, v2Dir)
    }

    @Test func testInitialNoChoiceSelectsLatestPublishedNonStagingResult() throws {
        let root = try temporaryDirectory()
        _ = try setupMultiVersionRecording(in: root)

        // Add an unfinished staging directory in raw/transcripts
        let stagingDir = root.appendingPathComponent("raw/transcripts/staging-res_v3")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagingResult = stagingDir.appendingPathComponent("result.json")
        try Data("{}".utf8).write(to: stagingResult)

        let selector = TranscriptVersionSelector(recordingDirectory: root)

        #expect(try selector.persistedSelectedResultID() == nil)

        let available = try selector.availableVersions()
        #expect(available.count == 2)
        #expect(available.first?.resultID == "res_v2")
        #expect(available.last?.resultID == "res_v1")

        let resolved = try selector.resolveSelectedResultID()
        #expect(resolved == "res_v2")

        let opened = try selector.selectAndOpenRepository()
        #expect(opened?.resultID == "res_v2")
    }

    @Test func testExplicitSavedSelectionRestoresChosenVersionEvenIfOlder() throws {
        let root = try temporaryDirectory()
        _ = try setupMultiVersionRecording(in: root)

        // Write existing metadata file with recording URL identity
        let recordingURL = root.appendingPathComponent("meeting.m4a")
        let rawDir = root.appendingPathComponent("raw")
        let metadataURL = rawDir.appendingPathComponent("meeting.processing.json")
        let initialJson = """
        {
            "recording": "\(recordingURL.absoluteString)",
            "title": "Совещание",
            "phase": "completed"
        }
        """
        try Data(initialJson.utf8).write(to: metadataURL)

        let selector = TranscriptVersionSelector(recordingURL: recordingURL)

        try selector.persistSelectedResultID("res_v1")
        #expect(try selector.persistedSelectedResultID() == "res_v1")

        let resolved = try selector.resolveSelectedResultID()
        #expect(resolved == "res_v1")

        let opened = try selector.selectAndOpenRepository()
        #expect(opened?.resultID == "res_v1")

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("raw/transcripts/res_v1/result.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("raw/transcripts/res_v2/result.json").path))
    }

    @Test func testExplicitUnavailableSelectionThrowsErrorAndDoesNotSilentlyDefault() throws {
        let root = try temporaryDirectory()
        _ = try setupMultiVersionRecording(in: root)

        let recordingURL = root.appendingPathComponent("meeting.m4a")
        let rawDir = root.appendingPathComponent("raw")
        let metadataURL = rawDir.appendingPathComponent("meeting.processing.json")
        let initialJson = """
        {
            "recording": "\(recordingURL.absoluteString)",
            "selectedResultID": "res_missing_nonexistent"
        }
        """
        try Data(initialJson.utf8).write(to: metadataURL)

        let selector = TranscriptVersionSelector(recordingURL: recordingURL)
        #expect(try selector.persistedSelectedResultID() == "res_missing_nonexistent")

        // Must throw selectedVersionUnavailable and NOT silently return res_v2
        #expect {
            try selector.resolveSelectedResultID()
        } throws: { error in
            guard case .selectedVersionUnavailable("res_missing_nonexistent") = error as? TranscriptVersionSelectionError else {
                return false
            }
            return true
        }
    }

    @Test func testStagingDirectoriesAreIgnoredInVersionSelection() throws {
        let root = try temporaryDirectory()
        _ = try setupMultiVersionRecording(in: root)

        let transcriptsDir = root.appendingPathComponent("raw/transcripts")
        for stagingName in ["staging-version_new", ".tmp.version_in_progress", ".hidden_version"] {
            let sDir = transcriptsDir.appendingPathComponent(stagingName)
            try FileManager.default.createDirectory(at: sDir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: sDir.appendingPathComponent("result.json"))
        }

        let selector = TranscriptVersionSelector(recordingDirectory: root)
        let available = try selector.availableVersions()
        #expect(available.count == 2)
        #expect(!available.contains(where: { $0.resultID.contains("staging") || $0.resultID.hasPrefix(".") }))
    }

    @Test func testLegacyProcessingJSONWithoutSelectedResultIDDecodesGracefully() throws {
        let root = try temporaryDirectory()
        _ = try setupMultiVersionRecording(in: root)

        let recordingURL = root.appendingPathComponent("meeting.m4a")
        let rawDir = root.appendingPathComponent("raw")
        let metadataURL = rawDir.appendingPathComponent("meeting.processing.json")
        let legacyJson = """
        {
            "recording": "\(recordingURL.absoluteString)",
            "date": "2026-10-30T10:00:00Z",
            "title": "Обсуждение",
            "phase": "completed"
        }
        """
        try Data(legacyJson.utf8).write(to: metadataURL)

        let selector = TranscriptVersionSelector(recordingURL: recordingURL)
        #expect(try selector.persistedSelectedResultID() == nil)
        #expect(try selector.resolveSelectedResultID() == "res_v2")
    }

    @Test func testPersistingSelectionPreservesRawNumericTokensAndAllExistingFieldsNonLossy() throws {
        let root = try temporaryDirectory()
        _ = try setupMultiVersionRecording(in: root)

        let recordingURL = root.appendingPathComponent("meeting.m4a")
        let rawDir = root.appendingPathComponent("raw")
        let metadataURL = rawDir.appendingPathComponent("meeting.processing.json")
        let initialMetadataJson = """
        {
            "b": true,
            "date": "2026-10-30T10:00:00Z",
            "i": 9223372036854775807,
            "n": 9007199254740992.1,
            "phase": "completed",
            "recording": "\(recordingURL.absoluteString)",
            "title": "Планирование квартала"
        }
        """
        try Data(initialMetadataJson.utf8).write(to: metadataURL)

        let selector = TranscriptVersionSelector(recordingURL: recordingURL)
        try selector.persistSelectedResultID("res_v1")

        // Re-read metadata file and verify raw text contains exact numeric tokens without loss
        let updatedBytes = try Data(contentsOf: metadataURL)
        let updatedString = String(decoding: updatedBytes, as: UTF8.self)

        #expect(updatedString.contains("\"n\": 9007199254740992.1") || updatedString.contains("\"n\" : 9007199254740992.1"))
        #expect(updatedString.contains("9223372036854775807"))
        #expect(updatedString.contains("\"title\": \"Планирование квартала\"") || updatedString.contains("\"title\" : \"Планирование квартала\""))
        #expect(try selector.persistedSelectedResultID() == "res_v1")
    }

    @Test func testCorruptProcessingJSONThrowsAndPreservesOriginalBytesWithoutOverwriting() throws {
        let root = try temporaryDirectory()
        _ = try setupMultiVersionRecording(in: root)

        let recordingURL = root.appendingPathComponent("meeting.m4a")
        let rawDir = root.appendingPathComponent("raw")
        let metadataURL = rawDir.appendingPathComponent("meeting.processing.json")
        let corruptData = Data("{broken".utf8)
        try corruptData.write(to: metadataURL)

        let selector = TranscriptVersionSelector(recordingURL: recordingURL)

        #expect {
            try selector.persistedSelectedResultID()
        } throws: { error in
            guard case .malformedMetadata = error as? TranscriptVersionSelectionError else { return false }
            return true
        }

        #expect {
            try selector.persistSelectedResultID("res_v1")
        } throws: { error in
            guard case .malformedMetadata = error as? TranscriptVersionSelectionError else { return false }
            return true
        }

        // Original corrupt bytes must remain intact on disk
        #expect(try Data(contentsOf: metadataURL) == corruptData)
    }

    @Test func testRawOrTranscriptsSymlinkOutsideRecordingDirectoryIsRejected() throws {
        let parentDir = try temporaryDirectory("parent")
        let root = parentDir.appendingPathComponent("recording")
        let outside = try temporaryDirectory("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Make raw a symlink pointing outside recording
        let rawLink = root.appendingPathComponent("raw")
        try FileManager.default.createSymbolicLink(at: rawLink, withDestinationURL: outside)

        let selector = TranscriptVersionSelector(recordingDirectory: root)
        #expect {
            try selector.availableVersions()
        } throws: { error in
            guard case .pathEscapesRecording = error as? TranscriptVersionSelectionError else { return false }
            return true
        }

        #expect {
            try selector.persistSelectedResultID("res_v1")
        } throws: { error in
            guard case .pathEscapesRecording = error as? TranscriptVersionSelectionError else { return false }
            return true
        }
    }

    @Test func testMultipleRecordingsInFolderUseExactIdentityNotFirstFile() throws {
        let root = try temporaryDirectory("multiRec")
        let rawDir = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

        let rec1 = root.appendingPathComponent("meeting_1.m4a")
        let rec2 = root.appendingPathComponent("meeting_2.m4a")
        let meta1 = rawDir.appendingPathComponent("meeting_1.processing.json")
        let meta2 = rawDir.appendingPathComponent("meeting_2.processing.json")

        try Data("{\"selectedResultID\": \"res_v1\"}".utf8).write(to: meta1)
        try Data("{\"selectedResultID\": \"res_v2\"}".utf8).write(to: meta2)

        let selector1 = TranscriptVersionSelector(recordingURL: rec1)
        let selector2 = TranscriptVersionSelector(recordingURL: rec2)

        #expect(try selector1.persistedSelectedResultID() == "res_v1")
        #expect(try selector2.persistedSelectedResultID() == "res_v2")
    }

    @Test func testLegacyRootMetadataWithoutRawDirectorySupported() throws {
        let root = try temporaryDirectory("legacyRoot")
        let rec = root.appendingPathComponent("meeting_legacy.m4a")
        let metaRoot = root.appendingPathComponent("meeting_legacy.processing.json")
        try Data("{\"selectedResultID\": \"res_legacy\"}".utf8).write(to: metaRoot)

        let selector = TranscriptVersionSelector(recordingURL: rec)
        #expect(try selector.persistedSelectedResultID() == "res_legacy")
    }

    @Test func testExplicitSelectionWithZeroVersionsThrowsSelectedVersionUnavailable() throws {
        let root = try temporaryDirectory("zeroVersions")
        let rec = root.appendingPathComponent("meeting.m4a")
        let rawDir = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let meta = rawDir.appendingPathComponent("meeting.processing.json")
        try Data("{\"selectedResultID\": \"res_nonexistent\"}".utf8).write(to: meta)

        let selector = TranscriptVersionSelector(recordingURL: rec)
        #expect(try selector.persistedSelectedResultID() == "res_nonexistent")

        // Zero published versions exist on disk: must throw selectedVersionUnavailable, NOT return nil!
        #expect {
            try selector.resolveSelectedResultID()
        } throws: { error in
            guard case .selectedVersionUnavailable("res_nonexistent") = error as? TranscriptVersionSelectionError else {
                return false
            }
            return true
        }
    }

    @Test func testSymlinkToOutsideResultJSONIsRejected() throws {
        let root = try temporaryDirectory("symlinkResult")
        let outsideDir = try temporaryDirectory("outsideResult")
        _ = try setupMultiVersionRecording(in: root)

        let resultV1Dir = root.appendingPathComponent("raw/transcripts/res_v1")
        let realResult = resultV1Dir.appendingPathComponent("result.json")
        let outsideResult = outsideDir.appendingPathComponent("stolen_result.json")

        // Move result.json outside and link to it
        try FileManager.default.moveItem(at: realResult, to: outsideResult)
        try FileManager.default.createSymbolicLink(at: realResult, withDestinationURL: outsideResult)

        let selector = TranscriptVersionSelector(recordingDirectory: root)
        let available = try selector.availableVersions()
        // res_v1 whose result.json is a symlink outside must be rejected!
        #expect(!available.contains(where: { $0.resultID == "res_v1" }))
        #expect(available.contains(where: { $0.resultID == "res_v2" }))
    }

    @Test(arguments: ["42", "{}", "[]", "true"])
    func testWrongSelectionTypeRejectedOnReadAndWrite(value: String) throws {
        let root = try temporaryDirectory()
        _ = try setupMultiVersionRecording(in: root)
        let recording = root.appendingPathComponent("meeting.m4a")
        let metadata = root.appendingPathComponent("raw/meeting.processing.json")
        let original = Data("{\"selectedResultID\":\(value)}".utf8)
        try original.write(to: metadata)
        let selector = TranscriptVersionSelector(recordingURL: recording)
        for operation in [
            { _ = try selector.persistedSelectedResultID() },
            { _ = try selector.resolveSelectedResultID() },
            { try selector.persistSelectedResultID("res_v1") }
        ] {
            #expect(throws: TranscriptVersionSelectionError.self) { try operation() }
            #expect(try Data(contentsOf: metadata) == original)
        }
    }

    @Test(arguments: ["", "{}", "{\"selectedResultID\":null}", "{\"selectedResultID\":\"gone\"}"])
    func testLegacyRootOnlyResolution(payload: String) throws {
        let root = try temporaryDirectory()
        let recording = root.appendingPathComponent("old.m4a")
        if !payload.isEmpty {
            try Data(payload.utf8).write(to: root.appendingPathComponent("old.processing.json"))
        }
        let selector = TranscriptVersionSelector(recordingURL: recording)
        #expect(try selector.availableVersions().isEmpty)
        if payload.contains("gone") {
            #expect(throws: TranscriptVersionSelectionError.selectedVersionUnavailable("gone")) {
                try selector.resolveSelectedResultID()
            }
        } else {
            #expect(try selector.resolveSelectedResultID() == nil)
        }
    }

    @Test(arguments: ["raw", "raw/transcripts"])
    func testDanglingDirectorySymlinkIsNotAbsence(component: String) throws {
        let root = try temporaryDirectory()
        let link = root.appendingPathComponent(component)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing"))
        let selector = TranscriptVersionSelector(recordingURL: root.appendingPathComponent("old.m4a"))
        #expect(throws: TranscriptVersionSelectionError.self) { try selector.availableVersions() }
        if component == "raw" {
            #expect(throws: TranscriptVersionSelectionError.self) { try selector.persistedSelectedResultID() }
        }
    }

    @Test func testDirectoryPermissionFailureIsNotAbsence() throws {
        let root = try temporaryDirectory()
        let raw = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        #expect(chmod(raw.path, 0) == 0)
        defer { _ = chmod(raw.path, 0o700) }
        let selector = TranscriptVersionSelector(recordingURL: root.appendingPathComponent("old.m4a"))
        #expect(throws: TranscriptVersionSelectionError.self) { try selector.availableVersions() }
        #expect(throws: TranscriptVersionSelectionError.self) { try selector.persistedSelectedResultID() }
    }

    @Test func testRecordingHistoryIntegrationLiveEntryRetainsSelectedResultIDAcrossUpdates() throws {
        let root = try temporaryDirectory()
        _ = try setupMultiVersionRecording(in: root)

        // Compile and run the independent history probe harness linking current code
        let probeSource = """
        import Foundation
        import MeetingCompanionCore

        @main struct ProbeMain {
            @MainActor static func main() throws {
                let root = URL(fileURLWithPath: CommandLine.arguments[1])
                let recording = root.appendingPathComponent("meeting_probe.m4a")

                let history = RecordingHistory()
                let initialEntry = RecordingEntry(recording: recording, date: Date(), title: "Original", phase: .completed)
                history.put(initialEntry)

                // Select version via authoritative history model
                history.selectResultID("res_v1", for: recording)

                guard history.entry(recording)?.selectedResultID == "res_v1" else {
                    fputs("FAIL: live entry did not record selectedResultID\\n", stderr)
                    exit(1)
                }

                let metadata = root.appendingPathComponent("raw/meeting_probe.processing.json")
                let selector = TranscriptVersionSelector(recordingURL: recording)
                guard try selector.persistedSelectedResultID() == "res_v1" else {
                    fputs("FAIL: selector did not read persisted selectedResultID\\n", stderr)
                    exit(2)
                }

                // Add an unknown high-precision numeric token to metadata
                var text = String(decoding: try Data(contentsOf: metadata), as: UTF8.self)
                text = String(text.dropLast()) + ",\\"n\\":9007199254740992.1}"
                try Data(text.utf8).write(to: metadata)

                // Normal lifecycle update (title change) must retain selectedResultID and preserve unknown token
                history.update(recording) { $0.title = "Updated Title" }

                guard history.entry(recording)?.selectedResultID == "res_v1" else {
                    fputs("FAIL: live entry lost selectedResultID after normal update\\n", stderr)
                    exit(3)
                }
                guard try selector.persistedSelectedResultID() == "res_v1" else {
                    fputs("FAIL: disk lost selectedResultID after normal update\\n", stderr)
                    exit(4)
                }

                let afterUpdateData = try Data(contentsOf: metadata)
                let afterUpdateStr = String(decoding: afterUpdateData, as: UTF8.self)
                guard afterUpdateStr.contains("9007199254740992.1") else {
                    fputs("FAIL: unknown precise number was lost during normal history update\\n", stderr)
                    exit(5)
                }

                var failures: [String] = []
                let stableEntry = history.entry(recording)!
                for payload in ["{broken", "{\\\"selectedResultID\\\":42}", "{\\\"selectedResultID\\\":{}}"] {
                    for selecting in [false, true] {
                        let history = RecordingHistory()
                        history.put(stableEntry, persist: false)
                        let original = Data(payload.utf8)
                        try original.write(to: metadata)
                        if selecting { history.selectResultID("res_v2", for: recording) }
                        else { history.update(recording) { $0.title = "Must not publish" } }
                        if try Data(contentsOf: metadata) != original { failures.append("overwrote \\(payload), selecting=\\(selecting)") }
                        if history.entry(recording) != stableEntry { failures.append("published failed update \\(payload), selecting=\\(selecting)") }
                        if history.error == nil { failures.append("no visible error \\(payload), selecting=\\(selecting)") }
                    }
                }
                try FileManager.default.removeItem(at: metadata)
                let missingTarget = root.appendingPathComponent("missing-metadata")
                try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: missingTarget)
                history.put(stableEntry, persist: false)
                history.selectResultID("res_v2", for: recording)
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: metadata.path)) != missingTarget.path {
                    failures.append("replaced dangling metadata symlink")
                }
                if history.entry(recording) != stableEntry { failures.append("published dangling-link update") }
                try FileManager.default.removeItem(at: metadata)
                try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
                let unreadableHistory = RecordingHistory()
                unreadableHistory.put(stableEntry, persist: false)
                unreadableHistory.selectResultID("res_v2", for: recording)
                if unreadableHistory.error == nil || unreadableHistory.entry(recording) != stableEntry {
                    failures.append("metadata read error was not preserved")
                }
                if !failures.isEmpty {
                    fputs((failures.joined(separator: "\\n") + "\\n").cString(using: .utf8)!, stderr)
                    exit(6)
                }
                fputs("PROBE_SUCCESS\\n", stdout)
            }
        }
        """
        let probeSourceURL = root.appendingPathComponent("ProbeMain.swift")
        try Data(probeSourceSourceBytes: probeSource.utf8).write(to: probeSourceURL)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let historySwift = repoRoot.appendingPathComponent("Sources/MeetingCompanionApp/RecordingHistory.swift")
        let probeBin = root.appendingPathComponent("probe_bin")

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
        #expect(runOutput.contains("PROBE_SUCCESS"))
    }
}

private extension Data {
    init(probeSourceSourceBytes bytes: String.UTF8View) {
        self.init(bytes)
    }
}
