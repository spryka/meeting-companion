import Foundation
import MeetingCompanionCore

/// Captured settings snapshot at the moment of recording or enqueueing.
public struct ProcessingJobSettings: Equatable, Sendable {
    public let parakeet: Bool
    public let echoCancellation: Bool

    public init(parakeet: Bool, echoCancellation: Bool) {
        self.parakeet = parakeet
        self.echoCancellation = echoCancellation
    }
}

/// A discrete unit of work in the transcription pipeline queue.
public struct ProcessingJob: Identifiable, Sendable {
    public let id: UUID
    public let recordingURL: URL
    public let settings: ProcessingJobSettings
    public let enqueuedAt: Date
    public let stoppedCapture: (any StoppedCaptureProtocol)?

    public init(
        id: UUID = UUID(),
        recordingURL: URL,
        settings: ProcessingJobSettings,
        enqueuedAt: Date = Date(),
        stoppedCapture: (any StoppedCaptureProtocol)? = nil
    ) {
        self.id = id
        self.recordingURL = recordingURL
        self.settings = settings
        self.enqueuedAt = enqueuedAt
        self.stoppedCapture = stoppedCapture
    }
}

/// Abstract runner interface for transcribing a recording.
public protocol TranscriptionRunnerProtocol: Sendable {
    func checkDependencies(availability: Bool, parakeet: Bool) async throws -> Bool
    func checkDependenciesWithOutput(
        prepare: Bool,
        availability: Bool,
        parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> (output: String, succeeded: Bool)
    func run(
        recording: URL,
        parakeet: Bool,
        echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> URL
}

public extension TranscriptionRunnerProtocol {
    func checkDependencies(availability: Bool, parakeet: Bool) async throws -> Bool {
        try await checkDependenciesWithOutput(
            prepare: false,
            availability: availability,
            parakeet: parakeet,
            onOutput: nil
        ).succeeded
    }
}

/// Abstract audio exporter interface.
public protocol AudioExporterProtocol: Sendable {
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws
}

/// Application service managing the single serial processing queue and job execution off MainActor.
public actor ProcessingService {
    public enum Event: Sendable {
        case enqueued(ProcessingJob)
        case started(ProcessingJob)
        case progress(ProcessingJob, TranscriptionProgress)
        case completed(ProcessingJob, transcriptURL: URL, persistenceWarning: String? = nil)
        case failed(ProcessingJob, errorDescription: String, persistenceWarning: String? = nil)
        case cancelled(ProcessingJob, persistenceWarning: String? = nil)
        case persistenceWarning(ProcessingJob, String)
        case dependenciesChecked(output: String, succeeded: Bool)
    }

    public enum PreparationState: Equatable, Sendable {
        case idle
        case preparing
        case checking
    }

    public struct Snapshot: Sendable {
        public let active: ProcessingJob?
        public let queued: [ProcessingJob]
        public let admitting: [ProcessingJob]
        public let preparation: PreparationState
        public let progress: [URL: TranscriptionProgress]
        public var jobCount: Int { queued.count + admitting.count + (active == nil ? 0 : 1) }

        public init(
            active: ProcessingJob?,
            queued: [ProcessingJob],
            admitting: [ProcessingJob] = [],
            preparation: PreparationState,
            progress: [URL: TranscriptionProgress]
        ) {
            self.active = active
            self.queued = queued
            self.admitting = admitting
            self.preparation = preparation
            self.progress = progress
        }
    }

    public enum Update: Sendable {
        case snapshot(Snapshot)
        case event(Event)
    }

    private var observers: [UUID: AsyncStream<Update>.Continuation] = [:]
    private var progress: [URL: TranscriptionProgress] = [:]

    public func observe() -> AsyncStream<Update> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        observers[id] = continuation
        continuation.yield(.snapshot(presentationSnapshot))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private var presentationSnapshot: Snapshot {
        Snapshot(
            active: activeJob,
            queued: queue,
            admitting: Array(admitting.values),
            preparation: preparationState,
            progress: progress
        )
    }

    private func publishSnapshot() {
        let snapshot = presentationSnapshot
        for observer in observers.values { observer.yield(.snapshot(snapshot)) }
    }

    private var admitting: [URL: ProcessingJob] = [:]
    private let retryAdmission: (@Sendable (URL) async -> Bool)?
    private var queue: [ProcessingJob] = []
    private var activeJob: ProcessingJob?
    private var activeTask: Task<Void, Never>?
    private var cancelledJobIDs: Set<UUID> = []
    private var preparationState: PreparationState = .idle
    private var preparationID: UUID?
    private var preparationTask: Task<(output: String, succeeded: Bool), Error>?
    private let transcriptionRunner: TranscriptionRunnerProtocol
    private let audioExporter: AudioExporterProtocol
    private let historyRepository: RecordingHistoryRepository?
    private var eventHandlers: [@Sendable (Event) -> Void] = []

    public init(
        transcriptionRunner: TranscriptionRunnerProtocol,
        audioExporter: AudioExporterProtocol,
        historyRepository: RecordingHistoryRepository? = nil,
        retryAdmission: (@Sendable (URL) async -> Bool)? = nil
    ) {
        self.transcriptionRunner = transcriptionRunner
        self.audioExporter = audioExporter
        self.historyRepository = historyRepository
        self.retryAdmission = retryAdmission
    }

    /// Registers an event handler and immediately delivers the current state if a job is active.
    public func addEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        eventHandlers.append(handler)
        if let active = activeJob {
            handler(.started(active))
        }
    }

    public func currentSnapshot() -> (active: ProcessingJob?, queued: [ProcessingJob]) {
        (activeJob, queue + Array(admitting.values))
    }

    public var currentPreparationState: PreparationState {
        preparationState
    }

    private func emit(_ event: Event) {
        for handler in eventHandlers { handler(event) }
        for observer in observers.values { observer.yield(.event(event)) }
        publishSnapshot()
    }

    /// Enqueue a recording with captured snapshot settings. Returns the enqueued ProcessingJob.
    @discardableResult
    public func enqueue(
        recordingURL: URL,
        settings: ProcessingJobSettings,
        stoppedCapture: (any StoppedCaptureProtocol)? = nil
    ) async -> ProcessingJob {
        let canonical = RecordingEntry.canonicalURL(recordingURL)
        guard RecordingPaths.isStandardLayout(canonical) else {
            let job = ProcessingJob(recordingURL: canonical, settings: settings, stoppedCapture: stoppedCapture)
            emit(.failed(job, errorDescription: RecordingPaths.unsupportedLayoutMessage))
            return job
        }
        if let existing = admitting[canonical] ?? queue.first(where: { $0.recordingURL == canonical }) ?? (activeJob?.recordingURL == canonical ? activeJob : nil) {
            return existing
        }
        let job = ProcessingJob(recordingURL: canonical, settings: settings, stoppedCapture: stoppedCapture)
        historyRepository?.reserveWork(canonical, id: job.id)
        var enqueued = false
        defer { if !enqueued { historyRepository?.releaseWork(canonical, id: job.id) } }
        if stoppedCapture == nil, let retryAdmission {
            admitting[canonical] = job
            publishSnapshot()
            let accepted = await retryAdmission(canonical)
            admitting.removeValue(forKey: canonical)
            let cancelled = cancelledJobIDs.remove(job.id) != nil
            guard accepted, !cancelled else {
                emit(.cancelled(job))
                drainNextIfNeeded()
                return job
            }
        }
        if let historyRepository {
            let cached = historyRepository.entry(recordingURL)
            let existingEntry = cached ?? RecordingEntry.load(recording: recordingURL)
            if stoppedCapture == nil && !existingEntry.capabilities.canRetry {
                let job = ProcessingJob(
                    recordingURL: recordingURL,
                    settings: settings,
                    stoppedCapture: stoppedCapture
                )
                emit(.enqueued(job))
                emit(.failed(job, errorDescription: existingEntry.capabilities.reason ?? "Исходные WAV отсутствуют или недоступны; повторная обработка невозможна."))
                return job
            }
            if cached == nil { historyRepository.put(existingEntry, persist: false) }
        }
        queue.append(job)
        enqueued = true
        if let historyRepository {
            let result = historyRepository.updateStatus(recordingURL) { $0.phase = .queued }
            if let warning = result.persistenceWarning { emit(.persistenceWarning(job, warning)) }
        }
        emit(.enqueued(job))
        drainNextIfNeeded()
        return job
    }

    public func isProcessing(recordingURL: URL) -> Bool {
        let key = RecordingEntry.canonicalURL(recordingURL)
        return admitting[key] != nil || activeJob?.recordingURL == key || queue.contains { $0.recordingURL == key }
    }

    /// Cancel a queued or active job by its ID.
    /// If active, waits for worker task teardown before completing to prevent overlapping processes.
    public func cancel(jobID: UUID) async {
        cancelledJobIDs.insert(jobID)

        if let index = queue.firstIndex(where: { $0.id == jobID }) {
            let removed = queue.remove(at: index)
            var warning: String?
            if let historyRepository {
                let result = historyRepository.updateStatus(removed.recordingURL) { entry in
                    entry.phase = .interrupted
                    entry.readArtifacts()
                    entry.addProblem(.transcription, "Обработка отменена.", error: true)
                }
                warning = result.persistenceWarning
            }
            historyRepository?.releaseWork(removed.recordingURL, id: removed.id)
            cancelledJobIDs.remove(removed.id)
            emit(.cancelled(removed, persistenceWarning: warning))
            return
        }

        if activeJob?.id == jobID, let task = activeTask {
            task.cancel()
            _ = await task.result
        }
    }

    /// Number of jobs pending in queue + currently active.
    public var totalJobCount: Int {
        admitting.count + queue.count + (activeJob != nil ? 1 : 0)
    }

    public var isBusy: Bool {
        !admitting.isEmpty || activeJob != nil || preparationState != .idle
    }

    public func cancelPreparation() async {
        guard let task = preparationTask, let id = preparationID else { return }
        task.cancel()
        _ = try? await task.value
        finishPreparation(id: id)
    }

    private func finishPreparation(id: UUID) {
        guard preparationID == id else { return }
        preparationID = nil
        preparationTask = nil
        preparationState = .idle
        publishSnapshot()
        drainNextIfNeeded()
    }

    public func checkOrPrepareDependencies(
        prepare: Bool,
        parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> (output: String, succeeded: Bool) {
        guard !isBusy else {
            throw NSError(
                domain: "ProcessingService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Сервис занят обработкой или подготовкой."]
            )
        }
        let id = UUID()
        preparationID = id
        preparationState = prepare ? .preparing : .checking
        publishSnapshot()
        let runner = transcriptionRunner
        let task = Task { () -> (output: String, succeeded: Bool) in
            try await runner.checkDependenciesWithOutput(
                prepare: prepare,
                availability: false,
                parakeet: parakeet,
                onOutput: onOutput
            )
        }
        preparationTask = task
        defer { finishPreparation(id: id) }
        let result = try await task.value
        guard !task.isCancelled else { throw CancellationError() }
        emit(.dependenciesChecked(output: result.output, succeeded: result.succeeded))
        return result
    }

    private func drainNextIfNeeded() {
        guard preparationState == .idle, admitting.isEmpty else { return }
        guard activeJob == nil, !queue.isEmpty else { return }
        let nextJob = queue.removeFirst()

        activeJob = nextJob
        emit(.started(nextJob))

        activeTask = Task { [weak self, nextJob, transcriptionRunner, audioExporter, historyRepository] in
            guard let self else { return }
            do {
                try Task.checkCancellation()

                // Mark saving phase in history
                if let historyRepository {
                    _ = historyRepository.updateStatus(nextJob.recordingURL) { entry in
                        entry.phase = .saving
                        entry.problems.removeAll { $0.stage == .transcription || $0.stage == .saving }
                    }
                }

                // Finalize stopped capture or export audio if missing
                if let stopped = nextJob.stoppedCapture {
                    let result = await stopped.finish()
                    if let historyRepository {
                        _ = historyRepository.updateStatus(nextJob.recordingURL) { entry in
                            entry.duration = result.duration
                            entry.problems.removeAll { $0.stage == .transcription || $0.stage == .saving }
                            for warning in result.warnings where warning.hasPrefix("Не удалось сохранить журнал") {
                                entry.addProblem(.saving, warning)
                            }
                            entry.readArtifacts()
                        }
                    }
                } else if !FileManager.default.fileExists(atPath: nextJob.recordingURL.path), let historyRepository {
                    let currentEntry = historyRepository.entry(nextJob.recordingURL)
                    let inputs = [
                        currentEntry?.rawBase.appendingPathExtension("host_record.wav"),
                        currentEntry?.rawBase.appendingPathExtension("remote_record.wav")
                    ].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }

                    if inputs.count == 2 {
                        do {
                            try await audioExporter.exportMixedAudio(from: inputs, to: nextJob.recordingURL)
                            _ = historyRepository.updateStatus(nextJob.recordingURL) {
                                do { try $0.clearExportFailure() } catch {}
                                $0.readArtifacts()
                            }
                        } catch {
                            _ = historyRepository.updateStatus(nextJob.recordingURL) {
                                $0.addProblem(.saving, "Сборка общего аудио не удалась: " + error.localizedDescription, error: true)
                                $0.readArtifacts()
                            }
                        }
                    } else if inputs.count == 1, let single = inputs.first {
                        do {
                            try await audioExporter.exportMixedAudio(from: [single], to: nextJob.recordingURL)
                            _ = historyRepository.updateStatus(nextJob.recordingURL) {
                                do { try $0.clearExportFailure() } catch {}
                                $0.readArtifacts()
                            }
                        } catch {
                            _ = historyRepository.updateStatus(nextJob.recordingURL) {
                                $0.addProblem(.saving, "Сборка общего аудио не удалась: " + error.localizedDescription, error: true)
                                $0.readArtifacts()
                            }
                        }
                    }
                }

                try Task.checkCancellation()

                // Mark processing phase in history
                if let historyRepository {
                    _ = historyRepository.updateStatus(nextJob.recordingURL) { $0.phase = .processing }
                }

                let storage = TranscriptResultStorage(recordingURL: nextJob.recordingURL)
                let previousID = try storage.currentResultDirectory()?.lastPathComponent
                let warnings = ProcessingWarnings()
                let transcriptURL: URL
                do {
                let returnedURL = try await transcriptionRunner.run(
                    recording: nextJob.recordingURL,
                    parakeet: nextJob.settings.parakeet,
                    echoCancellation: nextJob.settings.echoCancellation
                ) { [weak self] progress in
                    if let warning = progress.warning { warnings.append(warning) }
                    Task { [weak self] in
                        await self?.handleProgress(job: nextJob, progress: progress)
                    }
                }

                if let committed = try storage.committedText(after: previousID) {
                    transcriptURL = committed
                    if Task.isCancelled { warnings.append("Новый результат сохранён до отмены обработки.") }
                } else {
                    try Task.checkCancellation()
                    transcriptURL = returnedURL
                }
                } catch {
                    guard let committed = try? storage.committedText(after: previousID) else { throw error }
                    transcriptURL = committed
                    warnings.append("Новый результат сохранён; подтверждение обработки прервано: " + error.localizedDescription)
                }
                var terminalWarnings = warnings.values
                if let historyRepository {
                    let res = historyRepository.updateStatus(nextJob.recordingURL) { entry in
                        entry.phase = .completed
                        entry.readArtifacts()
                        for warning in warnings.values { entry.addProblem(.transcription, warning) }
                    }
                    if let warning = res.persistenceWarning { terminalWarnings.append(warning) }
                }
                let warning = terminalWarnings.isEmpty ? nil : terminalWarnings.joined(separator: "\n")
                await self.finishJob(nextJob, result: .success(transcriptURL, persistenceWarning: warning))
            } catch is CancellationError {
                var warning: String?
                if let historyRepository {
                    let result = historyRepository.updateStatus(nextJob.recordingURL) { entry in
                        entry.phase = .interrupted
                        entry.readArtifacts()
                        entry.addProblem(.transcription, "Обработка отменена.", error: true)
                    }
                    warning = result.persistenceWarning
                }
                await self.finishJob(nextJob, result: .cancelled(persistenceWarning: warning))
            } catch {
                var warning: String?
                if let historyRepository {
                    let res = historyRepository.updateStatus(nextJob.recordingURL) { entry in
                        entry.phase = .failed
                        entry.readArtifacts()
                        entry.addProblem(.transcription, error.localizedDescription, error: true)
                    }
                    warning = res.persistenceWarning
                }
                await self.finishJob(nextJob, result: .failure(error.localizedDescription, persistenceWarning: warning))
            }
        }
    }

