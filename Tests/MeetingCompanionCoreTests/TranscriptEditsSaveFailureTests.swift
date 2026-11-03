import Foundation
import Testing
@testable import MeetingCompanionCore

/// Injected error simulating an atomic file replacement failure (e.g. disk full or I/O error).
struct InjectedSaveError: Error, Equatable, Sendable {}

@Suite final class TranscriptEditsSaveFailureTests {
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
            "TranscriptEditsSaveFailureTests-" + UUID().uuidString
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

    private final class SaveFailureBox: @unchecked Sendable {
        var shouldFail: Bool = true
        var lastStagedURL: URL?
    }

    @Test func testFailedSavePreservesPreviousEditsAndAllowsRetrySavingNextRevision() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (resultURL, audioURLs, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let initialResultData = try Data(contentsOf: resultURL)
        let initialAudioData = try audioURLs.map { try Data(contentsOf: $0) }

        // Fixture previous valid edits.json directly (revision 1)
        let editsFile = versionDir.appendingPathComponent("edits.json")
        let previousEdits = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultID,
            revision: 1,
            overrides: [
                "turn_1": TranscriptTurnOverride(text: "Предыдущий сохранённый текст", displayName: "Предыдущий Автор")
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let previousData = try encoder.encode(previousEdits)
        try previousData.write(to: editsFile)
        #expect(FileManager.default.fileExists(atPath: editsFile.path))

        let failureBox = SaveFailureBox()
        let repo = TranscriptEditsRepository(recordingDirectory: root) { tempURL, destURL in
            if failureBox.shouldFail {
                #expect(destURL == editsFile)
                #expect(tempURL != destURL)
                #expect(FileManager.default.fileExists(atPath: tempURL.path))
                failureBox.lastStagedURL = tempURL

                let stagedData = try Data(contentsOf: tempURL)
                let staged = try JSONDecoder().decode(TranscriptEdits.self, from: stagedData)
                #expect(staged.schemaVersion == 1)
                #expect(staged.resultID == resultID)
                #expect(staged.revision == 2)
                #expect(staged.overrides["turn_1"]?.text == "Новый неотправленный текст")
                #expect(staged.overrides["turn_1"]?.displayName == "Новый Автор")

                throw InjectedSaveError()
            }
            // Successful path is a no-op; real atomic replacement is performed by production.
        }
        #expect(repo.editsURL(for: resultID) == editsFile)

        // Production loadEdits fixes the initial state (revision 1) in repository.
        // In RED skeleton this throws .notImplemented as expected prerequisite failure.
        let loaded = try repo.loadEdits(resultID: resultID)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.resultID == resultID)
        #expect(loaded.revision == 1)
        #expect(loaded.overrides["turn_1"]?.text == "Предыдущий сохранённый текст")

        // Local caller attempts to save new draft with active injected failure in atomic replace.
        // Must throw the injected failure (specifically rejecting .notImplemented).
        let pendingDraft = TranscriptTurnOverride(text: "Новый неотправленный текст", displayName: "Новый Автор")
        #expect {
            try repo.saveTurnOverride(
                resultID: resultID,
                turnID: "turn_1",
                text: pendingDraft.text,
                displayName: pendingDraft.displayName
            )
        } throws: { error in
            guard error as? TranscriptEditsError != .notImplemented else {
                return false
            }
            return error is InjectedSaveError
        }

        // Post-failure assertions for future GREEN:
        // 1. Last valid edits.json remains bytes-readable and preserved on disk
        let currentEditsData = try Data(contentsOf: editsFile)
        #expect(currentEditsData == previousData)
        let currentEdits = try JSONDecoder().decode(TranscriptEdits.self, from: currentEditsData)
        #expect(currentEdits.revision == 1)
        #expect(currentEdits.overrides["turn_1"]?.text == "Предыдущий сохранённый текст")

        // 2. Failed staging cleanup: staging temporary file removed after failure
        if let stagedURL = failureBox.lastStagedURL {
            #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        }

        // 3. Recognition result and audio files remain byte-for-byte immutable
        let currentResultData = try Data(contentsOf: resultURL)
        #expect(currentResultData == initialResultData)
        for (index, audioURL) in audioURLs.enumerated() {
            let currentAudio = try Data(contentsOf: audioURL)
            #expect(currentAudio == initialAudioData[index])
        }

        // 4. Local pending draft values remain accessible at caller site
        // (sanity check of caller variables without UI/session retention claims).
        #expect(pendingDraft.text == "Новый неотправленный текст")
        #expect(pendingDraft.displayName == "Новый Автор")

        // 5. Retry after clearing the injected error:
        // Squeezes through the seam successfully and saves revision 2.
        failureBox.shouldFail = false
        let saved = try repo.saveTurnOverride(
            resultID: resultID,
            turnID: "turn_1",
            text: pendingDraft.text,
            displayName: pendingDraft.displayName
        )
        #expect(saved.schemaVersion == 1)
        #expect(saved.resultID == resultID)
        #expect(saved.revision == 2)
        #expect(saved.overrides["turn_1"]?.text == "Новый неотправленный текст")
        #expect(saved.overrides["turn_1"]?.displayName == "Новый Автор")

        // 6. On-disk verification after successful retry
        let finalData = try Data(contentsOf: editsFile)
        let finalEdits = try JSONDecoder().decode(TranscriptEdits.self, from: finalData)
        #expect(finalEdits.revision == 2)
        #expect(finalEdits.overrides["turn_1"]?.text == "Новый неотправленный текст")
        #expect(finalEdits.overrides["turn_1"]?.displayName == "Новый Автор")
        #expect(try Data(contentsOf: resultURL) == initialResultData)
        for (index, audioURL) in audioURLs.enumerated() {
            #expect(try Data(contentsOf: audioURL) == initialAudioData[index])
        }
    }

