import AppKit
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

    @Published var outputDirectory: URL = UserDefaults.standard.string(forKey: "recordingsDirectory")
        .map { URL(fileURLWithPath: $0) } ?? RecordingPaths.defaultOutputDirectory {
        didSet { UserDefaults.standard.set(outputDirectory.path, forKey: "recordingsDirectory") }
    }
    let calendar = MeetingCalendar()
    @Published var selectedMeeting: MeetingContext?
    @Published var isBusy = false
    @Published var isRecording = false
    @Published var recordingSaveError: String?

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
    var showsRecordingCapsule: Bool {
        isRecording || recordingSaveError != nil || (!capsuleDismissed && transcriptionState != .idle)
    }
    var showsProcessingCapsule: Bool { !isRecording && recordingSaveError == nil && showsRecordingCapsule }

    func dismissCapsule() {
        capsuleDismissed = true
    }

    func revealTranscript() {
        guard let transcript = lastTranscriptURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([transcript])
    }
    @Published var elapsed: TimeInterval = 0
    @Published var status = "Готов к записи"
    @Published var lastFileURL: URL?
    @Published private(set) var transcriptionState: TranscriptionState = .idle
    var lastTranscriptURL: URL? { transcriptionState.transcript }
    @Published var transcriptionJobs = 0
    @Published var transcriptionReady = UserDefaults.standard.bool(forKey: "transcriptionPrepared") {
        didSet { UserDefaults.standard.set(transcriptionReady, forKey: "transcriptionPrepared") }
    }
    var transcriptionStatus: String { transcriptionState.text }
    @Published var captureBackend = AudioCaptureBackend(rawValue: UserDefaults.standard.string(forKey: "captureBackend") ?? "") ?? .screenCaptureKit {
        didSet {
            UserDefaults.standard.set(captureBackend.rawValue, forKey: "captureBackend")
            captureCheck = nil
            refreshAccess()
        }
    }
    private var captureCheck: RecorderDiagnostics.Access?
    @Published var diagnosticAccess = RecorderDiagnostics.access(coreAudioTap: UserDefaults.standard.string(forKey: "captureBackend") == AudioCaptureBackend.coreAudioTap.rawValue)
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
            if shouldPersistMicrophoneSelection {
                UserDefaults.standard.set(selectedMicrophoneID, forKey: RecorderViewModel.selectedMicrophoneIDKey)
            }
        }
    }
    let levels = AudioLevels()

    private var isWindowVisible = false
    @Published private(set) var isCheckingAudio = false
    private var audioCheckTimeout: Task<Void, Never>?
    private var recorder: Recorder?
    private var levelMonitor: AudioLevelMonitor?
    private var levelMonitorTask: Task<Void, Never>?
    private var startedAt: Date?
    private var timer: Timer?
    private var shouldPersistMicrophoneSelection = true

    var elapsedText: String {
        formatClock(elapsed)
    }

    var selectedMicrophoneDeviceID: String? {
        selectedMicrophoneID == Self.defaultMicrophoneID ? nil : selectedMicrophoneID
    }

    init() {
        refreshMicrophones()
        startTimer()
        if !transcriptionReady { Task { await checkTranscription(prepare: false) } }
    }

    func toggleRecording() {
        guard !isBusy, !diagnosticRunning else { return }
        isBusy = true
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    func setWindowVisible(_ visible: Bool) {
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        levels.setActive(visible)
        Task {
            if !visible { await endAudioCheck() }
        }
    }

    func toggleAudioCheck() {
        guard !isRecording, !isBusy, !diagnosticRunning, isWindowVisible else { return }
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
        NSWorkspace.shared.activateFileViewerSelecting([lastFileURL])
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

    func checkTranscription(prepare: Bool) async {
        guard !diagnosticRunning, !isRecording, !isBusy, transcriptionJobs == 0 else { return }
        diagnosticRunning = true
        diagnosticStartedAt = Date()
        defer { diagnosticRunning = false; diagnosticStartedAt = nil; preparationProgress = nil }
        diagnosticAccess = RecorderDiagnostics.access(coreAudioTap: captureBackend == .coreAudioTap, captureCheck: captureCheck)
        diagnosticReport = prepare ? "Скачивание и проверка моделей…" : "Проверка транскрибации…"
        do {
            try RecorderDiagnostics.checkFolder(outputDirectory)
            let result = try await Transcription.checkDependencies(prepare: prepare, parakeet: improveTerms) { [weak self] output in
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
        guard let lastFileURL, !isRecording, !isBusy, !diagnosticRunning, transcriptionJobs == 0 else { return }
        transcribe(lastFileURL)
    }

    private func transcribe(_ recording: URL) {
        transcriptionJobs += 1
        capsuleDismissed = false
        transcriptionWarnings = []
        transcriptionState = .running(nil)
        let selectedTerms = improveTerms
        Task { [self] in
            defer { transcriptionJobs -= 1 }
            do {
                var useParakeet = selectedTerms
                let available = try await Transcription.checkDependencies(availability: true, parakeet: useParakeet)
                if !available.succeeded {
                    let alert = NSAlert()
                    alert.messageText = "Выбранный режим ещё не подготовлен"
                    alert.informativeText = "Запись сохранена. " +
                        (useParakeet ? "Для выбранного режима нужен Parakeet (около 740 МБ) и основные модели. " : "Основные модели ещё не подготовлены. ") +
                        "Скачать недостающие файлы? Это может занять несколько минут."
                    alert.addButton(withTitle: "Скачать")
                    if useParakeet { alert.addButton(withTitle: "Только GigaAM") }
                    alert.addButton(withTitle: "Позже")
                    let answer = alert.runModal()
                    if useParakeet && answer == .alertSecondButtonReturn {
                        useParakeet = false
                        let basic = try await Transcription.checkDependencies(availability: true)
                        guard basic.succeeded else {
                            throw NSError(domain: "Transcription", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                "Основные модели тоже не подготовлены. Запись сохранена; скачайте модели в настройках."])
                        }
                    } else if answer == .alertFirstButtonReturn {
                        let prepared = try await Transcription.checkDependencies(prepare: true, parakeet: useParakeet) { [weak self] output in
                            Task { @MainActor in self?.diagnosticReport = output }
                        }
                        guard prepared.succeeded else {
                            throw NSError(domain: "Transcription", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                "Не удалось подготовить модели. Запись сохранена; подробности в настройках и диагностике."])
                        }
                        transcriptionReady = true
                    } else {
                        if lastFileURL == recording { transcriptionState = .idle }
                        return
                    }
                }
                let transcript = try await Transcription.run(recording: recording, parakeet: useParakeet) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.lastFileURL == recording,
                              case .running = self.transcriptionState else { return }
                        if let warning = progress.warning {
                            if !self.transcriptionWarnings.contains(warning) { self.transcriptionWarnings.append(warning) }
                            return
                        }
                        let next = TranscriptionState.running(progress)
                        if self.transcriptionState != next { self.transcriptionState = next }
                    }
                }
                guard lastFileURL == recording else { return }
                transcriptionState = .completed(transcript)
            } catch {
                guard lastFileURL == recording else { return }
                transcriptionState = .failed(error.localizedDescription)
            }
        }
    }

    func refreshMicrophones() {
        microphones = Microphones.available()
        if selectedMicrophoneID != Self.defaultMicrophoneID && !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
            setSelectedMicrophone(Self.defaultMicrophoneID, persist: false)
        }
    }

    func restartLevelMonitor() {
        guard isCheckingAudio, !isRecording else { return }
        Task { await startLevelMonitor(reportErrors: true) }
    }

    private func setSelectedMicrophone(_ microphoneID: String, persist: Bool) {
        shouldPersistMicrophoneSelection = persist
        selectedMicrophoneID = microphoneID
        shouldPersistMicrophoneSelection = true
    }

    private func startRecording() async {
        defer {
            isBusy = false
            restartLevelMonitor()
        }
        let meeting = selectedMeeting
        do {
            errorMessage = nil
            recordingSaveError = nil
            await endAudioCheck()
            let outputURL = try RecordingPaths.makeOutputURL(outputDirectory: outputDirectory)
            let recorder = try await Recorder(
                outputURL: outputURL,
                outputKind: .m4a,
                microphoneDeviceID: selectedMicrophoneDeviceID,
                backend: captureBackend,
                onLevels: { [weak self] mic, system in
                    Task { @MainActor in
                        guard let self else { return }
                        if system.isFinite { self.updateCaptureCheck(succeeded: true) }
                        guard self.isWindowVisible else { return }
                        self.levels.receive(mic: mic, system: system)
                    }
                }
            )
            try await recorder.start()
            self.recorder = recorder

            lastFileURL = outputURL
            transcriptionState = .idle
            capsuleDismissed = false
            lastRecordingTitle = meeting?.summary ?? "Запись встречи"
            isRecording = true
            elapsed = 0
            levels.reset()
            startedAt = Date()
            status = "Идёт запись"
            if let meeting {
                calendar.acknowledge(meeting)
                do { try meeting.save(beside: outputURL) }
                catch { errorMessage = "Запись идёт, но контекст не сохранён: " + error.localizedDescription }
            }
        } catch {
            updateCaptureCheck(succeeded: false)
            errorMessage = error.localizedDescription
            status = "Ошибка"
        }
    }

    private func stopRecording() async {
        defer {
            isBusy = false
            restartLevelMonitor()
        }
        do {
            status = "Сохранение…"
            guard let recorder else { throw RecorderError.notConfigured }
            let result = try await recorder.stop()
            self.recorder = nil
            isRecording = false
            levels.reset()
            elapsed = result.duration
            lastFileURL = result.outputURL
            errorMessage = nil
            status = "Запись сохранена · \(formatBytes(result.fileSize))"
            transcribe(result.outputURL)
        } catch {
            self.recorder = nil
            recordingSaveError = error.localizedDescription
            isRecording = false
            levels.reset()
            status = "Ошибка"
            errorMessage = error.localizedDescription
        }
    }

    private func startLevelMonitor(reportErrors: Bool) async {
        let previous = levelMonitorTask
        previous?.cancel()
        let task = Task { @MainActor [self] in
            await previous?.value
            await stopCurrentLevelMonitor()
            guard !Task.isCancelled, isCheckingAudio, !isRecording, !isBusy, recordingSaveError == nil, isWindowVisible else { return }

            assert(levelMonitor == nil, "Previous audio preview must stop before another starts")
            do {
                let monitor = try await AudioLevelMonitor(
                    microphoneDeviceID: selectedMicrophoneDeviceID,
                    backend: captureBackend,
                    onLevels: { [weak self] mic, system in
                        Task { @MainActor in
                            guard let self else { return }
                            if system.isFinite { self.updateCaptureCheck(succeeded: true) }
                            guard self.isWindowVisible else { return }
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
                        .frame(width: 288, height: 76)
                }
            } else {
                FullRecorderView(viewModel: viewModel, showSettings: showSettings)
                    .frame(width: 680, height: 560)
            }
        }
        .background(WindowAccessor { window in
            windowState.attach(window)
        })
        .onChange(of: viewModel.showsRecordingCapsule) { _, isRecording in
            if !isRecording { viewModel.setWindowVisible(false) }
            windowState.setCapsuleMode(isRecording, processing: viewModel.showsProcessingCapsule)
        }
        .onChange(of: viewModel.showsProcessingCapsule) { _, processing in
            windowState.setCapsuleMode(viewModel.showsRecordingCapsule, processing: processing)
        }
    }
}

struct FullRecorderView: View {
    @ObservedObject var viewModel: RecorderViewModel
    let showSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meeting Companion")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(viewModel.status)
                        .foregroundStyle(viewModel.isRecording ? .red : .secondary)
                }

                Spacer()

                Text(viewModel.elapsedText)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
            }

            HStack(spacing: 12) {
                Button(action: viewModel.toggleRecording) {
                    Text(viewModel.isRecording ? "Стоп" : "Записать")
                        .frame(width: 96)
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(viewModel.isRecording ? .red : .accentColor)
                .disabled(viewModel.isBusy || viewModel.diagnosticRunning)

                Button("Записи", action: viewModel.openFolder)
                    .controlSize(.large)

                Button("Настройки…", action: showSettings)
                    .controlSize(.large)
            }

            if viewModel.diagnosticRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(viewModel.isResettingCache ? "Сброс кэша…" : "Подготовка транскрибации…").foregroundStyle(.secondary)
                }
            } else if !viewModel.transcriptionReady {
                HStack {
                    Text("Для транскрибации скачай модели один раз.").font(.caption)
                    Spacer()
                    Button("Скачать модели") {
                        Task { await viewModel.checkTranscription(prepare: true) }
                    }
                    .disabled(viewModel.isBusy || viewModel.transcriptionJobs > 0)
                }
            }

            MeetingPicker(viewModel: viewModel, calendar: viewModel.calendar)

            Button(viewModel.isCheckingAudio ? "Завершить проверку звука" : "Проверить звук", action: viewModel.toggleAudioCheck)
                .disabled(viewModel.isBusy || viewModel.diagnosticRunning)
            if viewModel.isCheckingAudio {
                LevelMetersView(levels: viewModel.levels)
                Text("Проверка выключится через 30 секунд.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Микрофон")
                    .font(.headline)

                HStack {
                    Picker("Микрофон", selection: $viewModel.selectedMicrophoneID) {
                        Text("По умолчанию").tag(RecorderViewModel.defaultMicrophoneID)
                        ForEach(viewModel.microphones) { microphone in
                            Text(microphone.name).tag(microphone.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(viewModel.isRecording)
                    .onChange(of: viewModel.selectedMicrophoneID) { _, _ in
                        viewModel.restartLevelMonitor()
                    }

                    Button("Обновить", action: viewModel.refreshMicrophones)
                        .disabled(viewModel.isRecording)
                }
            }

            if let lastFileURL = viewModel.lastFileURL {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Последняя запись").font(.headline)
                        Spacer()
                        Button("Показать файл", action: viewModel.revealLastFile)
                        if viewModel.lastTranscriptURL != nil {
                            Button("Открыть текст", action: viewModel.openTranscript)
                        } else if viewModel.transcriptionJobs == 0 && viewModel.transcriptionReady {
                            Button("Получить текст", action: viewModel.transcribeLastRecording)
                                .disabled(viewModel.isBusy || viewModel.diagnosticRunning)
                        }
                    }
                    Text(lastFileURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if !viewModel.transcriptionStatus.isEmpty {
                HStack {
                    if viewModel.transcriptionJobs > 0 { Image(systemName: "text.magnifyingglass") }
                    Text(viewModel.transcriptionStatus)
                        .font(.caption).textSelection(.enabled).lineLimit(3)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Spacer()
            HStack {
                Spacer()
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(22)
    }
}

struct CompactRecordingView: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(viewModel.recordingSaveError == nil ? Color.red : Color.orange)
                .frame(width: 7, height: 7)
                .accessibilityLabel(viewModel.recordingSaveError != nil ? "Ошибка сохранения" : (viewModel.isBusy ? "Сохранение записи" : "Идёт запись"))

            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.elapsedText)
                    .font(.system(size: 25, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                if let error = viewModel.recordingSaveError {
                    Text("Ошибка сохранения")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(error)
                } else if viewModel.isBusy {
                    Text("Сохранение…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !viewModel.isBusy && viewModel.recordingSaveError == nil {
                CompactLevelMetersView(levels: viewModel.levels)
                    .frame(width: 64)
            }
            Group {
                if viewModel.isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Сохранение записи")
                } else if viewModel.recordingSaveError != nil {
                    Button {
                        viewModel.recordingSaveError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Закрыть. Подробности ошибки доступны в основном окне.")
                    .accessibilityLabel("Закрыть сообщение об ошибке")
                } else {
                    Button(action: viewModel.toggleRecording) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12))
                    }
                    .tint(.red)
                    .help("Остановить запись")
                    .accessibilityLabel("Остановить запись")
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .frame(width: 34, height: 34)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(MeetingOverlaySurface(capsule: true))
        .padding(4)
    }
}

struct ProcessingCapsuleView: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(viewModel.lastRecordingTitle).font(.headline).lineLimit(1)
                Spacer()
                Button(action: viewModel.dismissCapsule) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Скрыть обработку")
            }
            switch viewModel.transcriptionState {
            case .running(let progress):
                HStack(alignment: .top) {
                    Image(systemName: "text.magnifyingglass").accessibilityHidden(true)
                    Text(viewModel.transcriptionStatus).font(.caption).lineLimit(2)
                    Spacer(minLength: 0)
                    if let step = progress?.step, let steps = progress?.steps {
                        Text("\(step)/\(steps)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let progress, progress.total > 1 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .accessibilityLabel("Обработано окон")
                }
            case .completed:
                Label(viewModel.transcriptionWarnings.isEmpty ? "Транскрипт готов" : "Текст готов с предупреждениями",
                      systemImage: viewModel.transcriptionWarnings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                Button("Открыть папку", action: viewModel.revealTranscript)
                    .help(viewModel.transcriptionWarnings.joined(separator: "\n"))
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            case .failed(let message):
                Text(message).font(.caption).lineLimit(2).foregroundStyle(.red)
                HStack {
                    Button("Повторить", action: viewModel.transcribeLastRecording)
                        .disabled(viewModel.transcriptionJobs > 0)
                    Button("Открыть папку", action: viewModel.revealLastFile)
                }
                .buttonStyle(.bordered)
            case .idle:
                Text("Запись сохранена").font(.caption)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .modifier(MeetingOverlaySurface())
        .padding(4)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

struct MeetingOverlaySurface: ViewModifier {
    var capsule = false

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: capsule ? 36 : 24)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 1))
        }
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

struct MeetingPicker: View {
    @ObservedObject var viewModel: RecorderViewModel
    @ObservedObject var calendar: MeetingCalendar

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Встреча", selection: $viewModel.selectedMeeting) {
                Text("Без встречи").tag(Optional<MeetingContext>.none)
                ForEach(calendar.events) { event in
                    Text(event.start.formatted(date: .omitted, time: .shortened) + " · " + event.summary)
                        .tag(Optional(event))
                }
                if let selected = viewModel.selectedMeeting, !calendar.events.contains(selected) {
                    Text(selected.summary).tag(Optional(selected))
                }
            }
            .disabled(viewModel.isBusy || viewModel.isRecording)
            if !calendar.message.isEmpty {
                Text(calendar.message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
