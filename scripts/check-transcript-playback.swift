// Compile with TranscriptPlaybackController, TranscriptAVPlayerTransport and
// TranscriptDocument sources. Synthetic silence only; no installed application.
import AppKit
import AVFoundation
import Foundation

@main struct TranscriptPlaybackCheck {
    enum Failure: Error { case timeout(String), assertion(String) }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("synthetic.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<4 { try file.write(from: buffer) }
        }
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw Failure.assertion(name) }
            print("PASS: \(name)")
        }
        func bounded(_ name: String, _ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<250 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure.timeout(name)
        }
        let adapter = TranscriptAVPlayerTransport()
        var positions: [Double] = []
        var failed = false
        var ended = false
        adapter.onEvent = { event in
            switch event {
            case .position(let time): positions.append(time)
            case .failed: failed = true
            case .ended: ended = true
            default: break
            }
        }
        let duration = try await adapter.prepare(url: url)
        try check(abs(duration - 4) < 0.05, "real synthetic WAV ready duration")
        try check(!adapter.hasPeriodicObserver, "no observer before playing")
        adapter.play()
        try await bounded("AVPlayer start/head advancement") { adapter.timeControlStatus == .playing && adapter.currentPosition > 0.15 }
        try check(adapter.hasPeriodicObserver && !failed, "actual AVPlayer starts and advances global head")
        adapter.pause()
        let paused = adapter.currentPosition
        try await Task.sleep(for: .milliseconds(150))
        try check(!adapter.hasPeriodicObserver && abs(adapter.currentPosition - paused) < 0.05, "pause stable head and observer removed")
        let seeked = await adapter.seek(to: 2)
        try check(seeked && abs(adapter.currentPosition - 2) < 0.05, "real seek retains global timeline")
        let actualPlayer = Mirror(reflecting: adapter).children.first { $0.label == "player" }!.value as! AVPlayer
        let actualItem = actualPlayer.currentItem!
        // Deterministic queued same-item framework notification for the old playback head.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: actualItem)
        let backward = Task { await adapter.seek(to: 1) }
        adapter.play()
        _ = await backward.value
        try await Task.sleep(for: .milliseconds(150))
        try check(!ended && adapter.timeControlStatus == .playing && adapter.currentPosition < 2,
                  "queued old-head ended during seek does not pause replay")
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: actualItem)
        try await Task.sleep(for: .milliseconds(100))
        try check(!ended && adapter.timeControlStatus == .playing && adapter.currentPosition < 2,
                  "delayed ended after completed backward seek does not pause replay")
        adapter.play()
        try await bounded("end event") { ended || failed }
        try check(ended && !failed && !adapter.hasPeriodicObserver, "real end event stops periodic observer")
        try check(!positions.isEmpty, "periodic position events delivered only during playback")
        adapter.stop()
        try check(!adapter.hasPeriodicObserver, "stop cleanup")
        let invalid = root.appendingPathComponent("corrupt.m4a")
        try Data("not audio".utf8).write(to: invalid)
        do {
            _ = try await adapter.prepare(url: invalid)
            throw Failure.assertion("corrupt media unexpectedly ready")
        } catch is Failure { throw Failure.assertion("corrupt media unexpectedly ready") }
        catch { print("PASS: corrupt media readiness fails") }
        adapter.stop()
        adapter.onEvent = nil
        let version = root.appendingPathComponent("raw/transcripts/v1")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: "transcription/fixtures/transcript-document/valid_parakeet_off.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        json["resultID"] = "v1"
        json["playback"] = ["status": "ready", "mixPath": "raw/transcripts/v1/mix.wav"]
        try JSONSerialization.data(withJSONObject: json).write(to: version.appendingPathComponent("result.json"))
        try FileManager.default.copyItem(at: url, to: version.appendingPathComponent("mix.wav"))
        let closingAdapter = TranscriptAVPlayerTransport()
        let closingController = TranscriptPlaybackController(transport: closingAdapter)
        closingController.onChange = { [weak closingController] in
            if closingController?.state == .loading { closingController?.close() }
        }
        await closingController.select(resultID: "v1", recordingDirectory: root)
        let closingPlayer = Mirror(reflecting: closingAdapter).children.first { $0.label == "player" }!.value as! AVPlayer
        try check(closingController.state == .closed && closingPlayer.currentItem == nil && closingAdapter.onEvent == nil && !closingAdapter.hasPeriodicObserver,
                  "reentrant loading close leaves no actual item callback or observer")
        print("REAL AVPLAYER SMOKE GREEN (silent synthetic media, no audible-quality claim)")
    }
}