    @Test func testFailedSaveWithInitialAbsentEditsLeavesNoFileAndAllowsRetry() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (resultURL, audioURLs, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let initialResultData = try Data(contentsOf: resultURL)
        let initialAudioData = try audioURLs.map { try Data(contentsOf: $0) }

        let editsFile = versionDir.appendingPathComponent("edits.json")
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        let failureBox = SaveFailureBox()
        let repo = TranscriptEditsRepository(recordingDirectory: root) { tempURL, destURL in
            if failureBox.shouldFail {
                #expect(destURL == editsFile)
                #expect(tempURL != destURL)
                #expect(FileManager.default.fileExists(atPath: tempURL.path))
                failureBox.lastStagedURL = tempURL

                let stagedData = try Data(contentsOf: tempURL)
                let staged = try JSONDecoder().decode(TranscriptEdits.self, from: stagedData)
                #expect(staged.schemaVersion == 1)
                #expect(staged.resultID == resultID)
                #expect(staged.revision == 1)
                #expect(staged.overrides["turn_1"]?.text == "Черновик первой редакции")
                #expect(staged.overrides["turn_1"]?.displayName == "Автор")

                throw InjectedSaveError()
            }
            // Successful path is a no-op; real atomic replacement is performed by production.
        }
        #expect(repo.editsURL(for: resultID) == editsFile)

        // Production loadEdits fixes the initial absent state (revision 0) in repository.
        // In RED skeleton this throws .notImplemented as expected prerequisite failure.
        let loaded = try repo.loadEdits(resultID: resultID)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.resultID == resultID)
        #expect(loaded.revision == 0)
        #expect(loaded.overrides.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // Local caller attempts to save first draft with active failure.
        let pendingDraft = TranscriptTurnOverride(text: "Черновик первой редакции", displayName: "Автор")
        #expect {
            try repo.saveTurnOverride(
                resultID: resultID,
                turnID: "turn_1",
                text: pendingDraft.text,
                displayName: pendingDraft.displayName
            )
        } throws: { error in
            guard error as? TranscriptEditsError != .notImplemented else {
                return false
            }
            return error is InjectedSaveError
        }

        // Post-failure assertions for future GREEN:
        // 1. edits.json remains absent on disk (no corrupt / incomplete file)
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // 2. Failed staging cleanup: staging temporary file removed after failure
        if let stagedURL = failureBox.lastStagedURL {
            #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        }

        // 3. Recognition result and audio files remain byte-for-byte immutable
        let currentResultData = try Data(contentsOf: resultURL)
        #expect(currentResultData == initialResultData)
        for (index, audioURL) in audioURLs.enumerated() {
            let currentAudio = try Data(contentsOf: audioURL)
            #expect(currentAudio == initialAudioData[index])
        }

        // 4. Local pending draft values remain accessible at caller site
        #expect(pendingDraft.text == "Черновик первой редакции")
        #expect(pendingDraft.displayName == "Автор")

        // 5. Retry after clearing injected error:
        // Successfully saves revision 1 on disk.
        failureBox.shouldFail = false
        let saved = try repo.saveTurnOverride(
            resultID: resultID,
            turnID: "turn_1",
            text: pendingDraft.text,
            displayName: pendingDraft.displayName
        )
        #expect(saved.schemaVersion == 1)
        #expect(saved.resultID == resultID)
        #expect(saved.revision == 1)
        #expect(saved.overrides["turn_1"]?.text == "Черновик первой редакции")
        #expect(saved.overrides["turn_1"]?.displayName == "Автор")

        #expect(FileManager.default.fileExists(atPath: editsFile.path))
        let finalData = try Data(contentsOf: editsFile)
        let finalEdits = try JSONDecoder().decode(TranscriptEdits.self, from: finalData)
        #expect(finalEdits.revision == 1)
        #expect(finalEdits.overrides["turn_1"]?.text == "Черновик первой редакции")
        #expect(try Data(contentsOf: resultURL) == initialResultData)
        for (index, audioURL) in audioURLs.enumerated() {
            #expect(try Data(contentsOf: audioURL) == initialAudioData[index])
        }
    }
}
