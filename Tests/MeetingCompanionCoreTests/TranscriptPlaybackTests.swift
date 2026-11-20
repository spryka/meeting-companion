import Foundation
import Testing
@testable import MeetingCompanionCore

@MainActor private final class PlaybackFake: TranscriptPlaybackTransport {
    var onEvent: (@MainActor @Sendable (TranscriptPlaybackEvent) -> Void)?
    var urls: [URL] = []
    var seeks: [Double] = []
    var rates: [Float] = []
    var plays = 0
    var pauses = 0
    var stops = 0
    var duration: Double = 10
    var deferred = false
    var pending: [CheckedContinuation<Double, any Error>] = []
    var seekSuccess = true
    var deferSeek = false
    var pendingSeeks: [CheckedContinuation<Bool, Never>] = []
    func prepare(url: URL) async throws -> Double {
        urls.append(url)
        if deferred { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return duration
    }
    func play() { plays += 1 }
    func pause() { pauses += 1 }
    func stop() { stops += 1 }
    func seek(to seconds: Double) async -> Bool {
        seeks.append(seconds)
        if deferSeek { return await withCheckedContinuation { pendingSeeks.append($0) } }
        return seekSuccess
    }
    func setRate(_ rate: Float) { rates.append(rate) }
}

@Suite @MainActor final class TranscriptPlaybackTests {
    @Test func segmentStopsAtEndAndPauseResumesSameInterval() async throws {
        let root = try recording(), fake = PlaybackFake()
        let player = TranscriptPlaybackController(transport: fake)
        await player.select(resultID: "v1", recordingDirectory: root)
        await player.playSegment(start: 2, end: 4)
        #expect(fake.seeks == [2] && fake.plays == 1)
        fake.onEvent?(.playing(true))
        fake.onEvent?(.position(3))
        player.toggle()
        #expect(player.state == .ready)
        player.toggle(); fake.onEvent?(.playing(true))
        #expect(fake.plays == 2 && fake.seeks == [2])
        fake.onEvent?(.position(4.1))
        #expect(player.state == .ready && player.position == 4)
        fake.onEvent?(.position(5))
        #expect(fake.plays == 2) // No sequential playback.
    }

    @Test(arguments: ["cancel", "pause", "close", "switch", "select", "failure"])
    func segmentRejectsLateSeekAndFailedSeek(action: String) async throws {
        let root = try recording(), fake = PlaybackFake()
        let player = TranscriptPlaybackController(transport: fake)
        await player.select(resultID: "v1", recordingDirectory: root)
        fake.deferSeek = true
        let task = Task { await player.playSegment(start: 2, end: 4) }
        for _ in 0..<100 where fake.pendingSeeks.isEmpty { await Task.yield() }
        #expect(fake.plays == 0)
        switch action {
        case "close": player.close()
        case "pause": player.pause()
        case "select": await player.select(resultID: "v1", recordingDirectory: root)
        case "switch":
            fake.deferSeek = false
            await player.playSegment(start: 6, end: 8)
        case "failure": break
        default: player.cancelSegment()
        }
        try #require(!fake.pendingSeeks.isEmpty)
        fake.pendingSeeks.removeFirst().resume(returning: action != "failure")
        await task.value
        #expect(fake.plays == (action == "switch" ? 1 : 0))
        if action == "switch" { #expect(player.position == 6) }
    }

    @Test(arguments: [(0.0, 0.0), (-1.0, 1.0), (3.0, 2.0), (Double.nan, 4.0), (12.0, 15.0)])
    func invalidSegmentsNeverSeekOrPlay(interval: (Double, Double)) async throws {
        let root = try recording(), fake = PlaybackFake()
        let player = TranscriptPlaybackController(transport: fake)
        await player.select(resultID: "v1", recordingDirectory: root)
        await player.playSegment(start: interval.0, end: interval.1)
        #expect(fake.seeks.isEmpty && fake.plays == 0)
    }

    @Test func missingMixCannotPlaySegment() async throws {
        let root = try recording(mix: false), fake = PlaybackFake()
        let player = TranscriptPlaybackController(transport: fake)
        await player.select(resultID: "v1", recordingDirectory: root)
        await player.playSegment(start: 2, end: 4)
        #expect(fake.seeks.isEmpty && fake.plays == 0)
    }
    private var roots: [URL] = []
    deinit { for root in roots { try? FileManager.default.removeItem(at: root) } }

    private func recording(status: String = "ready", path: String = "raw/transcripts/v1/mix.m4a", mix: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Playback-" + UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw/transcripts/v1"), withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/transcript-document/valid_parakeet_off.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        json["resultID"] = "v1"
        json["playback"] = ["status": status, "mixPath": status == "ready" ? path as Any : NSNull()]
        if status != "ready" { json["warnings"] = [["code": "playback_mix_failed", "sourceID": NSNull(), "message": "No mix"]] }
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("raw/transcripts/v1/result.json"))
        if mix { try Data("synthetic".utf8).write(to: root.appendingPathComponent("raw/transcripts/v1/mix.m4a")) }
        return root
    }

