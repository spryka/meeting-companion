import Foundation
import MeetingCompanionCore

/// Captured settings snapshot at the moment of recording or enqueueing.
public struct ProcessingJobSettings: Equatable, Sendable {
    public let parakeet: Bool
    public let echoCancellation: Bool
    public let voiceMatchPolicy: VoiceMatchPolicy?
    public let voiceFeatureGeneration: UUID?

    public var voiceIdentification: Bool { voiceMatchPolicy != nil }

    public init(
        parakeet: Bool,
        echoCancellation: Bool,
        voiceMatchPolicy: VoiceMatchPolicy? = nil,
        voiceFeatureGeneration: UUID? = nil
    ) {
        self.parakeet = parakeet
        self.echoCancellation = echoCancellation
        self.voiceMatchPolicy = voiceMatchPolicy
        self.voiceFeatureGeneration = voiceFeatureGeneration
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

public protocol VoiceEmbeddingRunnerProtocol: Sendable {
    func extractVoiceEmbeddings(
        _ request: VoiceEmbeddingProtocol.Request, recordingDirectory: URL
    ) async throws -> VoiceEmbeddingProtocol.Response
    func checkOrPrepareVoiceModel(prepare: Bool) async throws
}

public extension VoiceEmbeddingRunnerProtocol {
    func checkOrPrepareVoiceModel(prepare: Bool) async throws { throw ProcessingService.VoiceJobError.unavailable }
}

/// Application service managing the single serial processing queue and job execution off MainActor.
public actor ProcessingService {
    public enum VoiceJobKind: Equatable, Sendable { case automaticAssignment, learning }

    public enum VoiceJobError: LocalizedError, Equatable {
        case unavailable, duplicate, staleResult

        public var errorDescription: String? {
            switch self {
            case .unavailable: "Обработка голосов недоступна."
            case .duplicate: "Это задание для голосов уже в очереди."
            case .staleResult: "Результат расшифровки изменился."
            }
        }
    }

    public enum Event: Sendable {
        case enqueued(ProcessingJob)
        case started(ProcessingJob)
        case recordingSaved(URL)
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
        public let routes: [URL: ProcessingProgressSnapshot]
        public let progress: [URL: TranscriptionProgress]
        public let voiceJobCount: Int
        public var jobCount: Int { queued.count + admitting.count + (active == nil ? 0 : 1) }

        public init(
            active: ProcessingJob?,
            queued: [ProcessingJob],
            admitting: [ProcessingJob] = [],
            preparation: PreparationState,
            progress: [URL: TranscriptionProgress],
            routes: [URL: ProcessingProgressSnapshot] = [:],
            voiceJobCount: Int = 0
        ) {
            self.active = active
            self.queued = queued
            self.admitting = admitting
            self.preparation = preparation
            self.routes = routes
            self.voiceJobCount = voiceJobCount
            self.progress = progress
        }
    }

    public enum Update: Sendable {
        case snapshot(Snapshot)
        case event(Event)
    }

    private var observers: [UUID: AsyncStream<Update>.Continuation] = [:]
    private var progress: [URL: TranscriptionProgress] = [:]
    private var routes: [URL: ProcessingProgressSnapshot] = [:]

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
            queued: queuedTranscriptions,
            admitting: Array(admitting.values),
            preparation: preparationIsASR ? preparationState : .idle,
            progress: progress,
            routes: routes,
            voiceJobCount: voiceJobCount
        )
    }

    private func publishSnapshot() {
        let snapshot = presentationSnapshot
        for observer in observers.values { observer.yield(.snapshot(snapshot)) }
    }

    package func failure(for job: ProcessingJob) -> String? {
        guard let route = routes[job.recordingURL], route.jobID == job.id else { return nil }
        return route.failure
    }

    private var admitting: [URL: ProcessingJob] = [:]
    private let retryAdmission: (@Sendable (URL) async -> Bool)?
    private let voiceLearning: VoiceLearningCoordinator?
    private var retryWriters: [UUID: TranscriptEditsRepository] = [:]

