import Foundation

@main struct Check {
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = folder.appendingPathComponent("meeting_2026-10-14_10-00-00.m4a")
        let context = recording.deletingPathExtension().appendingPathExtension("context.json")
        let fallback = TranscriptionNotifications.content(recording: recording)
        precondition(fallback.title == "Транскрибация завершена")
        precondition(fallback.body == "meeting_2026-10-14_10-00-00")
        precondition(fallback.categoryIdentifier.isEmpty && fallback.sound == nil)
        try Data(#"{"summary":"  Встреча CX  ","agenda":"private notes"}"#.utf8).write(to: context)
        precondition(TranscriptionNotifications.content(recording: recording).body == "Встреча CX")
        for value in [#"{"summary":"  "}"#, "broken JSON"] {
            try Data(value.utf8).write(to: context)
            precondition(TranscriptionNotifications.content(recording: recording).body == fallback.body)
        }
        print("Completion notification title and fallback checks passed")
    }
}
