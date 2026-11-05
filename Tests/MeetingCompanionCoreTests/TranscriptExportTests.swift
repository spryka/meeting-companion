import Foundation
import Testing
import CryptoKit
@testable import MeetingCompanionCore

@Suite final class TranscriptExportTests {
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

    private func temporaryDirectory(_ prefix: String = "TranscriptExportTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            prefix + "-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        return directory
    }

    private func computeSHA256(for fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func createSyntheticRecording(
        in root: URL,
        resultID: String = "res_export_test",
        title: String? = "Обсуждение архитектуры",
        startAt: String? = "2026-10-31T12:00:00+03:00",
        agenda: String? = "Планы на спринт",
        attendees: [String]? = ["Алиса", "Борис"],
        warnings: [[String: Any]] = []
    ) throws -> (resultURL: URL, versionDir: URL, hostAudioURL: URL, mixAudioURL: URL) {
        let rawDir = root.appendingPathComponent("raw")
        let transcriptsDir = rawDir.appendingPathComponent("transcripts")
        let versionDir = transcriptsDir.appendingPathComponent(resultID)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let fixtureData = try Data(contentsOf: fixture("valid_parakeet_off"))
        var docJson = try #require(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        docJson["resultID"] = resultID
        docJson["playback"] = ["status": "ready", "mixPath": "raw/transcripts/\(resultID)/mix.m4a"]
        docJson["warnings"] = warnings

        var contextJson: [String: Any] = [:]
        if let title { contextJson["title"] = title }
        if let startAt { contextJson["startAt"] = startAt }
        if let agenda { contextJson["agenda"] = agenda }
        if let attendees { contextJson["attendees"] = attendees }
        if !contextJson.isEmpty {
            docJson["context"] = contextJson
        } else {
            docJson["context"] = NSNull()
        }

        let resultData = try JSONSerialization.data(withJSONObject: docJson, options: [.sortedKeys])
        let resultURL = versionDir.appendingPathComponent("result.json")
        try resultData.write(to: resultURL)

        let hostAudio = rawDir.appendingPathComponent("meeting.host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("meeting.remote_record.wav")
        let mixAudio = versionDir.appendingPathComponent("mix.m4a")
        let dummy = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try dummy.write(to: hostAudio)
        try dummy.write(to: remoteAudio)
        try dummy.write(to: mixAudio)

        return (resultURL, versionDir, hostAudio, mixAudio)
    }

    // MARK: - 1. Export Selected Older vs Newer Version

    @Test func testExportSelectedOlderVsNewerVersion() throws {
        let root = try temporaryDirectory()
        let (resultURL1, _, _, _) = try createSyntheticRecording(in: root, resultID: "v1", title: "Версия 1")
        let (resultURL2, _, _, _) = try createSyntheticRecording(in: root, resultID: "v2", title: "Версия 2")

        let doc1 = try TranscriptDocument.load(from: resultURL1, recordingDirectory: root)
        let doc2 = try TranscriptDocument.load(from: resultURL2, recordingDirectory: root)

        let edits1 = TranscriptEdits(resultID: "v1", revision: 1, overrides: [
            "turn_1": TranscriptTurnOverride(text: "Исправленный текст V1", displayName: "Автор V1")
        ])
        let edits2 = TranscriptEdits(resultID: "v2", revision: 1, overrides: [
            "turn_1": TranscriptTurnOverride(text: "Исправленный текст V2", displayName: "Автор V2")
        ])

        let formatter = TranscriptExportFormatter()

        let exported1 = try formatter.format(document: doc1, edits: edits1)
        let exported2 = try formatter.format(document: doc2, edits: edits2)

        #expect(exported1.contains("Автор V1"))
        #expect(exported1.contains("Исправленный текст V1"))
        #expect(!exported1.contains("Автор V2"))

        #expect(exported2.contains("Автор V2"))
        #expect(exported2.contains("Исправленный текст V2"))
        #expect(!exported2.contains("Автор V1"))
    }

    // MARK: - 2. Header Formatting & Clean Omission

    @Test func testExportHeaderContextAndOmissionWhenAbsent() throws {
        let root = try temporaryDirectory()
        // With full context
        let (resultURLFull, _, _, _) = try createSyntheticRecording(
            in: root,
            resultID: "v_full",
            title: "Совет директоров",
            startAt: "2026-10-31T14:30:00+03:00",
            agenda: "Финансовый отчёт",
            attendees: ["Алиса", "Борис", "Сергей"]
        )
        let docFull = try TranscriptDocument.load(from: resultURLFull, recordingDirectory: root)
        let editsFull = TranscriptEdits.initial(resultID: "v_full")
        let formatter = TranscriptExportFormatter()
        let exportedFull = try formatter.format(document: docFull, edits: editsFull)

        #expect(exportedFull.contains("Совет директоров"))
        #expect(exportedFull.contains("2026-10-31T14:30:00+03:00"))
        #expect(exportedFull.contains("Финансовый отчёт"))
        #expect(exportedFull.contains("Приглашены: Алиса, Борис, Сергей"))

        // Without context (nil)
        let (resultURLNil, _, _, _) = try createSyntheticRecording(
            in: root,
            resultID: "v_nil",
            title: nil,
            startAt: nil,
            agenda: nil,
            attendees: nil
        )
        let docNil = try TranscriptDocument.load(from: resultURLNil, recordingDirectory: root)
        let editsNil = TranscriptEdits.initial(resultID: "v_nil")
        let exportedNil = try formatter.format(document: docNil, edits: editsNil)

        #expect(!exportedNil.contains("Приглашены"))
        #expect(!exportedNil.contains("Повестка"))
        #expect(!exportedNil.contains("Дата"))
        // First non-empty line is turn
        #expect(exportedNil.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["))
    }

    // MARK: - 3. Verbatim Preservation of User Fields: POSIX, Windows, UNC, fileURL, CRLF, Quotes

    @Test func testExportVerbatimPreservationOfUserFieldsPOSIXWindowsUNCfileURLCRLFquotes() throws {
        let root = try temporaryDirectory()

        let titleInput = "  Заседание /Users/alice/test и C:\\Admin\\notes.txt  "
        let startAtInput = "2026-10-31T12:00:00+03:00"
        let timeZoneInput = "  Europe/Moscow (file:///tmp/tz.txt)  "
        let agendaInput = "  Пункт 1: \\\\nas\\share\\agenda.doc\rПункт 2: \"Кавычки\"\nПункт 3: CRLF\r\nКонец  "
        let attendeesInput = ["  /Users/bob/lead  ", "  C:\\Users\\Charlie\r\nDept  ", "  \"Dr.\" Dan  "]
        let speakerNameInput = "  Алиса\r\n(Архитектор) /tmp/alice  "
        let turnTextInput = "  Строка 1 /tmp/test.wav\rСтрока 2 file:///var/a\nСтрока 3 C:\\win.txt\r\nСтрока 4 \\\\srv\\share  "

        let (resultURL, _, _, _) = try createSyntheticRecording(
            in: root,
            resultID: "v_verbatim",
            title: titleInput,
            startAt: startAtInput,
            agenda: agendaInput,
            attendees: attendeesInput
        )

        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
        var context = try #require(json["context"] as? [String: Any])
        context["timeZone"] = timeZoneInput
        json["context"] = context
        try JSONSerialization.data(withJSONObject: json).write(to: resultURL)

        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        let edits = TranscriptEdits(resultID: "v_verbatim", revision: 1, overrides: [
            "turn_1": TranscriptTurnOverride(text: turnTextInput, displayName: speakerNameInput)
        ])

        let formatter = TranscriptExportFormatter()
        let exported = try formatter.format(document: doc, edits: edits)

        // Full UTF-8 equality: all fields preserved verbatim, including leading/trailing whitespace,
        // standalone CR, LF, CRLF, multiline speaker names, POSIX/Windows/UNC/fileURL paths, quotes,
        // and unedited word text on turn_2.
        let expectedHeader = """
          Заседание /Users/alice/test и C:\\Admin\\notes.txt  
        Дата и время: 2026-10-31T12:00:00+03:00
        Часовой пояс:   Europe/Moscow (file:///tmp/tz.txt)  
        Повестка:   Пункт 1: \\\\nas\\share\\agenda.doc\rПункт 2: \"Кавычки\"\nПункт 3: CRLF\r\nКонец  
        Приглашены:   /Users/bob/lead  ,   C:\\Users\\Charlie\r\nDept  ,   \"Dr.\" Dan  
        """

        let expectedTurn1 = """
        [00:00:00]   Алиса\r\n(Архитектор) /tmp/alice  :
          Строка 1 /tmp/test.wav\rСтрока 2 file:///var/a\nСтрока 3 C:\\win.txt\r\nСтрока 4 \\\\srv\\share  
        """

        let expectedTurn2 = """
        [00:00:02] Speaker 2:
        Привет
        """

        let expectedFull = "\(expectedHeader)\n\n\(expectedTurn1)\n\n\(expectedTurn2)\n"
        #expect(exported == expectedFull)
    }

    // MARK: - 4. Assigned Speaker Names Not Fallback Redaction

    @Test func testAssignedSpeakerNamesNotFallbackRedaction() throws {
        let root = try temporaryDirectory()
        let (resultURL, _, _, _) = try createSyntheticRecording(in: root, resultID: "v_names")
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)

        // Case 1: Assigned name contains POSIX path -> preserved verbatim, not fallback
        let editsPath = TranscriptEdits(resultID: "v_names", revision: 1, overrides: [
            "turn_1": TranscriptTurnOverride(displayName: "/Users/alice/name.txt")
        ])
        let formatter = TranscriptExportFormatter()
        let exportedPath = try formatter.format(document: doc, edits: editsPath)
        #expect(exportedPath.contains("[00:00:00] /Users/alice/name.txt:\n"))
        #expect(!exportedPath.contains("Speaker 1:"))

        // Case 2: Assigned name contains Windows path -> preserved verbatim
        let editsWin = TranscriptEdits(resultID: "v_names", revision: 2, overrides: [
            "turn_1": TranscriptTurnOverride(displayName: "C:\\Users\\Bob")
        ])
        let exportedWin = try formatter.format(document: doc, edits: editsWin)
        #expect(exportedWin.contains("[00:00:00] C:\\Users\\Bob:\n"))

        // Case 3: Empty or blank assigned name in overrides is strictly rejected by validation
        let editsBlank = TranscriptEdits(resultID: "v_names", revision: 3, overrides: [
            "turn_1": TranscriptTurnOverride(text: "Привет", displayName: "   ")
        ])
        #expect(throws: TranscriptExportError.self) {
            _ = try formatter.format(document: doc, edits: editsBlank)
        }

        // Case 4: No override (displayName == nil) -> default Speaker <displayNumber>
        let editsNone = TranscriptEdits.initial(resultID: "v_names")
        let exportedNone = try formatter.format(document: doc, edits: editsNone)
        #expect(exportedNone.contains("[00:00:00] Speaker 1:\n"))
    }

