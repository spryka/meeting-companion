import AppKit
import Foundation
import MeetingCompanionCore
import MeetingCompanionPlatform
import UniformTypeIdentifiers

@main struct SpeakerAssignmentUIWindowCheck {
    enum Failure: Error { case check(String), timeout(String), persistence }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let args = CommandLine.arguments
        let targetCase: String?
        if let idx = args.firstIndex(of: "--case"), idx + 1 < args.count {
            targetCase = args[idx + 1]
        } else {
            targetCase = nil
        }

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
        var window = try await manager.open(recordingURL: recording, title: "Speaker UI Test")
        var model = manager.model(for: recording)!
        // Fixture import policy: close the editor, then reopen against directory creation dates.
        func importedCurrent(_ id: String, manager: TranscriptReviewWindowManager, root: URL) async throws -> (NSWindow, TranscriptReviewWindowModel) {
            let recording = root.appendingPathComponent("meeting.m4a")
            if let old = manager.model(for: recording) {
                var authorized = false
                old.requestWindowClose { authorized = true }
                if let prompt = old.unsavedPrompt { old.resolveUnsavedPrompt(.discard, promptID: prompt.id) }
                try check(authorized, "fixture replacement resolves draft explicitly")
                manager.windows[old.state.id]?.close()
            }
            for candidate in ["v1", "v2", "v3"] {
                try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: candidate == id ? 2 : 1)], ofItemAtPath: root.appendingPathComponent("raw/transcripts/" + candidate).path)
            }
            let window = try await manager.open(recordingURL: recording, title: "Imported current")
            return (window, manager.model(for: recording)!)
        }
        try check(window.isVisible, "real NSWindow opens")

        if targetCase == nil || targetCase == "decline-replacement" {
            let outside = root.deletingLastPathComponent().appendingPathComponent("decline_replacement_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let targetA = outside.appendingPathComponent("A.txt")
            let targetB = outside.appendingPathComponent("B.txt")
            try Data("EXISTING A".utf8).write(to: targetA)
            var callbackA: ((NSApplication.ModalResponse, URL?) -> Void)?
            var callbackB: ((NSApplication.ModalResponse, URL?) -> Void)?
            model.requestExport(savePanelRunner: { _, c in callbackA = c }, overwriteConsentHandler: { _ in
                model.requestExport(savePanelRunner: { _, c in callbackB = c })
                return false
            })
            callbackA?(.OK, targetA)
            try check(try Data(contentsOf: targetA) == Data("EXISTING A".utf8), "declined stale A writes no output")
            try check(model.activeExportRequest != nil, "declined stale A preserves replacement B generation")
            callbackA?(.cancel, nil)
            try check(model.activeExportRequest != nil, "stale A panel cancel preserves B generation")
            callbackB?(.OK, targetB)
            try check(FileManager.default.fileExists(atPath: targetB.path), "B subsequently succeeds after stale A decline and cancel")
            // A nested panel cancellation must not resurrect a consumed B token either.
            model.requestExport(savePanelRunner: { _, c in c(.OK, targetA) }, overwriteConsentHandler: { _ in
                model.requestExport(savePanelRunner: { _, c in c(.cancel, nil) })
                return false
            })
            try check(model.activeExportRequest == nil, "reentrant B panel cancellation stays consumed")
            try check(try Data(contentsOf: targetA) == Data("EXISTING A".utf8), "reentrant cancellation leaves A bytes intact")
            if targetCase != nil { return }
        }

        if let isolatedCase = targetCase {
            let outsideDir = root.deletingLastPathComponent().appendingPathComponent("isolated_case_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
            switch isolatedCase {
            case "reentrancy-close":
                let target = outsideDir.appendingPathComponent("reentrancy_close.txt")
                try Data("EXISTING".utf8).write(to: target)
                model.requestExport(
                    savePanelRunner: { _, c in c(.OK, target) },
                    overwriteConsentHandler: { _ in
                        model.close()
                        return true
                    }
                )
                try check(try String(contentsOf: target, encoding: .utf8) == "EXISTING", "export rejected when model closed during consent, target unchanged")
                print("ISOLATED CASE reentrancy-close PASSED")
                return

            case "reentrancy-replace":
                let targetA = outsideDir.appendingPathComponent("reentrancy_replace_A.txt")
                try Data("EXISTING".utf8).write(to: targetA)
                model.requestExport(
                    savePanelRunner: { _, c in c(.OK, targetA) },
                    overwriteConsentHandler: { _ in
                        model.requestExport(savePanelRunner: { _, _ in })
                        return true
                    }
                )
                try check(try String(contentsOf: targetA, encoding: .utf8) == "EXISTING", "export A rejected when request B began during consent, target A unchanged")
                print("ISOLATED CASE reentrancy-replace PASSED")
                return

            case "decline-deleted":
                let target = outsideDir.appendingPathComponent("decline_deleted.txt")
                try Data("EXISTING".utf8).write(to: target)
                model.requestExport(
                    savePanelRunner: { _, c in c(.OK, target) },
                    overwriteConsentHandler: { url in
                        try! FileManager.default.removeItem(at: url)
                        return false
                    }
                )
                try check(!FileManager.default.fileExists(atPath: target.path), "declined overwrite creates zero output even if destination was deleted during dialog")
                print("ISOLATED CASE decline-deleted PASSED")
                return

            default:
                fputs("Unknown isolated case: \(isolatedCase)\n", stderr)
                exit(1)
            }
        }

        // 1. Initial State & Context Attendees
        try check(model.activeDraft == nil, "no draft open initially")
        try check(!model.canUndo, "no undo available initially")
        try check(model.contextAttendees?.count == 3, "context attendees loaded from document context")

        // 2. Open Speaker Assignment for Turn 1
        model.openSpeakerAssignment(for: "turn_1")
        let draft1 = try require(model.activeDraft, "draft opened for turn_1")
        try check(draft1.turnID == "turn_1", "draft targets turn_1")
        try check(draft1.scope == .thisTurn, "draft defaults to THIS turn scope")
        try check(!draft1.replaceExistingManual, "replaceExistingManual defaults to false")
        try check(!model.follow.isFollowing, "beginEditing pauses follow mode")
        try check(draft1.calendarAttendees.count == 3, "calendar attendees available as hints")

        // 3. Select calendar suggestion (requires explicit action)
        model.selectCalendarAttendee("Алиса Иванова")
        try check(model.activeDraft?.inputName == "Алиса Иванова", "calendar selection populates inputName without auto-saving")

        // 4. Save THIS turn only
        model.saveSpeakerAssignment()
        try check(model.activeDraft == nil, "draft closed on successful save")
        try check(model.rows[0].name == "Алиса Иванова", "turn_1 name updated to Alice")
        try check(model.rows[2].name == "Speaker 1", "turn_3 in same group retains default Speaker 1")
        try check(model.canUndo, "undo is now available")

        // 5. Open Speaker Assignment for Turn 3 and select All Voice Group
        model.openSpeakerAssignment(for: "turn_3")
        _ = try require(model.activeDraft, "draft opened for turn_3")
        model.selectDraftScope(.allVoiceGroup)
        let preview1 = try require(model.activeDraft?.preview, "group preview generated")
        try check(preview1.totalTurnsInGroup == 2, "preview reports total 2 turns in group")
        try check(preview1.affectedTurnsCount == 1, "preview with replace=false reports 1 affected turn (turn_3)")
        try check(preview1.replacedManualAssignmentsCount == 0, "preview with replace=false reports 0 replaced manual names")

        // 6. Save group with replaceExistingManual == false
        model.updateDraftName("Группа Хост")
        model.saveSpeakerAssignment()
        try check(model.activeDraft?.isConfirmingGroup == true, "first save triggers group confirmation dialog")
        model.confirmGroupAssignment()
        try check(model.activeDraft == nil, "draft closed after group confirmation")
        try check(model.rows[0].name == "Алиса Иванова", "turn_1 preserved manual name with replace=false")
        try check(model.rows[2].name == "Группа Хост", "turn_3 updated to group name")

        // 7. Group assignment with replaceExistingManual == true
        model.openSpeakerAssignment(for: "turn_3")
        model.selectDraftScope(.allVoiceGroup)
        model.toggleReplaceExistingManual(true)
        let preview2 = try require(model.activeDraft?.preview, "group preview generated with replace=true")
        try check(preview2.affectedTurnsCount == 2, "preview with replace=true reports 2 affected turns")
        try check(preview2.replacedManualAssignmentsCount == 2, "preview with replace=true reports 2 replaced manual names")
        model.updateDraftName("Все Хост")
        model.saveSpeakerAssignment()
        model.confirmGroupAssignment()
        try check(model.rows[0].name == "Все Хост", "turn_1 replaced with replace=true")
        try check(model.rows[2].name == "Все Хост", "turn_3 updated with replace=true")

        // 8. Atomic Undo
        model.undoLastEdit()
        try check(model.rows[0].name == "Алиса Иванова", "single undo restored turn_1 manual name")
        try check(model.rows[2].name == "Группа Хост", "single undo restored turn_3 prior group name")

        model.undoLastEdit()
        try check(model.rows[0].name == "Алиса Иванова", "undo restored turn_1 Alice")
        try check(model.rows[2].name == "Speaker 1", "undo restored turn_3 default Speaker 1")

        model.undoLastEdit()
        try check(model.rows[0].name == "Speaker 1", "undo restored turn_1 default Speaker 1")
        try check(!model.canUndo, "no more undo available")

        // 9. Stale preview / closed session safety
        model.openSpeakerAssignment(for: "turn_1")
        try check(model.activeDraft != nil, "draft open on v2")
        (window, model) = try await importedCurrent("v1", manager: manager, root: root)
        try check(model.activeDraft == nil, "explicit discard before reopen clears old draft to prevent stale callbacks")

        // 10. Legacy / Corrupt mode does not allow opening form
        let legacyURL = root.appendingPathComponent("raw/legacy.txt")
        try Data("старый текст".utf8).write(to: legacyURL)
        let legacyState = TranscriptWindowState(
            id: legacyURL,
            recordingDirectory: root,
            recordingURL: recording,
            mode: .legacyReadOnly(transcriptURL: legacyURL)
        )
        let legacyModel = try await TranscriptReviewWindowModel(state: legacyState)
        legacyModel.openSpeakerAssignment(for: "turn_1")
        try check(legacyModel.activeDraft == nil, "legacy mode does not open speaker assignment draft")

        // 11. Blank Group Name Save is Rejected
        // Setup: turn_1 has manual name "Алиса", turn_3 has "Speaker 1"
        model.openSpeakerAssignment(for: "turn_1")
        model.selectDraftScope(.thisTurn)
        model.updateDraftName("Алиса Вручную")
        model.saveSpeakerAssignment()
        try check(model.rows[0].name == "Алиса Вручную", "turn_1 has manual name")

        model.openSpeakerAssignment(for: "turn_3")
        model.selectDraftScope(.allVoiceGroup)
        model.updateDraftName("   \t  ") // blank whitespace
        model.saveSpeakerAssignment()
        try check(model.activeDraft != nil, "blank save rejected and draft retained")
        try check(!model.activeDraft!.isConfirmingGroup, "blank group name does not enter confirmation")
        try check(model.error != nil, "blank name reports error")
        try check(model.rows[0].name == "Алиса Вручную", "blank group name does NOT delete manual name on turn_1")
        model.cancelDraft()

        // 12. Editing Name, Calendar, Scope, or Replacement Invalidates Confirmation
        model.openSpeakerAssignment(for: "turn_3")
        model.selectDraftScope(.allVoiceGroup)
        model.updateDraftName("Первое Имя")
        model.saveSpeakerAssignment()
        try check(model.activeDraft?.isConfirmingGroup == true, "entered confirmation for Первое Имя")

        // Edit name after confirmation triggered
        model.updateDraftName("Второе Имя")
        try check(model.activeDraft?.isConfirmingGroup == false, "editing name invalidates group confirmation")

        model.saveSpeakerAssignment()
        try check(model.activeDraft?.isConfirmingGroup == true, "re-entered confirmation for Второе Имя")

        // Toggle replacement after confirmation
        model.toggleReplaceExistingManual(true)
        try check(model.activeDraft?.isConfirmingGroup == false, "toggling replacement invalidates confirmation")

        model.cancelDraft()

        // 13. Stale Old Callback With Captured DraftID / Reopen
        model.openSpeakerAssignment(for: "turn_1")
        let staleDraftID = try require(model.activeDraft?.id, "captured draft id")
        model.updateDraftName("Новое Имя")

        // Switch to v2
        (window, model) = try await importedCurrent("v2", manager: manager, root: root)
        try check(model.currentResultID == "v2", "active version is now v2")

        // Triggering old callback with staleDraftID
        model.saveSpeakerAssignment(draftID: staleDraftID)
        try check(model.rows[0].name != "Новое Имя", "stale draftID callback does not mutate active version")

        // 14. Retained confirmation callback A -> draft switched to .thisTurn must not save
        model.openSpeakerAssignment(for: "turn_3")
        model.selectDraftScope(.allVoiceGroup)
        model.updateDraftName("Payload A")
        model.saveSpeakerAssignment()
        let confirmationA = try require(model.activeDraft?.pendingConfirmation, "confirmation A created")
        // Closure capturing confirmation A
        let confirmClosureA = { model.confirmGroupAssignment(confirmation: confirmationA) }

        // Now user switches the same draft to .thisTurn and types single turn name
        model.selectDraftScope(.thisTurn)
        model.updateDraftName("Single Turn Name")
        try check(model.activeDraft?.scope == .thisTurn, "draft switched to thisTurn")
        try check(model.activeDraft?.pendingConfirmation == nil, "pendingConfirmation cleared on scope switch")

        // Invoking retained confirmClosureA must be rejected!
        let repo = model.state.session!.editsRepository
        let diskEditsBefore14 = try repo.loadEdits(resultID: "v2")
        confirmClosureA()
        let diskEditsAfter14 = try repo.loadEdits(resultID: "v2")
        try check(diskEditsBefore14 == diskEditsAfter14, "closure A does not change disk after switch to thisTurn")
        try check(model.activeDraft != nil, "draft is retained on rejected confirm")
        try check(model.rows[2].name != "Single Turn Name", "retained confirm does not save single turn name")

        // 15. Retained confirmation callback A -> draft re-enters confirmation for Payload B
        model.selectDraftScope(.allVoiceGroup)
        model.updateDraftName("Payload B")
        model.saveSpeakerAssignment()
        let confirmationB = try require(model.activeDraft?.pendingConfirmation, "confirmation B created")
        try check(confirmationA.id != confirmationB.id, "confirmation identities are strictly distinct")

        // Invoking old confirmClosureA while confirmation B is pending must be rejected!
        let diskEditsBefore15 = try repo.loadEdits(resultID: "v2")
        confirmClosureA()
        let diskEditsAfter15 = try repo.loadEdits(resultID: "v2")
        try check(diskEditsBefore15 == diskEditsAfter15, "closure A does not change disk while B is pending")
        try check(model.activeDraft?.pendingConfirmation?.id == confirmationB.id, "pending confirmation B retained")
        try check(model.rows[2].name != "Payload B", "old closure A does not apply payload B")

        model.cancelDraft()

        // 16. Diarization 8+8 Warnings and Editing Allowed on 8-voice Limit
        (window, model) = try await importedCurrent("v3", manager: manager, root: root)
        try check(model.currentResultID == "v3", "switched to version 3 (8+8 voices)")
        try check(model.diarizationWarnings.count == 2, "2 diarization warnings rendered for 8+8 sources")
        try check(model.diarizationWarnings.contains(where: { $0.contains("Микрофон") }), "warning for host microphone rendered")
        try check(model.diarizationWarnings.contains(where: { $0.contains("Системный звук") }), "warning for remote system sound rendered")
        try check(model.presentationWarnings.count == 2, "2 structured presentation warnings")
        try check(model.presentationWarnings[0].id != model.presentationWarnings[1].id, "presentation warning IDs are distinct")
        try check(model.presentationWarnings.first(where: { $0.sourceID == .host })?.sourceLabel == "Микрофон", "host warning has label Микрофон")
        try check(model.presentationWarnings.first(where: { $0.sourceID == .remote })?.sourceLabel == "Системный звук", "remote warning has label Системный звук")
        try check(model.rows.count == 16, "16 rows loaded for 16 voices")
        model.openSpeakerAssignment(for: "turn_h1")
        try check(model.activeDraft != nil, "editing names allowed despite 8-voice limit warnings")
        model.updateDraftName("Новое Имя 8+8")
        model.saveSpeakerAssignment()
        try check(model.rows[0].name == "Новое Имя 8+8", "name saved successfully on 8-voice limit version")

        // 17. Section 4.4a: Text Editing Draft, Save, Cancel, Empty Text, Undo, and Exclusivity
        let v3ResultURL = dir3.appendingPathComponent("result.json")
        let v3ResultBytesBefore = try Data(contentsOf: v3ResultURL)
        let v3MixBytesBefore = try Data(contentsOf: dir3.appendingPathComponent("mix.m4a"))

        // Open text editing for turn_h1
        model.openTextEditing(for: "turn_h1")
        let textDraft1 = try require(model.activeTextDraft, "text draft opened for turn_h1")
        try check(textDraft1.turnID == "turn_h1", "text draft targets turn_h1")
        try check(textDraft1.initialText == model.rows[0].text, "initial text matches row text")
        try check(!model.follow.isFollowing, "opening text editor pauses follow mode")

        // Exclusivity: opening name assignment while text draft is active must be rejected
        model.openSpeakerAssignment(for: "turn_h1")
        try check(model.activeDraft == nil, "opening name draft rejected while text editing active")
        try check(model.error != nil, "exclusivity error reported")

        // Update text and save
        model.updateDraftText("Исправленный текст H1", draftID: textDraft1.id)
        model.saveTextEditing(draftID: textDraft1.id)
        try check(model.activeTextDraft == nil, "text draft closed on successful save")
        try check(model.rows[0].text == "Исправленный текст H1", "row text updated to new text")
        try check(model.rows[0].name == "Новое Имя 8+8", "existing displayName preserved when text is edited")
        try check(model.canUndo, "undo is available after text save")

        // 17b. Guard Undo While Text or Name Draft is Pending
        let repoV3 = model.state.session!.editsRepository
        let editsBeforeUndoGuard = try repoV3.loadEdits(resultID: "v3")

        // Open text draft and type dirty text
        model.openTextEditing(for: "turn_h1")
        let dirtyTextDraft = try require(model.activeTextDraft, "dirty text draft opened")
        model.updateDraftText("Несохранённый грязный текст", draftID: dirtyTextDraft.id)
        try check(!model.canUndo, "undo button is disabled while text draft is pending")

        // Invoking model.undoLastEdit() must NOT mutate disk or dismiss draft
        model.undoLastEdit()
        let editsAfterBlockedUndo = try repoV3.loadEdits(resultID: "v3")
        try check(editsBeforeUndoGuard == editsAfterBlockedUndo, "disk unchanged by blocked undo while text draft open")
        try check(model.activeTextDraft != nil, "text draft retained on blocked undo")
        try check(model.activeTextDraft?.text == "Несохранённый грязный текст", "entered dirty text preserved")
        try check(model.rows[0].text == "Исправленный текст H1", "rendered row text unchanged")

        // Cancel text draft re-enables undo
        model.cancelTextDraft(draftID: dirtyTextDraft.id)
        try check(model.activeTextDraft == nil, "text draft cancelled")
        try check(model.canUndo, "undo button re-enabled after text draft cancelled")

        // Open name draft and type dirty name
        model.openSpeakerAssignment(for: "turn_h1")
        let dirtyNameDraft = try require(model.activeDraft, "dirty name draft opened")
        model.updateDraftName("Несохранённое имя", draftID: dirtyNameDraft.id)
        try check(!model.canUndo, "undo button is disabled while name draft is pending")

        // Invoking model.undoLastEdit() must NOT mutate disk or dismiss name draft
        model.undoLastEdit()
        let editsAfterBlockedNameUndo = try repoV3.loadEdits(resultID: "v3")
        try check(editsBeforeUndoGuard == editsAfterBlockedNameUndo, "disk unchanged by blocked undo while name draft open")
        try check(model.activeDraft != nil, "name draft retained on blocked undo")
        try check(model.activeDraft?.inputName == "Несохранённое имя", "entered dirty name preserved")

        // Cancel name draft re-enables undo
        model.cancelDraft(draftID: dirtyNameDraft.id)
        try check(model.activeDraft == nil, "name draft cancelled")
        try check(model.canUndo, "undo button re-enabled after name draft cancelled")

        // Empty text override is allowed
        model.openTextEditing(for: "turn_h2")
        let textDraft2 = try require(model.activeTextDraft, "text draft opened for turn_h2")
        model.updateDraftText("", draftID: textDraft2.id)
        model.saveTextEditing(draftID: textDraft2.id)
        try check(model.activeTextDraft == nil, "empty text saved and draft closed")
        try check(model.rows[1].text == "", "row text rendered as empty string")

        // Verify disk has empty text override
        let v3Edits = try model.state.session!.editsRepository.loadEdits(resultID: "v3")
        try check(v3Edits.overrides["turn_h2"]?.text == "", "edits.json on disk stores empty text")
        try check(v3Edits.overrides["turn_h1"]?.text == "Исправленный текст H1", "edits.json preserves turn_h1 text")
        try check(v3Edits.overrides["turn_h1"]?.displayName == "Новое Имя 8+8", "edits.json preserves turn_h1 name")

        // Cancel text draft discards without I/O
        model.openTextEditing(for: "turn_h1")
        let textDraft3 = try require(model.activeTextDraft, "draft opened for cancellation test")
        model.updateDraftText("Несохранённый ввод", draftID: textDraft3.id)
        model.cancelTextDraft(draftID: textDraft3.id)
        try check(model.activeTextDraft == nil, "draft cancelled")
        try check(model.rows[0].text == "Исправленный текст H1", "row text unchanged after cancel")

        // Undo restores text
        model.undoLastEdit()
        try check(model.rows[1].text != "", "undo restored turn_h2 non-empty text")
        try check(model.rows[0].text == "Исправленный текст H1", "turn_h1 still has edited text")

        model.undoLastEdit()
        try check(model.rows[0].text == "Слово 1", "undo restored turn_h1 original text")
        try check(model.rows[0].name == "Новое Имя 8+8", "turn_h1 displayName still preserved after text undo")

        // Verify audio and result bytes unchanged
        let v3ResultBytesAfter = try Data(contentsOf: v3ResultURL)
        let v3MixBytesAfter = try Data(contentsOf: dir3.appendingPathComponent("mix.m4a"))
        try check(v3ResultBytesBefore == v3ResultBytesAfter, "result.json bytes unchanged")
        try check(v3MixBytesBefore == v3MixBytesAfter, "mix.m4a bytes unchanged")

        // 18. Section 4.4b: Unsaved Changes Navigation Prompts (Window Close & Reopen)
        // Probe 1: Prompt A -> Draft B (Draft replacement under prompt)
        model.openTextEditing(for: "turn_h1")
        let draftA = try require(model.activeTextDraft, "draft A open")
        model.updateDraftText("Текст черновика А", draftID: draftA.id)
        model.requestWindowClose {}
        let promptA = try require(model.unsavedPrompt, "prompt A created")

        // User cancels draft A and opens draft B on turn_h2
        model.cancelTextDraft(draftID: draftA.id)
        model.openTextEditing(for: "turn_h2")
        let draftB = try require(model.activeTextDraft, "draft B open")
        model.updateDraftText("Текст черновика Б", draftID: draftB.id)

        // Resolving prompt A (from draft A) must NOT discard or save draft B!
        model.resolveUnsavedPrompt(.discard, promptID: promptA.id)
        try check(model.activeTextDraft?.id == draftB.id, "prompt A resolution does not discard replacement draft B")
        try check(model.activeTextDraft?.text == "Текст черновика Б", "draft B input preserved")
        model.cancelTextDraft(draftID: draftB.id)

        // Probe 2: Dirty Name Check with Cleared Initial Name and Group Scope
        // 2a: Turn_h1 has manual name. Clearing name to empty is dirty!
        model.openSpeakerAssignment(for: "turn_h1")
        let clearNameDraft = try require(model.activeDraft, "name draft open for clear test")
        model.updateDraftName("", draftID: clearNameDraft.id)
        try check(model.hasUnsavedChanges, "clearing nonempty initial name is dirty")
        model.cancelDraft(draftID: clearNameDraft.id)

        // 2b: Changing scope to allVoiceGroup with unchanged initial name is dirty!
        model.openSpeakerAssignment(for: "turn_h2")
        let groupScopeDraft = try require(model.activeDraft, "name draft open for scope test")
        model.selectDraftScope(.allVoiceGroup, draftID: groupScopeDraft.id)
        try check(model.hasUnsavedChanges, "changing scope to allVoiceGroup is dirty even with same name")
        // Switching back to thisTurn is clean
        model.selectDraftScope(.thisTurn, draftID: groupScopeDraft.id)
        try check(!model.hasUnsavedChanges, "switching back to thisTurn restores clean state")
        model.cancelDraft(draftID: groupScopeDraft.id)

        // Probe 3: Navigation Save Group without Prior Confirmation Fails Closed
        model.openSpeakerAssignment(for: "turn_h1")
        let unconfirmedGroupDraft = try require(model.activeDraft, "group draft open")
        model.selectDraftScope(.allVoiceGroup, draftID: unconfirmedGroupDraft.id)
        model.updateDraftName("Неподтверждённая группа", draftID: unconfirmedGroupDraft.id)
        model.requestWindowClose {}
        let unconfirmedNavPrompt = try require(model.unsavedPrompt, "nav prompt for unconfirmed group")
        model.resolveUnsavedPrompt(.save, promptID: unconfirmedNavPrompt.id)
        try check(model.activeDraft != nil, "unconfirmed group draft retained on nav save")
        try check(model.error != nil, "unconfirmed group nav save reports error")
        try check(model.currentResultID == "v3", "remains on v3 after failed unconfirmed group save")
        model.cancelDraft(draftID: unconfirmedGroupDraft.id)

        // Test 2: Dirty text on window close -> window.performClose
        // Switch back to v3
        (window, model) = try await importedCurrent("v3", manager: manager, root: root)
        model.openTextEditing(for: "turn_h1")
        let closeDraft = try require(model.activeTextDraft, "draft open for close test")
        model.updateDraftText("Текст перед закрытием окна", draftID: closeDraft.id)

        // Close window via standard performClose
        window.performClose(nil)
        try check(window.isVisible, "window close intercepted while dirty")
        let closePrompt = try require(model.unsavedPrompt, "unsaved prompt shown on close")

        // Choice: "Остаться"
        model.resolveUnsavedPrompt(.stay, promptID: closePrompt.id)
        try check(window.isVisible, "window stays visible after stay")
        try check(model.activeTextDraft?.text == "Текст перед закрытием окна", "text retained after stay")

        // Close again and choose "Сохранить"
        window.performClose(nil)
        let closePrompt2 = try require(model.unsavedPrompt, "close prompt shown again")
        model.resolveUnsavedPrompt(.save, promptID: closePrompt2.id)
        try check(!window.isVisible, "window closed after saving")

        // Verify disk has saved text
        let v3EditsFinal = try repoV3.loadEdits(resultID: "v3")
        try check(v3EditsFinal.overrides["turn_h1"]?.text == "Текст перед закрытием окна", "disk has text saved on close")

        // Probe 4a: Same-content confirmation regeneration under prompt must reject old prompt A
        // Reopen window to test on live window
        let window2 = try await manager.open(recordingURL: recording, title: "Speaker UI Test 2")
        let model2 = manager.model(for: recording)!
        try check(window2.isVisible, "window 2 opened")

        model2.openSpeakerAssignment(for: "turn_h1")
        let regenDraft = try require(model2.activeDraft, "draft open for regeneration test")
        model2.selectDraftScope(.allVoiceGroup, draftID: regenDraft.id)
        model2.updateDraftName("Одинаковое Имя", draftID: regenDraft.id)
        model2.saveSpeakerAssignment(draftID: regenDraft.id)
        let confA = try require(model2.activeDraft?.pendingConfirmation, "confirmation A created")
        model2.requestWindowClose {}
        let regenPromptA = try require(model2.unsavedPrompt, "regen prompt A created")

        // Invalidate confirmation and re-confirm with same content (fresh confirmation B)
        model2.updateDraftName("Одинаковое Имя", draftID: regenDraft.id)
        model2.saveSpeakerAssignment(draftID: regenDraft.id)
        let confB = try require(model2.activeDraft?.pendingConfirmation, "confirmation B created")
        try check(confA.id != confB.id, "conf A and B have distinct IDs")

        // Old regenPromptA must reject applying confirmation B!
        let v3EditsBeforeRegen = try repoV3.loadEdits(resultID: "v3")
        model2.resolveUnsavedPrompt(.save, promptID: regenPromptA.id)
        let v3EditsAfterRegen = try repoV3.loadEdits(resultID: "v3")
        try check(v3EditsBeforeRegen == v3EditsAfterRegen, "prompt A cannot apply regenerated confirmation B")
        try check(model2.currentResultID == "v3", "remains on v3 after rejected stale prompt A")
        model2.cancelDraft(draftID: regenDraft.id)

        // Probe 4b: Foreign old prompt ID callback must NOOP and preserve newer prompt B
        model2.openTextEditing(for: "turn_h1")
        let foreignDraft = try require(model2.activeTextDraft, "foreign draft open")
        model2.updateDraftText("Текст Пробы 4b", draftID: foreignDraft.id)
        model2.requestWindowClose {}
        let promptB_active = try require(model2.unsavedPrompt, "prompt B active")

        // Invoke resolve with a foreign UUID (e.g. regenPromptA.id)
        model2.resolveUnsavedPrompt(.discard, promptID: regenPromptA.id)
        try check(model2.unsavedPrompt?.id == promptB_active.id, "foreign prompt ID NOOPs and preserves newer prompt B")

        // Double action / valid resolution on prompt B works
        model2.resolveUnsavedPrompt(.stay, promptID: promptB_active.id)
        try check(model2.unsavedPrompt == nil, "prompt B resolved with stay")
        // Double resolve is a NOOP
        model2.resolveUnsavedPrompt(.stay, promptID: promptB_active.id)
        try check(model2.activeTextDraft != nil, "draft still intact after double resolve")
        model2.cancelTextDraft(draftID: foreignDraft.id)

        // 19. Model Close Blocks Opening Draft and Saving
        model2.close()
        model2.openSpeakerAssignment(for: "turn_1")
        try check(model2.activeDraft == nil, "closed model cannot open draft")
        model2.openTextEditing(for: "turn_1")
        try check(model2.activeTextDraft == nil, "closed model cannot open text draft")
        window2.close()

        // 20. Section 4.5b Export UI Tests
        let outsideExportDir = root.deletingLastPathComponent().appendingPathComponent("export_dest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideExportDir, withIntermediateDirectories: true)

        let hostAudioBytesBaseline = try Data(contentsOf: root.appendingPathComponent("raw/meeting.host_record.wav"))
        let remoteAudioBytesBaseline = try Data(contentsOf: root.appendingPathComponent("raw/meeting.remote_record.wav"))
        let v1ResultBytesBaseline = try Data(contentsOf: root.appendingPathComponent("raw/transcripts/v1/result.json"))
        let v2ResultBytesBaseline = try Data(contentsOf: root.appendingPathComponent("raw/transcripts/v2/result.json"))
        let v3ResultBytesBaseline = try Data(contentsOf: root.appendingPathComponent("raw/transcripts/v3/result.json"))

        struct EditorBaseline {
            let files: [URL: Data]
            let editsExists: Bool
            let snapshot: TranscriptEditsRepository.LoadedSnapshot
            let canUndo: Bool
            let names: [String]
            let texts: [String]
            let draftName: String?
            let draftText: String?
            let draftID: UUID?
            let textDraftID: UUID?
            let position: Double
            let duration: Double
            let playbackState: TranscriptPlaybackController.State
        }
        func capture(_ model: TranscriptReviewWindowModel, _ resultID: String) throws -> EditorBaseline {
            let repository = try require(model.state.session?.editsRepository, "live repository for baseline")
            let snapshot = try require(repository.loadedSnapshot(for: resultID), "live CAS snapshot for baseline")
            var files: [URL: Data] = [:]
            for path in ["raw/meeting.host_record.wav", "raw/meeting.remote_record.wav", "raw/transcripts/\(resultID)/result.json", "raw/transcripts/\(resultID)/mix.m4a", "raw/transcripts/\(resultID)/edits.json"] {
                let url = model.state.recordingDirectory.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) { files[url] = try Data(contentsOf: url) }
            }
            return EditorBaseline(files: files, editsExists: FileManager.default.fileExists(atPath: model.state.recordingDirectory.appendingPathComponent("raw/transcripts/\(resultID)/edits.json").path), snapshot: snapshot, canUndo: model.canUndo,
                names: model.rows.map(\.name), texts: model.rows.map(\.text),
                draftName: model.activeDraft?.inputName, draftText: model.activeTextDraft?.text,
                draftID: model.activeDraft?.id, textDraftID: model.activeTextDraft?.id,
                position: model.playbackPosition, duration: model.playbackDuration, playbackState: model.playbackState)
        }
        var preOperation: EditorBaseline?
        func assertStatePreserved(
            model: TranscriptReviewWindowModel,
            resultID: String,
            expectedSavedRowNames: [String],
            expectedSavedRowTexts: [String],
            expectedDraftText: String? = nil,
            expectedDraftName: String? = nil,
            context: String
        ) throws {
            let hostAudio = root.appendingPathComponent("raw/meeting.host_record.wav")
            try check(try Data(contentsOf: hostAudio) == hostAudioBytesBaseline, "\(context): host audio bytes unchanged")
            let remoteAudio = root.appendingPathComponent("raw/meeting.remote_record.wav")
            try check(try Data(contentsOf: remoteAudio) == remoteAudioBytesBaseline, "\(context): remote audio bytes unchanged")

            let resultURL = root.appendingPathComponent("raw/transcripts/\(resultID)/result.json")
            let expectedResultBytes = resultID == "v1" ? v1ResultBytesBaseline : (resultID == "v2" ? v2ResultBytesBaseline : v3ResultBytesBaseline)
            try check(try Data(contentsOf: resultURL) == expectedResultBytes, "\(context): result.json bytes unchanged")

            let before = try require(preOperation, "\(context): pre-operation baseline exists")
            for (url, data) in before.files {
                try check(try Data(contentsOf: url) == data, "\(context): \(url.lastPathComponent) exact pre-operation bytes unchanged")
            }
            try check(FileManager.default.fileExists(atPath: model.state.recordingDirectory.appendingPathComponent("raw/transcripts/\(resultID)/edits.json").path) == before.editsExists, "\(context): edits.json existence unchanged")
            let snap = try require(model.state.session?.editsRepository.loadedSnapshot(for: resultID), "\(context): CAS snapshot exists")
            try check(snap.data == before.snapshot.data && snap.exists == before.snapshot.exists && snap.edits == before.snapshot.edits && snap.edits.revision == before.snapshot.edits.revision, "\(context): exact CAS data/revision/exists unchanged")
            try check(model.canUndo == before.canUndo, "\(context): undo availability unchanged")
            try check(model.rows.map(\.name) == before.names && model.rows.map(\.text) == before.texts, "\(context): pre-operation saved rows unchanged")
            try check(model.activeDraft?.inputName == before.draftName && model.activeTextDraft?.text == before.draftText && model.activeDraft?.id == before.draftID && model.activeTextDraft?.id == before.textDraftID, "\(context): exact draft name/text/identity unchanged")
            try check(model.playbackPosition == before.position && model.playbackDuration == before.duration && model.playbackState == before.playbackState, "\(context): playback unchanged")

            if let expText = expectedDraftText {
                try check(model.activeTextDraft?.text == expText, "\(context): active text draft text preserved")
            }
            if let expName = expectedDraftName {
                try check(model.activeDraft?.inputName == expName, "\(context): active name draft name preserved")
            }

            let currentNames = model.rows.map(\.name)
            try check(currentNames == expectedSavedRowNames, "\(context): saved row names unchanged")
            let currentTexts = model.rows.map(\.text)
            try check(currentTexts == expectedSavedRowTexts, "\(context): saved row texts unchanged")
        }

        let manager3 = TranscriptReviewWindowManager()
        var window3 = try await manager3.open(recordingURL: recording, title: "Export UI Test")
        var model3 = try require(manager3.model(for: recording), "model 3 loaded")
        try check(window3.isVisible, "window 3 visible")

        // 20.1 Export availability
        try check(model3.isExportAvailable, "export button available for valid structured review document")
        try check(model3.canExport, "canExport is true initially")

        // Test export button unavailable for legacy
        let legacyState2 = TranscriptWindowState(
            id: legacyURL,
            recordingDirectory: root,
            recordingURL: recording,
            mode: .legacyReadOnly(transcriptURL: legacyURL)
        )
        let legacyExportModel = try await TranscriptReviewWindowModel(state: legacyState2)
        try check(!legacyExportModel.isExportAvailable, "export button not available for legacy read-only mode")
        try check(!legacyExportModel.canExport, "canExport is false for legacy mode")

        // 20.2 Real NSSavePanel configuration & Panel Message Wording
        let savePanel = model3.configureSavePanel(hasDirtyDraft: true)
        try check(savePanel.allowedContentTypes == [.plainText], "save panel allowedContentTypes is plainText")
        try check(savePanel.nameFieldStringValue == "transcript.txt", "save panel nameFieldStringValue is transcript.txt")
        try check(savePanel.canCreateDirectories, "save panel canCreateDirectories is true")
        try check(!savePanel.showsTagField, "save panel showsTagField is false")
        try check(!savePanel.isExtensionHidden, "save panel isExtensionHidden is false")
        let expectedDocsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        try check(savePanel.directoryURL == expectedDocsDir, "save panel default directory is Documents")

        // Panel message identifies the request-time saved state and dirty draft exclusion.
        let dirtyMsg = try require(savePanel.message, "save panel message exists for dirty draft")
        try check(dirtyMsg.contains("сохранённого состояния"), "panel message identifies saved state")
        try check(dirtyMsg.contains("текущей расшифровки"), "panel message identifies current transcript")
        try check(dirtyMsg.contains("зафиксированного на момент запроса"), "panel message states state is frozen when request begins")
        try check(dirtyMsg.contains("Несохранённые изменения черновика исключены"), "panel message explains dirty draft exclusion")
        try check(!dirtyMsg.contains("последней") && !dirtyMsg.lowercased().contains("latest"), "panel message avoids promising latest result")

        let cleanPanel = model3.configureSavePanel(hasDirtyDraft: false)
        let cleanMsg = try require(cleanPanel.message, "save panel message exists for clean draft")
        try check(cleanMsg.contains("сохранённого состояния текущей расшифровки"), "clean message identifies current saved state")
        try check(!cleanMsg.contains("черновика"), "clean message does not mention draft exclusion")

        // 20.3 Canceled panel writes no file, leaves drafts and undo intact
        let baseRowsV3Names = model3.rows.map(\.name)
        let baseRowsV3Texts = model3.rows.map(\.text)
        let exportCancelTarget = outsideExportDir.appendingPathComponent("export_cancel.txt")
        preOperation = try capture(model3, "v3")
        model3.requestExport(savePanelRunner: { panel, completion in
            completion(.cancel, exportCancelTarget)
        })
        try check(!FileManager.default.fileExists(atPath: exportCancelTarget.path), "canceled panel writes no file")
        try check(model3.error == nil, "canceled panel produces no error")
        try check(model3.activeExportRequest == nil, "activeExportRequest cleared after cancel")
        try assertStatePreserved(
            model: model3,
            resultID: "v3",
            expectedSavedRowNames: baseRowsV3Names,
            expectedSavedRowTexts: baseRowsV3Texts,
            context: "after panel cancellation"
        )

        // 20.4 Saved version only vs dirty draft - draft warned, excluded, and preserved
        let turnTarget = model3.rows[0]
        model3.openTextEditing(for: turnTarget.id)
        let dirtyExportTextDraft = try require(model3.activeTextDraft, "text draft open for export")
        model3.updateDraftText("НЕСОХРАНЁННЫЙ ЧЕРНОВИК ТЕКСТА", draftID: dirtyExportTextDraft.id)
        try check(model3.hasUnsavedChanges, "draft is dirty")

        let exportDraftTarget = outsideExportDir.appendingPathComponent("export_saved_vs_draft.txt")
        preOperation = try capture(model3, "v3")
        model3.requestExport(savePanelRunner: { panel, completion in
            completion(.OK, exportDraftTarget)
        })
        try check(FileManager.default.fileExists(atPath: exportDraftTarget.path), "export file created")
        let draftExportContent = try String(contentsOf: exportDraftTarget, encoding: .utf8)
        try check(!draftExportContent.contains("НЕСОХРАНЁННЫЙ ЧЕРНОВИК ТЕКСТА"), "dirty draft text excluded from export")
        try check(draftExportContent.contains(turnTarget.text), "saved text included in export")
        try check(model3.activeTextDraft != nil, "draft preserved without auto-discard")
        try check(model3.activeTextDraft?.text == "НЕСОХРАНЁННЫЙ ЧЕРНОВИК ТЕКСТА", "dirty text intact in active draft")
        try check(model3.exportNotice?.contains("Внимание") == true, "export notice warns about dirty draft exclusion")
        try assertStatePreserved(
            model: model3,
            resultID: "v3",
            expectedSavedRowNames: baseRowsV3Names,
            expectedSavedRowTexts: baseRowsV3Texts,
            expectedDraftText: "НЕСОХРАНЁННЫЙ ЧЕРНОВИК ТЕКСТА",
            context: "during dirty text draft export"
        )
        model3.cancelTextDraft(draftID: dirtyExportTextDraft.id)

        // 20.6 Stale callback rejected on close/reopen before callback
        var staleSwitchCompletion: ((NSApplication.ModalResponse, URL?) -> Void)?
        model3.requestExport(savePanelRunner: { panel, completion in
            staleSwitchCompletion = completion
        })
        try check(staleSwitchCompletion != nil, "switch completion captured")
        (window3, model3) = try await importedCurrent("v2", manager: manager3, root: root)
        let staleSwitchTarget = outsideExportDir.appendingPathComponent("export_stale_switch.txt")
        staleSwitchCompletion?(.OK, staleSwitchTarget)
        try check(!FileManager.default.fileExists(atPath: staleSwitchTarget.path), "stale callback after close/reopen rejected, no file written")

        // 20.7 Stale callback rejected on window close before callback
        var staleCloseCompletion: ((NSApplication.ModalResponse, URL?) -> Void)?
        model3.requestExport(savePanelRunner: { panel, completion in
            staleCloseCompletion = completion
        })
        try check(staleCloseCompletion != nil, "close completion captured")
        window3.close()
        let staleCloseTarget = outsideExportDir.appendingPathComponent("export_stale_close.txt")
        staleCloseCompletion?(.OK, staleCloseTarget)
        try check(!FileManager.default.fileExists(atPath: staleCloseTarget.path), "stale callback after close rejected, no file written")
        try check(!model3.isExportAvailable, "closed model isExportAvailable is false")
        try check(!model3.canExport, "closed model canExport is false")

        // 20.8 Stale callback rejected on replacement request (token invalidation)
        let window4 = try await manager3.open(recordingURL: recording, title: "Export UI Test 4")
        let model4 = try require(manager3.model(for: recording), "model 4 loaded")
        var completionA: ((NSApplication.ModalResponse, URL?) -> Void)?
        var completionB: ((NSApplication.ModalResponse, URL?) -> Void)?
        model4.requestExport(savePanelRunner: { _, c in completionA = c })
        let tokenA = try require(model4.activeExportRequest?.id, "token A captured")
        model4.requestExport(savePanelRunner: { _, c in completionB = c })
        let tokenB = try require(model4.activeExportRequest?.id, "token B captured")
        try check(tokenA != tokenB, "replacement request generates distinct token")

        let exportTargetA = outsideExportDir.appendingPathComponent("export_stale_replaced_A.txt")
        completionA?(.OK, exportTargetA)
        try check(!FileManager.default.fileExists(atPath: exportTargetA.path), "stale replaced request A rejected")

        let exportTargetB = outsideExportDir.appendingPathComponent("export_replacement_B.txt")
        completionB?(.OK, exportTargetB)
        try check(FileManager.default.fileExists(atPath: exportTargetB.path), "active replacement request B succeeds")

        // 20.8b Replacement request B failing in preparation must still invalidate request A
        var completionA_failB: ((NSApplication.ModalResponse, URL?) -> Void)?
        preOperation = try capture(model4, "v2")
        model4.requestExport(savePanelRunner: { _, c in completionA_failB = c })
        _ = try require(model4.activeExportRequest?.id, "token A for failed B test captured")

        // Temporarily move result.json for v2 so request B preparation throws
        let v2ResultURL_fail = root.appendingPathComponent("raw/transcripts/v2/result.json")
        let v2ResultBackup = root.appendingPathComponent("raw/transcripts/v2/result.json.bak")
        try FileManager.default.moveItem(at: v2ResultURL_fail, to: v2ResultBackup)

        // Request B begins and fails in preparation
        model4.requestExport(savePanelRunner: { _, _ in })
        try check(model4.error != nil, "request B failed in preparation")

        // Restore v2 result.json
        try FileManager.default.moveItem(at: v2ResultBackup, to: v2ResultURL_fail)

        // Callback for request A must be rejected!
        let exportTargetA_afterFailedB = outsideExportDir.appendingPathComponent("export_stale_after_failed_B.txt")
        completionA_failB?(.OK, exportTargetA_afterFailedB)
        try check(!FileManager.default.fileExists(atPath: exportTargetA_afterFailedB.path), "stale request A invalidated even when request B preparation throws")
        try assertStatePreserved(
            model: model4,
            resultID: "v2",
            expectedSavedRowNames: preOperation!.names,
            expectedSavedRowTexts: preOperation!.texts,
            context: "after stale request A rejected following failed B"
        )

        // 20.9 Double callback handling is a NOOP
        completionB?(.OK, exportTargetB)
        try check(model4.activeExportRequest == nil, "request cleared after first completion, double callback is NOOP")

        // 20.10 Frozen saved snapshot: external edits while panel open do not alter frozen export
        var frozenCompletion: ((NSApplication.ModalResponse, URL?) -> Void)?
        model4.requestExport(savePanelRunner: { _, c in frozenCompletion = c })
        try check(model4.activeExportRequest != nil, "frozen export request active")

        // External process changes edits.json on disk during panel modal
        let v2EditsFile = root.appendingPathComponent("raw/transcripts/v2/edits.json")
        let externalEditsPayload = """
        {
          "schemaVersion": 1,
          "resultID": "v2",
          "revision": 99,
          "overrides": {
            "turn_1": { "text": "ВНЕШНЯЯ ПРАВКА НА ДИСКЕ", "displayName": "Внешний" }
          }
        }
        """
        try Data(externalEditsPayload.utf8).write(to: v2EditsFile)

        let exportFrozenTarget = outsideExportDir.appendingPathComponent("export_frozen.txt")
        frozenCompletion?(.OK, exportFrozenTarget)
        let frozenExported = try String(contentsOf: exportFrozenTarget, encoding: .utf8)
        try check(!frozenExported.contains("ВНЕШНЯЯ ПРАВКА НА ДИСКЕ"), "export uses frozen snapshot from request time, not external disk change")
        try check(model4.rows.first(where: { $0.id == "turn_1" })?.text != "ВНЕШНЯЯ ПРАВКА НА ДИСКЕ", "live editor rows not silently reloaded on external disk change")

        // 20.11 Destination protection fails closed and preserves source bytes
        let protectedSourceURL = root.appendingPathComponent("raw/meeting.host_record.wav")
        preOperation = try capture(model4, "v2")
        model4.requestExport(savePanelRunner: { _, c in c(.OK, protectedSourceURL) }, overwriteConsentHandler: { _ in true })
        try check(model4.error != nil, "protected destination reports error")
        try check(try Data(contentsOf: protectedSourceURL) == hostAudioBytesBaseline, "source audio bytes completely unchanged")
        try assertStatePreserved(
            model: model4,
            resultID: "v2",
            expectedSavedRowNames: preOperation!.names,
            expectedSavedRowTexts: preOperation!.texts,
            context: "after protected destination rejection"
        )

        // 20.12 Destination exists without overwrite consent rejected, NO automatic retry
        let existingTarget = outsideExportDir.appendingPathComponent("already_existing_export.txt")
        try Data("EXISTING UNTOUCHED".utf8).write(to: existingTarget)
        // User declines consent via overwriteConsentHandler
        var consentAskedForURL: URL? = nil
        preOperation = try capture(model4, "v2")
        model4.requestExport(
            savePanelRunner: { _, c in c(.OK, existingTarget) },
            overwriteConsentHandler: { url in
                consentAskedForURL = url
                return false // User declines consent
            }
        )
        try check(consentAskedForURL == existingTarget.standardizedFileURL, "overwrite consent was bound to exact target URL")
        try check(try String(contentsOf: existingTarget, encoding: .utf8) == "EXISTING UNTOUCHED", "existing file unchanged when consent declined")
        try assertStatePreserved(
            model: model4,
            resultID: "v2",
            expectedSavedRowNames: preOperation!.names,
            expectedSavedRowTexts: preOperation!.texts,
            context: "when overwrite consent declined"
        )

        // 20.13 Safe overwrite consent with confirmed existing destination succeeds
        var explicitConfirmedURL: URL? = nil
        model4.requestExport(
            savePanelRunner: { _, c in c(.OK, existingTarget) },
            overwriteConsentHandler: { url in
                explicitConfirmedURL = url
                return url == existingTarget.standardizedFileURL
            }
        )
        try check(explicitConfirmedURL == existingTarget.standardizedFileURL, "explicit consent confirmed for exact destination URL")
        try check(model4.error == nil, "overwrite succeeds with explicit consent")
        let overwrittenContent = try String(contentsOf: existingTarget, encoding: .utf8)
        try check(overwrittenContent != "EXISTING UNTOUCHED", "existing file overwritten with consent")

        // 20.14 Declined consent on existing destination cancels with zero output
        let declinedTarget = outsideExportDir.appendingPathComponent("declined_target.txt")
        try Data("PRESERVED".utf8).write(to: declinedTarget)
        preOperation = try capture(model4, "v2")
        model4.requestExport(
            savePanelRunner: { _, c in c(.OK, declinedTarget) },
            overwriteConsentHandler: { _ in false }
        )
        try check(try String(contentsOf: declinedTarget, encoding: .utf8) == "PRESERVED", "declined overwrite cancels with zero output")
        try assertStatePreserved(
            model: model4,
            resultID: "v2",
            expectedSavedRowNames: preOperation!.names,
            expectedSavedRowTexts: preOperation!.texts,
            context: "after declined consent cancellation"
        )

        // 20.15 Undo and result.json bytes preserved
        // Exercise usable Undo after each outcome, with real saved history and dirty input.
        // Earlier navigation probes retain repositories/locks; use an independent recording
        // rather than releasing or mutating their live state to make Undo appear usable.
        let undoRoot = outsideExportDir.appendingPathComponent("undo-recording/meeting")
        try FileManager.default.copyItem(at: root, to: undoRoot)
        let undoManager = TranscriptReviewWindowManager()
        let undoRecording = undoRoot.appendingPathComponent("meeting.m4a")
        var undoWindow = try await undoManager.open(recordingURL: undoRecording, title: "Export preservation")
        let undoModel = try require(undoManager.model(for: undoRecording), "independent undo model")
        do {
        var model4 = undoModel
        (undoWindow, model4) = try await importedCurrent("v1", manager: undoManager, root: undoRoot)
        for outcome in ["cancel", "protected-error"] {
            for draftKind in ["text", "name"] {
                let originalRows = model4.rows.map(\.text)
                let turnID = model4.rows[0].id
                model4.openTextEditing(for: turnID)
                let savedDraft = try require(model4.activeTextDraft, "saved edit draft")
                model4.updateDraftText("UNDO SEED \(outcome) \(draftKind)", draftID: savedDraft.id)
                model4.saveTextEditing(draftID: savedDraft.id)
                try check(model4.canUndo, "\(outcome)/\(draftKind): real undo entry seeded (\(model4.error ?? "no error"))")
                if draftKind == "text" {
                    model4.openTextEditing(for: turnID)
                    model4.updateDraftText("DIRTY TEXT", draftID: model4.activeTextDraft!.id)
                } else {
                    model4.openSpeakerAssignment(for: turnID)
                    model4.updateDraftName("DIRTY NAME", draftID: model4.activeDraft!.id)
                }
                preOperation = try capture(model4, "v1")
                let before = preOperation!
                model4.requestExport(savePanelRunner: { _, c in
                    c(outcome == "cancel" ? .cancel : .OK, outcome == "cancel" ? outsideExportDir.appendingPathComponent("never_\(draftKind).txt") : undoRoot.appendingPathComponent("raw/meeting.host_record.wav"))
                }, overwriteConsentHandler: { _ in true })
                try check(outcome == "cancel" ? model4.error == nil : model4.error != nil, "\(outcome)/\(draftKind): expected export outcome")
                try assertStatePreserved(model: model4, resultID: "v1", expectedSavedRowNames: before.names, expectedSavedRowTexts: before.texts, context: "\(outcome)/\(draftKind) dirty input")
                if let draft = model4.activeTextDraft { model4.cancelTextDraft(draftID: draft.id) }
                if let draft = model4.activeDraft { model4.cancelDraft(draftID: draft.id) }
                model4.undoLastEdit()
                try check(model4.error == nil && model4.rows.map(\.text) == originalRows, "\(outcome)/\(draftKind): Undo actually restores prior saved text")
            }
        }
        // The v2 live CAS snapshot must still reject the external revision, not autoload it.
        (undoWindow, model4) = try await importedCurrent("v2", manager: undoManager, root: undoRoot)
        model4.openTextEditing(for: "turn_1")
        let conflictDraft = try require(model4.activeTextDraft, "conflict draft")
        model4.updateDraftText("LOCAL CONFLICT INPUT", draftID: conflictDraft.id)
        // Write after loading so this is genuinely an external CAS conflict.
        let externalConflict = Data(externalEditsPayload.replacingOccurrences(of: "99", with: "100").utf8)
        let conflictEditsFile = undoRoot.appendingPathComponent("raw/transcripts/v2/edits.json")
        try externalConflict.write(to: conflictEditsFile)
        preOperation = try capture(model4, "v2")
        let beforeConflict = preOperation!
        model4.requestExport(savePanelRunner: { _, c in c(.cancel, nil) })
        try assertStatePreserved(model: model4, resultID: "v2", expectedSavedRowNames: beforeConflict.names, expectedSavedRowTexts: beforeConflict.texts, context: "external CAS conflict after export cancel")
        model4.requestExport(savePanelRunner: { _, c in c(.OK, undoRoot.appendingPathComponent("raw/meeting.host_record.wav")) }, overwriteConsentHandler: { _ in true })
        try check(model4.error != nil, "external CAS conflict: protected export reports error")
        try assertStatePreserved(model: model4, resultID: "v2", expectedSavedRowNames: beforeConflict.names, expectedSavedRowTexts: beforeConflict.texts, context: "external CAS conflict after export error")
        do {
            let repository = try require(model4.state.session?.editsRepository, "conflict repository")
            _ = try repository.saveTurnOverride(resultID: "v2", turnID: "turn_1", text: "LOCAL CONFLICT INPUT", displayName: nil)
            try check(false, "stale CAS save must fail")
        } catch TranscriptEditsError.conflict {
            try check(true, "stale CAS save reports exact conflict")
        }
        try check(try Data(contentsOf: conflictEditsFile) == externalConflict, "external write preserved after CAS conflict")
        try assertStatePreserved(model: model4, resultID: "v2", expectedSavedRowNames: beforeConflict.names, expectedSavedRowTexts: beforeConflict.texts, context: "CAS conflict does not autoload or discard draft")
        }
        undoWindow.close()
        let v2ResultJSON = root.appendingPathComponent("raw/transcripts/v2/result.json")
        try check(FileManager.default.fileExists(atPath: v2ResultJSON.path), "result.json exists")
        window4.close()

        print("ALL SPEAKER ASSIGNMENT UI CHECKS PASSED GREEN")
    }
}

// Minimal helper for #require in script harness
@MainActor func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    return value
}
