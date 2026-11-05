import Foundation
import MeetingCompanionCore

/// Result of stopping audio capture from hardware.
public struct AudioCaptureStopResult: Sendable {
    public let duration: TimeInterval
    public let outputURL: URL
    public let warnings: [String]
    public let stoppedCapture: (any StoppedCaptureProtocol)?

    public init(
        duration: TimeInterval,
        outputURL: URL,
        warnings: [String] = [],
        stoppedCapture: (any StoppedCaptureProtocol)? = nil
    ) {
        self.duration = duration
        self.outputURL = outputURL
        self.warnings = warnings
        self.stoppedCapture = stoppedCapture
    }
}

/// Abstract hardware capture controller protocol implemented by MeetingCompanionPlatform.
public protocol AudioCaptureControllerProtocol: Sendable {
    func startCapture() async throws
    func stopCapture() async throws -> AudioCaptureStopResult
    func setMicrophoneMuted(_ muted: Bool)
    func currentMicrophoneState() -> MicrophoneRecordingState
}

/// Snapshot of the active recording session.
public struct RecordingSessionSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting(outputURL: URL)
        case recording(outputURL: URL, startedAt: Date)
        case stopping(outputURL: URL)
        case cancelledShort(outputURL: URL)
        case failed(errorDescription: String)
    }

    public let phase: Phase
    public let meetingID: String?
    public let meetingSummary: String?
    public let sessionID: UUID?

    public init(phase: Phase, meetingID: String? = nil, meetingSummary: String? = nil, sessionID: UUID? = nil) {
        self.phase = phase
        self.meetingID = meetingID
        self.meetingSummary = meetingSummary
        self.sessionID = sessionID
    }
}

/// Result of stopping a recording session.
public struct RecordingSessionStopResult: Sendable {
    public let outputURL: URL
    public let duration: TimeInterval
    public let warnings: [String]
    public let wasCancelledShort: Bool
    public let stoppedCapture: (any StoppedCaptureProtocol)?

    public init(
        outputURL: URL,
        duration: TimeInterval,
        warnings: [String],
        wasCancelledShort: Bool,
        stoppedCapture: (any StoppedCaptureProtocol)? = nil
    ) {
        self.outputURL = outputURL
        self.duration = duration
        self.warnings = warnings
        self.wasCancelledShort = wasCancelledShort
        self.stoppedCapture = stoppedCapture
    }
}

