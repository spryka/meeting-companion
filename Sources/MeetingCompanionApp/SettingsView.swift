import AppKit
import SwiftUI
import MeetingCompanionCore

struct RecorderSettingsView: View {
    @ObservedObject var model: RecorderViewModel
    let page: Page
    let showRecorder: () -> Void

    enum Page: String, CaseIterable {
        case recording = "Запись", transcription = "Транскрибация"
        case calendar = "Календарь", diagnostics = "Диагностика"

        var symbol: String {
            switch self {
            case .recording: "mic"
            case .transcription: "text.alignleft"
            case .calendar: "calendar"
            case .diagnostics: "stethoscope"
            }
        }
    }

    @MainActor static func makeController(model: RecorderViewModel,
        showRecorder: @escaping () -> Void) -> NSTabViewController {
        let controller = NSTabViewController()
        controller.tabStyle = .toolbar
        for page in Page.allCases {
            let view = RecorderSettingsView(model: model, page: page, showRecorder: showRecorder)
            let item = NSTabViewItem(viewController: NSHostingController(rootView: view))
            item.label = page.rawValue
            item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.rawValue)
            controller.addTabViewItem(item)
        }
        return controller
    }

    var body: some View {
        Form {
            switch page {
            case .recording: recording
            case .transcription: transcription
            case .calendar: CalendarSettingsView(calendar: model.calendar)
            case .diagnostics: diagnostics
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, idealWidth: 620, minHeight: 400, idealHeight: 520)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onAppear {
            model.refreshAccess()
            model.refreshMicrophones()
            model.calendar.refresh()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refreshAccess()
            model.refreshPreparationProgress()
        }
    }

    private var recording: some View {
        Group {
            Section {
                Picker("Системный звук", selection: $model.captureBackend) {
                    Text("ScreenCaptureKit").tag(AudioCaptureBackend.screenCaptureKit)
                    Text("Core Audio Tap (экспериментальный)").tag(AudioCaptureBackend.coreAudioTap)
                }
                .disabled(model.isRecording || model.isBusy || model.isCheckingAudio || model.diagnosticRunning)
                Picker("Микрофон", selection: $model.selectedMicrophoneID) {
                    Text("По умолчанию").tag(RecorderViewModel.defaultMicrophoneID)
                    ForEach(model.microphones) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                }
                .disabled(model.isRecording || model.isBusy)
                .onChange(of: model.selectedMicrophoneID) { _, _ in model.restartLevelMonitor() }
                Button("Обновить микрофоны", action: model.refreshMicrophones)
                    .disabled(model.isRecording || model.isBusy)
            } header: {
                Text("Источники звука")
            } footer: {
                Text(model.captureBackend == .screenCaptureKit
                    ? "Записывается только звук, без видео."
                    : "Захват без экрана. Возможны сбои аудиоустройств; длительные записи пока не проверены.")
            }
            Section("Сохранение") {
                LabeledContent("Папка записей") {
                    Text(model.outputDirectory.path).lineLimit(2).textSelection(.enabled)
                    Button("Выбрать…", action: model.chooseFolder)
                        .disabled(model.isRecording || model.isBusy || model.diagnosticRunning)
                }
            }
        }
    }

    private var transcription: some View {
        Group {
            Section {
                Toggle("Улучшать технические термины", isOn: $model.improveTerms)
                    .disabled(model.isRecording || model.isBusy || model.diagnosticRunning || model.transcriptionJobs > 0)
            } header: {
                Text("Распознавание")
            } footer: {
                Text("Parakeet — дополнительная модель, около 740 МБ. Возможны неверные замены; исходный текст GigaAM сохраняется в raw/.")
            }
            Section {
                LabeledContent("Состояние", value: model.diagnosticRunning ? "Идёт подготовка…" :
                    model.transcriptionReady ? "Готово" : "Требуется проверка или подготовка")
                HStack {
                    Button("Проверить") { check(prepare: false) }
                    Button("Скачать модели") { check(prepare: true) }
                }
                .disabled(model.diagnosticRunning || model.isRecording || model.isBusy || model.transcriptionJobs > 0)
                if let progress = model.preparationProgress {
                    LabeledContent("Файлы подготовки", value: ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file))
                    if let changed = progress.lastModified {
                        LabeledContent("Последнее изменение") { Text(changed, style: .relative) }
                    }
                }
                DisclosureGroup("Подробности") { diagnosticLog }
            } header: {
                Text("Модели")
            } footer: {
                Text("Загрузка может занять несколько минут. Затем транскрибация работает офлайн; записи никуда не отправляются.")
            }
            Section {
                Button("Сбросить кэш…") { Task { await model.resetCache() } }
                    .disabled(!model.canResetCache)
            } footer: {
                Text("Удаляются только модели и Python-окружение приложения. Записи сохраняются.")
            }
        }
    }

    private var diagnostics: some View {
        Group {
            Section("Разрешения") {
                ForEach(model.diagnosticAccess) { access in
                    LabeledContent(access.name) {
                        Circle().fill(access.state == .granted ? Color.green : access.state == .pending ? .orange : .red)
                            .frame(width: 9, height: 9).accessibilityHidden(true)
                        Text(access.message).textSelection(.enabled)
                    }
                }
                Button("Разрешения macOS") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                }
            }
            Section {
                Button("Проверить звук…", action: showRecorder)
                Button("Проверить транскрибацию") { check(prepare: false) }
                    .disabled(model.diagnosticRunning || model.isRecording || model.isBusy || model.transcriptionJobs > 0)
                DisclosureGroup("Подробности") { diagnosticLog }
            } header: {
                Text("Проверки")
            } footer: {
                Text("Проверка звука открывает основное окно. Нажми «Проверить звук» и включи воспроизведение.")
            }
        }
    }

    private var diagnosticLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.diagnosticReport).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    .id("diagnostic-log")
            }
            .frame(height: 150)
            .onChange(of: model.diagnosticReport) { _, _ in
                proxy.scrollTo("diagnostic-log", anchor: .bottom)
            }
        }
    }

    private func check(prepare: Bool) {
        Task { await model.checkTranscription(prepare: prepare) }
    }
}

private struct CalendarSettingsView: View {
    @ObservedObject var calendar: MeetingCalendar

    var body: some View {
        Section("Календари встреч") {
            if calendar.calendars.isEmpty {
                Text(calendar.message.isEmpty ? "Нет доступных календарей." : calendar.message)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(calendar.calendars, id: \.calendarIdentifier) { item in
                    Toggle(item.title + " · " + item.source.title, isOn: Binding(
                        get: { calendar.isSelected(item) },
                        set: { calendar.select(item, enabled: $0) }
                    ))
                }
            }
        }
        Section {
            Toggle("Только встречи со ссылкой на созвон", isOn: $calendar.requireCallLink)
        } header: {
            Text("Напоминания")
        } footer: {
            Text("Ссылки ищутся в URL, месте и описании встречи. Для очных встреч отключи фильтр или начни запись вручную.")
        }
    }
}
