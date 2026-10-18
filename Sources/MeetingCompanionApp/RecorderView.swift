import SwiftUI

struct FullRecorderView: View {
    @ObservedObject var viewModel: RecorderViewModel
    let showSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Новая запись") {
                    MeetingPicker(viewModel: viewModel, calendar: viewModel.calendar)
                    HStack {
                        Picker("Микрофон", selection: $viewModel.selectedMicrophoneID) {
                            Text("По умолчанию").tag(RecorderViewModel.defaultMicrophoneID)
                            ForEach(viewModel.microphones) { microphone in
                                Text(microphone.name).tag(microphone.id)
                            }
                        }
                        .onChange(of: viewModel.selectedMicrophoneID) { _, _ in viewModel.restartLevelMonitor() }
                        Button("Обновить микрофоны", systemImage: "arrow.clockwise", action: viewModel.refreshMicrophones)
                            .labelStyle(.iconOnly)
                            .help("Обновить список микрофонов")
                    }
                    .disabled(viewModel.isBusy)
                    HStack {
                        Spacer()
                        Button(action: viewModel.toggleRecording) {
                            Label(viewModel.isBusy ? "Запуск записи…" : "Начать запись", systemImage: "record.circle")
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(viewModel.isBusy || viewModel.diagnosticRunning)
                    }
                }
                if let lastFileURL = viewModel.lastFileURL {
                    Section("Последняя запись") {
                        Text(viewModel.lastRecordingTitle).font(.headline)
                        Text(lastFileURL.lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        if !viewModel.transcriptionStatus.isEmpty {
                            Text(viewModel.transcriptionStatus).font(.caption)
                                .textSelection(.enabled)
                        }
                        HStack {
                            if viewModel.lastTranscriptURL != nil {
                                Button("Открыть текст", action: viewModel.openTranscript)
                            } else if viewModel.transcriptionJobs == 0 && viewModel.transcriptionReady {
                                Button("Получить текст", action: viewModel.transcribeLastRecording)
                                    .disabled(viewModel.isBusy || viewModel.diagnosticRunning)
                            }
                            Button("Показать в Finder", action: viewModel.revealLastFile)
                        }
                    }
                }
                if viewModel.diagnosticRunning || !viewModel.transcriptionReady {
                    Section {
                        HStack {
                            Text(viewModel.diagnosticRunning ? "Идёт подготовка транскрибации" : "Модели ещё не подготовлены")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Настройки…", action: showSettings)
                        }
                    }
                }
                if let error = viewModel.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
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