    /// Keep the retry writers stable throughout the synchronous metadata reconciliation.
    func reconcileVoiceLibrary(_ coordinator: VoiceLearningCoordinator, recordings: [URL],
                               scanComplete: Bool, id: UUID, editorWriter: TranscriptEditsRepository?) {
        var writers = Array(retryWriters.values)
        if let editorWriter { writers.append(editorWriter) }
        coordinator.reconcileLibrary(recordings: recordings, scanComplete: scanComplete, id: id, openWriters: writers)
    }
    private struct VoiceJob {
        let id: UUID
        let recordingURL: URL
        let kind: VoiceJobKind
        let request: VoiceEmbeddingProtocol.Request
        let shouldStart: @Sendable () -> Bool
        let continuation: CheckedContinuation<VoiceEmbeddingProtocol.Response, any Error>
    }

    private enum QueuedJob {
        case transcription(ProcessingJob)
        case voice(VoiceJob)

        var transcription: ProcessingJob? {
            if case .transcription(let job) = self { return job }
            return nil
        }

        var voice: VoiceJob? {
            if case .voice(let job) = self { return job }
            return nil
        }
    }

    private var queue: [QueuedJob] = []
    private var queuedTranscriptions: [ProcessingJob] { queue.compactMap(\.transcription) }
    private var activeVoiceJob: VoiceJob?
    private var activeInlineVoiceTask: Task<Void, Never>?
    private var voiceJobCount: Int {
        queue.count - queuedTranscriptions.count + (activeVoiceJob == nil ? 0 : 1)
    }
    private var activeJob: ProcessingJob?
    private var activeTask: Task<Void, Never>?
    private var cancelledJobIDs: Set<UUID> = []
    private var preparationState: PreparationState = .idle
    private var preparationIsASR = false
    private var preparationID: UUID?
    private var preparationTask: Task<(output: String, succeeded: Bool), Error>?
    private let transcriptionRunner: TranscriptionRunnerProtocol
    private let audioExporter: AudioExporterProtocol
    private let historyRepository: RecordingHistoryRepository?
    private let voiceRunner: (any VoiceEmbeddingRunnerProtocol)?
    private let isRecordingInCurrentLibrary: (@Sendable (URL) async -> Bool)?
    private var eventHandlers: [@Sendable (Event) -> Void] = []

    public init(
        transcriptionRunner: TranscriptionRunnerProtocol,
        audioExporter: AudioExporterProtocol,
        historyRepository: RecordingHistoryRepository? = nil,
        retryAdmission: (@Sendable (URL) async -> Bool)? = nil,
        voiceLearning: VoiceLearningCoordinator? = nil,
        voiceRunner: (any VoiceEmbeddingRunnerProtocol)? = nil,
        isRecordingInCurrentLibrary: (@Sendable (URL) async -> Bool)? = nil
    ) {
        self.transcriptionRunner = transcriptionRunner
        self.audioExporter = audioExporter
        self.historyRepository = historyRepository
        self.retryAdmission = retryAdmission
        self.voiceLearning = voiceLearning
        self.voiceRunner = voiceRunner
        self.isRecordingInCurrentLibrary = isRecordingInCurrentLibrary
    }

