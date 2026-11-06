import Foundation
import AppKit
import SwiftUI
import Testing
import MeetingCompanionCore
@testable import MeetingCompanionApp

@MainActor private final class CalendarContextTransport: TranscriptPlaybackTransport {
    var onEvent: (@MainActor @Sendable (TranscriptPlaybackEvent) -> Void)?
    func prepare(url: URL) async throws -> Double { 1 }
    func play() {}
    func pause() {}
    func seek(to seconds: Double) async -> Bool { true }
    func stop() {}
    func setRate(_ rate: Float) {}
}

@Suite @MainActor struct CalendarContextRegressionTests {
    private func fixture(context: [String: Any]? = nil) throws -> (root: URL, recording: URL, result: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("meeting")
        let result = root.appendingPathComponent("raw/transcripts/res_valid_empty_voices/result.json")
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_empty_voices.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        json["context"] = context.map { $0 as Any } ?? NSNull()
        try JSONSerialization.data(withJSONObject: json).write(to: result)
        return (root, root.appendingPathComponent("meeting.m4a"), result)
    }

    private func saveMeeting(_ recording: URL, attendees: [String] = ["Алиса Иванова", "Борис Петров"]) throws {
        try MeetingContext(id: "synthetic", calendar: "Test", summary: "CX (CC) Standup",
            start: Date(timeIntervalSince1970: 1793953800), end: Date(timeIntervalSince1970: 1793955600),
            agenda: "Планы команды", attendees: attendees).save(beside: recording)
    }

    @Test(arguments: [false, true])
    func processedRecordingUsesSavedCalendarWithoutRewritingResult(emptyAttendees: Bool) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let attendees = emptyAttendees ? [] : ["Алиса Иванова", "Борис Петров"]
        try saveMeeting(f.recording, attendees: attendees)
        let original = try Data(contentsOf: f.result)
        let sidecar = f.root.appendingPathComponent("meeting.context.json")
        let originalContext = try Data(contentsOf: sidecar)
        let editsURL = f.result.deletingLastPathComponent().appendingPathComponent("edits.json")
        let edits = try JSONEncoder().encode(TranscriptEdits(resultID: "res_valid_empty_voices", revision: 1,
            overrides: ["turn_1": .init(text: "Сохранённая правка", displayName: "Ручное имя")]))
        try edits.write(to: editsURL)
        let manager = TranscriptReviewWindowManager(transportFactory: { CalendarContextTransport() })
        defer { manager.closeCurrent() }
        let model = try await manager.open(recordingURL: f.recording, title: "Standup")
        #expect(model.calendarAttendees == attendees)
        #expect(model.contextAttendees == (emptyAttendees ? nil : attendees))
        #expect(model.rows.first?.text == "Сохранённая правка")
        #expect(model.rows.first?.name == "Ручное имя")
        model.openSpeakerAssignment(for: "turn_1")
        #expect(model.activeDraft?.calendarAttendees == attendees)
        model.cancelDraft()
        let document = try TranscriptDocument.load(from: f.result, recordingDirectory: f.root)
        #expect(document.context?.title == "CX (CC) Standup")
        #expect(document.context?.agenda == "Планы команды")
        let export = try TranscriptExportFormatter().format(document: document,
            edits: TranscriptEdits(resultID: document.resultID, revision: 0, overrides: [:]))
        #expect(export.contains("CX (CC) Standup"))
        if !emptyAttendees { #expect(export.contains("Приглашены: Алиса Иванова, Борис Петров")) }
        #expect(try Data(contentsOf: f.result) == original)
        #expect(try Data(contentsOf: sidecar) == originalContext)
        #expect(try Data(contentsOf: editsURL) == edits)
    }

    @Test func embeddedSnapshotRemainsAuthoritative() async throws {
        let f = try fixture(context: ["title": "Snapshot", "attendees": ["Из результата"]])
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        try saveMeeting(f.recording)
        let document = try TranscriptDocument.load(from: f.result, recordingDirectory: f.root)
        #expect(document.context?.title == "Snapshot")
        #expect(document.context?.attendees == ["Из результата"])
    }

    @Test(arguments: ["missing", "malformed", "invalid-date", "outside-symlink"])
    func unavailableCalendarKeepsTranscriptReadable(kind: String) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let sidecar = f.root.appendingPathComponent("meeting.context.json")
        if kind == "malformed" { try Data("{".utf8).write(to: sidecar) }
        if kind == "invalid-date" { try Data(#"{"summary":"Standup","start":"not-a-date","attendees":["Алиса"]}"#.utf8).write(to: sidecar) }
        if kind == "outside-symlink" {
            let outside = f.root.deletingLastPathComponent().appendingPathComponent("outside.json")
            try Data(#"{"summary":"Private","start":"2026-11-06T08:30:00Z","attendees":["Outside"]}"#.utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
        }
        let document = try TranscriptDocument.load(from: f.result, recordingDirectory: f.root)
        #expect(!document.turns.isEmpty)
        #expect(document.context == nil)
        #expect(document.warnings.contains { $0.code == "context_warning" } == (kind != "missing"))
    }

    @Test func nativeCalendarSpeakerForm() async throws {
        guard let destination = ProcessInfo.processInfo.environment["MC_CONTEXT_UI_ROOT"] else { return }
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.regular)
        var windows: [NSWindow] = []
        var managers: [TranscriptReviewWindowManager] = []
        var roots: [URL] = []
        defer {
            for window in windows { window.orderOut(nil); window.close() }
            for manager in managers { manager.closeCurrent() }
            for root in roots { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        }
        for (index, name) in ["old", "new"].enumerated() {
            let f = try fixture(context: name == "new" ? ["title": "CX (CC) Standup", "attendees": ["Алиса Иванова", "Борис Петров"]] : nil)
            roots.append(f.root)
            if name == "old" { try saveMeeting(f.recording) }
            let manager = TranscriptReviewWindowManager(transportFactory: { CalendarContextTransport() })
            managers.append(manager)
            let model = try await manager.open(recordingURL: f.recording, title: "Standup")
            model.openSpeakerAssignment(for: "turn_1")
            #expect(model.activeDraft?.calendarAttendees == ["Алиса Иванова", "Борис Петров"])
            let window = NSWindow(contentRect: NSRect(x: 80 + index * 630, y: 150, width: 600, height: 740),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Calendar context — " + name
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: TranscriptReviewWindowView(model: model, title: "Standup").editingSheet)
            window.contentView = host
            window.orderFront(nil)
            windows.append(window)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
            "executable": ProcessInfo.processInfo.arguments[0], "bundleID": Bundle.main.bundleIdentifier ?? ""])
            .write(to: output.appendingPathComponent("host.json"))
        if ProcessInfo.processInfo.environment["MC_CONTEXT_UI_HOLD"] == "1" {
            for _ in 0..<3000 {
                if FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
