@preconcurrency import AVFoundation
import Foundation

/// Streaming file playback; never decodes the complete recording into memory.
/// Call stop() when its owning window/session closes.
@MainActor
public final class TranscriptAVPlayerTransport: TranscriptPlaybackTransport {
    public var onEvent: (@MainActor @Sendable (TranscriptPlaybackEvent) -> Void)?
    private let player = AVPlayer()
    private var generation: UInt64 = 0
    private var periodicObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeObservation: NSKeyValueObservation?
    private var endObserver: (any NSObjectProtocol)?
    private var failureObserver: (any NSObjectProtocol)?
    private var wantsPlay = false
    private var playbackEpoch: UInt64 = 0
    private var seekEpoch: UInt64 = 0
    private var isSeeking = false
    public var hasPeriodicObserver: Bool { periodicObserver != nil }
    public var timeControlStatus: AVPlayer.TimeControlStatus { player.timeControlStatus }
    public var currentPosition: Double { player.currentTime().seconds }

    public init() {}

    public func prepare(url: URL) async throws -> Double {
        stop()
        let ticket = generation
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        try Task.checkCancellation()
        guard generation == ticket, duration.isFinite, duration > 0 else { throw TransportError.notReady }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        // Readiness is bounded and cancellable; no indefinite continuation if an item is replaced.
        for _ in 0..<500 {
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            if item.status == .failed { throw TransportError.notReady }
            if item.status == .readyToPlay {
                installEvents(item: item, ticket: ticket)
                return duration
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TransportError.notReady
    }

    private func installEvents(item: AVPlayerItem, ticket: UInt64) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            guard failed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                self.pause()
                self.onEvent?(.failed)
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                self.refreshPeriodicObserver()
                self.onEvent?(.playing(playing && self.wantsPlay))
            }
        }
        installEndObserver(item: item, ticket: ticket)
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                self.pause()
                self.onEvent?(.failed)
            }
        }
    }

    private func installEndObserver(item: AVPlayerItem, ticket: UInt64) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let epoch = playbackEpoch
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket, self.playbackEpoch == epoch,
                      !self.isSeeking, let current = self.player.currentItem else { return }
                let duration = current.duration.seconds
                let position = self.player.currentTime().seconds
                guard duration.isFinite, position.isFinite, duration > 0,
                      position >= duration - 0.05 else { return }
                self.pause()
                self.onEvent?(.ended)
            }
        }
    }

    public func play() {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        playbackEpoch &+= 1
        installEndObserver(item: item, ticket: generation)
        wantsPlay = true
        player.play()
        refreshPeriodicObserver()
    }

    public func pause() {
        wantsPlay = false
        player.pause()
        removePeriodicObserver()
    }

    public func seek(to seconds: Double) async -> Bool {
        guard seconds.isFinite, seconds >= 0, let item = player.currentItem, item.status == .readyToPlay else { return false }
        let ticket = generation
        playbackEpoch &+= 1
        seekEpoch &+= 1
        let seekTicket = seekEpoch
        isSeeking = true
        installEndObserver(item: item, ticket: ticket)
        item.cancelPendingSeeks()
        let success = await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                continuation.resume(returning: finished)
            }
        }
        guard generation == ticket, seekEpoch == seekTicket else { return false }
        isSeeking = false
        return success
    }

    public func stop() {
        generation &+= 1
        playbackEpoch &+= 1
        isSeeking = false
        pause()
        statusObservation = nil
        timeObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
    }

    private func refreshPeriodicObserver() {
        guard wantsPlay, player.timeControlStatus == .playing else { removePeriodicObserver(); return }
        guard periodicObserver == nil else { return }
        let ticket = generation
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket, self.wantsPlay,
                      self.player.timeControlStatus == .playing, seconds.isFinite else { return }
                self.onEvent?(.position(seconds))
            }
        }
    }

    private func removePeriodicObserver() {
        if let periodicObserver { player.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
    }

    private enum TransportError: Error { case notReady }
}