    /// Registers an event handler and immediately delivers the current state if a job is active.
    public func addEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        eventHandlers.append(handler)
        if let active = activeJob {
            handler(.started(active))
        }
    }

    public func currentSnapshot() -> (active: ProcessingJob?, queued: [ProcessingJob]) {
        (activeJob, queuedTranscriptions + Array(admitting.values))
    }

    public var hasPendingWork: Bool { !queue.isEmpty || isBusy }

    func containsRecordingInCurrentLibrary(_ recording: URL) async -> Bool {
        await isRecordingInCurrentLibrary?(recording) ?? true
    }

    public func extractVoiceEmbeddings(
        _ request: VoiceEmbeddingProtocol.Request, recordingURL: URL, kind: VoiceJobKind,
        shouldStart: @escaping @Sendable () -> Bool = { true }
    ) async throws -> VoiceEmbeddingProtocol.Response {
        guard voiceRunner != nil else { throw VoiceJobError.unavailable }
        try VoiceEmbeddingProtocol.validateRequest(request)
        let recording = RecordingEntry.canonicalURL(recordingURL)
        let id = UUID()
        if let historyRepository, !historyRepository.reserveWork(recording, id: id) { throw VoiceJobError.unavailable }
        defer { historyRepository?.releaseWork(recording, id: id) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response: VoiceEmbeddingProtocol.Response = try await withCheckedThrowingContinuation { continuation in
                if kind == .automaticAssignment,
                   (queue.compactMap(\.voice) + [activeVoiceJob].compactMap { $0 }).contains(where: {
                       $0.kind == kind && $0.recordingURL == recording && $0.request.resultID == request.resultID
                   }) {
                    continuation.resume(throwing: VoiceJobError.duplicate)
                    return
                }
                queue.append(.voice(VoiceJob(id: id, recordingURL: recording, kind: kind,
                                             request: request, shouldStart: shouldStart, continuation: continuation)))
                publishSnapshot()
                drainNextIfNeeded()
            }
            try Task.checkCancellation()
            return response
        } onCancel: {
            Task { await self.cancelVoiceJob(id: id) }
        }
    }

    public func cancelVoiceJobsIfDisabled() async {
        guard voiceLearning?.isEnabled != true else { return }
        let queued = queue.compactMap(\.voice)
        queue.removeAll { $0.voice != nil }
        for job in queued { job.continuation.resume(throwing: CancellationError()) }
        publishSnapshot()
        if let active = activeVoiceJob { await cancelVoiceJob(id: active.id) }
        if let inline = activeInlineVoiceTask {
            inline.cancel()
            await inline.value
        }
    }

    private func cancelVoiceJob(id: UUID) async {
        if let index = queue.firstIndex(where: { $0.voice?.id == id }),
           let job = queue.remove(at: index).voice {
            job.continuation.resume(throwing: CancellationError())
            publishSnapshot()
        } else if activeVoiceJob?.id == id, let task = activeTask {
            task.cancel()
            _ = await task.result
        }
    }

    public var currentPreparationState: PreparationState {
        preparationState
    }

    private func emit(_ event: Event) {
        for handler in eventHandlers { handler(event) }
        for observer in observers.values { observer.yield(.event(event)) }
        publishSnapshot()
    }

    private func reject(_ job: ProcessingJob, reason: String) {
        var route = ProcessingProgressSnapshot(job: job)
        route.finish(success: false, reason: reason)
        routes[job.recordingURL] = route
        emit(.failed(job, errorDescription: reason))
    }

    /// Enqueue a recording with captured snapshot settings. Returns the enqueued ProcessingJob.
    @discardableResult
    public func enqueue(
        recordingURL: URL,
        settings: ProcessingJobSettings,
        stoppedCapture: (any StoppedCaptureProtocol)? = nil,
        jobID: UUID = UUID()
    ) async -> ProcessingJob {
        let canonical = RecordingEntry.canonicalURL(recordingURL)
        guard RecordingPaths.isStandardLayout(canonical) else {
            let job = ProcessingJob(id: jobID, recordingURL: canonical, settings: settings, stoppedCapture: stoppedCapture)
            reject(job, reason: RecordingPaths.unsupportedLayoutMessage)
            return job
        }
        if let existing = admitting[canonical] ?? queuedTranscriptions.first(where: { $0.recordingURL == canonical }) ?? (activeJob?.recordingURL == canonical ? activeJob : nil) {
            return existing
        }
        let job = ProcessingJob(id: jobID, recordingURL: canonical, settings: settings, stoppedCapture: stoppedCapture)
        if let historyRepository, !historyRepository.reserveWork(canonical, id: job.id) {
            reject(job, reason: "Дождитесь завершения работы с записью")
            return job
        }
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
                reject(job, reason: existingEntry.capabilities.reason ?? "Исходные WAV отсутствуют или недоступны; повторная обработка невозможна.")
                drainNextIfNeeded()
                return job
            }
            if cached == nil { historyRepository.put(existingEntry, persist: false) }
        }
        if stoppedCapture == nil, let voiceLearning {
            let writer = TranscriptEditsRepository(recordingDirectory: canonical.deletingLastPathComponent())
            do {
                try voiceLearning.preserveOutboxes(recording: canonical, writer: writer, includeHistory: false)
                retryWriters[job.id] = writer
            } catch {
                reject(job, reason: error.localizedDescription)
                drainNextIfNeeded()
                return job
            }
        }
        routes[canonical] = ProcessingProgressSnapshot(job: job)
        queue.append(.transcription(job))
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
        return admitting[key] != nil || activeJob?.recordingURL == key || queue.contains { $0.transcription?.recordingURL == key }
    }

    /// Cancel a queued or active job by its ID.
    /// If active, waits for worker task teardown before completing to prevent overlapping processes.
    public func cancel(jobID: UUID) async {
        cancelledJobIDs.insert(jobID)

        if let index = queue.firstIndex(where: { $0.transcription?.id == jobID }),
           let removed = queue.remove(at: index).transcription {
            var warning: String?
            if let historyRepository {
                let result = historyRepository.updateStatus(removed.recordingURL) { entry in
                    entry.phase = .interrupted
                    entry.readArtifacts()
                    entry.addProblem(.transcription, "Обработка отменена.", error: true)
                }
                warning = result.persistenceWarning
            }
            retryWriters.removeValue(forKey: removed.id)?.releaseWriteLock()
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
        admitting.count + queuedTranscriptions.count + (activeJob != nil ? 1 : 0)
    }

    public var isBusy: Bool {
        !admitting.isEmpty || activeTask != nil || preparationState != .idle
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
        let runner = transcriptionRunner
        return try await runPreparation(prepare: prepare, reportASRResult: true) {
            try await runner.checkDependenciesWithOutput(
                prepare: prepare, availability: false, parakeet: parakeet, onOutput: onOutput
            )
        }
    }

    public func checkOrPrepareVoiceModel(prepare: Bool) async throws {
        guard let voiceRunner else { throw VoiceJobError.unavailable }
        guard prepare else {
            try await voiceRunner.checkOrPrepareVoiceModel(prepare: false)
            return
        }
        _ = try await runPreparation(prepare: true, reportASRResult: false) {
            try await voiceRunner.checkOrPrepareVoiceModel(prepare: true)
            return ("", true)
        }
    }

    private func runPreparation(
        prepare: Bool, reportASRResult: Bool,
        operation: @escaping @Sendable () async throws -> (output: String, succeeded: Bool)
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
        preparationIsASR = reportASRResult
        preparationState = prepare ? .preparing : .checking
        publishSnapshot()
        let task = Task { try await operation() }
        preparationTask = task
        defer { finishPreparation(id: id) }
        let result = try await task.value
        guard !task.isCancelled else { throw CancellationError() }
        if reportASRResult { emit(.dependenciesChecked(output: result.output, succeeded: result.succeeded)) }
        return result
    }

    private func drainNextIfNeeded() {
        guard preparationState == .idle, admitting.isEmpty else { return }
        guard activeTask == nil, !queue.isEmpty else { return }
        let nextIndex = queue.firstIndex { $0.transcription != nil } ?? queue.startIndex
        switch queue.remove(at: nextIndex) {
        case .transcription(let job): startTranscription(job)
        case .voice(let job): startVoice(job)
        }
    }

    private func startVoice(_ job: VoiceJob) {
        activeVoiceJob = job
        activeTask = Task { [self] in
            let result: Result<VoiceEmbeddingProtocol.Response, any Error>
            do {
                try Task.checkCancellation()
                guard let voiceRunner else { throw VoiceJobError.unavailable }
                let storage = TranscriptResultStorage(recordingURL: job.recordingURL)
                guard try storage.currentResultDirectory()?.lastPathComponent == job.request.resultID else {
                    throw VoiceJobError.staleResult
                }
                guard await containsRecordingInCurrentLibrary(job.recordingURL), job.shouldStart() else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                let response = try await voiceRunner.extractVoiceEmbeddings(
                    job.request, recordingDirectory: job.recordingURL.deletingLastPathComponent()
                )
                try Task.checkCancellation()
                guard try storage.currentResultDirectory()?.lastPathComponent == job.request.resultID else {
                    throw VoiceJobError.staleResult
                }
                result = .success(response)
            } catch {
                result = .failure(Task.isCancelled ? CancellationError() : error)
            }
            activeVoiceJob = nil
            activeTask = nil
            job.continuation.resume(with: result)
            publishSnapshot()
            drainNextIfNeeded()
        }
        publishSnapshot()
    }

    private func startTranscription(_ nextJob: ProcessingJob) {
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

                await self.handleProgress(job: nextJob, progress: .init(stage: .audio, completed: 0, total: 0, state: .started))
                // Finalize stopped capture or export audio if missing
                if let stopped = nextJob.stoppedCapture {
                    let result = await stopped.finish()
                    if result.fileSize > 0 { await self.emit(.recordingSaved(nextJob.recordingURL)) }
                    for warning in result.warnings {
                        await self.handleProgress(job: nextJob, progress: .init(stage: .audio, completed: 0, total: 0, warning: warning))
                    }
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
                            await self.handleProgress(job: nextJob, progress: .init(stage: .audio, completed: 0, total: 0,
                                warning: "Сборка общего аудио не удалась: " + error.localizedDescription))
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
                            await self.handleProgress(job: nextJob, progress: .init(stage: .audio, completed: 0, total: 0,
                                warning: "Сборка общего аудио не удалась: " + error.localizedDescription))
                            _ = historyRepository.updateStatus(nextJob.recordingURL) {
                                $0.addProblem(.saving, "Сборка общего аудио не удалась: " + error.localizedDescription, error: true)
                                $0.readArtifacts()
                            }
                        }
                    }
                }

                try Task.checkCancellation()

                await self.handleProgress(job: nextJob, progress: .init(stage: .audio, completed: 0, total: 0, state: .completed))
                // Mark processing phase in history
                if let historyRepository {
                    _ = historyRepository.updateStatus(nextJob.recordingURL) { $0.phase = .processing }
                }

                let storage = TranscriptResultStorage(recordingURL: nextJob.recordingURL)
                let previousID = try storage.currentResultDirectory()?.lastPathComponent
                let warnings = ProcessingWarnings()
                let transcriptURL: URL
                // AsyncStream preserves callback order and is drained before terminal acceptance.
                let (events, continuation) = AsyncStream<TranscriptionProgress>.makeStream()
                let delivery = Task {
                    for await event in events { await self.handleProgress(job: nextJob, progress: event) }
                }
                do {
                let returnedURL = try await transcriptionRunner.run(
                    recording: nextJob.recordingURL,
                    parakeet: nextJob.settings.parakeet,
                    echoCancellation: nextJob.settings.echoCancellation
                ) { progress in
                    if let warning = progress.warning { warnings.append(warning) }
                    continuation.yield(progress)
                }

                continuation.finish()
                await delivery.value
                if let committed = try storage.committedText(after: previousID) {
                    transcriptURL = committed
                    if Task.isCancelled { warnings.append("Новый результат сохранён до отмены обработки.") }
                } else {
                    try Task.checkCancellation()
                    transcriptURL = returnedURL
                }
                } catch {
                    continuation.finish()
                    await delivery.value
                    guard let committed = try? storage.committedText(after: previousID) else { throw error }
                    transcriptURL = committed
                    warnings.append("Новый результат сохранён; подтверждение обработки прервано: " + error.localizedDescription)
                }
                if let policy = nextJob.settings.voiceMatchPolicy {
                    await self.runInlineVoiceAssignment(
                        job: nextJob,
                        transcriptURL: transcriptURL,
                        policy: policy,
                        warnings: warnings
                    )
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
        retryWriters.removeValue(forKey: job.id)?.releaseWriteLock()
        historyRepository?.releaseWork(job.recordingURL, id: job.id)
        switch result {
        case .success(_, let warning): routes[job.recordingURL]?.finish(success: true, reason: warning)
        case .failure(let message, _): routes[job.recordingURL]?.finish(success: false, reason: message)
        case .cancelled: routes[job.recordingURL]?.finish(success: false, reason: "Обработка отменена.")
        }
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
        routes[job.recordingURL]?.receive(progress, jobID: job.id)
        self.progress[job.recordingURL] = progress
        if let warning = progress.warning, !(progress.stage == .voices && progress.state == .skipped),
           let historyRepository {
            let source = progress.channel.map { "[\($0)] " } ?? ""
            _ = historyRepository.updateStatus(job.recordingURL) { $0.addProblem(.transcription, source + warning) }
        }
        emit(.progress(job, progress))
    }

    private func runInlineVoiceAssignment(
        job: ProcessingJob,
        transcriptURL: URL,
        policy: VoiceMatchPolicy,
        warnings: ProcessingWarnings
    ) async {
        let featureDisabled = "Определение голосов выключено."
        let libraryUnavailable = "Библиотека ещё не сверена для определения голосов."
        let noStructuredResult = "Структурированный результат недоступен."
        func publishVoiceEvent(_ state: TranscriptionProgress.State, warning: String? = nil, skipReason: String? = nil) {
            let event = TranscriptionProgress(stage: .voices, completed: 0, total: 0, warning: warning, state: state, skipReason: skipReason)
            if cancelledJobIDs.contains(job.id) {
                routes[job.recordingURL]?.receive(event, jobID: job.id)
                publishSnapshot()
            } else {
                handleProgress(job: job, progress: event)
            }
        }

        publishVoiceEvent(.started)

        if Task.isCancelled || cancelledJobIDs.contains(job.id) {
            let note = "Новый результат сохранён до отмены определения голосов."
            warnings.append(note)
            publishVoiceEvent(.skipped, warning: note)
            return
        }
        guard transcriptURL.lastPathComponent == "transcript.txt" else {
            publishVoiceEvent(.skipped, skipReason: noStructuredResult)
            return
        }
        guard let voiceLearning, let voiceRunner else {
            publishVoiceEvent(.skipped, skipReason: "Модель определения голосов недоступна.")
            return
        }
        if !(await containsRecordingInCurrentLibrary(job.recordingURL)) {
            publishVoiceEvent(.skipped, skipReason: "Запись вне текущей библиотеки.")
            return
        }
        guard voiceLearning.isEnabled,
              job.settings.voiceFeatureGeneration == nil || voiceLearning.featureGeneration == job.settings.voiceFeatureGeneration else {
            publishVoiceEvent(.skipped, skipReason: featureDisabled)
            return
        }
        guard let libraryGeneration = voiceLearning.matchingLibraryGeneration,
              let featureGeneration = voiceLearning.featureGeneration else {
            publishVoiceEvent(.skipped, skipReason: libraryUnavailable)
            return
        }

        let resultID = transcriptURL.deletingLastPathComponent().lastPathComponent
        let recordingDirectory = job.recordingURL.deletingLastPathComponent()
        let storage = TranscriptResultStorage(recordingURL: job.recordingURL)
        let writer = retryWriters[job.id]

        let inlineTask = Task<VoiceLearningCoordinator.AutomaticAssignmentOutcome, Error> {
            try await voiceLearning.automaticallyAssign(
                recordingURL: job.recordingURL,
                resultID: resultID,
                policy: policy,
                expectedLibraryGeneration: libraryGeneration,
                expectedFeatureGeneration: featureGeneration,
                openWriter: writer
            ) { request in
                try Task.checkCancellation()
                try VoiceEmbeddingProtocol.validateRequest(request)
                guard try storage.currentResultDirectory()?.lastPathComponent == request.resultID else {
                    throw VoiceJobError.staleResult
                }
                let response = try await voiceRunner.extractVoiceEmbeddings(request, recordingDirectory: recordingDirectory)
                try Task.checkCancellation()
                guard try storage.currentResultDirectory()?.lastPathComponent == request.resultID else {
                    throw VoiceJobError.staleResult
                }
                return response
            }
        }
        let cancellationHandle = Task<Void, Never> {
            await withTaskCancellationHandler {
                _ = try? await inlineTask.value
            } onCancel: {
                inlineTask.cancel()
            }
        }
        activeInlineVoiceTask = cancellationHandle
        defer {
            cancellationHandle.cancel()
            if activeInlineVoiceTask == cancellationHandle {
                activeInlineVoiceTask = nil
            }
        }

        do {
            let outcome = try await withTaskCancellationHandler {
                try await inlineTask.value
            } onCancel: {
                inlineTask.cancel()
            }
            switch outcome {
            case .applied:
                publishVoiceEvent(.completed)
            case .skippedFeatureDisabled:
                publishVoiceEvent(.skipped, skipReason: featureDisabled)
            case .skippedLibraryUnavailable:
                publishVoiceEvent(.skipped, skipReason: libraryUnavailable)
            case .skippedInsufficientProfiles:
                publishVoiceEvent(.skipped, skipReason: "Нужно не менее двух совместимых профилей голосов.")
            case .skippedNoStructuredResult:
                publishVoiceEvent(.skipped, skipReason: noStructuredResult)
            }
        } catch is CancellationError {
            if !voiceLearning.isEnabled ||
                (job.settings.voiceFeatureGeneration != nil && voiceLearning.featureGeneration != job.settings.voiceFeatureGeneration) {
                publishVoiceEvent(.skipped, skipReason: featureDisabled)
            } else {
                let note = "Новый результат сохранён до отмены определения голосов."
                warnings.append(note)
                publishVoiceEvent(.skipped, warning: note)
            }
        } catch VoiceJobError.staleResult {
            publishVoiceEvent(.skipped, skipReason: "Текущий результат изменился.")
        } catch {
            let message = "Автоопределение голосов не выполнено: " + error.localizedDescription
            warnings.append(message)
            publishVoiceEvent(.failed, warning: message)
        }
    }
}

