import AppKit
import Combine
import Foundation
import MeetingCompanionCore
import MeetingCompanionPlatform
import MeetingCompanionApplication
import SwiftUI

@main
struct MeetingCompanionApp: App {
    @NSApplicationDelegateAdaptor(RecorderAppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Настройки…") { delegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .appInfo) {
                    Button("Проверить обновления…") { delegate.checkForUpdates() }
                }
            }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onAttach(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onAttach(window)
            }
        }
    }
}

@MainActor
final class RecorderViewModel: ObservableObject {
    static let defaultMicrophoneID = "__default__"
    private static let selectedMicrophoneIDKey = "selectedMicrophoneID"

    private let defaults: UserDefaults
    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appAppearance")
            NSApp.appearance = appearance.value
        }
    }

    @Published var outputDirectory: URL {
        didSet {
            defaults.set(outputDirectory.path, forKey: "recordingsDirectory")
            Task { await history.refresh(root: outputDirectory) }
        }
    }
    let calendar: MeetingCalendar
    let historyRepository: RecordingHistoryRepository
    let recordingSessionService: RecordingSessionService
    let processingService: ProcessingService
    let history: RecordingHistory
    var onOpenTranscript: ((RecordingEntry) -> Void)?
    enum MainPage: String, CaseIterable, Identifiable {
        case recording, history
        var id: Self { self }
        var title: String { self == .recording ? "Запись" : "История" }
    }
    @Published var mainPage = MainPage.recording
    @Published var selectedHistoryURL: URL?
    @Published var audioPreviewURL: URL?
    @Published var reminderMeeting: MeetingContext?
    @Published var mainWindowRequested = false
    private var historySubscription: AnyCancellable?
    private var capsuleTimer: Timer?
    private var activeRecordingURL: URL?
    private(set) var recordingMeetingID: String?

    @Published private var meetingSelection = MeetingSelection()
    private var calendarSubscription: AnyCancellable?
    private var meetingSelectionTimer: Timer?
    var selectedMeeting: MeetingContext? {
        get { meetingSelection.meeting }
        set {
            meetingSelection.select(newValue)
            refreshMeetingSelection()
        }
    }
    @Published var isBusy = false
    @Published var isRecording = false { didSet { updateLevelVisibility() } }
    @Published var recordingSaveError: String?
    @Published private(set) var microphoneMuted = false
    @Published private(set) var microphoneState: MicrophoneRecordingState = .receiving
    var microphoneCaptureHint: String {
        switch microphoneState {
        case .receiving: return ""
        case .silent: return "Проверьте микрофон: долго нет звука"
        case .missing: return "Микрофон не записывается"
        case .reconnecting: return "Переподключаем микрофон…"
        }
    }
    @Published private(set) var mutedMicrophoneActivity = false
    private var muteActivity = MutedMicrophoneActivity()

    func toggleMicrophoneMute() {
        guard isRecording, !isBusy else { return }
        let muted = !microphoneMuted
        Task {
            await recordingSessionService.setMicrophoneMuted(muted)
            microphoneState = await recordingSessionService.currentMicrophoneState()
        }
        microphoneMuted = muted
        muteActivity = MutedMicrophoneActivity()
        mutedMicrophoneActivity = false
        levels.reset()
    }

    @Published var capsuleDismissed = false
    @Published private(set) var transcriptionWarnings: [String] = []
    @Published private(set) var lastRecordingTitle = "Запись встречи"
    @Published var improveTerms: Bool {
        didSet {
            defaults.set(improveTerms, forKey: "improveTechnicalTerms")
            transcriptionReady = false
            let selected = improveTerms
            Task {
                let result = try? await Transcription.checkDependencies(availability: true, parakeet: selected)
                guard improveTerms == selected else { return }
                transcriptionReady = result?.succeeded ?? false
            }
        }
    }
    @Published var echoCancellation: Bool {
        didSet { defaults.set(echoCancellation, forKey: "echoCancellation") }
    }
    var showsRecordingCapsule: Bool {
        !mainWindowRequested && (isRecording || recordingCancelled || recordingSaveError != nil || (!capsuleDismissed && transcriptionState != .idle))
    }
    var showsProcessingCapsule: Bool { !isRecording && !recordingCancelled && recordingSaveError == nil && showsRecordingCapsule }
    @Published private(set) var recordingCancelled = false
    var showsCancelRecording: Bool { isRecording && elapsed < 10 }

    func dismissCapsule() {
        capsuleDismissed = true
    }

    @Published private var recordingOvertime: RecordingOvertime?
    var showsOvertimeReminder: Bool {
        guard isRecording, !isBusy, recordingSaveError == nil, let startedAt else { return false }
        return recordingOvertime?.needsReminder(at: startedAt.addingTimeInterval(elapsed)) ?? false
    }
    var overtimeMessage: String {
        recordingOvertime?.hasMeeting == true ? "Время встречи истекло" : "Запись длится больше часа"
    }
    func postponeOvertimeReminder() {
        recordingOvertime?.postpone(at: Date())
    }

    func openResults() {
        guard let lastFileURL else { return }
        selectedHistoryURL = RecordingEntry.canonicalURL(lastFileURL)
        mainPage = .history
        mainWindowRequested = true
        NSApp.activate(ignoringOtherApps: true)
    }
    @Published var elapsed: TimeInterval = 0
    @Published var status = "Готов к записи"
    @Published var lastFileURL: URL?
    @Published private(set) var transcriptionState: TranscriptionState = .idle
    var lastTranscriptURL: URL? { transcriptionState.transcript }
    @Published var transcriptionJobs = 0
    @Published var transcriptionReady: Bool {
        didSet { defaults.set(transcriptionReady, forKey: "transcriptionPrepared") }
    }
    var transcriptionStatus: String {
        if let url = lastFileURL, let entry = history.entry(url), [.queued, .saving].contains(entry.phase) { return entry.status + "…" }
        return transcriptionState.text
    }
    @Published var captureBackend: AudioCaptureBackend {
        didSet {
            defaults.set(captureBackend.rawValue, forKey: "captureBackend")
            captureCheck = nil
            refreshAccess()
        }
    }
    private var captureCheck: RecorderDiagnostics.Access?
    @Published var diagnosticAccess: [RecorderDiagnostics.Access] = []
    @Published var diagnosticReport = ""
    @Published private var localDiagnosticRunning = false
    @Published private var preparationState: ProcessingService.PreparationState = .idle
    var diagnosticRunning: Bool { localDiagnosticRunning || preparationState != .idle }
    @Published private var sessionAttached = false
    @Published private var processingAttached = false
    @Published private var sessionStopping = false
    private var sessionObservation: Task<Void, Never>?
    private var processingObservation: Task<Void, Never>?
    private var shouldCheckDependenciesAfterAttachment = false
    @Published private(set) var isResettingCache = false
    @Published var diagnosticStartedAt: Date?
    @Published var preparationProgress: RecorderDiagnostics.PreparationProgress?
    private var progressProbeRunning = false
    @Published var errorMessage: String?
    @Published var microphones: [MicrophoneDevice] = []
    @Published var selectedMicrophoneID: String {
        didSet {
            defaults.set(selectedMicrophoneID, forKey: RecorderViewModel.selectedMicrophoneIDKey)
        }
    }
    let levels = AudioLevels()
    var preventsTermination: Bool {
        !sessionAttached || !processingAttached || sessionStopping || isRecording || isBusy || diagnosticRunning || transcriptionJobs > 0 || isResettingCache || isCheckingAudio
    }

    private var isWindowVisible = false
    private var isAudioCheckVisible = false
    private var isLevelDisplayActive = false
    @Published private(set) var isCheckingAudio = false { didSet { updateLevelVisibility() } }
    private var audioCheckTimeout: Task<Void, Never>?
    private var recorder: Recorder?
    private var levelMonitor: AudioLevelMonitor?
    private var levelMonitorTask: Task<Void, Never>?
    private var startedAt: Date?
    private var timer: Timer?

    var elapsedText: String {
        formatClock(elapsed)
    }

    var selectedMicrophoneDeviceID: String? {
        selectedMicrophoneID == Self.defaultMicrophoneID ? nil : selectedMicrophoneID
    }

    init(
        sessionService: RecordingSessionService? = nil,
        processingService: ProcessingService? = nil,
        historyRepository: RecordingHistoryRepository? = nil,
        defaults: UserDefaults = .standard,
        startBackgroundServices: Bool = true
    ) {
        self.defaults = defaults
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: "appAppearance") ?? "") ?? .system
        self.outputDirectory = defaults.string(forKey: "recordingsDirectory").map { URL(fileURLWithPath: $0) } ?? RecordingPaths.defaultOutputDirectory
        self.improveTerms = defaults.bool(forKey: "improveTechnicalTerms")
        self.echoCancellation = defaults.bool(forKey: "echoCancellation")
        self.transcriptionReady = defaults.bool(forKey: "transcriptionPrepared")
        self.captureBackend = AudioCaptureBackend(rawValue: defaults.string(forKey: "captureBackend") ?? "") ?? .coreAudioTap
        self.selectedMicrophoneID = defaults.string(forKey: Self.selectedMicrophoneIDKey) ?? Self.defaultMicrophoneID
        self.calendar = MeetingCalendar(defaults: defaults)
        let repo = historyRepository ?? RecordingHistoryRepository()
        self.historyRepository = repo
        self.recordingSessionService = sessionService ?? RecordingSessionService(historyRepo: repo)
        let proc = processingService ?? ProcessingService(
            transcriptionRunner: PlatformTranscriptionRunner(),
            audioExporter: PlatformAudioExporter(),
            historyRepository: repo
        )
        self.processingService = proc
        self.history = RecordingHistory(repository: repo)

        // Retire the old setting; unknown combined backends fall back to unprocessed Core Audio Tap.
        defaults.removeObject(forKey: "microphoneVoiceProcessing")
        defaults.set(captureBackend.rawValue, forKey: "captureBackend")
        calendarSubscription = calendar.$events.sink { [weak self] events in
            self?.refreshMeetingSelection(events: events)
        }
        historySubscription = history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if startBackgroundServices {
            Task { await history.refresh(root: outputDirectory) }
            refreshMicrophones()
            refreshAccess()
            startTimer()
            shouldCheckDependenciesAfterAttachment = !transcriptionReady
        }

        let session = self.recordingSessionService
        sessionObservation = Task { [weak self] in
            let stream = await session.observe()
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                self?.applySessionSnapshot(snapshot)
            }
        }
        processingObservation = Task { [weak self] in
            let stream = await proc.observe()
            for await update in stream {
                guard !Task.isCancelled else { break }
                switch update {
                case .snapshot(let snapshot): self?.applyProcessingSnapshot(snapshot)
                case .event(let event): await self?.handleProcessingEvent(event)
                }
            }
        }
    }

    deinit {
        sessionObservation?.cancel()
        processingObservation?.cancel()
    }

    private func applySessionSnapshot(_ snapshot: RecordingSessionSnapshot) {
        sessionAttached = true
        defer { checkDependenciesAfterAttachment() }
        recordingMeetingID = snapshot.meetingID
        sessionStopping = false
        switch snapshot.phase {
        case .recording(let url, let date):
            isRecording = true
            activeRecordingURL = url
            lastFileURL = url
            startedAt = date
            elapsed = max(0, Date().timeIntervalSince(date))
            lastRecordingTitle = snapshot.meetingSummary ?? "Запись встречи"
            status = "Идёт запись"
        case .stopping(let url):
            isRecording = false
            activeRecordingURL = url
            sessionStopping = true
            status = "Сохранение…"
        case .idle, .cancelledShort, .failed:
            isRecording = false
            activeRecordingURL = nil
        }
    }

    private func applyProcessingSnapshot(_ snapshot: ProcessingService.Snapshot) {
        processingAttached = true
        defer { checkDependenciesAfterAttachment() }
        preparationState = snapshot.preparation
        transcriptionJobs = snapshot.jobCount
        history.progress = snapshot.progress
        if snapshot.preparation != .idle {
            diagnosticReport = snapshot.preparation == .preparing ? "Скачивание и проверка моделей…" : "Проверка транскрибации…"
        }
        if !isRecording, !sessionStopping, let job = snapshot.active ?? snapshot.queued.first {
            lastFileURL = job.recordingURL
            lastRecordingTitle = history.entry(job.recordingURL)?.title ?? "Запись встречи"
            transcriptionState = .running(snapshot.progress[job.recordingURL])
        }
    }

    private func checkDependenciesAfterAttachment() {
        guard sessionAttached, processingAttached, shouldCheckDependenciesAfterAttachment else { return }
        shouldCheckDependenciesAfterAttachment = false
        Task { await checkTranscription(prepare: false) }
    }

    private func handleProcessingEvent(_ event: ProcessingService.Event) async {
        await history.synchronize()
        switch event {
        case .enqueued(let job), .started(let job):
            syncProcessingPresentation(job.recordingURL)
        case .progress(let job, let progress):
            history.progress[job.recordingURL] = progress
            syncProcessingPresentation(job.recordingURL)
        case .completed(let job, _, let warning), .failed(let job, _, let warning), .cancelled(let job, let warning):
            history.progress.removeValue(forKey: job.recordingURL)
            if let warning { history.reportError(warning) }
            syncProcessingPresentation(job.recordingURL)
        case .persistenceWarning(_, let warning): history.reportError(warning)
        case .dependenciesChecked(let output, let succeeded):
            transcriptionReady = succeeded
            diagnosticReport = output + (succeeded ? "\nТранскрибация готова." : "\nПроверка транскрибации не пройдена.")
        }
    }

    func toggleRecording() {
        guard sessionAttached, processingAttached, !sessionStopping, !isBusy, !diagnosticRunning else { return }
        if !isRecording {
            calendar.refresh()
            meetingSelectionTimer?.invalidate()
        }
        isBusy = true
        if isRecording {
            Task { _ = await stopRecording() }
        } else {
            let meeting = selectedMeeting
            Task { await startRecording(meeting: meeting) }
        }
    }

    func setWindowVisible(_ visible: Bool) {
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        updateLevelVisibility()
        refreshMeetingSelection()
    }

    private func refreshMeetingSelection(events: [MeetingContext]? = nil) {
        meetingSelectionTimer?.invalidate()
        guard !isRecording, !isBusy else { return }
        let events = events ?? calendar.events
        let now = Date()
        var selection = meetingSelection
        selection.refresh(events: events, now: now)
        if selection != meetingSelection { meetingSelection = selection }
        guard isWindowVisible, let boundary = MeetingSelection.nextBoundary(events: events, now: now) else { return }
        meetingSelectionTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, boundary.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshMeetingSelection() }
        }
    }

    func setAudioCheckVisible(_ visible: Bool) {
        guard isAudioCheckVisible != visible else { return }
        isAudioCheckVisible = visible
        updateLevelVisibility()
        if !visible {
            Task { if !isAudioCheckVisible { await endAudioCheck() } }
        }
    }

    private func updateLevelVisibility() {
        let active = (isRecording && isWindowVisible) || (isCheckingAudio && isAudioCheckVisible)
        guard active != isLevelDisplayActive else { return }
        isLevelDisplayActive = active
        levels.setActive(active)
    }

    func toggleAudioCheck() {
        guard !isRecording, !isBusy, !diagnosticRunning, isAudioCheckVisible else { return }
        if isCheckingAudio {
            isCheckingAudio = false
            Task { await endAudioCheck() }
            return
        }
        isCheckingAudio = true
        audioCheckTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            await self?.endAudioCheck()
        }
        Task { await startLevelMonitor(reportErrors: true) }
    }

    private func endAudioCheck() async {
        isCheckingAudio = false
        audioCheckTimeout?.cancel()
        audioCheckTimeout = nil
        await stopLevelMonitor()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    func openFolder() {
        NSWorkspace.shared.open(outputDirectory)
    }

    func revealLastFile() {
        guard let lastFileURL else {
            openFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: lastFileURL.path) ? lastFileURL : lastFileURL.deletingLastPathComponent()])
    }

    func openTranscript() {
        guard let lastFileURL, let entry = history.entry(lastFileURL) else { return }
        onOpenTranscript?(entry)
    }

    var canResetCache: Bool {
        !preventsTermination
    }

    func resetCache() async {
        guard canResetCache else { return }
        localDiagnosticRunning = true
        isResettingCache = true
        defer { localDiagnosticRunning = false; isResettingCache = false }
        let directory = RecorderDiagnostics.dataDirectory
        let recordings = outputDirectory
        do {
            let bytes = try await Task.detached {
                let targets = try RecorderDiagnostics.cacheDirectories(in: directory, recordings: recordings)
                return targets.reduce(Int64(0)) { $0 + RecorderDiagnostics.preparationProgress(in: $1).bytes }
            }.value
            let alert = NSAlert()
            alert.messageText = "Сбросить кэш транскрибации?"
            alert.informativeText = "Будет удалён локальный кэш моделей и подготовки Meeting Companion (" +
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) +
                "). Для транскрибации потребуется скачать их заново. Записи, тексты, настройки и разрешения сохранятся."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Отмена")
            alert.addButton(withTitle: "Сбросить кэш")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            transcriptionReady = false
            diagnosticReport = "Удаление локального кэша моделей и подготовки…"
            try await Task.detached {
                try RecorderDiagnostics.resetCache(in: directory, recordings: recordings)
            }.value
            preparationProgress = nil
            transcriptionState = .idle
            diagnosticReport = "Кэш сброшен. Нажмите «Скачать модели» перед транскрибацией."
        } catch {
            diagnosticReport = "Ошибка сброса кэша: " + error.localizedDescription
        }
    }

    func checkTranscription(prepare: Bool) async {
        guard sessionAttached, processingAttached, !sessionStopping, !diagnosticRunning, !isRecording, !isBusy, transcriptionJobs == 0 else { return }
        localDiagnosticRunning = true
        diagnosticStartedAt = Date()
        defer { localDiagnosticRunning = false; diagnosticStartedAt = nil; preparationProgress = nil }
        diagnosticAccess = RecorderDiagnostics.access(coreAudioTap: captureBackend == .coreAudioTap, captureCheck: captureCheck)
        diagnosticReport = prepare ? "Скачивание и проверка моделей…" : "Проверка транскрибации…"
        do {
            let directory = outputDirectory
            try await Task.detached { try RecorderDiagnostics.checkFolder(directory) }.value
            let result = try await processingService.checkOrPrepareDependencies(
                prepare: prepare,
                parakeet: improveTerms
            ) { [weak self] output in
                Task { @MainActor in
                    guard let self, self.diagnosticRunning else { return }
                    self.diagnosticReport = "Папка записей: OK\n" + output
                }
            }
            transcriptionReady = result.succeeded
            diagnosticReport = "Папка записей: OK\n" + result.output +
                (result.succeeded ? "\nТранскрибация готова." : "\nНе удалось подготовить транскрибацию. Подробности выше.")
            calendar.refresh()
        } catch { diagnosticReport = "Ошибка: " + error.localizedDescription }
    }

    private func updateCaptureCheck(succeeded: Bool) {
        let result = RecorderDiagnostics.Access(name: "Системный звук",
            message: succeeded ? "захват проверен" : "проверка захвата не пройдена",
            state: succeeded ? .granted : .denied)
        guard captureCheck != result else { return }
        captureCheck = result
        refreshAccess()
    }

    func refreshAccess() {
        let access = RecorderDiagnostics.access(coreAudioTap: captureBackend == .coreAudioTap, captureCheck: captureCheck)
        if access != diagnosticAccess { diagnosticAccess = access }
    }

    func refreshPreparationProgress() {
        guard diagnosticRunning, !progressProbeRunning else { return }
        progressProbeRunning = true
        Task {
            defer { progressProbeRunning = false }
            let progress = await Task.detached(priority: .utility) {
                RecorderDiagnostics.preparationProgress(in: RecorderDiagnostics.dataDirectory)
            }.value
            if diagnosticRunning && preparationProgress != progress { preparationProgress = progress }
        }
    }

    func transcribeLastRecording() {
        guard let lastFileURL else { return }
        retryRecording(lastFileURL)
    }

    func retryRecording(_ recording: URL) {
        guard sessionAttached, processingAttached, !sessionStopping, !isBusy, !diagnosticRunning, let entry = history.entry(recording), !entry.phase.isWorking else { return }
        if !entry.capabilities.canRetry {
            history.reportError(entry.capabilities.reason ?? "Исходные WAV отсутствуют или недоступны; повторная обработка невозможна.")
            return
        }
        if !isRecording {
            lastFileURL = recording
            lastRecordingTitle = entry.title
            recordingSaveError = nil
        }
        enqueue(recording, stopped: nil)
    }

    func startMeeting(_ meeting: MeetingContext?) {
        guard sessionAttached, processingAttached, !sessionStopping, !isBusy, !diagnosticRunning else { return }
        calendar.refresh()
        let latest = meeting.flatMap { selected in calendar.events.first { $0.id == selected.id } }
        if meeting != nil && latest == nil {
            errorMessage = "Встреча изменилась или удалена. Выберите её заново; текущая запись продолжается."
            return
        }
        isBusy = true
        Task {
            if isRecording {
                guard await stopRecording() else { return }
                isBusy = true
            }
            selectedMeeting = latest
            await startRecording(meeting: latest)
        }
    }

    private func enqueue(_ recording: URL, stopped: StoppedRecording?) {
        guard let entry = history.entry(recording) else { return }
        if stopped == nil && !entry.capabilities.canRetry {
            history.reportError(entry.capabilities.reason ?? "Исходные WAV отсутствуют или недоступны; повторная обработка невозможна.")
            return
        }
        let settings = ProcessingJobSettings(
            parakeet: improveTerms,
            echoCancellation: echoCancellation
        )
        if lastFileURL == recording && !isRecording {
            capsuleTimer?.invalidate()
            capsuleDismissed = false
            syncProcessingPresentation(recording)
        }
        Task {
            _ = await processingService.enqueue(
                recordingURL: recording,
                settings: settings,
                stoppedCapture: stopped
            )
        }
    }

    private func syncProcessingPresentation(_ recording: URL) {
        guard lastFileURL == recording, !isRecording, let entry = history.entry(recording) else { return }
        transcriptionWarnings = entry.problems.map(\.message)
        switch entry.phase {
        case .completed: transcriptionState = .completed(entry.currentTranscriptURL ?? entry.currentResultURL ?? entry.transcript)
        case .failed, .interrupted:
            transcriptionState = .failed(entry.problems.last(where: \.isError)?.message ?? entry.status)
        case .queued, .saving, .processing: transcriptionState = .running(history.progress[recording])
        case .recording: transcriptionState = .idle
        }
        if entry.phase == .completed || entry.phase == .failed {
            capsuleTimer?.invalidate()
            capsuleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.lastFileURL == recording, !self.isRecording else { return }
                    self.dismissCapsule()
                }
            }
        }
    }

    func refreshMicrophones() {
        microphones = Microphones.available()
    }

    func restartLevelMonitor() {
        guard isCheckingAudio, !isRecording else { return }
        Task { await startLevelMonitor(reportErrors: true) }
    }


    private func startRecording(meeting: MeetingContext?) async {
        defer {
            isBusy = false
            refreshMeetingSelection()
            restartLevelMonitor()
        }
        var attemptedURL: URL?
        do {
            errorMessage = nil
            recordingSaveError = nil
            microphoneMuted = false
            microphoneState = .receiving
            mutedMicrophoneActivity = false
            muteActivity = MutedMicrophoneActivity()
            await endAudioCheck()
            let directory = outputDirectory
            let outputURL = try await Task.detached {
                RecordingEntry.canonicalURL(try RecordingPaths.makeOutputURL(outputDirectory: directory))
            }.value
            attemptedURL = outputURL
            let recorder = try await Recorder(
                outputURL: outputURL,
                outputKind: .m4a,
                microphoneDeviceID: selectedMicrophoneDeviceID,
                backend: captureBackend,
                onLevels: { [weak self] mic, system in
                    Task { @MainActor in
                        guard let self else { return }
                        if system.isFinite { self.updateCaptureCheck(succeeded: true) }
                        if mic.isFinite {
                            let active = self.muteActivity.receive(mic, muted: self.microphoneMuted)
                            if active != self.mutedMicrophoneActivity { self.mutedMicrophoneActivity = active }
                        }
                        guard self.isWindowVisible else { return }
                        self.levels.receive(mic: self.microphoneMuted ? 0 : mic, system: system)
                    }
                }
            )
            let controller = PlatformAudioCaptureController(recorder: recorder)
            let sessionConfig = RecordingSessionService.Configuration(
                outputURL: outputURL,
                meetingID: meeting?.id,
                meetingSummary: meeting?.summary,
                captureBackend: captureBackend.rawValue,
                microphoneDeviceUID: selectedMicrophoneDeviceID,
                prompt: nil,
                controller: controller
            )
            _ = try await recordingSessionService.start(configuration: sessionConfig)
            self.recorder = recorder

            recordingMeetingID = meeting?.id
            activeRecordingURL = outputURL
            lastFileURL = outputURL
            capsuleTimer?.invalidate()
            mainWindowRequested = false
            recordingCancelled = false
            transcriptionState = .idle
            capsuleDismissed = false
            lastRecordingTitle = meeting?.summary ?? "Запись встречи"
            elapsed = 0
            levels.reset()
            startedAt = Date()
            recordingOvertime = RecordingOvertime(start: startedAt!, meetingEnd: meeting?.end)
            status = "Идёт запись"
            await history.synchronize()
            if let meeting {
                calendar.acknowledge(meeting)
                do { try await Task.detached { try meeting.save(beside: outputURL) }.value }
                catch {
                    let message = "Запись идёт, но контекст не сохранён: " + error.localizedDescription
                    errorMessage = message
                    await history.updateStatus(outputURL) { $0.addProblem(.context, message) }
                }
            }
            await history.updateStatus(outputURL) { $0.readArtifacts() }
        } catch {
            if let url = attemptedURL {
                let message = error.localizedDescription
                let title = meeting?.summary ?? "Запись встречи"
                let entry = await Task.detached {
                    var entry = RecordingEntry(recording: url, date: Date(), title: title, phase: .failed)
                    entry.addProblem(.capture, message, error: true)
                    return entry
                }.value
                await history.put(entry)
            }
            updateCaptureCheck(succeeded: false)
            errorMessage = error.localizedDescription
            status = "Ошибка"
        }
    }

    private func stopRecording() async -> Bool {
        defer {
            isBusy = false
            refreshMeetingSelection()
            restartLevelMonitor()
        }
        do {
            status = "Сохранение…"
            self.recorder = nil
            levels.reset()

            let stopResult = try await recordingSessionService.stop(elapsed: elapsed)
            elapsed = stopResult.duration
            lastFileURL = stopResult.outputURL
            activeRecordingURL = nil
            recordingMeetingID = nil
            errorMessage = nil
            mutedMicrophoneActivity = false

            if stopResult.wasCancelledShort {
                lastFileURL = nil
                transcriptionState = .idle
                transcriptionWarnings = []
                capsuleDismissed = true
                status = "Короткая запись отменена"
                recordingCancelled = true
                capsuleTimer?.invalidate()
                capsuleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.recordingCancelled = false }
                }
                return true
            }

            status = "Исходные дорожки сохранены"
            await history.synchronize()
            for warning in stopResult.warnings { history.reportError(warning) }
            enqueue(stopResult.outputURL, stopped: stopResult.stoppedCapture as? StoppedRecording)
            return true
        } catch {
            self.recorder = nil
            recordingSaveError = error.localizedDescription
            if let url = activeRecordingURL {
                let message = error.localizedDescription
                await history.updateStatus(url) { $0.phase = .failed; $0.addProblem(.saving, message, error: true) }
            }
            activeRecordingURL = nil
            recordingMeetingID = nil
            errorMessage = "Не удалось завершить запись: " + error.localizedDescription
            status = "Ошибка"
            return false
        }
    }

    private func startLevelMonitor(reportErrors: Bool) async {
        let previous = levelMonitorTask
        previous?.cancel()
        let task = Task { @MainActor [self] in
            await previous?.value
            await stopCurrentLevelMonitor()
            guard !Task.isCancelled, isCheckingAudio, !isRecording, !isBusy, recordingSaveError == nil, isAudioCheckVisible else { return }

            assert(levelMonitor == nil, "Previous audio preview must stop before another starts")
            do {
                let monitor = try await AudioLevelMonitor(
                    microphoneDeviceID: selectedMicrophoneDeviceID,
                    backend: captureBackend,
                        onLevels: { [weak self] mic, system in
                        Task { @MainActor in
                            guard let self else { return }
                            if system.isFinite { self.updateCaptureCheck(succeeded: true) }
                            guard self.isAudioCheckVisible else { return }
                            self.levels.receive(mic: mic, system: system)
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                try await monitor.start()
                if Task.isCancelled {
                    try? await monitor.stop()
                    return
                }
                levelMonitor = monitor
                if reportErrors && status == "Не удалось проверить звук" {
                    errorMessage = nil
                    status = "Готов к записи"
                }
            } catch {
                if !Task.isCancelled {
                    updateCaptureCheck(succeeded: false)
                    isCheckingAudio = false
                    audioCheckTimeout?.cancel()
                    if reportErrors {
                        errorMessage = error.localizedDescription
                        status = "Не удалось проверить звук"
                    }
                }
            }
        }
        levelMonitorTask = task
        await task.value
    }

    private func stopLevelMonitor() async {
        let previous = levelMonitorTask
        previous?.cancel()
        let task = Task { @MainActor [self] in
            await previous?.value
            await stopCurrentLevelMonitor()
        }
        levelMonitorTask = task
        await task.value
    }

    private func stopCurrentLevelMonitor() async {
        guard let monitor = levelMonitor else { return }
        levelMonitor = nil
        try? await monitor.stop()
        levels.reset()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isRecording, !self.isBusy, let startedAt = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(startedAt)
                    let state = await self.recordingSessionService.currentMicrophoneState()
                    if state != self.microphoneState {
                        self.microphoneState = state
                        self.status = self.microphoneCaptureHint.isEmpty ? "Идёт запись" : self.microphoneCaptureHint
                    }
                }

            }
        }
    }

}

