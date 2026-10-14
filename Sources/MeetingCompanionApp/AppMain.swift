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

@MainActor
final class AppWindowState: ObservableObject {
    weak var window: NSWindow?
    private var normalFrame: NSRect?
    private let normalSize = NSSize(width: 680, height: 560)
    private let compactSize = NSSize(width: 330, height: 122)

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.title = "Meeting Companion"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.minSize = normalSize
    }

    func setRecordingMode(_ isRecording: Bool) {
        guard let window else { return }

        if isRecording {
            if normalFrame == nil {
                normalFrame = window.frame
            }

            window.minSize = compactSize
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let origin = NSPoint(
                x: screenFrame.maxX - compactSize.width - 24,
                y: screenFrame.maxY - compactSize.height - 24
            )

            window.level = .floating
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.setFrame(NSRect(origin: origin, size: compactSize), display: true, animate: true)
            window.orderFrontRegardless()
        } else {
            window.level = .normal
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.minSize = normalSize

            if let normalFrame {
                let restoredFrame = NSRect(
                    x: normalFrame.minX,
                    y: normalFrame.maxY - max(normalFrame.height, normalSize.height),
                    width: max(normalFrame.width, normalSize.width),
                    height: max(normalFrame.height, normalSize.height)
                )
                window.setFrame(restoredFrame, display: true, animate: true)
            } else {
                window.setContentSize(normalSize)
                window.center()
            }
            self.normalFrame = nil
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
    @Published var elapsed: TimeInterval = 0
    @Published var status = "Готов к записи"
    @Published var lastFileURL: URL?
    @Published var lastTranscriptURL: URL?
    @Published var transcriptionJobs = 0
    @Published var transcriptionReady = UserDefaults.standard.bool(forKey: "transcriptionPrepared") {
        didSet { UserDefaults.standard.set(transcriptionReady, forKey: "transcriptionPrepared") }
    }
    @Published var transcriptionStatus = ""
    @Published var diagnosticAccess = RecorderDiagnostics.access()
    @Published var diagnosticReport = ""
    @Published var diagnosticRunning = false
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
    @Published var micLevel = 0.0
    @Published var systemLevel = 0.0

    private var isWindowVisible = true
    private var recorder: Recorder?
    private var levelMonitor: AudioLevelMonitor?
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
        Task { await startLevelMonitor(reportErrors: true) }
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
        Task {
            if visible { await startLevelMonitor(reportErrors: false) }
            else { await stopLevelMonitor() }
        }
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

    func checkTranscription(prepare: Bool) async {
        guard !diagnosticRunning, !isRecording, !isBusy, transcriptionJobs == 0 else { return }
        diagnosticRunning = true
        diagnosticStartedAt = Date()
        defer { diagnosticRunning = false; diagnosticStartedAt = nil; preparationProgress = nil }
        diagnosticAccess = RecorderDiagnostics.access()
        diagnosticReport = prepare ? "Скачивание и проверка моделей…" : "Проверка транскрибации…"
        do {
            try RecorderDiagnostics.checkFolder(outputDirectory)
            let result = try await Transcription.checkDependencies(prepare: prepare) { [weak self] output in
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

    func refreshAccess() {
        let access = RecorderDiagnostics.access()
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
        transcriptionStatus = "Распознавание речи…"
        Task {
            defer { transcriptionJobs -= 1 }
            do {
                let transcript = try await Transcription.run(recording: recording)
                await TranscriptionNotifications.shared.completed(recording: recording)
                guard lastFileURL == recording else { return }
                lastTranscriptURL = transcript
                transcriptionStatus = "Текст готов"
            } catch {
                guard lastFileURL == recording else { return }
                transcriptionStatus = error.localizedDescription
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
        guard !isRecording else { return }
        Task { await startLevelMonitor(reportErrors: true) }
    }

    private func setSelectedMicrophone(_ microphoneID: String, persist: Bool) {
        shouldPersistMicrophoneSelection = persist
        selectedMicrophoneID = microphoneID
        shouldPersistMicrophoneSelection = true
    }

    private func startRecording() async {
        defer { isBusy = false }
        let meeting = selectedMeeting
        do {
            errorMessage = nil
            await stopLevelMonitor()
            let outputURL = try RecordingPaths.makeOutputURL(outputDirectory: outputDirectory)
            let recorder = try await Recorder(
                outputURL: outputURL,
                outputKind: .m4a,
                microphoneDeviceID: selectedMicrophoneDeviceID,
                onLevels: { [weak self] mic, system in
                    Task { @MainActor in
                        guard let self else { return }
                        if mic.isFinite {
                            self.micLevel = mic
                        }
                        if system.isFinite {
                            self.systemLevel = system
                        }
                    }
                }
            )
            try await recorder.start()
            self.recorder = recorder

            lastFileURL = outputURL
            lastTranscriptURL = nil
            isRecording = true
            elapsed = 0
            micLevel = 0
            systemLevel = 0
            startedAt = Date()
            status = "Идёт запись"
            transcriptionStatus = ""
            if let meeting {
                calendar.acknowledge(meeting)
                do { try meeting.save(beside: outputURL) }
                catch { errorMessage = "Запись идёт, но контекст не сохранён: " + error.localizedDescription }
            }
        } catch {
            errorMessage = error.localizedDescription
            status = "Ошибка"
            await startLevelMonitor(reportErrors: false)
        }
    }

    private func stopRecording() async {
        defer { isBusy = false }
        do {
            status = "Сохранение…"
            guard let recorder else { throw RecorderError.notConfigured }
            let result = try await recorder.stop()
            self.recorder = nil
            isRecording = false
            micLevel = 0
            systemLevel = 0
            elapsed = result.duration
            lastFileURL = result.outputURL
            errorMessage = nil
            status = "Запись сохранена · \(formatBytes(result.fileSize))"
            transcribe(result.outputURL)
            await startLevelMonitor(reportErrors: false)
        } catch {
            self.recorder = nil
            isRecording = false
            micLevel = 0
            systemLevel = 0
            status = "Ошибка"
            errorMessage = error.localizedDescription
            await startLevelMonitor(reportErrors: false)
        }
    }

    private func startLevelMonitor(reportErrors: Bool) async {
        await stopLevelMonitor()
        guard !isRecording, isWindowVisible else { return }

        do {
            let monitor = try await AudioLevelMonitor(
                microphoneDeviceID: selectedMicrophoneDeviceID,
                onLevels: { [weak self] mic, system in
                    Task { @MainActor in
                        guard let self else { return }
                        if mic.isFinite {
                            self.micLevel = mic
                        }
                        if system.isFinite {
                            self.systemLevel = system
                        }
                    }
                }
            )
            try await monitor.start()
            levelMonitor = monitor
            if reportErrors && status == "Не удалось проверить звук" {
                errorMessage = nil
                status = "Готов к записи"
            }
        } catch {
            levelMonitor = nil
            if reportErrors && (status == "Готов к записи" || status == "Не удалось проверить звук") {
                errorMessage = error.localizedDescription
                status = "Не удалось проверить звук"
            }
        }
    }

    private func stopLevelMonitor() async {
        guard let levelMonitor else { return }
        try? await levelMonitor.stop()
        self.levelMonitor = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isRecording, let startedAt = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
                self.micLevel *= 0.86
                self.systemLevel *= 0.86
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
            if viewModel.isRecording {
                CompactRecordingView(viewModel: viewModel)
                    .frame(width: 330, height: 122)
            } else {
                FullRecorderView(viewModel: viewModel, showSettings: showSettings)
                    .frame(width: 680, height: 560)
            }
        }
        .background(WindowAccessor { window in
            windowState.attach(window)
        })
        .onChange(of: viewModel.isRecording) { _, isRecording in
            windowState.setRecordingMode(isRecording)
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
                    Text("Подготовка транскрибации…").foregroundStyle(.secondary)
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

            LevelMetersView(micLevel: viewModel.micLevel, systemLevel: viewModel.systemLevel)

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
                    if viewModel.transcriptionJobs > 0 { ProgressView().controlSize(.small) }
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
        }
        .padding(22)
    }
}

struct CompactRecordingView: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(.red)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text("Идёт запись")
                    .font(.headline)
                Text(viewModel.elapsedText)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                CompactLevelMetersView(micLevel: viewModel.micLevel, systemLevel: viewModel.systemLevel)
            }

            Spacer()

            Button(action: viewModel.toggleRecording) {
                Text("Стоп")
                    .frame(width: 70)
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(viewModel.isBusy)
        }
        .padding(18)
    }
}

struct LevelMetersView: View {
    let micLevel: Double
    let systemLevel: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Уровни звука")
                .font(.headline)
            LevelMeterRow(label: "Микрофон", level: micLevel, color: .green)
            LevelMeterRow(label: "Система", level: systemLevel, color: .blue)
        }
    }
}

struct CompactLevelMetersView: View {
    let micLevel: Double
    let systemLevel: Double

    var body: some View {
        VStack(spacing: 3) {
            ThinMeter(level: micLevel, color: .green)
            ThinMeter(level: systemLevel, color: .blue)
        }
        .frame(width: 118)
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
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: max(3, proxy.size.width * min(max(level, 0), 1)))
                    .animation(.linear(duration: 0.08), value: level)
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
