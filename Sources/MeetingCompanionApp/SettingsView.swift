import ServiceManagement
import AppKit
import SwiftUI
import MeetingCompanionCore

struct RecorderSettingsView: View {
    @ObservedObject var model: RecorderViewModel
    let page: Page
    var onCheckForUpdates: (() -> Void)? = nil
    @AppStorage("receiveBetaUpdates") private var receiveBetaUpdates = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autostartError: String?

    enum Page: String, CaseIterable {
        case general = "Основные"
        case recording = "Запись", transcription = "Транскрибация"
        case calendar = "Календарь", diagnostics = "Диагностика"

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .recording: "mic"
            case .transcription: "text.alignleft"
            case .calendar: "calendar"
            case .diagnostics: "stethoscope"
            }
        }
        var introduction: String {
            switch self {
            case .general: "Оформление и поведение приложения."
            case .recording: "Источники звука и сохранение встреч."
            case .transcription: "Локальное распознавание и подготовка моделей."
            case .calendar: "Встречи для выбора перед записью и напоминаний."
            case .diagnostics: "Разрешения и проверки, если что-то работает не так."
            }
        }
        var icon: ODIcon {
            switch self {
            case .general: .settings
            case .recording: .mic
            case .transcription: .wave
            case .calendar: .calendar
            case .diagnostics: .shield
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.rawValue).font(.system(size: 20, weight: .semibold)).odLineBox(size: 20, height: 31)
                Text(page.introduction).font(.system(size: 13)).odLineBox(size: 13, height: 20.8).foregroundStyle(ODColors.muted)
            }
            switch page {
            case .general: general
            case .recording: recording
            case .transcription: transcription
            case .calendar: CalendarSettingsView(calendar: model.calendar)
            case .diagnostics: diagnostics
            }
        }
        .toggleStyle(.switch)
        .labeledContentStyle(ODSettingsLabeledStyle())
        .buttonStyle(ODButtonStyle(compact: true))
        .disclosureGroupStyle(FullWidthDisclosureStyle())
        .font(.system(size: 14))
        .foregroundStyle(ODColors.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var general: some View {
        Group {
            ODSettingsGroup("Оформление") {
                ODSettingsPicker(title: "Тема приложения", hint: "Системная тема меняется вместе с macOS.", selection: $model.appearance,
                    options: AppAppearance.allCases.map { ($0.title, $0) })
            }
            ODSettingsGroup("Поведение") {
                ODSettingsToggle("Запускать при входе", hint: "Чтобы запись была под рукой в строке меню.", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            autostartError = nil
                        } catch {
                            autostartError = "Автозапуск: " + error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                ))
                if let error = autostartError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                ODSettingsToggle("Следовать за текстом", hint: model.isFollowAvailable ? "Прокручивать транскрипт при воспроизведении." : "Автопрокрутка доступна при открытом тексте встречи.", isOn: Binding(
                    get: { model.isEditorFollowing },
                    set: { model.setEditorFollowing($0) }
                )).disabled(!model.isFollowAvailable)
            }
            ODSettingsGroup {
                LabeledContent("Проверка обновлений") {
                    Button("Проверить…") {
                        onCheckForUpdates?()
                    }
                    .disabled(model.isBusy || model.isRecording)
                }
                ODSettingsToggle("Получать бета-версии", hint: "Экспериментальные версии могут содержать ошибки.", isOn: $receiveBetaUpdates)
            } header: {
                Text("Обновления")
            } footer: {
                Text("Экспериментальные версии могут содержать ошибки. Настройка применяется при следующей проверке обновлений через Sparkle. Отключение бета-версий не откатывает установленную версию и не отменяет уже подготовленное обновление.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var recording: some View {
        Group {
            ODSettingsGroup("Источники звука") {
                let missing = model.selectedMicrophoneID != RecorderViewModel.defaultMicrophoneID && !model.microphones.contains { $0.id == model.selectedMicrophoneID }
                ODSettingsPicker(title: "Микрофон", hint: "Можно изменить и перед началом записи.", selection: $model.selectedMicrophoneID,
                    options: [("Системный по умолчанию", RecorderViewModel.defaultMicrophoneID)]
                        + (missing ? [("Выбранный микрофон недоступен", model.selectedMicrophoneID)] : [])
                        + model.microphones.map { ($0.name, $0.id) })
                .disabled(model.isRecording || model.isBusy)
                .onChange(of: model.selectedMicrophoneID) { _, _ in model.restartLevelMonitor() }

                LabeledContent("Уровень микрофона") {
                Button(model.audioCheckActionTitle(for: .recording)) {
                    model.toggleAudioCheck(from: .recording)
                }
                .disabled(model.isRecording || model.isBusy || model.diagnosticRunning)
                }
                if model.isCheckingAudio {
                    LevelMetersView(levels: model.levels)
                }

            }
            ODSettingsGroup {
                ODSettingsToggle("Эхоподавление микрофона", hint: "При разговоре через динамики. С наушниками лучше выключить.", isOn: $model.echoCancellation)
                    .disabled(model.isRecording || model.isBusy || model.transcriptionJobs > 0)
            } header: {
                Text("Обработка после записи")
            } footer: {
                Text("Перед распознаванием обрабатывается копия микрофона. Возможна потеря частей слов; исходное аудио сохраняется.")
            }
            ODSettingsGroup("Сохранение") {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Папка записей")
                        Text(model.outputDirectory.path).font(.system(size: 12)).foregroundStyle(ODColors.muted).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Выбрать…", action: model.chooseFolder)
                        .disabled(model.isRecording || model.isBusy || model.diagnosticRunning)
                }
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            DisclosureGroup("Дополнительно") {
                    ODSettingsPicker(title: "Захват системного звука", selection: $model.captureBackend,
                        options: [("Core Audio Tap (рекомендуется)", .coreAudioTap), ("ScreenCaptureKit (при проблемах)", .screenCaptureKit)])
                    .disabled(model.isRecording || model.isBusy || model.isCheckingAudio || model.diagnosticRunning)
                    Text(model.captureBackend == .coreAudioTap
                        ? "Захват системного звука без экрана. Если возникнут проблемы, переключитесь на ScreenCaptureKit."
                        : "Запасной вариант при проблемах с Core Audio Tap. Записывается только звук, без видео.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Обновить микрофоны", action: model.refreshMicrophones).disabled(model.isRecording || model.isBusy)
            }
        }
    }

    private var transcription: some View {
        Group {
            ODSettingsGroup {
                ODSettingsToggle("Улучшать технические термины", hint: "Дополнительная модель Parakeet, около 740 МБ.", isOn: $model.improveTerms)
                    .disabled(model.isRecording || model.isBusy || model.diagnosticRunning || model.transcriptionJobs > 0)
            } header: {
                Text("Распознавание")
            } footer: {
                Text("Parakeet — дополнительная модель, около 740 МБ. Возможны неверные замены; исходный текст GigaAM сохраняется в raw/.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ODSettingsGroup {
                LabeledContent {
                    Text(model.diagnosticStatusText).font(.system(size: 12)).foregroundStyle(model.transcriptionReady ? ODColors.green : ODColors.muted)
                } label: {
                    ODSettingsLabel("Состояние моделей", hint: "Готовность локального распознавания.")
                }
                if let summary = model.diagnosticSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Проверить") { check(prepare: false) }
                        Button("Скачать") { check(prepare: true) }
                    }
                } label: {
                    ODSettingsLabel("Подготовка транскрибации", hint: "Проверить модели или скачать компоненты.")
                }
                .disabled(model.diagnosticRunning || model.isRecording || model.isBusy || model.transcriptionJobs > 0)
                if let progress = model.preparationProgress {
                    LabeledContent("Файлы подготовки", value: "\(progress.fileCount) (\(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file)))")
                    if let changed = progress.lastModified {
                        LabeledContent("Последнее изменение") { Text(changed, style: .relative) }
                    }
                }
            } header: {
                Text("Модели и окружение")
            } footer: {
                Text("Модели загружаются и проверяются по SHA-256 один раз. Затем транскрибация работает офлайн; записи никуда не отправляются.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Технические подробности") { diagnosticLog }
            ODSettingsGroup {
                LabeledContent {
                    Button("Сбросить…") { Task { await model.resetCache() } }
                        .disabled(!model.canResetCache).foregroundStyle(ODColors.red)
                } label: {
                    ODSettingsLabel("Сбросить кэш моделей", hint: "Модели и окружение потребуется скачать снова.")
                }
            } header: {
                Text("Обслуживание")
            } footer: {
                Text("Удаляются только подпапки native-models и runtime приложения. Записи сохраняются.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var diagnostics: some View {
        Group {
            ODSettingsGroup("Разрешения") {
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
                LabeledContent {
                    Button("Разрешения macOS…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                    }
                } label: {
                    Text("Доступ к источникам и календарю").font(.system(size: 12)).foregroundStyle(ODColors.muted)
                }
            }
            ODSettingsGroup {
                LabeledContent {
                Button(model.audioCheckActionTitle(for: .diagnostics)) {
                    model.toggleAudioCheck(from: .diagnostics)
                }
                .disabled(model.isRecording || model.isBusy || model.diagnosticRunning)
                } label: {
                    ODSettingsLabel("Источники звука", hint: "Проверка двух каналов; остановится через 30 секунд.")
                }
                if model.isCheckingAudio {
                    LevelMetersView(levels: model.levels)
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("Проверки")
            } footer: {
                Text("Включи звук и скажи несколько слов. Проверка выключится через 30 секунд, при уходе из диагностики или закрытии настроек.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Журнал диагностики") { diagnosticLog }
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
        ODSettingsGroup("Календари встреч") {
            if calendar.isLoadingCalendars {
                ProgressView("Загружаем календари…")
            } else if !calendar.hasAccess {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Нет доступа к календарю macOS. Напоминания и список встреч недоступны, но запись работает вручную.")
                        .foregroundStyle(.secondary)
                    Button("Разрешения macOS") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                    }
                }
            } else if calendar.calendars.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(calendar.message.isEmpty ? "Календари не найдены." : calendar.message)
                        .foregroundStyle(.secondary)
                    Text("Не видны рабочие встречи? Подключите корпоративную учётную запись в системных Настройках macOS → Учётные записи в Интернете, затем включите Календари.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(calendar.calendars, id: \.calendarIdentifier) { item in
                    ODSettingsToggle(item.title + " · " + item.source.title, isOn: Binding(
                        get: { calendar.isSelected(item) },
                        set: { calendar.select(item, enabled: $0) }
                    ))
                }
                Text("Не видны рабочие встречи? Подключите корпоративную учётную запись в системных Настройках macOS → Учётные записи в Интернете, затем включите Календари.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        ODSettingsGroup {
            ODSettingsToggle("Только встречи со ссылкой на созвон", hint: "Ссылка ищется в адресе, месте и описании встречи.", isOn: $calendar.requireCallLink)
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

struct SettingsShell: View {
    @ObservedObject var model: RecorderViewModel
    @FocusState private var closeFocused: Bool
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Настройки").font(.system(size: 22, weight: .semibold)).odLineBox(size: 22, height: 29.7)
                        Text("Meeting Companion").font(.system(size: 12)).odLineBox(size: 12, height: 18.6).foregroundStyle(ODColors.muted)
                    }
                    Spacer()
                    Button { model.dismissSettings() } label: {
                        ODIconView(.close, size: 20, color: ODColors.muted).frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Закрыть настройки").focused($closeFocused)
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
                .background(ODColors.toolbar)
                if geometry.size.width <= 600 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Раздел настроек").font(.system(size: 12)).foregroundStyle(ODColors.muted)
                        ODMenuField(title: "Раздел настроек", selection: $model.settingsPage,
                            options: RecorderSettingsView.Page.allCases.map { ($0.rawValue, $0) })
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                } else {
                    HStack(spacing: 4) {
                        ForEach(RecorderSettingsView.Page.allCases, id: \.self) { page in
                            Button { model.settingsPage = page } label: {
                                VStack(spacing: 8) {
                                    ODIconView(page.icon, size: 22, color: page == model.settingsPage ? ODColors.selectedInk : ODColors.muted)
                                    Text(page.rawValue)
                                }
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 4).frame(height: 72)
                                .foregroundStyle(page == model.settingsPage ? ODColors.selectedInk : ODColors.muted)
                                .background(page == model.settingsPage ? ODColors.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(page == model.settingsPage ? ODColors.accent.opacity(0.16) : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(page == model.settingsPage ? .isSelected : [])
                        }
                    }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12).background(ODColors.toolbar)
                }
                Rectangle().fill(ODColors.line).frame(height: 1)
                ScrollView {
                    RecorderSettingsView(model: model, page: model.settingsPage, onCheckForUpdates: model.onCheckForUpdates)
                        .id(model.settingsPage)
                        .padding(.horizontal, geometry.size.width <= 600 ? 20 : 32)
                        .padding(.top, geometry.size.width <= 600 ? 20 : 24)
                        .padding(.bottom, geometry.size.width <= 600 ? 20 : 32)
                }
                Rectangle().fill(ODColors.line).frame(height: 1)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Изменения сохраняются автоматически")
                        Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · сборка \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                    }
                    .font(.system(size: 11)).foregroundStyle(ODColors.muted)
                    Spacer()
                    Button("Готово") { model.dismissSettings() }
                        .buttonStyle(ODButtonStyle(primary: true))
                        .keyboardShortcut(.cancelAction)
                }.padding(.horizontal, 24).padding(.vertical, 16)
            }
            .foregroundStyle(ODColors.ink).background(ODColors.surface)
        }
        .focusSection()
        .onAppear { closeFocused = true }
    }
}

struct WorkspaceSettingsOverlay: View {
    @ObservedObject var model: RecorderViewModel
    var body: some View {
        GeometryReader { bounds in
            ZStack {
                Color.black.opacity(0.3).contentShape(Rectangle()).onTapGesture { }
                    .accessibilityHidden(true)
                SettingsShell(model: model)
                    .frame(width: min(760, max(0, bounds.size.width - 32)), height: min(740, max(0, bounds.size.height - 32)))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityAddTraits(.isModal)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ODSettingsGroup<Content: View, Header: View, Footer: View>: View {
    let content: Content
    let header: Header
    let footer: Footer
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }
    init(_ title: String, @ViewBuilder content: () -> Content) where Header == Text, Footer == EmptyView {
        self.content = content(); header = Text(title); footer = EmptyView()
    }
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) where Header == EmptyView {
        self.content = content(); header = EmptyView(); self.footer = footer()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.font(.system(size: 12, weight: .semibold)).odLineBox(size: 12, height: 18.6).foregroundStyle(ODColors.muted).padding(.horizontal, 4)
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        row.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 16)
                        if index < rows.count - 1 { Rectangle().fill(ODColors.line).frame(height: 1) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(ODColors.toolbar, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ODColors.line))
            footer.font(.system(size: 12)).foregroundStyle(ODColors.muted).padding(.horizontal, 4)
        }
    }
}

private struct ODSettingsLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                configuration.content.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 12) { configuration.label; configuration.content }
        }
    }
}

private struct ODSettingsLabel: View {
    let title: String
    var hint: String? = nil
    init(_ title: String, hint: String? = nil) { self.title = title; self.hint = hint }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .medium)).odLineBox(size: 14, height: 21.7)
            if let hint { Text(hint).font(.system(size: 12)).odLineBox(size: 12, height: 19.2).foregroundStyle(ODColors.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ODSettingsToggle: View {
    let title: String
    var hint: String? = nil
    @Binding var isOn: Bool
    init(_ title: String, hint: String? = nil, isOn: Binding<Bool>) {
        self.title = title; self.hint = hint; _isOn = isOn
    }
    var body: some View {
        HStack(spacing: 20) {
            ODSettingsLabel(title, hint: hint)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(ODSettingsSwitchStyle())
        }
    }
}

private struct ODSettingsPicker<Selection: Hashable>: View {
    let title: String
    var hint: String? = nil
    @Binding var selection: Selection
    let options: [(String, Selection)]
    var body: some View {
        HStack(spacing: 20) {
            ODSettingsLabel(title, hint: hint)
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    Button { selection = options[index].1 } label: {
                        if selection == options[index].1 { Label(options[index].0, systemImage: "checkmark") }
                        else { Text(options[index].0) }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Text(options.first { $0.1 == selection }?.0 ?? "Не выбран").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }.font(.system(size: 13)).padding(8).frame(minWidth: 124)
                    .background(ODColors.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ODColors.line))
                    .contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize().frame(maxWidth: 232, alignment: .trailing).accessibilityLabel(title)
        }
    }
}

private struct ODSettingsSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? ODColors.accent : ODColors.track)
                .overlay(Capsule().strokeBorder(configuration.isOn ? ODColors.accent : ODColors.muted))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(ODColors.surface).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1).padding(3)
                }.frame(width: 36, height: 22)
        }.buttonStyle(.plain).opacity(isEnabled ? 1 : 0.45)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}