    // MARK: - 5. Safe Static Warning Mapping & Raw Diagnostic Message Exclusion

    @Test func testWarningMappingStaticSafeAndExcludesRawDiagnosticMessages() throws {
        let root = try temporaryDirectory()
        let (resultURL, _, _, _) = try createSyntheticRecording(
            in: root,
            resultID: "v_warnings",
            warnings: [
                ["code": "diarization_voice_limit", "sourceID": "host", "message": "CRITICAL error in /private/var/folders/audio.wav: 8 voices exceeded"],
                ["code": "aec_failed", "sourceID": "remote", "message": "AEC failed at /tmp/scratch.wav with errno 13"],
                ["code": "aec_warning", "sourceID": "remote", "message": "AEC warning: bypass filter at /Volumes/data/aec.caf"],
                ["code": "correction_failed", "sourceID": "host", "message": "Parakeet exception at /usr/local/bin/parakeet: failure"],
                ["code": "playback_mix_failed", "sourceID": NSNull(), "message": "Failed mix render to /raw/transcripts/v_warnings/mix.m4a"],
                ["code": "diarization_failed", "sourceID": "remote", "message": "Nemotron died at C:\\temp\\diarize.py"],
                ["code": "capture_warning", "sourceID": "host", "message": "Dropped 25 frames from CoreAudio tap at /dev/audio0"],
                ["code": "recognition_warning", "sourceID": "host", "message": "GigaAM beam search failed at /tmp/asr.bin"],
                ["code": "context_unavailable", "sourceID": NSNull(), "message": "EKEventStore error /private/var/calendar.db locked"],
                ["code": "recognition_voice_limit_recovery_failed", "sourceID": "host", "message": "Recovery failed for /audio/chunk.wav"],
                ["code": "unknown_future_sensor_code", "sourceID": "host", "message": "Internal sensor dump /dev/hw/sensor9: error 99"]
            ]
        )
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        let edits = TranscriptEdits.initial(resultID: "v_warnings")
        let formatter = TranscriptExportFormatter()
        let exported = try formatter.format(document: doc, edits: edits)

        // Warnings header
        #expect(exported.contains("Предупреждения:"))

        // Verify mapped safe static texts with track source labels
        #expect(exported.contains("[Микрофон] Достигнут предел распознавания 8 голосов."))
        #expect(exported.contains("[Системный звук] Эхоподавление не выполнено; распознаётся исходный микрофон."))
        #expect(exported.contains("[Системный звук] Эхоподавление завершилось с предупреждением."))
        #expect(exported.contains("[Микрофон] Коррекция терминов не выполнена; сохранён исходный текст."))
        #expect(exported.contains("Подготовка совместного аудио не удалась; доступен только текстовый режим."))
        #expect(exported.contains("[Системный звук] Разделение голосов не выполнено."))
        #expect(exported.contains("[Микрофон] Предупреждение захвата аудио."))
        #expect(exported.contains("[Микрофон] Предупреждение распознавания речи."))
        #expect(exported.contains("Не удалось прочитать контекст встречи."))
        #expect(exported.contains("[Микрофон] Восстановление после превышения лимита голосов не выполнено."))
        // Unknown code emits documented generic safe warning
        #expect(exported.contains("[Микрофон] Предупреждение обработки записи."))

        // Verify that NONE of the raw diagnostic messages or technical paths leak into export!
        #expect(!exported.contains("/private/var/folders"))
        #expect(!exported.contains("/tmp/scratch.wav"))
        #expect(!exported.contains("/Volumes/data/aec.caf"))
        #expect(!exported.contains("/usr/local/bin/parakeet"))
        #expect(!exported.contains("/raw/transcripts/v_warnings/mix.m4a"))
        #expect(!exported.contains("C:\\temp\\diarize.py"))
        #expect(!exported.contains("/dev/audio0"))
        #expect(!exported.contains("/tmp/asr.bin"))
        #expect(!exported.contains("/private/var/calendar.db"))
        #expect(!exported.contains("/audio/chunk.wav"))
        #expect(!exported.contains("/dev/hw/sensor9"))

        // Warnings appear BEFORE turns
        let warningsIndex = try #require(exported.range(of: "Предупреждения:")?.lowerBound)
        let firstTurnIndex = try #require(exported.range(of: "[00:")?.lowerBound)
        #expect(warningsIndex < firstTurnIndex)
    }

