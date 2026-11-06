import Foundation

public enum TranscriptPlaybackEvent: Sendable {
    case position(Double)
    case playing(Bool)
    case ended
    case failed
}

@MainActor
public protocol TranscriptPlaybackTransport: AnyObject {
    var onEvent: (@MainActor @Sendable (TranscriptPlaybackEvent) -> Void)? { get set }
    func prepare(url: URL) async throws -> Double
    func play()
    func pause()
    func seek(to seconds: Double) async -> Bool
    func stop()
    func setRate(_ rate: Float)
}

public extension TranscriptPlaybackTransport {
    func setRate(_ rate: Float) {}
}

@MainActor
public final class TranscriptPlaybackController {
    public enum State: Equatable, Sendable { case idle, loading, ready, playing, unavailable, failed, closed }
    public private(set) var state: State = .idle
    public private(set) var resultID: String?
    public private(set) var mixURL: URL?
    public private(set) var duration: Double = 0
    public private(set) var position: Double = 0
    public private(set) var playbackRate: Float = 1.0
    public var onChange: (@MainActor () -> Void)?
    private let transport: any TranscriptPlaybackTransport
    private var generation: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var wantsPlay = false

    public init(transport: any TranscriptPlaybackTransport) { self.transport = transport }

    public func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        playbackRate = rate
        transport.setRate(rate)
        onChange?()
    }

    public func select(resultID: String, recordingDirectory: URL) async {
        guard state != .closed else { return }
        generation &+= 1
        let ticket = generation
        wantsPlay = false
        transport.onEvent = nil
        transport.stop()
        self.resultID = resultID
        self.mixURL = nil
        duration = 0
        position = 0
        state = .loading
        onChange?()
        guard generation == ticket, state != .closed else { return }
        do {
            guard !resultID.isEmpty, !resultID.contains("/"), resultID != ".", resultID != "..", !resultID.contains("\0") else {
                throw PlaybackError.invalidMix
            }
            let root = recordingDirectory.resolvingSymlinksInPath().standardizedFileURL
            let version = root.appendingPathComponent("raw/transcripts/\(resultID)")
            let resolvedVersion = Self.resolve("raw/transcripts/\(resultID)", in: root)
            // Reject redirected version directories, even when their destination stays in the recording.
            guard resolvedVersion == version.standardizedFileURL else { throw PlaybackError.invalidMix }
            let document = try TranscriptDocument.load(from: version.appendingPathComponent("result.json"), recordingDirectory: root)
            guard document.resultID == resultID else { throw PlaybackError.invalidMix }
            guard document.playback.status == .ready, let path = document.playback.mixPath else {
                state = .unavailable
                onChange?()
                return
            }
            let mix = Self.resolve(path, in: root)
            guard mix.pathComponents.count > version.pathComponents.count,
                  mix.pathComponents.starts(with: version.pathComponents),
                  FileManager.default.isReadableFile(atPath: mix.path),
                  (try mix.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw PlaybackError.invalidMix
            }
            guard generation == ticket, state != .closed else { return }
            self.mixURL = mix
            transport.onEvent = { [weak self] event in
                guard let self, self.generation == ticket, self.state != .closed else { return }
                self.receive(event)
            }
            let loadedDuration = try await transport.prepare(url: mix)
            guard generation == ticket, state != .closed else { return }
            try Task.checkCancellation()
            guard loadedDuration.isFinite, loadedDuration > 0 else { throw PlaybackError.invalidDuration }
            duration = loadedDuration
            transport.setRate(playbackRate)
            state = .ready
            onChange?()
        } catch {
            guard generation == ticket, state != .closed else { return }
            transport.onEvent = nil
            transport.stop()
            self.mixURL = nil
            state = .failed
            onChange?()
        }
    }

    public func toggle() {
        if wantsPlay || state == .playing { pause() }
        else { play() }
    }

    public func play() {
        guard state == .ready else { return }
        wantsPlay = true
        transport.setRate(playbackRate)
        transport.play()
    }

    public func pause() {
        wantsPlay = false
        guard state == .playing || state == .ready else { return }
        transport.pause()
        state = .ready
        onChange?()
    }

    public func seek(to seconds: Double) async {
        guard seconds.isFinite, state == .ready || state == .playing else { return }
        let target = min(duration, max(0, seconds))
        let ticket = generation
        seekGeneration &+= 1
        let seekTicket = seekGeneration
        let success = await transport.seek(to: target)
        guard generation == ticket, seekGeneration == seekTicket, state == .ready || state == .playing else { return }
        if success { position = target }
        else { wantsPlay = false; transport.pause(); state = .failed }
        onChange?()
    }

    public func close() {
        guard state != .closed else { return }
        generation &+= 1
        wantsPlay = false
        transport.onEvent = nil
        transport.stop()
        mixURL = nil
        state = .closed
        onChange = nil
    }

    private func receive(_ event: TranscriptPlaybackEvent) {
        guard state == .ready || state == .playing else { return }
        switch event {
        case .position(let seconds):
            guard seconds.isFinite else { return }
            position = min(duration, max(0, seconds))
        case .playing(let playing): state = playing ? .playing : .ready
        case .ended: wantsPlay = false; transport.pause(); position = duration; state = .ready
        case .failed: wantsPlay = false; transport.pause(); state = .failed
        }
        onChange?()
    }

    private static func resolve(_ path: String, in root: URL) -> URL {
        path.split(separator: "/").reduce(root) { partial, component in
            partial.appendingPathComponent(String(component)).resolvingSymlinksInPath().standardizedFileURL
        }
    }

    private enum PlaybackError: Error { case invalidMix, invalidDuration }
}