/// Application service managing the active recording session lifecycle.
/// Strictly guards against reentrant concurrent start and stop invocations,
/// manages session state transitions, and notifies subscribers.
public actor RecordingSessionService {
    public enum ServiceError: LocalizedError, Equatable {
        case alreadyRecording
        case notRecording
        case captureFailed(String)
        case staleCommand
        case shortCancellationExpired

        public var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "Запись уже идёт."
            case .notRecording:
                return "Запись не запущена."
            case .captureFailed(let msg):
                return "Сбой захвата звука: \(msg)"
            case .staleCommand:
                return "Команда относится к другой или завершённой записи."
            case .shortCancellationExpired:
                return "Короткая отмена уже недоступна. Остановите запись с сохранением."
            }
        }
    }

    public struct Configuration: Sendable {
        public let outputURL: URL
        public let meetingID: String?
        public let meetingSummary: String?
        public let captureBackend: String
        public let microphoneDeviceUID: String?
        public let prompt: String?
        public let controller: AudioCaptureControllerProtocol

        public init(
            outputURL: URL,
            meetingID: String? = nil,
            meetingSummary: String? = nil,
            captureBackend: String = "coreAudioTap",
            microphoneDeviceUID: String? = nil,
            prompt: String? = nil,
            controller: AudioCaptureControllerProtocol
        ) {
            self.outputURL = outputURL
            self.meetingID = meetingID
            self.meetingSummary = meetingSummary
            self.captureBackend = captureBackend
            self.microphoneDeviceUID = microphoneDeviceUID
            self.prompt = prompt
            self.controller = controller
        }
    }

    private enum State {
        case idle
        case starting(outputURL: URL, controller: AudioCaptureControllerProtocol, meetingID: String?, meetingSummary: String?)
        case recording(outputURL: URL, startedAt: Date, controller: AudioCaptureControllerProtocol, meetingID: String?, meetingSummary: String?)
        case stopping(outputURL: URL, startedAt: Date, controller: AudioCaptureControllerProtocol, meetingID: String?, meetingSummary: String?)
    }

    private var observers: [UUID: AsyncStream<RecordingSessionSnapshot>.Continuation] = [:]
    public func observe() -> AsyncStream<RecordingSessionSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RecordingSessionSnapshot>.makeStream()
        observers[id] = continuation
        continuation.yield(currentSnapshot)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private var state: State = .idle
    private var workReservation: UUID?
    private var subscribers: [@Sendable (RecordingSessionSnapshot) -> Void] = []
    private let historyRepo: RecordingHistoryRepository

    public init(historyRepo: RecordingHistoryRepository = RecordingHistoryRepository()) {
        self.historyRepo = historyRepo
    }

    public var isRecording: Bool {
        switch state {
        case .recording:
            return true
        case .idle, .starting, .stopping:
            return false
        }
    }

    public var currentSnapshot: RecordingSessionSnapshot {
        switch state {
        case .idle:
            return RecordingSessionSnapshot(phase: .idle)
        case .starting(let url, _, let mID, let mSum):
            return RecordingSessionSnapshot(
                phase: .starting(outputURL: url),
                meetingID: mID,
                meetingSummary: mSum,
                sessionID: workReservation
            )
        case .recording(let url, let started, _, let mID, let mSum):
            return RecordingSessionSnapshot(
                phase: .recording(outputURL: url, startedAt: started),
                meetingID: mID,
                meetingSummary: mSum,
                sessionID: workReservation
            )
        case .stopping(let url, _, _, let mID, let mSum):
            return RecordingSessionSnapshot(
                phase: .stopping(outputURL: url),
                meetingID: mID,
                meetingSummary: mSum,
                sessionID: workReservation
            )
        }
    }

    /// Registers a state subscriber and delivers the current snapshot immediately.
    @discardableResult
    public func addSubscriber(
        _ subscriber: @escaping @Sendable (RecordingSessionSnapshot) -> Void
    ) -> RecordingSessionSnapshot {
        subscribers.append(subscriber)
        let snapshot = currentSnapshot
        subscriber(snapshot)
        return snapshot
    }

    private func notifySubscribers() {
        let snapshot = currentSnapshot
        for subscriber in subscribers { subscriber(snapshot) }
        for observer in observers.values { observer.yield(snapshot) }
    }

    /// Starts a recording session with the given controller and output URL.
    /// Atomically reserves starting state BEFORE any await to prevent reentrant double-start.
    public func start(
        controller: AudioCaptureControllerProtocol,
        outputURL: URL,
        meetingID: String? = nil,
        meetingSummary: String? = nil
    ) async throws -> RecordingSessionSnapshot {
        try RecordingPaths.requireStandardLayout(outputURL)
        guard case .idle = state else {
            throw ServiceError.alreadyRecording
        }

        let reservation = UUID()
        historyRepo.reserveWork(outputURL, id: reservation)
        workReservation = reservation
        // Reserve starting ownership before awaiting startCapture
        state = .starting(outputURL: outputURL, controller: controller, meetingID: meetingID, meetingSummary: meetingSummary)
        notifySubscribers()

        do {
            try await controller.startCapture()
            let startedAt = Date()
            state = .recording(
                outputURL: outputURL,
                startedAt: startedAt,
                controller: controller,
                meetingID: meetingID,
                meetingSummary: meetingSummary
            )
            notifySubscribers()

            let entry = RecordingEntry(
                recording: outputURL,
                date: startedAt,
                title: meetingSummary ?? outputURL.deletingPathExtension().lastPathComponent,
                phase: .recording
            )
            _ = historyRepo.put(entry)

            return currentSnapshot
        } catch {
            historyRepo.releaseWork(outputURL, id: reservation)
            workReservation = nil
            state = .idle
            notifySubscribers()
            throw ServiceError.captureFailed(error.localizedDescription)
        }
    }

    public func start(configuration: Configuration) async throws -> RecordingSessionSnapshot {
        try await start(
            controller: configuration.controller,
            outputURL: configuration.outputURL,
            meetingID: configuration.meetingID,
            meetingSummary: configuration.meetingSummary
        )
    }

    /// Controls microphone mute on the active capture controller.
    @discardableResult
    public func setMicrophoneMuted(_ muted: Bool, expectedSessionID: UUID? = nil) -> Bool {
        guard let expectedSessionID, expectedSessionID == workReservation else { return false }
        switch state {
        case .recording(_, _, let controller, _, _):
            controller.setMicrophoneMuted(muted)
            return true
        default:
            return false
        }
    }

    /// Queries current microphone recording state from the active capture controller.
    public func currentMicrophoneState() -> MicrophoneRecordingState {
        switch state {
        case .starting(_, let controller, _, _), .recording(_, _, let controller, _, _):
            return controller.currentMicrophoneState()
        default:
            return .receiving
        }
    }

    /// Stops the active recording session.
    /// Atomically reserves stopping state BEFORE any await to prevent reentrant double-stop.
    /// Only explicit short cancellation can discard files; ordinary stop always saves.
    public func stop(
        elapsed: TimeInterval? = nil,
        shortRecordingThreshold: TimeInterval = 10.0,
        expectedSessionID: UUID? = nil,
        cancelShort: Bool = false,
        trash: (@Sendable (URL) throws -> Void)? = nil
    ) async throws -> RecordingSessionStopResult {
        guard let expectedSessionID, expectedSessionID == workReservation else { throw ServiceError.staleCommand }
        guard case let .recording(outputURL, startedAt, controller, meetingID, meetingSummary) = state else {
            throw ServiceError.notRecording
        }
        if cancelShort, let elapsed, elapsed >= shortRecordingThreshold { throw ServiceError.shortCancellationExpired }

        // Reserve stopping ownership before awaiting stopCapture
        state = .stopping(
            outputURL: outputURL,
            startedAt: startedAt,
            controller: controller,
            meetingID: meetingID,
            meetingSummary: meetingSummary
        )
        notifySubscribers()

        defer {
            if let reservation = workReservation { historyRepo.releaseWork(outputURL, id: reservation) }
            workReservation = nil
            state = .idle
            notifySubscribers()
        }

        let captureResult: AudioCaptureStopResult
        do {
            captureResult = try await controller.stopCapture()
        } catch {
            _ = historyRepo.updateStatus(outputURL) {
                $0.phase = .failed
                $0.addProblem(.capture, error.localizedDescription, error: true)
            }
            throw error
        }
        let effectiveDuration = elapsed ?? captureResult.duration

        // Check short recording cancellation if duration is under threshold
        let wasCancelled: Bool
        if cancelShort && effectiveDuration < shortRecordingThreshold {
            wasCancelled = try historyRepo.cancelShortRecording(
                outputURL,
                duration: effectiveDuration,
                trash: trash
            )
        } else {
            wasCancelled = false
        }

        var warnings = captureResult.warnings
        if !wasCancelled {
            let result = historyRepo.updateStatus(outputURL) { entry in
                entry.duration = effectiveDuration
                entry.phase = captureResult.stoppedCapture == nil ? .interrupted : .saving
                entry.readArtifacts()
                for warning in captureResult.warnings { entry.addProblem(.capture, warning) }
            }
            if let warning = result.persistenceWarning { warnings.append(warning) }
        }
        return RecordingSessionStopResult(
            outputURL: captureResult.outputURL,
            duration: effectiveDuration,
            warnings: warnings,
            wasCancelledShort: wasCancelled,
            stoppedCapture: captureResult.stoppedCapture
        )
    }
}
