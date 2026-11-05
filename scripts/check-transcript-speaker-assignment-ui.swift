import AppKit
import Foundation
import MeetingCompanionCore
import MeetingCompanionPlatform
import UniformTypeIdentifiers

@main struct SpeakerAssignmentUIWindowCheck {
    enum Failure: Error { case check(String), timeout(String), persistence }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func check(_ condition: Bool, _ message: String) throws {
            guard condition else {
                fputs("FAIL: \(message)\n", stderr)
                exit(1)
            }
            print("PASS: \(message)")
        }

        let fixtureURL = URL(fileURLWithPath: "Tests/Fixtures/transcript-document/valid_parakeet_off.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        var docJson = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
        docJson["resultID"] = "v1"
        docJson["createdAt"] = "2026-10-30T10:00:00Z"
        docJson["playback"] = [
            "status": "ready",
            "mixPath": "raw/transcripts/v1/mix.m4a"
        ]
        docJson["context"] = [
            "title": "Синхронизация CX",
            "attendees": ["Алиса Иванова", "Борис Петров", "Дмитрий Сидоров"]
        ]
        var words = docJson["words"] as! [[String: Any]]
        words.append([
            "id": "w_4",
            "speakerID": "spk_h1",
            "start": 3.0,
            "end": 3.5,
            "text": "Ещё"
        ])
        words.append([
            "id": "w_5",
            "speakerID": "spk_h1",
            "start": 3.6,
            "end": 4.0,
            "text": "фраза"
        ])
        docJson["words"] = words
        var baseline = docJson["baselineWords"] as! [[String: Any]]
        baseline.append([
            "id": "bw_4",
            "speakerID": "spk_h1",
            "start": 3.0,
            "end": 3.5,
            "text": "Ещё"
        ])
        baseline.append([
            "id": "bw_5",
            "speakerID": "spk_h1",
            "start": 3.6,
            "end": 4.0,
            "text": "фраза"
        ])
        docJson["baselineWords"] = baseline
        var turns = docJson["turns"] as! [[String: Any]]
        turns.append([
            "id": "turn_3",
            "speakerID": "spk_h1",
            "start": 3.0,
            "end": 4.0,
            "wordIDs": ["w_4", "w_5"]
        ])
        docJson["turns"] = turns

        let dir1 = root.appendingPathComponent("raw/transcripts/v1")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: docJson).write(to: dir1.appendingPathComponent("result.json"))