struct ContentView: View {
    @ObservedObject var viewModel: RecorderViewModel
    let showSettings: () -> Void
    @StateObject private var windowState = AppWindowState()

    var body: some View {
        Group {
            if viewModel.showsRecordingCapsule {
                if viewModel.showsProcessingCapsule {
                    ProcessingCapsuleView(viewModel: viewModel)
                        .frame(width: 348, height: 140)
                } else {
                    CompactRecordingView(viewModel: viewModel)
                        .frame(width: AppWindowState.recordingCapsuleSize.width,
                               height: viewModel.showsOvertimeReminder ? AppWindowState.overtimeCapsuleHeight : AppWindowState.recordingCapsuleSize.height)
                }
            } else {
                RecorderWorkspaceView(model: viewModel, showSettings: showSettings)
                    .frame(minWidth: 820, minHeight: 500)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    pageButton("Запись", symbol: "record.circle", page: .recording)
                    pageButton("История", symbol: "clock", page: .history)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Настройки…", systemImage: "gearshape", action: showSettings)
                    .labelStyle(.iconOnly)
                    .help("Настройки")
            }
        }
        .background(WindowAccessor { window in
            windowState.attach(window)
        })
        .onChange(of: [viewModel.showsRecordingCapsule, viewModel.showsProcessingCapsule, viewModel.showsOvertimeReminder]) { _, modes in
            let isRecording = modes[0]
            if !isRecording { viewModel.setWindowVisible(false) }
            if isRecording { viewModel.calendar.setMainWindowVisible(false) }
            windowState.setCapsuleMode(isRecording, processing: modes[1], overtime: modes[2])
            if !isRecording && viewModel.mainWindowRequested { windowState.window?.makeKeyAndOrderFront(nil) }
        }
    }
    private func pageButton(_ title: String, symbol: String, page: RecorderViewModel.MainPage) -> some View {
        Button { viewModel.mainPage = page } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                Text(title).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(viewModel.mainPage == page ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(viewModel.mainPage == page ? .isSelected : [])
    }
}

struct LevelMetersView: View {
    @ObservedObject var levels: AudioLevels

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Уровни звука")
                .font(.headline)
            LevelMeterRow(label: "Микрофон", level: levels.mic, color: .green)
            LevelMeterRow(label: "Система", level: levels.system, color: .blue)
        }
    }
}

struct CompactLevelMetersView: View {
    @ObservedObject var levels: AudioLevels

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "mic.fill").frame(width: 14)
                ThinMeter(level: levels.mic, color: .green)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Микрофон")
            .accessibilityValue("\(Int(levels.mic * 100)) процентов")
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.2.fill").frame(width: 14)
                ThinMeter(level: levels.system, color: .blue)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Системный звук")
            .accessibilityValue("\(Int(levels.system * 100)) процентов")
        }
        .font(.system(size: 10))
        .foregroundStyle(.primary)
    }
}

struct LevelMeterRow: View {
    let label: String
    let level: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 84, alignment: .leading)
                .foregroundStyle(.secondary)
            ThinMeter(level: level, color: color)
        }
    }
}

struct ThinMeter: View {
    let level: Double
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < Int(level * 10) ? color : Color.secondary.opacity(0.18))
            }
        }
        .frame(height: 8)
    }

}
