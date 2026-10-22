import AppKit
import SwiftUI
import MeetingCompanionCore

struct RecorderSettingsView: View {
    @ObservedObject var model: RecorderViewModel
    let page: Page
    @AppStorage("receiveBetaUpdates") private var receiveBetaUpdates = false

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

    @MainActor static func makeController(model: RecorderViewModel) -> SettingsTabViewController {
        let controller = SettingsTabViewController()
        controller.tabStyle = .toolbar
        for page in Page.allCases {
            let view = RecorderSettingsView(model: model, page: page)
            let item = NSTabViewItem(viewController: NSHostingController(rootView: view))
            item.identifier = page.rawValue
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
        .disclosureGroupStyle(FullWidthDisclosureStyle())
        .frame(minWidth: 580, idealWidth: 620, minHeight: 400, idealHeight: 520)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onAppear {
            model.refreshAccess()
            model.refreshMicrophones()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refreshAccess()
            model.refreshPreparationProgress()
        }
    }

    private var recording: some View {
        Group {
            Section("Оформление") {
                Picker("Тема", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            }
            Section {
                Picker("Системный звук", selection: $model.captureBackend) {
                    Text("Core Audio Tap (рекомендуется)").tag(AudioCaptureBackend.coreAudioTap)
                    Text("ScreenCaptureKit (при проблемах)").tag(AudioCaptureBackend.screenCaptureKit)
                }
                .disabled(model.isRecording || model.isBusy || model.isCheckingAudio || model.diagnosticRunning)
                Picker("Микрофон", selection: $model.selectedMicrophoneID) {
                    Text("Системный по умолчанию").tag(RecorderViewModel.defaultMicrophoneID)
                    if model.selectedMicrophoneID != RecorderViewModel.defaultMicrophoneID,
                       !model.microphones.contains(where: { $0.id == model.selectedMicrophoneID }) {
                        Text("Выбранный микрофон недоступен").tag(model.selectedMicrophoneID)
                    }
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
                Text(model.captureBackend == .coreAudioTap
                    ? "Захват системного звука без экрана. Если возникнут проблемы, переключитесь на ScreenCaptureKit."
                    : "Запасной вариант при проблемах с Core Audio Tap. Записывается только звук, без видео.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Эхоподавление микрофона", isOn: $model.echoCancellation)
                    .disabled(model.isRecording || model.isBusy || model.transcriptionJobs > 0)
            } header: {
                Text("Обработка после записи")
            } footer: {
                Text("Для записи через динамики. WebRTC AEC3 очищает копию микрофона перед распознаванием; может терять части слов. Исходники и общая запись сохраняются без обработки. С наушниками лучше выключить.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Сохранение") {
                LabeledContent("Папка записей") {
                    Text(model.outputDirectory.path).lineLimit(2).textSelection(.enabled)
                    Button("Выбрать…", action: model.chooseFolder)
                        .disabled(model.isRecording || model.isBusy || model.diagnosticRunning)
                }
            }
            Section {
                Toggle("Получать бета-версии", isOn: $receiveBetaUpdates)
            } header: {
                Text("Обновления")
            } footer: {
                Text("Экспериментальные версии могут содержать ошибки. Настройка применяется при следующей проверке обновлений через Sparkle. Отключение не откатывает установленную версию и не отменяет уже подготовленное обновление.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Button("Сбросить кэш…") { Task { await model.resetCache() } }
                    .disabled(!model.canResetCache)
            } footer: {
                Text("Удаляются только модели и Python-окружение приложения. Записи сохраняются.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var diagnostics: some View {
        Group {
            Section("Разрешения") {
                ForEach(model.diagnosticAccess) { access in
                    LabeledContent(access.name) {
                        HStack(spacing: 8) {
                            Text(access.message).multilineTextAlignment(.trailing).textSelection(.enabled)
                            Circle().fill(access.state == .granted ? Color.green : access.state == .pending ? .secondary : .red)
                                .frame(width: 9, height: 9).accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                Button("Разрешения macOS") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                }
            }
            Section {
                Button(model.isCheckingAudio ? "Завершить проверку звука" : "Проверить звук", action: model.toggleAudioCheck)
                    .disabled(model.isRecording || model.isBusy || model.diagnosticRunning)
                if model.isCheckingAudio { LevelMetersView(levels: model.levels) }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                Button("Проверить транскрибацию") { check(prepare: false) }
                    .disabled(model.diagnosticRunning || model.isRecording || model.isBusy || model.transcriptionJobs > 0)
                DisclosureGroup("Подробности") { diagnosticLog }
            } header: {
                Text("Проверки")
            } footer: {
                Text("Включи звук и скажи несколько слов. Проверка выключится через 30 секунд, при уходе из диагностики или закрытии настроек.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            if calendar.isLoadingCalendars {
                ProgressView("Загружаем календари…")
            } else if calendar.calendars.isEmpty {
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
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 12).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Развёрнуто" : "Свёрнуто")
            if configuration.isExpanded { configuration.content }
        }
    }
}

@MainActor
final class SettingsTabViewController: NSTabViewController {
    var onSelectionChange: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelectionChange?()
    }
}
