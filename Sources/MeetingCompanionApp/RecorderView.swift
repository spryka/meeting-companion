import SwiftUI

struct RecordingFormTitle {
    private(set) var text: String
    private var userEdited = false
    init(text: String) { self.text = text }
    mutating func edit(_ value: String) { text = value; userEdited = true }
    mutating func meetingChanged(_ meeting: MeetingContext?) {
        if !userEdited { text = meeting?.summary ?? "Новая встреча" }
    }
}

struct FullRecorderView: View {
    @ObservedObject var viewModel: RecorderViewModel
    let showSettings: () -> Void
    @State private var titleDraft: RecordingFormTitle

    init(viewModel: RecorderViewModel, showSettings: @escaping () -> Void, title: String? = nil) {
        self.viewModel = viewModel
        self.showSettings = showSettings
        _titleDraft = State(initialValue: RecordingFormTitle(text: title ?? viewModel.selectedMeeting?.summary ?? "Новая встреча"))
    }

    var recordingAction: (title: String, perform: () async -> Bool) {
        let sessionID = viewModel.activeSessionID
        if viewModel.isRecording {
            if viewModel.showsCancelRecording {
                return ("Отменить короткую запись", {
                    guard !viewModel.settingsPresented else { return false }
                    return await viewModel.cancelRecordingIntent(sessionID: sessionID)
                })
            }
            return ("Остановить запись", {
                guard !viewModel.settingsPresented else { return false }
                return await viewModel.stopRecordingIntent(sessionID: sessionID)
            })
        }
        let title = titleDraft.text
        return ("Начать запись", {
            guard !viewModel.settingsPresented else { return false }
            let started = await viewModel.startRecordingIntent(customTitle: title.isEmpty ? nil : title)
            if started { viewModel.mainPage = .history }
            return started
        })
    }

