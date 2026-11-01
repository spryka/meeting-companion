import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import MeetingCompanionCore

@Suite final class TranscriptEditsConflictTests {
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

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TranscriptEditsConflictTests-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        return directory
    }

    private func createSyntheticRecording(
        in root: URL,
        resultID: String = "res_valid_parakeet_off"
    ) throws -> (resultURL: URL, audioURLs: [URL], versionDir: URL) {
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

        let hostBytes = Data("SYNTHETIC_PCM_AUDIO_HOST_16KHZ".utf8)
        let remoteBytes = Data("SYNTHETIC_PCM_AUDIO_REMOTE_16KHZ".utf8)
        let mixBytes = Data("SYNTHETIC_M4A_MIX_AUDIO_PAYLOAD".utf8)

        try hostBytes.write(to: hostAudio)
        try remoteBytes.write(to: remoteAudio)
        try mixBytes.write(to: mixAudio)

        // Validate baseline document with production reader to ensure valid starting state
        _ = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)

        return (resultURL, [hostAudio, remoteAudio, mixAudio], versionDir)
    }

    @Test func testConflictWhenExternalWriterChangesRevisionAndOverrides() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (resultURL, audioURLs, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let initialResultData = try Data(contentsOf: resultURL)
        let initialAudioData = try audioURLs.map { try Data(contentsOf: $0) }

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let editsFile = repo.editsURL(for: resultID)
        #expect(editsFile == versionDir.appendingPathComponent("edits.json"))

        // Directly prepare initial valid edits.json per design (schemaVersion=1, nonnegative revision=1, overrides for existing turn_1)
        let initialEdits = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultID,
            revision: 1,
            overrides: [
                "turn_1": TranscriptTurnOverride(text: "Начальный сохранённый текст", displayName: "Алиса")
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let initialData = try encoder.encode(initialEdits)
        try initialData.write(to: editsFile)
        #expect(FileManager.default.fileExists(atPath: editsFile.path))

        // Production loadEdits fixes the opened state in the repository.
        // In RED skeleton this throws .notImplemented as expected prerequisite failure.
        let loaded = try repo.loadEdits(resultID: resultID)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.resultID == resultID)
        #expect(loaded.revision == 1)

        // External writer synchronously modifies edits.json BEFORE save:
        // changes revision (1 -> 2) and supplies new valid overrides.
        let externalEdits = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultID,
            revision: 2,
            overrides: [
                "turn_1": TranscriptTurnOverride(text: "Внешняя правка другого автора", displayName: "Алиса Внешняя")
            ]
        )
        let externalData = try encoder.encode(externalEdits)
        try externalData.write(to: editsFile)

        // Local caller attempts to save local draft via production API.
        // Must throw TranscriptEditsError.conflict specifically (not .notImplemented, not generic error).
        let draftOverride = TranscriptTurnOverride(text: "Локальный черновик", displayName: "Алиса Локальная")
        #expect {
            try repo.saveTurnOverride(
                resultID: resultID,
                turnID: "turn_1",
                text: draftOverride.text,
                displayName: draftOverride.displayName
            )
        } throws: { error in
            guard case .conflict = error as? TranscriptEditsError else {
                return false
            }
            return true
        }

        // Post-conflict assertions for future GREEN:
        // 1. External writer's bytes on disk are preserved and not overwritten
        let currentEditsData = try Data(contentsOf: editsFile)
        #expect(currentEditsData == externalData)

        // 2. Recognition result and audio files remain byte-for-byte immutable
        let currentResultData = try Data(contentsOf: resultURL)
        #expect(currentResultData == initialResultData)
        for (index, audioURL) in audioURLs.enumerated() {
            let currentAudio = try Data(contentsOf: audioURL)
            #expect(currentAudio == initialAudioData[index])
        }

        // 3. Caller-value sanity checks: verify caller-owned draft values remain accessible.
        // Note: these checks only verify caller-side local values and do not provide
        // guarantees about repository partial state or UI/session retention.
        #expect(draftOverride.text == "Локальный черновик")
        #expect(draftOverride.displayName == "Алиса Локальная")
    }

    @Test func testConflictWhenExternalWriterChangesContentWithUnchangedRevision() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (resultURL, audioURLs, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let initialResultData = try Data(contentsOf: resultURL)
        let initialAudioData = try audioURLs.map { try Data(contentsOf: $0) }

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let editsFile = repo.editsURL(for: resultID)
        #expect(editsFile == versionDir.appendingPathComponent("edits.json"))

        // Initial valid edits.json with revision 1
        // Using fixed-width strings so external payload can match byte length exactly
        let initialJSON = "{\"overrides\":{\"turn_1\":{\"displayName\":\"Alice\",\"text\":\"Alpha\"}},\"resultID\":\"\(resultID)\",\"revision\":1,\"schemaVersion\":1}\n"
        let initialData = Data(initialJSON.utf8)
        try initialData.write(to: editsFile)

        #if canImport(Darwin)
        var st = stat()
        #expect(stat(editsFile.path, &st) == 0)
        let initialTimes = [st.st_atimespec, st.st_mtimespec]
        #endif

        // Production loadEdits fixes the opened state.
        // In RED skeleton this throws .notImplemented as expected prerequisite failure.
        let loaded = try repo.loadEdits(resultID: resultID)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.resultID == resultID)
        #expect(loaded.revision == 1)

        // External writer synchronously modifies content BEFORE save:
        // revision remains UNCHANGED (1), but text and displayName differ.
        // Byte length is identical and mtime is restored so size/mtime-only checks cannot pass.
        let externalJSON = "{\"overrides\":{\"turn_1\":{\"displayName\":\"Carol\",\"text\":\"Bravo\"}},\"resultID\":\"\(resultID)\",\"revision\":1,\"schemaVersion\":1}\n"
        let externalData = Data(externalJSON.utf8)
        #expect(externalData.count == initialData.count)
        try externalData.write(to: editsFile)

        #if canImport(Darwin)
        utimensat(AT_FDCWD, editsFile.path, initialTimes, 0)
        var stAfter = stat()
        #expect(stat(editsFile.path, &stAfter) == 0)
        #expect(stAfter.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec)
        #expect(stAfter.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec)
        #endif

        // Local caller attempts to save local draft via production API.
        // Must throw TranscriptEditsError.conflict specifically.
        let draftOverride = TranscriptTurnOverride(text: "Delta", displayName: "David")
        #expect {
            try repo.saveTurnOverride(
                resultID: resultID,
                turnID: "turn_1",
                text: draftOverride.text,
                displayName: draftOverride.displayName
            )
        } throws: { error in
            guard case .conflict = error as? TranscriptEditsError else {
                return false
            }
            return true
        }

        // Post-conflict assertions for future GREEN:
        // 1. External writer's bytes on disk are preserved
        let currentEditsData = try Data(contentsOf: editsFile)
        #expect(currentEditsData == externalData)

        // 2. Recognition result and audio files remain byte-for-byte immutable
        let currentResultData = try Data(contentsOf: resultURL)
        #expect(currentResultData == initialResultData)
        for (index, audioURL) in audioURLs.enumerated() {
            let currentAudio = try Data(contentsOf: audioURL)
            #expect(currentAudio == initialAudioData[index])
        }

        // 3. Caller-value sanity checks: verify caller-owned draft values remain accessible
        // without claiming repository partial state or UI/session guarantees.
        #expect(draftOverride.text == "Delta")
        #expect(draftOverride.displayName == "David")
    }
}
