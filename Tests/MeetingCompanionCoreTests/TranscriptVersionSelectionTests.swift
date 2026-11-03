import Foundation
import Testing
import Darwin
import MeetingCompanionApplication
@testable import MeetingCompanionCore

@Suite final class TranscriptResultStorageTests {
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

    private func temporaryDirectory(_ prefix: String = "TranscriptVersionSelectionTests") throws -> URL {
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

    @Test func creationDateChoosesBeforeValidationAndIgnoresSelection() throws {
        let root = try temporaryDirectory()
        let pair = try setupMultiVersionRecording(in: root)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1), .modificationDate: Date()], ofItemAtPath: pair.v1Dir.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: pair.v2Dir.path)
        let metadata = root.appendingPathComponent("raw/meeting.processing.json")
        let bytes = Data("{\"selectedResultID\":\"res_v1\"}".utf8)
        try bytes.write(to: metadata)
        let storage = TranscriptResultStorage(recordingURL: root.appendingPathComponent("meeting.m4a"))
        #expect(try storage.currentDocument()?.resultID == "res_v2")
        try Data("{broken".utf8).write(to: pair.v2Dir.appendingPathComponent("result.json"))
        #expect(throws: Error.self) { try storage.currentDocument() }
        #expect(try Data(contentsOf: metadata) == bytes)
    }

    @Test func directoryNameBreaksCreationDateTieAndStagingIsExcluded() throws {
        let root = try temporaryDirectory()
        let pair = try setupMultiVersionRecording(in: root)
        for dir in [pair.v1Dir, pair.v2Dir] {
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: dir.path)
        }
        for name in ["staging-z", ".staging-z", "z.tmp"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("raw/transcripts/" + name), withIntermediateDirectories: true)
        }
        #expect(try TranscriptResultStorage(recordingDirectory: root).currentDocument()?.resultID == "res_v2")
    }

    @Test(arguments: ["raw", "raw/transcripts", "raw/transcripts/res_v2/result.json"])
    func escapingAndDanglingSymlinksAreRejected(component: String) throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let target = root.appendingPathComponent(component)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        #expect(throws: TranscriptStorageError.self) { try TranscriptResultStorage(recordingDirectory: root).currentDocument() }
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("missing"))
        #expect(throws: TranscriptStorageError.self) { try TranscriptResultStorage(recordingDirectory: root).currentDocument() }
    }

    @Test func unreadableDirectoryIsNotAbsence() throws {
        let root = try temporaryDirectory()
        let dir = root.appendingPathComponent("raw/transcripts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        #expect(throws: Error.self) { try TranscriptResultStorage(recordingDirectory: root).currentDocument() }
    }

    @Test func exactMetadataIdentityAndLosslessRepeatedSaves() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
        let recording = root.appendingPathComponent("meeting.m4a")
        let entry = RecordingEntry(recording: recording, date: Date(), title: "Before", phase: .completed)
        let other = entry.metadata.deletingLastPathComponent().appendingPathComponent("aaa.processing.json")
        try Data("{broken".utf8).write(to: other)
        let number = "1234567890123456789012345678901234567890.1234567890123456789"
        let raw = Data(("{\"recordingFormatVersion\":1,\"recordingFormatVersion\":999,\"selectedResultID\":42,\"unknown\":" + number + "}").utf8)
        try raw.write(to: entry.metadata)
        let repository = RecordingHistoryRepository()
        try repository.putThrowing(entry)
        for i in 0..<3 { _ = repository.updateStatus(recording) { $0.title = String(i) } }
        let saved = try String(contentsOf: entry.metadata, encoding: .utf8)
        #expect(saved.contains(number))
        #expect(saved.components(separatedBy: "\"recordingFormatVersion\"").count - 1 == 2)
        #expect(saved.contains("\"selectedResultID\": 42"))
        #expect(RecordingEntry.load(recording: recording).title == "2")
        #expect(try Data(contentsOf: other) == Data("{broken".utf8))
        try Data("{broken".utf8).write(to: entry.metadata)
        #expect(throws: Error.self) { try repository.putThrowing(entry) }
        #expect(try Data(contentsOf: entry.metadata) == Data("{broken".utf8))
    }
}