    var body: some View {
        let action = recordingAction
        ODDialog(title: "Новая запись", close: { viewModel.mainPage = .history }) {
            Text("Выбери встречу и источник звука. После остановки запись появится в библиотеке.")
                .font(.system(size: 14)).foregroundStyle(ODColors.muted)
                if viewModel.diagnosticRunning || !viewModel.transcriptionReady {
                    Section("Подготовка транскрибации") {
                        Text(viewModel.diagnosticRunning ? "Идёт проверка или загрузка…" : "Сначала скачайте модели для распознавания речи")
                            .font(.headline)
                        Text("Нажмите «Скачать модели»: приложение скачает и проверит необходимые веса моделей. Нужен интернет; подготовка может занять несколько минут, при медленном соединении — дольше. Затем распознавание работает офлайн.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if viewModel.improveTerms {
                            Text("Включено улучшение терминов: дополнительно загрузится Parakeet, около 740 МБ.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Скачать модели") { Task {
                                guard !viewModel.settingsPresented else { return }
                                await viewModel.checkTranscription(prepare: true)
                            } }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.diagnosticRunning || viewModel.isBusy || viewModel.isRecording || viewModel.transcriptionJobs > 0)
                            Button("Настройки…", action: showSettings)
                        }
                        if !viewModel.diagnosticReport.isEmpty {
                            DisclosureGroup("Подробности") {
                                ScrollView {
                                    Text(viewModel.diagnosticReport)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 120)
                            }
                            .disclosureGroupStyle(FullWidthDisclosureStyle())
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 20) {
                    MeetingPicker(viewModel: viewModel, calendar: viewModel.calendar)

                    ODField(title: "Название записи") {
            TextField("Название записи", text: Binding(get: { viewModel.isRecording ? viewModel.lastRecordingTitle : titleDraft.text }, set: { if !viewModel.settingsPresented { titleDraft.edit($0) } }))
                        .odInput()
                        .disabled(viewModel.isBusy || viewModel.isRecording)
                    }

                    ODField(title: "Микрофон") {
                        let missing = viewModel.selectedMicrophoneID != RecorderViewModel.defaultMicrophoneID
                            && !viewModel.microphones.contains { $0.id == viewModel.selectedMicrophoneID }
                        ODMenuField(title: "Микрофон", selection: Binding(get: { viewModel.selectedMicrophoneID }, set: { if !viewModel.settingsPresented { viewModel.selectedMicrophoneID = $0 } }),
                            options: [("Системный по умолчанию", RecorderViewModel.defaultMicrophoneID)]
                                + (missing ? [("Выбранный микрофон недоступен", viewModel.selectedMicrophoneID)] : [])
                                + viewModel.microphones.map { ($0.name, $0.id) })
                        .onChange(of: viewModel.selectedMicrophoneID) { _, _ in
                            if !viewModel.settingsPresented { viewModel.restartLevelMonitor() }
                        }
                        Button("Обновить микрофоны") {
                            if !viewModel.settingsPresented { viewModel.refreshMicrophones() }
                        }
                            .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(ODColors.accent)
                    }
                    .disabled(viewModel.isBusy || viewModel.isRecording)

                    FormLevelMetersView(levels: viewModel.levels)

                    if viewModel.isRecording { Text(viewModel.elapsedText).monospacedDigit() }
                }
                if let error = viewModel.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
        } actions: {
            Button("Отмена") { viewModel.mainPage = .history }.keyboardShortcut(.cancelAction)
            Button {
                Task { _ = await action.perform() }
            } label: {
                Label(viewModel.isBusy ? "Подождите…" : action.title,
                      systemImage: viewModel.isRecording ? "stop.circle" : "record.circle")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(ODButtonStyle(primary: true))
            .disabled(viewModel.isRecording ? viewModel.isBusy : !viewModel.canStartRecording || titleDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .disabled(viewModel.settingsPresented)
        .allowsHitTesting(!viewModel.settingsPresented)
        .accessibilityHidden(viewModel.settingsPresented)
        .overlay { if viewModel.settingsPresented { WorkspaceSettingsOverlay(model: viewModel) } }
        .interactiveDismissDisabled(viewModel.settingsPresented)
        .onAppear {
            viewModel.setRecordingFormVisible(true)
        }
        .onDisappear { viewModel.setRecordingFormVisible(false) }
        .onChange(of: viewModel.selectedMeeting) { _, newMeeting in
            titleDraft.meetingChanged(newMeeting)
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

struct MeetingPicker: View {
    @ObservedObject var viewModel: RecorderViewModel
    @ObservedObject var calendar: MeetingCalendar

    var body: some View {
        ODField(title: "Встреча") {
            let events = calendar.events + (viewModel.selectedMeeting.map { calendar.events.contains($0) ? [] : [$0] } ?? [])
            ODMenuField(title: "Встреча", selection: $viewModel.selectedMeeting,
                options: [("Без встречи", Optional<MeetingContext>.none)] + events.map {
                    ($0.start.formatted(date: .omitted, time: .shortened) + " · " + $0.summary, Optional($0))
                })
            .disabled(viewModel.isBusy || viewModel.isRecording)
            if !calendar.message.isEmpty {
                Text(calendar.message).font(.caption).foregroundStyle(.secondary)
            }
            if calendar.suggestsCalendarSetup {
                DisclosureGroup("Не видите рабочие встречи?") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Открой приложение «Календарь» на Mac и проверь, видны ли там рабочие встречи.")
                        Text("2. Если их нет, выбери «Календарь → Добавить учётную запись…» и подключи рабочий аккаунт. Параметры подключения уточни у своей ИТ-команды.")
                        Text("3. Когда встречи появятся в «Календаре», выбери нужный календарь в настройках Meeting Companion → Календарь.")
                        Text("Если встреч на этой неделе действительно нет, настраивать ничего не нужно. Запись можно начать без встречи.")
                        Link("Инструкция Apple", destination: URL(string: "https://support.apple.com/ru-ru/guide/calendar/welcome/mac")!)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .disclosureGroupStyle(FullWidthDisclosureStyle())
            }
        }
    }
}

private struct FormLevelMetersView: View {
    @ObservedObject var levels: AudioLevels
    var body: some View {
        VStack(spacing: 0) {
            row("Микрофон", level: levels.mic)
            row("Системный звук", level: levels.system)
        }
    }
    private func row(_ title: String, level: Double) -> some View {
        HStack(spacing: 16) {
            Text(title)
            Spacer()
            ThinMeter(level: level, color: ODColors.accent).frame(width: 84, height: 18)
        }.font(.system(size: 13)).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(ODColors.line).frame(height: 1) }
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityValue("\(Int(level * 100)) процентов")
    }
}
