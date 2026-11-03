import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite final class TranscriptEditsPresenceConflictTests {
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

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TranscriptEditsPresenceConflictTests-" + UUID().uuidString
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

    @Test func testConflictWhenExternalWriterCreatesEditsAfterInitialAbsentLoad() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (resultURL, audioURLs, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let initialResultData = try Data(contentsOf: resultURL)
        let initialAudioData = try audioURLs.map { try Data(contentsOf: $0) }

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let editsFile = repo.editsURL(for: resultID)
        #expect(editsFile == versionDir.appendingPathComponent("edits.json"))

        // Initial condition: edits.json is absent on disk
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // Production loadEdits fixes the initial absent state (revision 0) in repository.
        // In RED skeleton this throws .notImplemented as expected prerequisite failure.
        let loaded = try repo.loadEdits(resultID: resultID)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.resultID == resultID)
        #expect(loaded.revision == 0)
        #expect(loaded.overrides.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // External writer synchronously creates valid edits.json BEFORE save:
        // schemaVersion=1, revision=1, and valid turn override.
        let externalEdits = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultID,
            revision: 1,
            overrides: [
                "turn_1": TranscriptTurnOverride(text: "Внешне созданный текст", displayName: "Внешний Автор")
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let externalData = try encoder.encode(externalEdits)
        try externalData.write(to: editsFile)
        #expect(FileManager.default.fileExists(atPath: editsFile.path))

        // Local caller attempts to save local draft via production API.
        // Must throw TranscriptEditsError.conflict specifically (not silently overwrite external creation).
        let draftOverride = TranscriptTurnOverride(text: "Локальный текст", displayName: "Локальный Автор")
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

        // 3. Caller-value sanity checks: verify caller-owned draft values remain accessible
        // without claiming repository partial state or UI/session guarantees.
        #expect(draftOverride.text == "Локальный текст")
        #expect(draftOverride.displayName == "Локальный Автор")
    }

    @Test func testConflictWhenExternalWriterDeletesEditsAfterInitialLoad() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (resultURL, audioURLs, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let initialResultData = try Data(contentsOf: resultURL)
        let initialAudioData = try audioURLs.map { try Data(contentsOf: $0) }

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let editsFile = repo.editsURL(for: resultID)
        #expect(editsFile == versionDir.appendingPathComponent("edits.json"))

        // Initial condition: valid edits.json exists on disk
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

        // Production loadEdits fixes the initial existing state (revision 1) in repository.
        // In RED skeleton this throws .notImplemented as expected prerequisite failure.
        let loaded = try repo.loadEdits(resultID: resultID)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.resultID == resultID)
        #expect(loaded.revision == 1)
        #expect(loaded.overrides["turn_1"]?.text == "Начальный сохранённый текст")

        // External process synchronously deletes edits.json BEFORE save
        try FileManager.default.removeItem(at: editsFile)
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // Local caller attempts to save local draft via production API.
        // Must throw TranscriptEditsError.conflict specifically (must NOT silently recreate file as revision 1).
        let draftOverride = TranscriptTurnOverride(text: "Локальный черновик после удаления", displayName: "Алиса Локальная")
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
        // 1. edits.json remains absent on disk (deletion is preserved, not recreated)
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // 2. Recognition result and audio files remain byte-for-byte immutable
        let currentResultData = try Data(contentsOf: resultURL)
        #expect(currentResultData == initialResultData)
        for (index, audioURL) in audioURLs.enumerated() {
            let currentAudio = try Data(contentsOf: audioURL)
            #expect(currentAudio == initialAudioData[index])
        }

        // 3. Caller-value sanity checks: verify caller-owned draft values remain accessible
        // without claiming repository partial state or UI/session guarantees.
        #expect(draftOverride.text == "Локальный черновик после удаления")
        #expect(draftOverride.displayName == "Алиса Локальная")
    }
}
