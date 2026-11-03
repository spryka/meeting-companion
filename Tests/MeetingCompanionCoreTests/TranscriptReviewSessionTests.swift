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

    @Test func closedSessionCannotEditAndReopenResolvesCurrent() async throws {
        let root = try temporaryDirectory()
        try setupInitialRecording(in: root)
        let session = try #require(try TranscriptReviewSession.open(recordingDirectory: root))
        let saved = try session.editsRepository.saveTurnOverride(resultID: "res_v1", turnID: "turn_1", text: "Saved", displayName: "Alice")
        #expect(saved.revision == 1)
        let preview = try session.previewGroupAssignment(speakerID: "spk_h1", replaceManuallyAssigned: false)
        session.close()
        #expect(throws: TranscriptReviewSessionError.self) { try session.assignSpeakerName(preview: preview, displayName: "Closed") }
        let oldBytes = try Data(contentsOf: root.appendingPathComponent("raw/transcripts/res_v1/edits.json"))
        let next = try createPublishedVersion(in: root, resultID: "res_v2", createdAt: "2000-01-01T00:00:00Z")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: root.appendingPathComponent("raw/transcripts/res_v1").path)
        let reopened = try #require(try TranscriptReviewSession.open(recordingDirectory: root))
        #expect(reopened.activeResultID == next.lastPathComponent)
        #expect { try reopened.assignSpeakerName(preview: preview, displayName: "Wrong") } throws: { ($0 as? TranscriptEditsError) != nil }
        #expect(try Data(contentsOf: root.appendingPathComponent("raw/transcripts/res_v1/edits.json")) == oldBytes)
        #expect(!FileManager.default.fileExists(atPath: next.appendingPathComponent("edits.json").path))
    }

    @Test func stagingDoesNotChangeCurrentOrOriginalBytes() async throws {
        let root = try temporaryDirectory()
        let recording = try setupInitialRecording(in: root)
        let original = try Data(contentsOf: root.appendingPathComponent("raw/meeting.host_record.wav"))
        let staging = root.appendingPathComponent("raw/transcripts/.staging-failed")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: staging.appendingPathComponent("result.json"))
        let session = try #require(try TranscriptReviewSession.open(recordingURL: recording))
        #expect(session.activeResultID == "res_v1")
        #expect(try Data(contentsOf: root.appendingPathComponent("raw/meeting.host_record.wav")) == original)
    }

    @Test func noResultsReturnsNil() throws {
        let root = try temporaryDirectory()
        #expect(try TranscriptReviewSession.open(recordingDirectory: root) == nil)
    }
}