    // MARK: - 6. Field Allowlist Excludes Service Metadata and Technical Paths

    @Test func testFieldAllowlistExcludesServiceMetadataAndTechnicalPaths() throws {
        let root = try temporaryDirectory()
        let resultID = "res_secret_metadata_guid_987654"
        let (resultURL, _, _, _) = try createSyntheticRecording(
            in: root,
            resultID: resultID,
            title: "Обычное название",
            startAt: "2026-10-31T10:00:00+03:00"
        )

        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        let edits = TranscriptEdits.initial(resultID: resultID)
        let formatter = TranscriptExportFormatter()
        let exported = try formatter.format(document: doc, edits: edits)

        // Service identifiers and metadata fields must be excluded by allowlist
        #expect(!exported.contains(resultID))
        #expect(!exported.contains("meeting.host_record.wav"))
        #expect(!exported.contains("meeting.remote_record.wav"))
        #expect(!exported.contains("raw/transcripts"))
        #expect(!exported.contains("schemaVersion"))
        #expect(!exported.contains("createdAt"))
        #expect(!exported.contains("turn_1"))
        #expect(!exported.contains("turn_2"))
        #expect(!exported.contains("w_1"))
        #expect(!exported.contains("spk_h1"))
        #expect(!exported.contains("spk_r1"))
    }