    @Test func workspaceEightHourStreamingBoundaryUsesURLAndGlobalSeek() async throws {
        let root = try recording()
        let fake = PlaybackFake(); fake.duration = 28_800
        let player = TranscriptPlaybackController(transport: fake)
        await player.select(resultID: "v1", recordingDirectory: root)
        await player.seek(to: 28_799)
        #expect(fake.urls.count == 1 && fake.seeks == [28_799] && player.position == 28_799)
        player.play(); fake.onEvent?(.position(28_799.5))
        #expect(player.position == 28_799.5)
        player.close()
        #expect(fake.onEvent == nil)
        #expect(try Data(contentsOf: root.appendingPathComponent("raw/transcripts/v1/mix.m4a")) == Data("synthetic".utf8))
    }

    @Test func selectedReadyMixOnly() async throws {
        let root = try recording(); let fake = PlaybackFake(); let player = TranscriptPlaybackController(transport: fake)
        await player.select(resultID: "v1", recordingDirectory: root)
        #expect(player.state == .ready && player.resultID == "v1" && player.duration == 10)
        #expect(fake.urls == [root.appendingPathComponent("raw/transcripts/v1/mix.m4a")])
        #expect(fake.plays == 0)
    }
    @Test(arguments: ["buffered", "waiting", "seek-through-end"])
    func toggleCancelsRequestedPlaybackWithoutInferringEnd(scenario: String) async throws {
        let root = try recording(), fake = PlaybackFake()
        let player = TranscriptPlaybackController(transport: fake)
        await player.select(resultID: "v1", recordingDirectory: root)
        player.toggle()
        if scenario == "waiting" {
            fake.onEvent?(.playing(true)); fake.onEvent?(.playing(false))
        } else if scenario == "seek-through-end" {
            await player.seek(to: 10)
            player.setPlaybackRate(1.5)
            await player.seek(to: 8)
        }
        player.toggle()
        #expect(fake.plays == 1 && fake.pauses == 1 && player.state == .ready)
    }

    @Test(arguments: ["pause", "ended", "failed", "select", "close", "seek-failure"])
    func terminalPlaybackActionsReleaseToggleIntent(event: String) async throws {
        let root = try recording(), fake = PlaybackFake()
        let player = TranscriptPlaybackController(transport: fake)
        await player.select(resultID: "v1", recordingDirectory: root)
        player.toggle()
        switch event {
        case "pause": player.pause()
        case "ended": fake.onEvent?(.ended)
        case "failed": fake.onEvent?(.failed)
        case "close": player.close()
        case "seek-failure": fake.seekSuccess = false; await player.seek(to: 2)
        default: break
        }
        if event == "failed" || event == "seek-failure" || event == "select" {
            await player.select(resultID: "v1", recordingDirectory: root)
        }
        let pauses = fake.pauses
        player.toggle()
        #expect(fake.plays == (event == "close" ? 1 : 2) && fake.pauses == pauses)
    }
    @Test func unavailableNeverPreparesFallback() async throws {
        let root = try recording(status: "unavailable"); let fake = PlaybackFake(); let p = TranscriptPlaybackController(transport: fake)
        await p.select(resultID: "v1", recordingDirectory: root); p.play()
        #expect(p.state == .unavailable && fake.urls.isEmpty && fake.plays == 0)
    }
    @Test func missingMixAfterRetentionIsUnavailable() async throws {
        let root = try recording(mix: false)
        let marker = root.appendingPathComponent("raw").appendingPathComponent(RecordingPaths.audioRetentionMarker)
        try Data().write(to: marker)
        let fake = PlaybackFake()
        let player = TranscriptPlaybackController(transport: fake)
        await player.select(resultID: "v1", recordingDirectory: root)
        #expect(player.state == .unavailable && fake.urls.isEmpty)
    }

