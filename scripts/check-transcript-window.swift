// Compile with actual Core sources and TranscriptReviewWindow.swift, defining
// TRANSCRIPT_WINDOW_HARNESS. Does not launch the installed app or use audio.
import AppKit
import Foundation

@main struct TranscriptWindowCheck {
    enum Failure: Error { case check(String), persistence }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure.check(message) }
            print("PASS: \(message)")
        }
        func version(_ id: String, date: String, text: String) throws {
            let dir = root.appendingPathComponent("raw/transcripts/\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
            json["resultID"] = id
            json["createdAt"] = date
            json["playback"] = ["status": "ready", "mixPath": "raw/transcripts/\(id)/mix.m4a"]
            var words = json["words"] as! [[String: Any]]
            words[0]["text"] = text
            json["words"] = words
            var baseline = json["baselineWords"] as! [[String: Any]]
            baseline[0]["text"] = text
            json["baselineWords"] = baseline
            try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("result.json"))
            try Data("synthetic".utf8).write(to: dir.appendingPathComponent("mix.m4a"))
        }
        try version("v1", date: "2026-10-30T10:00:00Z", text: "First")
        try version("v2", date: "2026-10-31T10:00:00Z", text: "Second")
        let recording = root.appendingPathComponent("meeting.m4a")
        let selector = TranscriptVersionSelector(recordingURL: recording)
        try Data("{}".utf8).write(to: root.appendingPathComponent("raw/meeting.processing.json"))
        let manager = TranscriptReviewWindowManager()
        var rejectPersistence = true
        var calls = 0
        let window: NSWindow
        do {
            window = try manager.open(recordingURL: recording, title: "Synthetic") { id in
                calls += 1
                if rejectPersistence { throw Failure.persistence }
                try selector.persistSelectedResultID(id)
            }
        } catch {
            print("SEMANTIC RED: actual window opening failed: \(error)")
            throw error
        }
        let model = manager.model(for: recording)!
        let retainedSession = model.state.session!
        try check(window.isVisible && window.title == "Synthetic", "real NSWindow opens with title")
        try check(model.selectedResultID == "v2" && model.versions.count == 2, "validated picker pinned latest")
        let initialRows = model.rows.map(\.text)
        model.switchVersion(to: "v1")
        try check(model.selectedResultID == "v2" && model.rows.map(\.text) == initialRows && model.error != nil,
                  "failed persistence preserves old view and reports error")
        rejectPersistence = false
        model.switchVersion(to: "v1")
        try check(model.selectedResultID == "v1" && model.rows[0].text.contains("First") && model.error == nil,
                  "successful picker loads matching version after persistence")
        let persistedID = try selector.persistedSelectedResultID()
        try check(persistedID == "v1" && calls == 2, "selection persisted on disk")
        let repo = retainedSession.editsRepository
        try repo.acquireWriteLock()
        _ = try repo.loadEdits(resultID: "v1")
        _ = try repo.saveTurnOverride(resultID: "v1", turnID: model.rows[0].id,
                                    text: "Saved override", displayName: "Saved name")
        repo.releaseWriteLock()
        try version("v3", date: "2026-11-01T10:00:00Z", text: "Third")
        let repeated = try manager.open(recordingURL: root.appendingPathComponent("./meeting.m4a"), title: "Ignored") { _ in
            throw Failure.check("repeat replaced callback")
        }
        try check(repeated === window && manager.windows.count == 1 && model.selectedResultID == "v1",
                  "canonical repeat focuses existing pinned window")
        let legacyDir = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyURL = legacyDir.appendingPathComponent("old.m4a")
        try "Legacy text".write(to: legacyDir.appendingPathComponent("old.sources.transcript.txt"), atomically: true, encoding: .utf8)
        let legacy = try manager.open(recordingURL: legacyURL, title: "Legacy") { _ in throw Failure.persistence }
        let legacyModel = manager.model(for: legacyURL)!
        try check(legacyModel.state.isReadOnly && legacyModel.legacyText == "Legacy text" && legacyModel.versions.isEmpty && legacyModel.explanation != nil,
                  "legacy is explicitly read-only without version/edit/player controls")
        window.close()
        try check(model.state.isClosed && retainedSession.onPersistSelection == nil && manager.model(for: recording) == nil,
                  "closing real NSWindow cleans session callback and registry")
        try check(legacy.isVisible && !legacyModel.state.isClosed && manager.windows.count == 1, "other window unaffected")
        let reopened = try manager.open(recordingURL: recording, title: "Reopened") { try selector.persistSelectedResultID($0) }
        let reopenedModel = manager.model(for: recording)!
        try check(reopened !== window && reopenedModel.selectedResultID == "v1", "reopen uses persisted selection")
        try check(reopenedModel.rows[0].text == "Saved override" && reopenedModel.rows[0].name == "Saved name",
                  "saved overrides and stable row IDs displayed")
        try check(reopenedModel.rows.dropFirst().allSatisfy { $0.name.hasPrefix("Speaker ") }, "unassigned logical Speaker N")
        reopened.close()
        legacy.close()
        // Persisted unavailable selection must remain an explained fallback, not latest.
        try Data("{\"selectedResultID\":\"missing\"}".utf8).write(to: root.appendingPathComponent("raw/meeting.processing.json"))
        try "Safe fallback".write(to: root.appendingPathComponent("meeting.sources.transcript.txt"), atomically: true, encoding: .utf8)
        let unavailable = try manager.open(recordingURL: recording, title: "Unavailable") { _ in }
        let fallback = manager.model(for: recording)!
        try check(fallback.legacyText == "Safe fallback" && fallback.explanation?.contains("missing") == true && fallback.selectedResultID == nil,
                  "unavailable version explains error alongside safe TXT fallback")
        unavailable.close()
        try Data("invalid JSON".utf8).write(to: root.appendingPathComponent("raw/meeting.processing.json"))
        let corrupt = try manager.open(recordingURL: recording, title: "Corrupt") { _ in }
        try check(manager.model(for: recording)!.explanation != nil && manager.model(for: recording)!.legacyText == "Safe fallback",
                  "corrupt metadata is not masked by TXT fallback")
        corrupt.close()
        try check(manager.windows.isEmpty && manager.coordinator.openWindows.isEmpty, "all window lifecycle state removed")
        print("APPKIT HARNESS GREEN")
    }
}
