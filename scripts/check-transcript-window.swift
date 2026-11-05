// Compile with Core/Platform modules and TranscriptReviewWindow.swift.
// Does not launch the installed app or use audio.
import AppKit
import Foundation
import MeetingCompanionCore
import MeetingCompanionPlatform

@main struct TranscriptWindowCheck {
    enum Failure: Error { case check(String), persistence }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("meeting")
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
        try Data("{\"selectedResultID\":\"v1\"}".utf8).write(to: root.appendingPathComponent("raw/meeting.processing.json"))
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: root.appendingPathComponent("raw/transcripts/v1").path)
        let manager = TranscriptReviewWindowManager()
        let window = try await manager.open(recordingURL: recording, title: "Synthetic")
        let model = manager.model(for: recording)!
        let retainedSession = model.state.session!
        try check(manager.current === window, "one embedded current model opens")
        try check(model.currentResultID == "v2", "current ignores old selection")
        model.openTextEditing(for: model.rows[0].id)
        model.updateDraftText("Saved override")
        model.saveTextEditing()
        model.openSpeakerAssignment(for: model.rows[0].id)
        model.updateDraftName("Saved name")
        model.saveSpeakerAssignment()
        let repeated = try await manager.open(recordingURL: root.appendingPathComponent("./meeting.m4a"), title: "Ignored")
        try check(repeated === window && manager.coordinator.openWindows.count == 1, "canonical repeat focuses existing window")
        manager.closeCurrent()
        try check(model.state.isClosed && retainedSession.isClosed && manager.model(for: recording) == nil,
                  "closing window invalidates session and registry")
        _ = try await manager.open(recordingURL: recording, title: "Reopened")
        let reopenedModel = manager.model(for: recording)!
        try check(reopenedModel.currentResultID == "v2" && reopenedModel.rows[0].text == "Saved override" && reopenedModel.rows[0].name == "Saved name", "reopen retains current corrections")
        manager.closeCurrent()
        try version("v3", date: "2000-01-01T00:00:00Z", text: "Third")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: root.appendingPathComponent("raw/transcripts/v2").path)
        try Data("{broken".utf8).write(to: root.appendingPathComponent("raw/transcripts/v3/result.json"))
        try "Saved text".write(to: root.appendingPathComponent("meeting.sources.transcript.txt"), atomically: true, encoding: .utf8)
        _ = try await manager.open(recordingURL: recording, title: "Unavailable")
        let readOnly = manager.model(for: recording)!
        try check(readOnly.state.isReadOnly && readOnly.currentResultID == nil && readOnly.legacyText == "Saved text" && readOnly.explanation != nil, "corrupt newest has contained saved text without older fallback")
        try check(!readOnly.canExport && !readOnly.playbackEnabled, "saved compatibility text is read-only")
        manager.closeCurrent()
        try check(manager.current == nil && manager.coordinator.openWindows.isEmpty, "all window state removed")
        print("EMBEDDED CURRENT WORKSPACE HARNESS GREEN")
    }
}