    @Test func missingNeverFallsBack() async throws {
        let root = try recording(mix: false); let fake = PlaybackFake(); let p = TranscriptPlaybackController(transport: fake)
        try Data("master".utf8).write(to: root.appendingPathComponent("meeting.m4a"))
        await p.select(resultID: "v1", recordingDirectory: root)
        #expect(p.state == .failed && fake.urls.isEmpty)
    }
    @Test func rejectsOtherVersionAndTraversal() async throws {
        for path in ["raw/transcripts/v2/mix.m4a", "../outside.m4a"] {
            let root = try recording(path: path); let f = PlaybackFake(); let p = TranscriptPlaybackController(transport: f)
            await p.select(resultID: "v1", recordingDirectory: root)
            #expect(p.state == .failed && f.urls.isEmpty)
        }
    }
    @Test func rejectsEscapingSymlinkAndInvalidID() async throws {
        let root = try recording(); let f = PlaybackFake(); let p = TranscriptPlaybackController(transport: f)
        let mix = root.appendingPathComponent("raw/transcripts/v1/mix.m4a")
        try FileManager.default.removeItem(at: mix)
        try FileManager.default.createSymbolicLink(at: mix, withDestinationURL: root.appendingPathComponent("meeting.m4a"))
        try Data("master".utf8).write(to: root.appendingPathComponent("meeting.m4a"))
        await p.select(resultID: "v1", recordingDirectory: root)
        #expect(p.state == .failed && f.urls.isEmpty)
        await p.select(resultID: "../v1", recordingDirectory: root)
        #expect(p.state == .failed && f.urls.isEmpty)
    }
    @Test func globalTimelinePlayPauseSeek() async throws {
        let root = try recording(); let f = PlaybackFake(); let p = TranscriptPlaybackController(transport: f)
        await p.select(resultID: "v1", recordingDirectory: root)
        p.play(); f.onEvent?(.playing(true)); f.onEvent?(.position(4.5))
        #expect(p.state == .playing && p.position == 4.5 && f.plays == 1)
        p.pause(); #expect(p.state == .ready && p.position == 4.5 && f.pauses == 1)
        await p.seek(to: 7.25); #expect(p.position == 7.25 && f.seeks == [7.25])
    }
    @Test func clampsSeeksRejectsNonfinite() async throws {
        let root = try recording(); let f = PlaybackFake(); let p = TranscriptPlaybackController(transport: f)
        await p.select(resultID: "v1", recordingDirectory: root)
        await p.seek(to: -2); await p.seek(to: 999); await p.seek(to: .nan); await p.seek(to: .infinity)
        #expect(f.seeks == [0, 10] && p.position == 10)
        f.onEvent?(.position(.nan)); #expect(p.position == 10)
    }
    @Test func invalidDurationAndFailedSeek() async throws {
        let root = try recording(); let f = PlaybackFake(); let p = TranscriptPlaybackController(transport: f)
        for duration in [Double.nan, .infinity, -1, 0] {
            f.duration = duration; await p.select(resultID: "v1", recordingDirectory: root)
            #expect(p.state == .failed && p.duration == 0)
        }
        f.duration = 10; await p.select(resultID: "v1", recordingDirectory: root)
        f.seekSuccess = false; await p.seek(to: 5)
        #expect(p.position == 0 && p.state == .failed)
    }
    @Test func stalePreparationAndEventsIgnored() async throws {
        let root = try recording(); let f = PlaybackFake(); f.deferred = true
        let p = TranscriptPlaybackController(transport: f)
        let first = Task { await p.select(resultID: "v1", recordingDirectory: root) }
        while f.pending.isEmpty { await Task.yield() }
        let oldEvent = f.onEvent
        await p.select(resultID: "missing", recordingDirectory: root)
        f.pending.removeFirst().resume(returning: 99); await first.value
        oldEvent?(.playing(true)); oldEvent?(.position(88)); oldEvent?(.failed)
        #expect(p.resultID == "missing" && p.state == .failed && p.duration == 0 && p.position == 0)
    }
    @Test func endedFailureCloseCleanup() async throws {
        let root = try recording(); let f = PlaybackFake(); let p = TranscriptPlaybackController(transport: f)
        await p.select(resultID: "v1", recordingDirectory: root)
        p.play(); f.onEvent?(.ended); #expect(p.state == .ready && p.position == 10)
        f.onEvent?(.failed); #expect(p.state == .failed)
        p.close(); #expect(p.state == .closed && f.onEvent == nil && f.stops > 0)
        let count = f.urls.count
        await p.select(resultID: "v1", recordingDirectory: root); p.play()
        #expect(p.state == .closed && f.urls.count == count)
    }
    @Test func closeDuringAsyncPreparationStaysClosed() async throws {
        let root = try recording(); let f = PlaybackFake(); f.deferred = true
        let p = TranscriptPlaybackController(transport: f)
        let task = Task { await p.select(resultID: "v1", recordingDirectory: root) }
        while f.pending.isEmpty { await Task.yield() }
        let oldEvent = f.onEvent
        p.close()
        f.pending.removeFirst().resume(returning: 10)
        await task.value
        oldEvent?(.playing(true))
        #expect(p.state == .closed && p.duration == 0 && f.onEvent == nil)
    }
    @Test func cancellationDoesNotPublishReady() async throws {
        let root = try recording(); let f = PlaybackFake(); f.deferred = true
        let p = TranscriptPlaybackController(transport: f)
        let task = Task { await p.select(resultID: "v1", recordingDirectory: root) }
        while f.pending.isEmpty { await Task.yield() }
        task.cancel()
        f.pending.removeFirst().resume(returning: 10)
        await task.value
        #expect(p.state == .failed && p.duration == 0 && f.onEvent == nil)
    }
    @Test func loadingCallbackClosesBeforePreparation() async throws {
        let root = try recording(); let f = PlaybackFake(); let p = TranscriptPlaybackController(transport: f)
        p.onChange = { [weak p] in if p?.state == .loading { p?.close() } }
        await p.select(resultID: "v1", recordingDirectory: root)
        #expect(p.state == .closed && f.urls.isEmpty && f.onEvent == nil)
    }
    @Test func loadingCallbackQueuesReselectionWithoutOldReady() async throws {
        let root = try recording(); let f = PlaybackFake(); let p = TranscriptPlaybackController(transport: f)
        var replacement: Task<Void, Never>?
        p.onChange = { [weak p] in
            guard let p, p.state == .loading, replacement == nil else { return }
            p.close()
            replacement = Task { await p.select(resultID: "missing", recordingDirectory: root) }
        }
        await p.select(resultID: "v1", recordingDirectory: root)
        await replacement?.value
        #expect(p.state == .closed && f.urls.isEmpty && f.onEvent == nil)
    }

    @Test func playbackRateForwardingAndClamping() async throws {
        let root = try recording(); let fake = PlaybackFake(); let player = TranscriptPlaybackController(transport: fake)
        await player.select(resultID: "v1", recordingDirectory: root)
        #expect(player.playbackRate == 1.0)
        player.setPlaybackRate(1.5)
        #expect(player.playbackRate == 1.5)
        #expect(fake.rates.contains(1.5))
        player.setPlaybackRate(-1.0)
        #expect(player.playbackRate == 1.5)
        player.setPlaybackRate(Float.nan)
        #expect(player.playbackRate == 1.5)
        player.setPlaybackRate(2.0)
        #expect(player.playbackRate == 2.0)
        #expect(fake.rates.last == 2.0)
    }
}