    // MARK: - 7. Destination Protection (Source Audio, Result JSON, Edits JSON, Symlink/Hardlink)

    @Test func testDestinationProtectionRejectsProtectedFilesAndRecordingTree() throws {
        let root = try temporaryDirectory()
        let (resultURL, versionDir, hostAudio, mixAudio) = try createSyntheticRecording(in: root, resultID: "v_protect")
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        let edits = TranscriptEdits.initial(resultID: "v_protect")

        let writer = TranscriptExportWriter(recordingDirectory: root)

        // 1. Attempt to export directly over result.json
        #expect(throws: TranscriptExportError.self) {
            try writer.export(document: doc, edits: edits, to: resultURL, allowOverwrite: true)
        }

        // 2. Attempt to export over source audio
        #expect(throws: TranscriptExportError.self) {
            try writer.export(document: doc, edits: edits, to: hostAudio, allowOverwrite: true)
        }

        // 3. Attempt to export over mix audio
        #expect(throws: TranscriptExportError.self) {
            try writer.export(document: doc, edits: edits, to: mixAudio, allowOverwrite: true)
        }

        // 4. Attempt to export into recording tree
        let insideURL = versionDir.appendingPathComponent("exported.txt")
        #expect(throws: TranscriptExportError.self) {
            try writer.export(document: doc, edits: edits, to: insideURL, allowOverwrite: true)
        }

        // 5. Attempt to export via external symlink pointing to protected hostAudio
        let externalDir = try temporaryDirectory("external")
        let symlinkURL = externalDir.appendingPathComponent("link_to_audio.txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: hostAudio)

        #expect(throws: TranscriptExportError.self) {
            try writer.export(document: doc, edits: edits, to: symlinkURL, allowOverwrite: true)
        }

        // Verify hostAudio bytes are completely unchanged
        let audioData = try Data(contentsOf: hostAudio)
        #expect(audioData == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    // MARK: - 8. Destination Exists Without Overwrite Rejected

    @Test func testDestinationExistsWithoutOverwriteRejected() throws {
        let root = try temporaryDirectory()
        let (resultURL, _, _, _) = try createSyntheticRecording(in: root, resultID: "v_exists")
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        let edits = TranscriptEdits.initial(resultID: "v_exists")

        let externalDir = try temporaryDirectory("external")
        let targetURL = externalDir.appendingPathComponent("export.txt")
        try Data("Предыдущий экспорт".utf8).write(to: targetURL)

        let writer = TranscriptExportWriter(recordingDirectory: root)

        // allowOverwrite == false must throw destinationExists
        #expect {
            try writer.export(document: doc, edits: edits, to: targetURL, allowOverwrite: false)
        } throws: { error in
            if case .destinationExists = (error as? TranscriptExportError) { return true }
            return false
        }

        // allowOverwrite == true must succeed and overwrite atomically
        try writer.export(document: doc, edits: edits, to: targetURL, allowOverwrite: true)
        let content = try String(contentsOf: targetURL, encoding: .utf8)
        #expect(content != "Предыдущий экспорт")
        #expect(content.contains("Speaker 1:"))
    }

    // MARK: - 9. Result ID Mismatch Throws Error

    @Test func testResultIDMismatchThrowsError() throws {
        let root = try temporaryDirectory()
        let (resultURL, _, _, _) = try createSyntheticRecording(in: root, resultID: "v_real")
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        let editsMismatch = TranscriptEdits.initial(resultID: "v_other")

        let formatter = TranscriptExportFormatter()
        #expect {
            try formatter.format(document: doc, edits: editsMismatch)
        } throws: { error in
            if case .resultMismatch = (error as? TranscriptExportError) { return true }
            return false
        }
    }

    // MARK: - 10. Destination Canonicalizes Parent and Rejects Traversal or Symlink Parent

    @Test func testDestinationCanonicalizesParentAndRejectsTraversalOrSymlinkParent() throws {
        let root = try temporaryDirectory()
        let rec = root.appendingPathComponent("recording")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let (resultURL, _, _, _) = try createSyntheticRecording(in: rec, resultID: "v_parent_canon")
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: rec)
        let edits = TranscriptEdits.initial(resultID: "v_parent_canon")

        let writer = TranscriptExportWriter(recordingDirectory: rec)

        // 1. Symlink parent pointing into recording tree
        let parentSym = outside.appendingPathComponent("recording-link")
        try FileManager.default.createSymbolicLink(at: parentSym, withDestinationURL: rec)
        let targetInsideSymParent = parentSym.appendingPathComponent("new.txt")
        #expect(throws: TranscriptExportError.self) {
            try writer.export(document: doc, edits: edits, to: targetInsideSymParent, allowOverwrite: true)
        }

        // 2. Traversal normalized into recording tree
        let traversalTarget = outside.appendingPathComponent("../recording/raw/new.txt")
        #expect(throws: TranscriptExportError.self) {
            try writer.export(document: doc, edits: edits, to: traversalTarget, allowOverwrite: true)
        }
    }

    // MARK: - 11. Unreadable Recording Subtree Fails Closed

    @Test func testDestinationProtectionFailsClosedOnUnreadableRecordingSubtree() throws {
        let root = try temporaryDirectory()
        let rec = root.appendingPathComponent("recording")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let (resultURL, _, _, _) = try createSyntheticRecording(in: rec, resultID: "v_unreadable")
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: rec)
        let edits = TranscriptEdits.initial(resultID: "v_unreadable")

        let writer = TranscriptExportWriter(recordingDirectory: rec)

        let hiddenDir = rec.appendingPathComponent("unreadable_dir")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        let hiddenFile = hiddenDir.appendingPathComponent("secret.bin")
        try Data("SECRET".utf8).write(to: hiddenFile)
        let hiddenHard = outside.appendingPathComponent("unreadable-hardlink.txt")
        try FileManager.default.linkItem(at: hiddenFile, to: hiddenHard)

        // Make subtree unreadable
        guard chmod(hiddenDir.path, 0) == 0 else { return }
        defer { _ = chmod(hiddenDir.path, 0o700) }

        #expect(throws: TranscriptExportError.self) {
            try writer.export(document: doc, edits: edits, to: hiddenHard, allowOverwrite: true)
        }
    }

    // MARK: - 12. Rejects Invalid Edits Schema, Revision, Unknown Turns, and Blank Names

    @Test func testExportRejectsInvalidEditsSchemaRevisionUnknownTurnsBlankNames() throws {
        let root = try temporaryDirectory()
        let (resultURL, _, _, _) = try createSyntheticRecording(in: root, resultID: "v_invalid_edits")
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        let formatter = TranscriptExportFormatter()
        let writer = TranscriptExportWriter(recordingDirectory: root)
        let externalTarget = root.appendingPathComponent("../outside_target.txt")

        let invalidCases = [
            TranscriptEdits(schemaVersion: 99, resultID: "v_invalid_edits", revision: 0, overrides: [:]),
            TranscriptEdits(resultID: "v_invalid_edits", revision: -1, overrides: [:]),
            TranscriptEdits(resultID: "v_invalid_edits", revision: 1, overrides: ["unknown_turn": .init(text: "orphan")]),
            TranscriptEdits(resultID: "v_invalid_edits", revision: 1, overrides: ["turn_1": .init(displayName: "   ")])
        ]

        for edits in invalidCases {
            #expect(throws: TranscriptExportError.self) {
                _ = try formatter.format(document: doc, edits: edits)
            }
            #expect(throws: TranscriptExportError.self) {
                try writer.export(document: doc, edits: edits, to: externalTarget, allowOverwrite: true)
            }
        }
    }

    // MARK: - 13. Timestamp Formatting (Hours > 23 No Day Wrap) & Empty Text

    @Test func testExportTimestampFormattingOver24HoursAndEmptyText() throws {
        let root = try temporaryDirectory()
        let (resultURL, _, _, _) = try createSyntheticRecording(in: root, resultID: "v_long")
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)

        let edits = TranscriptEdits(resultID: "v_long", revision: 1, overrides: [
            "turn_1": TranscriptTurnOverride(text: "", displayName: "Алиса")
        ])

        let formatter = TranscriptExportFormatter()
        let exported = try formatter.format(document: doc, edits: edits)

        let expected = """
        Обсуждение архитектуры
        Дата и время: 2026-10-31T12:00:00+03:00
        Повестка: Планы на спринт
        Приглашены: Алиса, Борис

        [00:00:00] Алиса:


        [00:00:02] Speaker 2:
        Привет

        """
        #expect(exported == expected)
        #expect(!exported.contains("Добрый"))
        #expect(!exported.contains("день"))

        let formattedTime = TranscriptExportFormatter.formatTimestamp(seconds: 90061.0)
        #expect(formattedTime == "25:01:01")
    }

    // MARK: - 14. Large Finite Timestamp Formatting Without Int Trap

    @Test func testExportLargeFiniteTimestampNonNarrowingWithoutIntTrap() throws {
        let largeHour = TranscriptExportFormatter.formatTimestamp(seconds: 4_294_967_296.0 * 3600)
        #expect(largeHour == "4294967296:00:00")

        let hugeTime = TranscriptExportFormatter.formatTimestamp(seconds: 1e20)
        #expect(!hugeTime.isEmpty)
        #expect(hugeTime.contains(":"))
    }

    // MARK: - 15. TimeZone Renders Independently of startAt

    @Test func testExportRendersTimeZoneIndependentlyOfStartAt() throws {
        let root = try temporaryDirectory()
        let (resultURL, _, _, _) = try createSyntheticRecording(
            in: root,
            resultID: "v_tz_only",
            title: nil,
            startAt: nil,
            agenda: nil,
            attendees: nil
        )
        var docJson = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
        docJson["context"] = ["timeZone": "Europe/Moscow"]
        try JSONSerialization.data(withJSONObject: docJson, options: [.sortedKeys]).write(to: resultURL)

        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        let edits = TranscriptEdits.initial(resultID: "v_tz_only")

        let formatter = TranscriptExportFormatter()
        let exported = try formatter.format(document: doc, edits: edits)

        #expect(exported.contains("Часовой пояс: Europe/Moscow"))
    }

    // MARK: - 16. Deterministic Atomic No-Replace Race Check

    @Test func testAtomicNoReplacePublicationPreservesConcurrentDestinationAtRenameBoundary() throws {
        let root = try temporaryDirectory()
        let (resultURL, _, _, _) = try createSyntheticRecording(in: root, resultID: "v_race")
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        let edits = TranscriptEdits.initial(resultID: "v_race")

        let externalDir = try temporaryDirectory("external")
        let raceTarget = externalDir.appendingPathComponent("race_target.txt")

        let writer = TranscriptExportWriter(recordingDirectory: root) { _, destURL in
            let fd = open(destURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                _ = "CONCURRENT-OWNER".utf8CString.withUnsafeBufferPointer { buf in
                    write(fd, buf.baseAddress, 16)
                }
                close(fd)
            }
        }

        #expect {
            try writer.export(document: doc, edits: edits, to: raceTarget, allowOverwrite: false)
        } throws: { error in
            if case .destinationExists = (error as? TranscriptExportError) { return true }
            return false
        }

        let content = try String(contentsOf: raceTarget, encoding: .utf8)
        #expect(content.hasPrefix("CONCURRENT-OWNER"))

        let remainingTemp = try FileManager.default.contentsOfDirectory(atPath: externalDir.path).filter { $0.hasPrefix(".export.tmp.") }
        #expect(remainingTemp.isEmpty)
    }

    // MARK: - 17. Inaccessible External Hardlink Referent Fails Closed

    @Test func testInaccessibleExternalHardlinkReferentFailsClosed() throws {
        let root = try temporaryDirectory()
        let rec = root.appendingPathComponent("recording")
        let (resultURL, _, audio, _) = try createSyntheticRecording(in: rec)
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: rec)
        let hidden = root.appendingPathComponent("external-hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let hardlink = hidden.appendingPathComponent("audio-alias")
        try FileManager.default.linkItem(at: audio, to: hardlink)
        let symlink = root.appendingPathComponent("export-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: hardlink)
        let original = try Data(contentsOf: audio)
        try #require(chmod(hidden.path, 0) == 0)
        defer { _ = chmod(hidden.path, 0o700) }
        var info = stat()
        try #require(stat(hardlink.path, &info) == -1 && errno == EACCES)
        #expect {
            try TranscriptExportWriter(recordingDirectory: rec).export(
                document: doc, edits: .initial(resultID: doc.resultID), to: symlink, allowOverwrite: true)
        } throws: { error in
            if case .protectedDestination = error as? TranscriptExportError { return true }
            return false
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == hardlink.path)
        #expect(try Data(contentsOf: audio) == original)
        try #require(chmod(hidden.path, 0o700) == 0)
        #expect(try Data(contentsOf: hardlink) == original)
    }

    // MARK: - 18. Dangling External Symlink Can Be Replaced Without Creating Referent

    @Test func testDanglingExternalSymlinkCanBeReplacedWithoutCreatingReferent() throws {
        let root = try temporaryDirectory()
        let rec = root.appendingPathComponent("recording")
        let (resultURL, _, _, _) = try createSyntheticRecording(in: rec)
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: rec)
        let missing = root.appendingPathComponent("missing")
        let symlink = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: missing)
        try TranscriptExportWriter(recordingDirectory: rec).export(
            document: doc, edits: .initial(resultID: doc.resultID), to: symlink, allowOverwrite: true)
        #expect(try String(contentsOf: symlink, encoding: .utf8).contains("Speaker 1:"))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // MARK: - 19. Destination Protection Rejects Final Symlink to External Hardlink of Recording Artifact

    @Test func testDestinationProtectionRejectsFinalSymlinkToExternalHardlinkOfRecordingArtifact() throws {
        let root = try temporaryDirectory()
        let rec = root.appendingPathComponent("recording")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let (resultURL, _, _, _) = try createSyntheticRecording(in: rec, resultID: "v_symlink_hardlink")
        let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: rec)
        let edits = TranscriptEdits.initial(resultID: "v_symlink_hardlink")

        let deepArtifact = rec.appendingPathComponent("raw/unlisted/deep/new-artifact.bin")
        try FileManager.default.createDirectory(at: deepArtifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xCA, 0xFE, 0xBA, 0xBE]).write(to: deepArtifact)

        // 1. External hardlink
        let externalHard = outside.appendingPathComponent("unknown-hardlink.txt")
        try FileManager.default.linkItem(at: deepArtifact, to: externalHard)

        // 2. Chained symlink to external hardlink
        let chainedSym = outside.appendingPathComponent("symlink-to-external-hardlink.txt")
        try FileManager.default.createSymbolicLink(at: chainedSym, withDestinationURL: externalHard)

        let writer = TranscriptExportWriter(recordingDirectory: rec)
        #expect(throws: TranscriptExportError.self) {
            try writer.export(document: doc, edits: edits, to: chainedSym, allowOverwrite: true)
        }
    }
}
