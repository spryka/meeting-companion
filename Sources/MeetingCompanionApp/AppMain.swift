import AppKit
import Combine
import Foundation
import MeetingCompanionCore
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

    @Published var appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appAppearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appAppearance")
            NSApp.appearance = appearance.value
        }
    }

    @Published var outputDirectory: URL = UserDefaults.standard.string(forKey: "recordingsDirectory")
        .map { URL(fileURLWithPath: $0) } ?? RecordingPaths.defaultOutputDirectory {
        didSet {
            UserDefaults.standard.set(outputDirectory.path, forKey: "recordingsDirectory")
            Task { await history.refresh(root: outputDirectory) }
        }
    }
    let calendar = MeetingCalendar()
    let history = RecordingHistory()
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
    private struct ProcessingJob {
        let recording: URL
        let stopped: StoppedRecording?
        let parakeet: Bool
        let echoCancellation: Bool
    }
    private let processingQueue = RecordingWorkQueue()
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
        guard isRecording, !isBusy, let recorder else { return }
        let muted = !microphoneMuted
        recorder.setMicrophoneMuted(muted)
        microphoneMuted = muted
        microphoneState = recorder.microphoneState()
        muteActivity = MutedMicrophoneActivity()
        mutedMicrophoneActivity = false
        levels.reset()
    }

    @Published var capsuleDismissed = false
    @Published private(set) var transcriptionWarnings: [String] = []
    @Published private(set) var lastRecordingTitle = "Запись встречи"
    @Published var improveTerms = UserDefaults.standard.bool(forKey: "improveTechnicalTerms") {
        didSet {
            UserDefaults.standard.set(improveTerms, forKey: "improveTechnicalTerms")
            transcriptionReady = false
            let selected = improveTerms
            Task {
                let result = try? await Transcription.checkDependencies(availability: true, parakeet: selected)
                guard improveTerms == selected else { return }
                transcriptionReady = result?.succeeded ?? false
            }
        }
    }
    @Published var echoCancellation = UserDefaults.standard.bool(forKey: "echoCancellation") {
        didSet { UserDefaults.standard.set(echoCancellation, forKey: "echoCancellation") }
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
    @Published var transcriptionReady = false
    var transcriptionStatus: String {
        if let url = lastFileURL, let entry = history.entry(url), [.queued, .saving].contains(entry.phase) { return entry.status + "…" }
        return transcriptionState.text
    }
    @Published var captureBackend = AudioCaptureBackend(rawValue: UserDefaults.standard.string(forKey: "captureBackend") ?? "") ?? .coreAudioTap {
        didSet {
            UserDefaults.standard.set(captureBackend.rawValue, forKey: "captureBackend")
            captureCheck = nil
            refreshAccess()
        }
    }
    private var captureCheck: RecorderDiagnostics.Access?
    @Published var diagnosticAccess = RecorderDiagnostics.access(coreAudioTap: (AudioCaptureBackend(rawValue: UserDefaults.standard.string(forKey: "captureBackend") ?? "") ?? .coreAudioTap) == .coreAudioTap)
    @Published var diagnosticReport = ""
    @Published var diagnosticRunning = false
    @Published private(set) var isResettingCache = false
    @Published var diagnosticStartedAt: Date?
    @Published var preparationProgress: RecorderDiagnostics.PreparationProgress?
    private var progressProbeRunning = false
    @Published var errorMessage: String?
    @Published var microphones: [MicrophoneDevice] = []
    @Published var selectedMicrophoneID = UserDefaults.standard.string(forKey: RecorderViewModel.selectedMicrophoneIDKey) ?? RecorderViewModel.defaultMicrophoneID {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: RecorderViewModel.selectedMicrophoneIDKey)
        }
    }
    let levels = AudioLevels()
    var preventsTermination: Bool {
        isRecording || isBusy || diagnosticRunning || transcriptionJobs > 0 || isResettingCache || isCheckingAudio
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

    init() {
        // Retire the old setting; unknown combined backends fall back to unprocessed Core Audio Tap.
        UserDefaults.standard.removeObject(forKey: "microphoneVoiceProcessing")
        UserDefaults.standard.set(captureBackend.rawValue, forKey: "captureBackend")
        calendarSubscription = calendar.$events.sink { [weak self] events in
            self?.refreshMeetingSelection(events: events)
        }
        historySubscription = history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        Task { await history.refresh(root: outputDirectory) }
        refreshMicrophones()
        startTimer()
        Task { await checkTranscription(prepare: false, availability: true) }
    }

    func toggleRecording() {
        guard !isBusy, !diagnosticRunning else { return }
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
        guard let lastTranscriptURL else { return }
        NSWorkspace.shared.open(lastTranscriptURL)
    }

    var canResetCache: Bool {
        !isRecording && !isBusy && !isCheckingAudio && !diagnosticRunning && transcriptionJobs == 0
    }

    func resetCache() async {
        guard canResetCache else { return }
        diagnosticRunning = true
        isResettingCache = true
        defer { diagnosticRunning = false; isResettingCache = false }
        let directory = RecorderDiagnostics.dataDirectory
        let recordings = outputDirectory
        do {
            let bytes = try await Task.detached {
                let targets = try RecorderDiagnostics.cacheDirectories(in: directory, recordings: recordings)
                return targets.reduce(Int64(0)) { $0 + RecorderDiagnostics.preparationProgress(in: $1).bytes }
            }.value
            let alert = NSAlert()
            alert.messageText = "Сбросить кэш транскрибации?"
            alert.informativeText = "Будут удалены модели и Python-окружение Meeting Companion (" +
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) +
                "). Для транскрибации потребуется скачать их заново. Записи, тексты, настройки и разрешения сохранятся."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Отмена")
            alert.addButton(withTitle: "Сбросить кэш")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            transcriptionReady = false
            diagnosticReport = "Удаление моделей и Python-окружения…"
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

    func checkTranscription(prepare: Bool, availability: Bool = false) async {
        guard !diagnosticRunning, !isRecording, !isBusy, transcriptionJobs == 0 else { return }
        diagnosticRunning = true
        diagnosticStartedAt = Date()
        defer { diagnosticRunning = false; diagnosticStartedAt = nil; preparationProgress = nil }
        diagnosticAccess = RecorderDiagnostics.access(coreAudioTap: captureBackend == .coreAudioTap, captureCheck: captureCheck)
        diagnosticReport = prepare ? "Скачивание и проверка моделей…" : "Проверка транскрибации…"
        do {
            try RecorderDiagnostics.checkFolder(outputDirectory)
            let result = try await Transcription.checkDependencies(prepare: prepare, availability: availability, parakeet: improveTerms) { [weak self] output in
                Task { @MainActor in
                    guard let self, self.diagnosticRunning else { return }
                    self.diagnosticReport = "Папка записей: OK\n" + output
                }
            }
            transcriptionReady = result.succeeded
            diagnosticReport = "Папка записей: OK\n" + result.output +
                (result.succeeded ? "\nТранскрибация готова." : availability
                    ? "\nНе хватает моделей или Python-окружения. Нажмите «Скачать модели» на экране записи."
                    : "\nНе удалось подготовить транскрибацию. Подробности выше.")
            calendar.refresh()
        } catch {
            transcriptionReady = false
            diagnosticReport = "Ошибка: " + error.localizedDescription
        }
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
        guard !isBusy, !diagnosticRunning, let entry = history.entry(recording), !entry.phase.isWorking else { return }
        if !isRecording {
            lastFileURL = recording
            lastRecordingTitle = entry.title
            recordingSaveError = nil
        }
        enqueue(recording, stopped: nil)
    }

    func startMeeting(_ meeting: MeetingContext?) {
        guard !isBusy, !diagnosticRunning else { return }
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
        history.update(recording) { $0.phase = .queued }
        let job = ProcessingJob(recording: recording, stopped: stopped, parakeet: improveTerms,
                                echoCancellation: echoCancellation)
        transcriptionJobs += 1
        if lastFileURL == recording && !isRecording {
            capsuleTimer?.invalidate()
            capsuleDismissed = false
            syncProcessingPresentation(recording)
        }
        processingQueue.enqueue { [self] in
            await processRecording(job)
            transcriptionJobs -= 1
        }
    }

    private func syncProcessingPresentation(_ recording: URL) {
        guard lastFileURL == recording, !isRecording, let entry = history.entry(recording) else { return }
        transcriptionWarnings = entry.problems.map(\.message)
        switch entry.phase {
        case .completed: transcriptionState = .completed(entry.transcript)
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

    private func processRecording(_ job: ProcessingJob) async {
        let recording = job.recording
        history.update(recording) { entry in
            entry.phase = .saving
            // Retry replaces only processing problems; capture loss cannot be repaired by ASR.
            entry.problems.removeAll { $0.stage == .transcription || $0.stage == .saving }
        }
        syncProcessingPresentation(recording)
        if let stopped = job.stopped {
            let result = await stopped.finish()
            history.update(recording) { entry in
                entry.duration = result.duration
                entry.readArtifacts()
                for warning in result.warnings where warning.hasPrefix("Не удалось сохранить журнал") { entry.addProblem(.saving, warning) }
            }
        } else if !FileManager.default.fileExists(atPath: recording.path), let entry = history.entry(recording) {
            do {
                try await exportMixedAudio(from: ["host", "remote"].map { entry.rawBase.appendingPathExtension($0 + ".capture.caf") }, to: recording)
                do { try entry.clearExportFailure() }
                catch { history.update(recording) { $0.addProblem(.saving, "Аудио собрано, но журнал не обновлён: " + error.localizedDescription) } }
            } catch {
                history.update(recording) { $0.addProblem(.saving, "Общая запись не собрана; пробуем распознать WAV: " + error.localizedDescription) }
            }
        }
        do {
            let available = try await Transcription.checkDependencies(availability: true, parakeet: job.parakeet)
            guard available.succeeded else {
                transcriptionReady = false
                throw NSError(domain: "Transcription", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Не хватает моделей выбранного режима. Скачайте их в настройках и нажмите «Повторить обработку». Аудио сохранено."])
            }
            history.update(recording) { $0.phase = .processing }
            syncProcessingPresentation(recording)
            _ = try await Transcription.run(recording: recording, parakeet: job.parakeet,
                                            echoCancellation: job.echoCancellation) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.history.entry(recording)?.phase == .processing else { return }
                    if let warning = progress.warning {
                        let source = progress.channel.map { $0 == "host" ? "Микрофон: " : "Системный звук: " } ?? ""
                        let reported = ["Попыток восстановления", "При захвате", "Сбой захвата", "Во время записи переставали", "Общая запись не собрана"].contains { warning.hasPrefix($0) }
                        if !reported { self.history.update(recording) { $0.addProblem(.transcription, source + warning) } }
                    } else { self.history.progress[recording] = progress }
                    self.syncProcessingPresentation(recording)
                }
            }
            history.update(recording) { entry in entry.phase = .completed; entry.readArtifacts() }
        } catch {
            let stage = history.progress[recording]?.text ?? "Подготовка транскрибации"
            history.update(recording) {
                $0.phase = .failed
                $0.readArtifacts()
                $0.addProblem(.transcription, stage + "\n" + error.localizedDescription, error: true)
            }
        }
        history.progress[recording] = nil
        syncProcessingPresentation(recording)
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
            let outputURL = RecordingEntry.canonicalURL(try RecordingPaths.makeOutputURL(outputDirectory: outputDirectory))
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
            try await recorder.start()
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
            isRecording = true
            elapsed = 0
            levels.reset()
            startedAt = Date()
            recordingOvertime = RecordingOvertime(start: startedAt!, meetingEnd: meeting?.end)
            status = "Идёт запись"
            var entry = RecordingEntry(recording: outputURL, date: startedAt ?? Date(), title: lastRecordingTitle, phase: .recording)
            if let meeting {
                calendar.acknowledge(meeting)
                do { try meeting.save(beside: outputURL) }
                catch {
                    errorMessage = "Запись идёт, но контекст не сохранён: " + error.localizedDescription
                    entry.addProblem(.context, errorMessage!)
                }
            }
            entry.readArtifacts()
            history.put(entry)
        } catch {
            if let url = attemptedURL {
                var entry = RecordingEntry(recording: url, date: Date(), title: meeting?.summary ?? "Запись встречи", phase: .failed)
                entry.addProblem(.capture, error.localizedDescription, error: true)
                history.put(entry)
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
            guard let recorder else { throw RecorderError.notConfigured }
            let stopped = try await recorder.stopCapture()
            self.recorder = nil
            isRecording = false
            levels.reset()
            elapsed = stopped.duration
            lastFileURL = stopped.outputURL
            activeRecordingURL = nil
            recordingMeetingID = nil
            errorMessage = nil
            mutedMicrophoneActivity = false
            do {
                if try history.cancelShortRecording(stopped.outputURL, duration: stopped.duration) {
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
            } catch {
                let message = "Не удалось отменить короткую запись. Исходники сохранены: " + error.localizedDescription
                history.update(stopped.outputURL) {
                    $0.duration = stopped.duration
                    $0.phase = .interrupted
                    $0.addProblem(.saving, message, error: true)
                }
                status = "Короткая запись не обработана"
                errorMessage = message
                transcriptionState = .failed(message)
                return true
            }
            status = "Исходные дорожки сохранены"
            history.update(stopped.outputURL) { $0.duration = stopped.duration; $0.readArtifacts() }
            enqueue(stopped.outputURL, stopped: stopped)
            return true
        } catch {
            self.recorder = nil
            recordingSaveError = error.localizedDescription
            if let url = activeRecordingURL {
                history.update(url) { $0.phase = .failed; $0.addProblem(.saving, error.localizedDescription, error: true) }
            }
            activeRecordingURL = nil
            recordingMeetingID = nil
            isRecording = false
            levels.reset()
            status = "Ошибка"
            errorMessage = error.localizedDescription
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
                    if let state = self.recorder?.microphoneState(), state != self.microphoneState {
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