        // Version 2
        var docJson2 = docJson
        docJson2["resultID"] = "v2"
        docJson2["createdAt"] = "2026-10-31T10:00:00Z"
        docJson2["playback"] = [
            "status": "ready",
            "mixPath": "raw/transcripts/v2/mix.m4a"
        ]
        let dir2 = root.appendingPathComponent("raw/transcripts/v2")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: docJson2).write(to: dir2.appendingPathComponent("result.json"))

        // Version 3 (8+8 voices)
        var speakers3: [[String: Any]] = []
        var words3: [[String: Any]] = []
        var baseline3: [[String: Any]] = []
        var turns3: [[String: Any]] = []
        for i in 1...8 {
            let spkID = "spk_h\(i)"
            speakers3.append(["id": spkID, "sourceID": "host", "localID": i, "displayNumber": i])
            let wID = "w_h\(i)"
            words3.append(["id": wID, "speakerID": spkID, "start": Double(i), "end": Double(i) + 0.5, "text": "Слово \(i)"])
            baseline3.append(["id": "b\(wID)", "speakerID": spkID, "start": Double(i), "end": Double(i) + 0.5, "text": "Слово \(i)"])
            turns3.append(["id": "turn_h\(i)", "speakerID": spkID, "start": Double(i), "end": Double(i) + 0.5, "wordIDs": [wID]])
        }
        for i in 1...8 {
            let spkID = "spk_r\(i)"
            let displayNum = 8 + i
            speakers3.append(["id": spkID, "sourceID": "remote", "localID": i, "displayNumber": displayNum])
            let wID = "w_r\(i)"
            words3.append(["id": wID, "speakerID": spkID, "start": Double(displayNum), "end": Double(displayNum) + 0.5, "text": "Слово \(displayNum)"])
            baseline3.append(["id": "b\(wID)", "speakerID": spkID, "start": Double(displayNum), "end": Double(displayNum) + 0.5, "text": "Слово \(displayNum)"])
            turns3.append(["id": "turn_r\(i)", "speakerID": spkID, "start": Double(displayNum), "end": Double(displayNum) + 0.5, "wordIDs": [wID]])
        }
        var docJson3 = docJson
        docJson3["resultID"] = "v3"
        docJson3["createdAt"] = "2026-10-29T10:00:00Z"
        docJson3["sources"] = [
            [
                "id": "host",
                "originalAudioPath": "raw/meeting.host_record.wav",
                "recognitionAudioPath": "raw/meeting.host_record.wav",
                "diarizationStatus": "completed",
                "detectedVoiceCount": 8,
                "correctionStatus": "disabled"
            ],
            [
                "id": "remote",
                "originalAudioPath": "raw/meeting.remote_record.wav",
                "recognitionAudioPath": "raw/meeting.remote_record.wav",
                "diarizationStatus": "completed",
                "detectedVoiceCount": 8,
                "correctionStatus": "disabled"
            ]
        ]
        docJson3["speakers"] = speakers3
        docJson3["words"] = words3
        docJson3["baselineWords"] = baseline3
        docJson3["turns"] = turns3
        docJson3["playback"] = [
            "status": "ready",
            "mixPath": "raw/transcripts/v3/mix.m4a"
        ]
        let dir3 = root.appendingPathComponent("raw/transcripts/v3")
        try FileManager.default.createDirectory(at: dir3, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: docJson3).write(to: dir3.appendingPathComponent("result.json"))

        let hostAudio = root.appendingPathComponent("raw/meeting.host_record.wav")
        let remoteAudio = root.appendingPathComponent("raw/meeting.remote_record.wav")
        let dummy = Data([0x01, 0x02, 0x03, 0x04])
        try dummy.write(to: hostAudio)
        try dummy.write(to: remoteAudio)
        try dummy.write(to: dir1.appendingPathComponent("mix.m4a"))
        try dummy.write(to: dir2.appendingPathComponent("mix.m4a"))
        try dummy.write(to: dir3.appendingPathComponent("mix.m4a"))

        let metaURL = root.appendingPathComponent("raw/meeting.processing.json")
        try Data("{}".utf8).write(to: metaURL)

        let recording = root.appendingPathComponent("meeting.m4a")
        let manager = TranscriptReviewWindowManager()
        for (id, date) in [("v1", 1.0), ("v2", 2.0), ("v3", 0.0)] {
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: root.appendingPathComponent("raw/transcripts/" + id).path)
        }
        let model = try await manager.open(recordingURL: recording, title: "Speaker model")
        let retained = model.state.session!
        let original = try Data(contentsOf: dir2.appendingPathComponent("result.json"))
        try check(model.currentResultID == "v2", "current authority, no version selection")
        try check(model.calendarAttendees == ["Алиса Иванова", "Борис Петров", "Дмитрий Сидоров"], "saved context suggestions only")
        model.openTextEditing(for: "turn_1")
        model.updateDraftText("  Дословный текст  ")
        var rejected = false
        model.requestWindowClose(onAuthorizedClose: { }, onCancelled: { rejected = true })
        try check(rejected && model.activeTextDraft?.text == "  Дословный текст  ", "modal close retains input without prompt")
        try check(!(await manager.prepareForRetry(recording)), "retry rejects modal input")
        model.saveTextEditing()
        try check(model.activeTextDraft == nil && model.rows.first?.text == "  Дословный текст  ", "verbatim durable text")
        let editsURL = dir2.appendingPathComponent("edits.json")
        let saved = try Data(contentsOf: editsURL)
        model.openTextEditing(for: "turn_1"); model.saveTextEditing()
        try check(try Data(contentsOf: editsURL) == saved, "unchanged text is no-op")
        model.openTextEditing(for: "turn_1"); model.updateDraftText(" \n")
        model.saveTextEditing()
        try check(model.activeTextDraft != nil && model.error != nil, "blank error retains input")
        model.cancelTextDraft()
        try check(try Data(contentsOf: editsURL) == saved, "cancel writes nothing")
        model.openSpeakerAssignment(for: "turn_3")
        model.updateDraftName("Ручное"); model.saveSpeakerAssignment()
        model.openSpeakerAssignment(for: "turn_1")
        model.updateDraftName("Алиса"); model.selectDraftScope(.allVoiceGroup); model.saveSpeakerAssignment()
        let confirmation = model.activeDraft!.pendingConfirmation!
        try check(confirmation.preview.affectedTurnsCount == 2 && confirmation.preview.replacedManualAssignmentsCount == 1, "preview counts actual changes including manual replacement")
        model.updateDraftName("Другое")
        model.confirmGroupAssignment(confirmation: confirmation)
        try check(model.activeDraft != nil && model.rows.last?.name == "Ручное", "changed input invalidates confirmation")
        model.updateDraftName("Алиса"); model.saveSpeakerAssignment(); model.confirmGroupAssignment()
        try check(model.rows[0].name == "Алиса" && model.rows[2].name == "Алиса" && model.rows[1].name != "Алиса", "same original source and voice only")
        model.openSpeakerAssignment(for: "turn_3")
        model.updateDraftName("Конец"); model.selectDraftScope(.allVoiceGroup); model.saveSpeakerAssignment()
        try check(model.activeDraft!.pendingConfirmation!.preview.targetTurnIDs == ["turn_3"], "remaining scope excludes earlier turn")
        model.confirmGroupAssignment()
        try check(model.rows[0].name == "Алиса" && model.rows[2].name == "Конец", "earlier manual assignment preserved")
        model.openTextEditing(for: "turn_1"); model.updateDraftText("Unsaved input")
        let repository = model.state.session!.editsRepository
        let edits = try repository.loadEdits(resultID: "v2")
        let changed = TranscriptEdits(resultID: "v2", revision: edits.revision + 1, overrides: edits.overrides)
        try JSONEncoder().encode(changed).write(to: editsURL, options: .atomic)
        let beforeFailure = try Data(contentsOf: editsURL)
        model.saveTextEditing()
        try check(model.activeTextDraft?.text == "Unsaved input" && model.error != nil, "CAS failure keeps draft")
        try check(try Data(contentsOf: editsURL) == beforeFailure, "failed save has no partial write")
        model.cancelTextDraft()
        try check(try Data(contentsOf: dir2.appendingPathComponent("result.json")) == original, "recognition immutable")
        manager.closeCurrent()
        try check(retained.isClosed && model.state.isClosed, "embedded close releases session")
        let reopened = try await manager.open(recordingURL: recording, title: "Reopen")
        try check(reopened.rows.first?.text == "  Дословный текст  " && reopened.activeTextDraft == nil, "saved text reopens without old draft")
        manager.closeCurrent()
        print("EMBEDDED SPEAKER/TEXT MODAL HARNESS GREEN")
    }
}