private final class ProcessingWarnings: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; if !messages.contains(value) { messages.append(value) } }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return messages }
}

/// Presentation state is transient and belongs to the accepted job, never live Settings.
public struct ProcessingProgressSnapshot: Equatable, Sendable {
    public enum Station: String, CaseIterable, Sendable {
        case audio, echo, diarization, recognition, correction, saving, voices
        public var title: String {
            switch self {
            case .audio: "Сборка аудио"
            case .echo: "Подавление эха"
            case .diarization: "Разделение голосов"
            case .recognition: "Распознавание"
            case .correction: "Уточнение терминов"
            case .saving: "Сохранение"
            case .voices: "Определение голосов"
            }
        }
        public var model: String? {
            switch self {
            case .echo: "WebRTC AEC"
            case .diarization: "Nemotron"
            case .recognition: "GigaAM"
            case .correction: "Parakeet"
            case .voices: "WeSpeaker"
            default: nil
            }
        }
        public var hasSources: Bool { [.diarization, .recognition, .correction].contains(self) }
    }
    public enum State: String, Sendable { case future, current, completed, warning, skipped, failed }
    public let jobID: UUID
    public let route: [Station]
    public private(set) var states: [Station: State] = [:]
    public private(set) var sources: [Station: Set<String>] = [:]
    public private(set) var skipReasons: [Station: String] = [:]
    private var warningsByStation: [Station: String] = [:]
    public var reasons: [Station: String] {
        skipReasons.merging(warningsByStation) { skipReason, warning in skipReason + "\n" + warning }
    }
    public private(set) var local: TranscriptionProgress?
    public private(set) var terminal = false
    public private(set) var failure: String?
    private var position: Station = .audio
    private var sourceStates: [Station: [String: State]] = [:]
    public init(job: ProcessingJob) {
        jobID = job.id
        route = Station.allCases.filter {
            ($0 != .echo || job.settings.echoCancellation)
                && ($0 != .correction || job.settings.parakeet)
                && ($0 != .voices || job.settings.voiceIdentification)
        }
    }
    public var currentIndex: Int { route.firstIndex(of: position) ?? 0 }
    public var current: Station? { local == nil && !terminal ? nil : position }
    public var countText: String {
        guard current != nil else { return "В очереди · \(route.count) этапов" }
        return "Этап \(currentIndex + 1) из \(route.count)"
    }
    public var localFraction: Double? {
        guard !terminal, let local, local.state == nil,
              [.echo, .gigaam, .speakers, .parakeet].contains(local.stage) else { return nil }
        return local.stageFraction
    }
    public var warnings: [String] { route.compactMap { warningsByStation[$0] } }
    public mutating func receive(_ event: TranscriptionProgress, jobID: UUID) {
        guard self.jobID == jobID, !terminal else { return }
        let station: Station
        switch event.stage {
        case .audio: station = .audio
        case .echo: station = .echo
        case .diarization: station = .diarization
        case .gigaam, .speakers: station = .recognition
        case .parakeet, .correction: station = .correction
        case .merge, .mix, .publication: station = .saving
        case .voices: station = .voices
        case .warning:
            if let warning = event.warning { appendReason(warning, to: position) }
            return
        }
        guard route.contains(station) else { return }
        if station == .voices && (states[.saving] == nil || states[.saving] == .current) {
            states[.saving] = warningsByStation[.saving] == nil ? .completed : .warning
        }
        position = station
        local = event
        if let reason = event.warning { appendReason(reason, to: station) }
        if event.state == .skipped, let reason = event.skipReason { skipReasons[station] = reason }
        var state: State
        switch event.state {
        case .completed: state = .completed
        case .skipped: state = .skipped
        case .failed: state = .failed
        case .started: state = .current
        case nil:
            // Older start/end-only producers report the two model sources independently.
            state = station == .diarization && event.total > 0 && event.completed == event.total ? .completed : .current
        }
        if state == .completed, warningsByStation[station] != nil { state = .warning }
        if station == .saving { states[station] = .current; return }
        if station.hasSources {
            guard let channel = event.channel else { states[station] = .current; return }
            sourceStates[station, default: [:]][channel] = state
            if state != .current { sources[station, default: []].insert(channel) }
            else { sources[station, default: []].remove(channel) }
            let values = sourceStates[station, default: [:]]
            if sources[station] == Set(["host", "remote"]) {
                states[station] = values.values.contains(.failed) ? .failed : values.values.contains(.skipped) ? .skipped : values.values.contains(.warning) ? .warning : .completed
            } else { states[station] = .current }
        } else { states[station] = state }
    }
    private mutating func appendReason(_ reason: String, to station: Station) {
        guard !reason.isEmpty else { return }
        if warningsByStation[station]?.contains(reason) == true { return }
        warningsByStation[station] = [warningsByStation[station], reason].compactMap { $0 }.joined(separator: "\n")
        if states[station] == .completed { states[station] = .warning }
    }
    public mutating func finish(success: Bool, reason: String?) {
        guard !terminal else { return }
        terminal = true
        local = nil
        if success {
            if route.contains(.voices) {
                let recorded = Set(warningsByStation.values.flatMap { $0.split(separator: "\n").map(String.init) })
                let unrecorded = (reason ?? "")
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { !$0.isEmpty && !recorded.contains($0) }
                if !unrecorded.isEmpty {
                    for line in unrecorded { appendReason(line, to: .saving) }
                }
                if states[.saving] == nil || states[.saving] == .current {
                    states[.saving] = warningsByStation[.saving] == nil ? .completed : .warning
                }
                position = .voices
                if states[.voices] == nil || states[.voices] == .current {
                    states[.voices] = warningsByStation[.voices] == nil ? .completed : .warning
                }
            } else {
                position = .saving
                states[.saving] = warningsByStation[.saving] == nil && reason == nil ? .completed : .warning
                if let reason { appendReason(reason, to: position) }
            }
        } else {
            states[position] = .failed
            failure = reason
            if let reason { appendReason(reason, to: position) }
        }
    }
}
