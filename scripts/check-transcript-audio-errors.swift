import AppKit
import AVFoundation
import Foundation
import MeetingCompanionCore
import MeetingCompanionPlatform

@main struct AudioErrorsCheck {
    enum Failure: Error { case assertion(String), timeout }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let validClip = URL(fileURLWithPath: CommandLine.arguments[2])
        let fixture = URL(fileURLWithPath: "Tests/Fixtures/transcript-document/valid_parakeet_off.json")
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure.assertion(message) }
            print("PASS: \(message)")
        }
        func wait(_ test: @MainActor () -> Bool) async throws {
            for _ in 0..<600 { if test() { return }; try await Task.sleep(for: .milliseconds(20)) }
            throw Failure.timeout
        }
        func resources(_ model: TranscriptReviewWindowModel) -> (TranscriptPlaybackController, TranscriptAVPlayerTransport, AVPlayer) {
            let c = Mirror(reflecting: model).children.first { $0.label == "playback" }!.value as! TranscriptPlaybackController
            let t = Mirror(reflecting: c).children.first { $0.label == "transport" }!.value as! TranscriptAVPlayerTransport
            let p = Mirror(reflecting: t).children.first { $0.label == "player" }!.value as! AVPlayer
            return (c,t,p)
        }
        for scenario in ["missing", "corrupt", "unavailable", "runtime"] {
            let dir = root.appendingPathComponent(scenario).appendingPathComponent("meeting")
            let version = dir.appendingPathComponent("raw/transcripts/v1")
            try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
            json["resultID"] = "v1"
            json["playback"] = scenario == "unavailable" ? ["status": "unavailable", "mixPath": NSNull()] : ["status": "ready", "mixPath": "raw/transcripts/v1/mix.wav"]
            if scenario == "unavailable" { json["warnings"] = [["code": "playback_mix_failed", "sourceID": NSNull(), "message": "Mix unavailable"]] }
            try JSONSerialization.data(withJSONObject: json).write(to: version.appendingPathComponent("result.json"))
            if scenario == "corrupt" { try Data("corrupt media".utf8).write(to: version.appendingPathComponent("mix.wav")) }
            if scenario == "runtime" { try FileManager.default.copyItem(at: validClip, to: version.appendingPathComponent("mix.wav")) }
            // Valid alternatives deliberately exist but must never be selected.
            for path in ["meeting.m4a", "raw/host.wav", "raw/remote.wav", "raw/transcripts/other/mix.wav"] {
                let url = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: validClip, to: url)
            }
            // Current authority is directory creation order, never selectedResultID.
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: dir.appendingPathComponent("raw/transcripts/other").path)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: version.path)
            try Data("{\"selectedResultID\":\"v1\"}".utf8).write(to: dir.appendingPathComponent("raw/meeting.processing.json"))
            let edits = "{\"schemaVersion\":1,\"resultID\":\"v1\",\"revision\":1,\"overrides\":{\"turn_1\":{\"text\":\"Saved text\",\"displayName\":\"Saved name\"}}}"
            try edits.write(to: version.appendingPathComponent("edits.json"), atomically: true, encoding: .utf8)
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            let bytes = try Dictionary(uniqueKeysWithValues: files.map { ($0, try Data(contentsOf: $0)) })
            let manager = TranscriptReviewWindowManager()
            let recording = dir.appendingPathComponent("meeting.m4a")
            _ = try await manager.open(recordingURL: recording, title: "Audio error")
            let model = manager.model(for: recording)!
            var verifiedRuntimeURL: URL?
            if scenario == "runtime" {
                try await wait { model.playbackState == .ready }
                model.togglePlayback()
                try await wait { model.playbackState == .playing }
                let (_,transport,player) = resources(model)
                verifiedRuntimeURL = (player.currentItem!.asset as! AVURLAsset).url
                try check(verifiedRuntimeURL!.resolvingSymlinksInPath().standardizedFileURL == version.appendingPathComponent("mix.wav").resolvingSymlinksInPath().standardizedFileURL,
                          "runtime: exact selected asset before deletion")
                try FileManager.default.removeItem(at: version.appendingPathComponent("mix.wav"))
                // Deterministic actual AVPlayer notification boundary: OS can cache deleted audio.
                NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem!)
                try await wait { model.playbackState == .failed }
                try check(!transport.hasPeriodicObserver && player.rate == 0, "runtime native failure stops playback and observer")
            } else {
                try await wait { model.playbackState == .failed || model.playbackState == .unavailable }
            }
            try check(model.rows.first?.text == "Saved text" && model.rows.first?.name == "Saved name" && model.currentResultID == "v1" && !model.playbackEnabled,
                      "\(scenario): text overrides selection retained; controls disabled")
            let (_,transport,player) = resources(model)
            let itemURL = (player.currentItem?.asset as? AVURLAsset)?.url
            try check(player.currentItem == nil || itemURL == verifiedRuntimeURL, "\(scenario): no fallback item (exact selected version URL)")
            try check(!transport.hasPeriodicObserver, "\(scenario): error has zero periodic observer")
            // Existing behavior assertions precede new status-message semantic RED.
            try check(model.playbackMessage != nil && !model.playbackMessage!.contains(dir.path), "\(scenario): localized path-free audio message")
            if scenario == "unavailable" { try check(model.playbackMessage!.contains("не подготовлено"), "explicit unavailable distinguished from damaged media") }
            let oldMessage = model.playbackMessage
            manager.closeCurrent()
            transport.onEvent?(.position(100))
            try check(model.playbackState == .closed && model.playbackMessage == oldMessage, "\(scenario): close ignores late error callbacks")
            for (url,data) in bytes where !(scenario == "runtime" && url == version.appendingPathComponent("mix.wav")) {
                try check(try Data(contentsOf: url) == data, "unchanged " + url.lastPathComponent)
            }
        }
        print("AUDIO ERROR WINDOW GREEN")
    }
}
