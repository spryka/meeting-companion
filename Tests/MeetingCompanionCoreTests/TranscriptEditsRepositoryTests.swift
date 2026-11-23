import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite final class TranscriptEditsRepositoryTests {
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
            "TranscriptEditsRepositoryTests-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        return directory
    }

    private func createSyntheticRecording(
        in root: URL,
        resultID: String = "res_valid_parakeet_off"
    ) throws -> (resultURL: URL, audioURLs: [URL]) {
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

        return (resultURL, [hostAudio, remoteAudio, mixAudio])
    }

    @Test func testDurableEditsHappyPathReopenRestoresLatestState() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (resultURL, audioURLs) = try createSyntheticRecording(in: root, resultID: resultID)

        let initialResultData = try Data(contentsOf: resultURL)
        let initialAudioData = try audioURLs.map { try Data(contentsOf: $0) }

        var repo1: TranscriptEditsRepository? = TranscriptEditsRepository(recordingDirectory: root)
        let editsFile = repo1!.editsURL(for: resultID)

        // Initial condition: no edits.json on disk
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        // First save: override text and displayName of a specific turn (turn_1)
        let saved1 = try repo1!.saveTurnOverride(
            resultID: resultID,
            turnID: "turn_1",
            text: "Первая редакция реплики",
            displayName: "Алиса"
        )
        #expect(saved1.schemaVersion == 2)
        #expect(saved1.resultID == resultID)
        #expect(saved1.revision == 1)
        #expect(saved1.overrides["turn_1"]?.text == "Первая редакция реплики")
        #expect(saved1.overrides["turn_1"]?.displayName == "Алиса")

        // Sequential repeated save for latest state: increments revision to 2
        let saved2 = try repo1!.saveTurnOverride(
            resultID: resultID,
            turnID: "turn_1",
            text: "Финальный исправленный текст реплики",
            displayName: "Алиса"
        )
        #expect(saved2.schemaVersion == 2)
        #expect(saved2.resultID == resultID)
        #expect(saved2.revision == 2)
        #expect(saved2.overrides["turn_1"]?.text == "Финальный исправленный текст реплики")
        #expect(saved2.overrides["turn_1"]?.displayName == "Алиса")

        // Close repository instance 1
        repo1 = nil

        // Open NEW repository instance for the same recording directory
        let repo2 = TranscriptEditsRepository(recordingDirectory: root)
        let restored = try repo2.loadEdits(resultID: resultID)

        // Verify restoration of the last saved state
        #expect(restored.schemaVersion == 2)
        #expect(restored.resultID == resultID)
        #expect(restored.revision == 2)
        #expect(restored.overrides["turn_1"]?.text == "Финальный исправленный текст реплики")
        #expect(restored.overrides["turn_1"]?.displayName == "Алиса")

        // Post-RED disk verification: edits.json file structure and fields
        #expect(FileManager.default.fileExists(atPath: editsFile.path))
        let editsData = try Data(contentsOf: editsFile)
        let rawJson = try #require(JSONSerialization.jsonObject(with: editsData) as? [String: Any])
        #expect(rawJson["schemaVersion"] as? Int == 2)
        #expect(rawJson["resultID"] as? String == resultID)
        #expect(rawJson["revision"] as? Int == 2)
        let rawOverrides = try #require(rawJson["overrides"] as? [String: Any])
        let turn1Overrides = try #require(rawOverrides["turn_1"] as? [String: Any])
        #expect(turn1Overrides["text"] as? String == "Финальный исправленный текст реплики")
        #expect(turn1Overrides["displayName"] as? String == "Алиса")

        // Byte-for-byte immutability of result.json (recognition baseline, IDs, intervals)
        let currentResultData = try Data(contentsOf: resultURL)
        #expect(currentResultData == initialResultData)

        // Production document reader re-verifies result.json consistency
        let reloadedDoc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        #expect(reloadedDoc.resultID == resultID)
        #expect(reloadedDoc.turns.first?.id == "turn_1")
        #expect(reloadedDoc.turns.first?.start == 0.5)
        #expect(reloadedDoc.turns.first?.end == 1.6)

        // Byte-for-byte immutability of synthetic audio files
        for (index, audioURL) in audioURLs.enumerated() {
            let currentAudio = try Data(contentsOf: audioURL)
            #expect(currentAudio == initialAudioData[index])
        }
    }

    @Test func testInitialAbsenceOfEditsYieldsRevisionZero() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (resultURL, _) = try createSyntheticRecording(in: root, resultID: resultID)
        #expect(FileManager.default.fileExists(atPath: resultURL.path))

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let editsFile = repo.editsURL(for: resultID)
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        let initial = try repo.loadEdits(resultID: resultID)
        #expect(initial.schemaVersion == 1)
        #expect(initial.resultID == resultID)
        #expect(initial.revision == 0)
        #expect(initial.overrides.isEmpty)

        // Must not create edits.json on disk just by reading initial revision 0
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))
    }

    @Test func v2SavedNamesAndPendingLearningSurviveTextEditAndExport() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (resultURL, _) = try createSyntheticRecording(in: root, resultID: resultID)
        let document = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let editsURL = repo.editsURL(for: resultID)

        let manual: [String: Any] = [
            "assignmentID": UUID().uuidString, "personID": UUID().uuidString,
            "origin": "manual", "version": 1
        ]
        let automatic: [String: Any] = [
            "assignmentID": UUID().uuidString, "personID": UUID().uuidString,
            "origin": "automaticVoiceMatch", "version": 1
        ]
        let event: [String: Any] = [
            "eventID": UUID().uuidString, "turnID": "turn_2", "editsRevision": 1,
            "allowsLearning": true, "assignment": manual
        ]
        let original: [String: Any] = [
            "schemaVersion": 2, "resultID": resultID, "revision": 1,
            "overrides": [
                "turn_1": ["displayName": "Анна", "assignment": automatic],
                "turn_2": ["displayName": "Илья", "assignment": manual]
            ],
            "pendingLearningEvents": [event]
        ]
        let originalData = try JSONSerialization.data(withJSONObject: original)
        try originalData.write(to: editsURL)
        let restored = try repo.loadEdits(resultID: resultID)
        #expect(restored.schemaVersion == 2)
        #expect(try Data(contentsOf: editsURL) == originalData)
        #expect(restored.overrides["turn_1"]?.displayName == "Анна")
        #expect(restored.overrides["turn_2"]?.displayName == "Илья")

        let corrected = try repo.saveTurnOverride(
            resultID: resultID, turnID: "turn_1", text: "Исправленный текст", displayName: nil
        )
        let persisted = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: editsURL)) as? [String: Any])
        let overrides = try #require(persisted["overrides"] as? [String: [String: Any]])
        #expect(persisted["schemaVersion"] as? Int == 2)
        #expect(corrected.revision == 2)
        #expect(overrides["turn_1"]?["assignment"] as? NSDictionary == automatic as NSDictionary)
        #expect(overrides["turn_2"]?["assignment"] as? NSDictionary == manual as NSDictionary)
        #expect(persisted["pendingLearningEvents"] as? NSArray == [event] as NSArray)

        let export = try TranscriptExportFormatter().format(document: document, edits: corrected)
        #expect(export.contains("Анна"))
        #expect(export.contains("Илья"))
        #expect(export.contains("Исправленный текст"))
    }

    @Test func v2MachineAssignmentsDoNotLearnAndManualCorrectionCommitsWithOutbox() throws {
        enum InjectedFailure: Error { case beforeRename }
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        _ = try createSyntheticRecording(in: root, resultID: resultID)
        let machine = TranscriptNameAssignment(personID: UUID(), origin: "automaticVoiceMatch")
        let derived = TranscriptNameAssignment(personID: machine.personID, origin: "derivedVoiceMatch")
        let personID = UUID()
        let correction = TranscriptNameAssignment(personID: personID, origin: "manual")
        let intent = TranscriptVoicePersonIntent(personID: personID, nameToCreate: nil, catalogueID: UUID(),
                                                catalogueGeneration: 0, personGeneration: 0)
        let repo = TranscriptEditsRepository(recordingDirectory: root, learningCommitObserver: { _, _ in })
        let autoSaved = try repo.saveEdits(resultID: resultID, overrides: [
            "turn_1": TranscriptTurnOverride(displayName: "Анна", assignment: machine),
            "turn_2": TranscriptTurnOverride(displayName: "Анна", assignment: derived)
        ])
        #expect(autoSaved.schemaVersion == 2)
        #expect(autoSaved.pendingLearningEvents?.isEmpty != false)
        let editsURL = repo.editsURL(for: resultID)
        let previousBytes = try Data(contentsOf: editsURL)
        repo.releaseWriteLock()

        let update = TranscriptTurnOverride(displayName: "Анна", assignment: correction)
        let faultingRepo = TranscriptEditsRepository(recordingDirectory: root, atomicReplaceHook: { temporary, _ in
            let staged = try JSONDecoder().decode(TranscriptEdits.self, from: Data(contentsOf: temporary))
            #expect(staged.overrides["turn_1"]?.assignment == correction)
            #expect(staged.pendingLearningEvents?.first?.previousAssignment == machine)
            #expect(staged.pendingLearningEvents?.first?.assignment == correction)
            throw InjectedFailure.beforeRename
        }, learningCommitObserver: { _, _ in })
        #expect(throws: InjectedFailure.beforeRename) {
            try faultingRepo.mutateOverrides(resultID: resultID, learnVoice: true, personIntent: intent) {
                $0["turn_1"] = update
            }
        }
        #expect(try Data(contentsOf: editsURL) == previousBytes)
        faultingRepo.releaseWriteLock()

        let committed = try repo.mutateOverrides(resultID: resultID, learnVoice: true, personIntent: intent) {
            $0["turn_1"] = update
        }
        #expect(committed.revision == autoSaved.revision + 1)
        #expect(committed.pendingLearningEvents?.count == 1)
        let reopened = try TranscriptEditsRepository(recordingDirectory: root).loadEdits(resultID: resultID)
        #expect(reopened == committed)

        let featureOff = try repo.saveEdits(resultID: resultID, overrides: [
            "turn_1": TranscriptTurnOverride(displayName: "Борис", assignment: .init(personID: UUID(), origin: "manual"))
        ])
        #expect(featureOff.pendingLearningEvents?.count == 2)
        #expect(featureOff.pendingLearningEvents?.last?.previousAssignment == correction)
        #expect(featureOff.pendingLearningEvents?.last?.allowsLearning == false)
    }
}