    private enum JobInternalResult {
        case success(URL, persistenceWarning: String?)
        case failure(String, persistenceWarning: String?)
        case cancelled(persistenceWarning: String?)
    }

    private func finishJob(_ job: ProcessingJob, result: JobInternalResult) {
        historyRepository?.releaseWork(job.recordingURL, id: job.id)
        activeJob = nil
        activeTask = nil
        cancelledJobIDs.remove(job.id)
        progress.removeValue(forKey: job.recordingURL)

        switch result {
        case .success(let transcriptURL, let warning):
            emit(.completed(job, transcriptURL: transcriptURL, persistenceWarning: warning))
        case .failure(let errorDescription, let warning):
            emit(.failed(job, errorDescription: errorDescription, persistenceWarning: warning))
        case .cancelled(let warning):
            emit(.cancelled(job, persistenceWarning: warning))
        }

        drainNextIfNeeded()
    }

    private func handleProgress(job: ProcessingJob, progress: TranscriptionProgress) {
        guard activeJob?.id == job.id else { return }
        guard !cancelledJobIDs.contains(job.id) else { return }
        self.progress[job.recordingURL] = progress
        if let warning = progress.warning, let historyRepository {
            let source = progress.channel.map { "[\($0)] " } ?? ""
            _ = historyRepository.updateStatus(job.recordingURL) { $0.addProblem(.transcription, source + warning) }
        }
        emit(.progress(job, progress))
    }
}

private final class ProcessingWarnings: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; messages.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return messages }
}
