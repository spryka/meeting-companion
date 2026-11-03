import AppKit
import AVFoundation
import Foundation
import MeetingCompanionCore
import MeetingCompanionPlatform

@main struct PlayerWindowCheck {
    enum Failure: Error { case check(String), timeout(String), persistence }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure.check(message) }
            print("PASS: \(message)")
        }
        func wait(_ label: String, _ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<600 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure.timeout(label)
        }
        let fixture = URL(fileURLWithPath: "Tests/Fixtures/transcript-document/valid_parakeet_off.json")
        for (id, seconds, date) in [("v1", 4, "2026-10-30T10:00:00Z"), ("v2", 6, "2026-10-31T10:00:00Z")] {
            let dir = root.appendingPathComponent("raw/transcripts/\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
            do {
                let file = try AVAudioFile(forWriting: dir.appendingPathComponent("mix.wav"), settings: format.settings)
                for _ in 0..<seconds { try file.write(from: buffer) }
            }
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
            json["resultID"] = id; json["createdAt"] = date
            var turns = json["turns"] as! [[String: Any]]
            turns[1]["start"] = 0.5
            json["turns"] = turns
            json["playback"] = ["status": "ready", "mixPath": "raw/transcripts/\(id)/mix.wav"]
            try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("result.json"))
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent("raw/meeting.processing.json"))
        let recording = root.appendingPathComponent("meeting.m4a")
        let manager = TranscriptReviewWindowManager()
        let window = try await manager.open(recordingURL: recording, title: "Player synthetic")
        let model = manager.model(for: recording)!
        // Immediate assertion provides semantic RED for the compiled API skeleton.
        try check(model.playbackState == .loading, "window starts asynchronous player preparation")
        try await wait("ready") { model.playbackState == .ready }
        try check(window.isVisible && abs(model.playbackDuration - 6) < 0.05, "actual window ready with v2 clip duration")
        await model.seekPlayback(to: 0.75)
        try check(model.playbackState == .ready && abs(model.playbackPosition - 0.75) < 0.05, "paused seek stays paused")
        try check(model.activeTurnIDs == model.rows.map(\.id), "interval index highlights ALL overlapping stable rows")
        try check(model.follow.request == 0, "paused seek highlights without automatic jump")
        model.togglePlayback()
        try await wait("start") { model.playbackState == .playing && model.playbackPosition > 0.9 }
        try check(model.follow.targetID == model.rows.first?.id && model.follow.request > 0,
                  "playing follows first DISPLAY order overlap")
        model.userScrollPhaseChanged(.animating)
        model.userScrollPhaseChanged(.idle)
        try check(model.follow.isFollowing, "programmatic animation and idle do not suspend follow")
        model.userScrollPhaseChanged(.interacting)
        let manualRequest = model.follow.request
        model.togglePlayback()
        let paused = model.playbackPosition
        try await Task.sleep(for: .milliseconds(200))
        try check(model.playbackState == .ready && abs(model.playbackPosition - paused) < 0.05, "UI pause handler stops real head updates")
        await model.seekPlayback(to: 0.75)
        model.togglePlayback()
        try await wait("manual replay") { model.playbackState == .playing }
        try check(!model.follow.isFollowing && model.follow.request == manualRequest, "manual scroll remains suspended through pause seek play")
        model.returnToPlayback()
        try check(model.follow.isFollowing && model.follow.targetID == model.rows.first?.id && model.follow.request == manualRequest + 1,
                  "explicit return immediately targets current first overlap")
        model.beginEditing()
        try check(!model.follow.isFollowing, "editing hook suspends without providing editing UI")
        model.togglePlayback()
        let actualController = Mirror(reflecting: model).children.first { $0.label == "playback" }!.value as! TranscriptPlaybackController
        let actualTransport = Mirror(reflecting: actualController).children.first { $0.label == "transport" }!.value as! TranscriptAVPlayerTransport
        let actualPlayer = Mirror(reflecting: actualTransport).children.first { $0.label == "player" }!.value as! AVPlayer
        try check(!actualTransport.hasPeriodicObserver, "paused current result has zero periodic observers")
        let actualURL = (actualPlayer.currentItem!.asset as! AVURLAsset).url
        try check(actualURL.resolvingSymlinksInPath().standardizedFileURL == root.appendingPathComponent("raw/transcripts/v2/mix.wav").resolvingSymlinksInPath().standardizedFileURL, "actual AVPlayer asset URL matches current result")
        await model.seekPlayback(to: model.rows[0].start)
        try check(abs(model.playbackPosition - model.rows[0].start) < 0.05, "timestamp uses same global seek handler")
        model.togglePlayback()
        try await wait("replay") { model.playbackState == .playing }
        try check(actualTransport.hasPeriodicObserver, "actual playing owns periodic observer")
        model.togglePlayback()
        try check(!actualTransport.hasPeriodicObserver, "actual pause removes periodic observer immediately")
        model.togglePlayback()
        try await wait("repeat replay") { model.playbackState == .playing }
        window.close()
        let closedPosition = model.playbackPosition
        try await Task.sleep(for: .milliseconds(200))
        try check(model.playbackState == .closed && model.playbackPosition == closedPosition && model.state.isClosed,
                  "window close stops player and prevents callback publication")
        try check(actualPlayer.currentItem == nil && !actualTransport.hasPeriodicObserver && actualTransport.onEvent == nil,
                  "actual close releases item observer and callbacks")
        try check(model.follow.isClosed && model.follow.targetID == nil, "close clears follow target and ignores further return")
        let rapid = try await manager.open(recordingURL: recording, title: "Reopen")
        let rapidModel = manager.model(for: recording)!
        rapid.close()
        try await Task.sleep(for: .milliseconds(150))
        try check(rapidModel.playbackState == .closed && rapidModel.playbackDuration == 0, "close during preparation rejects late ready callback")
        // Missing current mix preserves all transcript rows and displays audio failure.
        try FileManager.default.removeItem(at: root.appendingPathComponent("raw/transcripts/v2/mix.wav"))
        let broken = try await manager.open(recordingURL: recording, title: "Missing mix")
        let brokenModel = manager.model(for: recording)!
        try await wait("failed") { brokenModel.playbackState == .failed }
        try check(!brokenModel.rows.isEmpty && !brokenModel.playbackEnabled, "missing mix preserves text with disabled player")
        broken.close()
        let legacyDir = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyURL = legacyDir.appendingPathComponent("old.m4a")
        try "Legacy text".write(to: legacyDir.appendingPathComponent("old.sources.transcript.txt"), atomically: true, encoding: .utf8)
        let legacy = try await manager.open(recordingURL: legacyURL, title: "Legacy")
        let legacyModel = manager.model(for: legacyURL)!
        try check(!legacyModel.playbackEnabled && legacyModel.legacyText == "Legacy text" && legacyModel.explanation != nil,
                  "legacy retains TXT and disabled audio")
        legacy.close()
        print("ACTUAL APPKIT PLAYER WINDOW GREEN")
    }
}
