import AppKit
import SwiftUI
import QuickLook
import MeetingCompanionCore
import UniformTypeIdentifiers

struct RecorderWorkspaceView: View {
    @ObservedObject var model: RecorderViewModel
    let showSettings: () -> Void

    var body: some View {
        Group {
            if model.mainPage == .recording {
                FullRecorderView(viewModel: model, showSettings: showSettings)
            } else {
                RecordingHistoryView(model: model, history: model.history)
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

struct RecordingHistoryView: View {
    @ObservedObject var model: RecorderViewModel
    @ObservedObject var history: RecordingHistory

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("История записей").font(.headline)
                Spacer()
                if history.loading { ProgressView().controlSize(.small).accessibilityLabel("Загрузка истории") }
                Button("Обновить", systemImage: "arrow.clockwise") { Task { await history.refresh(root: model.outputDirectory) } }
                    .labelStyle(.iconOnly).disabled(history.loading)
            }.padding(12)
            if let error = history.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
            if !history.initialLoadComplete {
                ProgressView("Загружаем историю…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.entries.isEmpty {
                ContentUnavailableView("Записей пока нет", systemImage: "waveform", description: Text("После первой записи здесь появятся её результаты и контекст встречи."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                List(history.entries, selection: $model.selectedHistoryURL) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).lineLimit(2)
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        statusLabel(entry).font(.caption)
                    }.padding(.vertical, 4).tag(entry.id).id(entry.id)
                }
                .listStyle(.plain)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                if let url = model.selectedHistoryURL, let entry = history.entry(url) {
                    details(entry).frame(minWidth: 300, maxWidth: .infinity)
                } else {
                    ContentUnavailableView("Выберите запись", systemImage: "waveform", description: Text("Здесь будут контекст встречи, результаты и проблемы обработки."))
                        .frame(minWidth: 300, maxWidth: .infinity)
                }
                }
            }
        }
        .quickLookPreview($model.audioPreviewURL)
        .task {
            if !history.initialLoadComplete { await history.refresh(root: model.outputDirectory) }
            if model.selectedHistoryURL == nil { model.selectedHistoryURL = history.entries.first?.id }
        }
    }

    private func statusLabel(_ entry: RecordingEntry) -> some View {
        Label(entry.status, systemImage: entry.phase == .failed ? "xmark.circle" :
            !entry.problems.isEmpty ? "exclamationmark.triangle" : entry.phase == .completed ? "checkmark.circle" : "clock")
            .foregroundStyle(entry.phase == .failed ? Color.red : !entry.problems.isEmpty ? Color.orange : Color.secondary)
    }

    private func exists(_ url: URL) -> Bool { history.entries.contains { $0.availableFiles.contains(url) } }

    private func openButton(_ title: String, _ url: URL) -> some View {
        Button(title) {
            if !NSWorkspace.shared.open(url) { history.reportError("Не удалось открыть файл «" + url.lastPathComponent + "».") }
        }.disabled(!exists(url))
    }

    private func exportTranscript(_ entry: RecordingEntry) {
        guard entry.capabilities.canReview else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = entry.transcript.lastPathComponent
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
            do {
                try await Task.detached {
                guard let document = try TranscriptResultStorage(recordingURL: entry.recording).currentDocument() else {
                    throw TranscriptWindowError.transcriptNotFound(entry.recording.path)
                }
                let edits = try TranscriptEditsRepository(recordingDirectory: entry.folder).loadEdits(resultID: document.resultID)
                try TranscriptExportWriter(recordingDirectory: entry.folder).export(document: document, edits: edits, to: url, allowOverwrite: true)
                }.value
            } catch { history.reportError("Не удалось экспортировать текст: " + error.localizedDescription) }
            }
        }
    }

    private func details(_ entry: RecordingEntry) -> some View {
        Form {
            Section {
                Text(entry.title).font(.title2).textSelection(.enabled)
                Text(entry.date.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
                statusLabel(entry)
                if let warning = entry.persistenceWarning { Text(warning).foregroundStyle(.orange).textSelection(.enabled) }
                if let problem = entry.problems.first(where: { $0.isError }) ?? entry.problems.first {
                    Text(problem.stage.title + ": " + problem.message)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(3)
                    Text("Подробности — в разделе «Проблемы» ниже.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let duration = entry.duration { Text("Длительность: " + formatClock(duration)).font(.caption) }
                if let progress = history.progress[entry.id], entry.phase == .processing {
                    TranscriptionProgressView(progress: progress)
                }
            }
            if entry.capabilities.isTextOnly {
                Section("Файлы") {
                    Button("Открыть текст только для чтения") { model.onOpenTranscript?(entry) }
                        .disabled(!entry.capabilities.hasSavedText)
                    Text(entry.capabilities.reason ?? "Доступен только просмотр сохранённого текста.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Файлы") {
                    Button("Открыть расшифровку") { model.onOpenTranscript?(entry) }
                        .disabled(!entry.capabilities.canReview && !entry.capabilities.hasSavedText)
                    HStack {
                        Button("Открыть аудио") { model.audioPreviewURL = entry.recording }
                            .disabled(!entry.capabilities.canPreviewAudio)
                            .help("Прослушать запись в системном предпросмотре Quick Look")
                        Button("Открыть текст") { model.onOpenTranscript?(entry) }
                            .disabled(!entry.capabilities.hasSavedText)
                        Button("Показать в Finder") { NSWorkspace.shared.open(entry.folder) }
                    }
                    Button("Экспортировать текст…") { exportTranscript(entry) }
                        .disabled(!entry.capabilities.canReview)
                    Text("В экспортируемой копии технические пути заменяются относительными; исходный файл сохраняется.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let reason = entry.capabilities.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Дополнительные действия") {
                    if entry.capabilities.canReview {
                        HStack {
                            openButton("Текст микрофона", entry.rawBase.appendingPathExtension("host_record.local.transcript.txt"))
                            openButton("Текст системного звука", entry.rawBase.appendingPathExtension("remote_record.local.transcript.txt"))
                        }
                    }
                    Button("Повторить обработку") { model.retryRecording(entry.id) }
                        .disabled(!entry.capabilities.canRetry || entry.phase.isWorking || model.isBusy || model.diagnosticRunning)
                }
                if let meeting = entry.meeting {
                    Section("Контекст встречи") {
                        Text(meeting.start.formatted(date: .omitted, time: .shortened) + " — " + meeting.end.formatted(date: .omitted, time: .shortened))
                        if !meeting.agenda.isEmpty { Text(meeting.agenda).textSelection(.enabled) }
                        if !meeting.attendees.isEmpty {
                            LabeledContent("Приглашены") { Text(meeting.attendees.joined(separator: ", ")).textSelection(.enabled) }
                            Text("Список приглашённых не подтверждает участие и не определяет голоса в транскрипте.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(meeting.links, id: \.self) { link in
                            if let url = URL(string: link), ["http", "https"].contains(url.scheme) { Link(link, destination: url).lineLimit(2) }
                        }
                        openButton("Файл контекста", entry.context)
                    }
                }
            }
            Section("Проблемы") {
                if entry.problems.isEmpty {
                    Text(entry.phase == .completed ? "Предупреждений не обнаружено. Это не проверка точности распознавания." : "Пока нет обнаруженных проблем.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entry.problems) { problem in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(problem.stage.title + " · " + (problem.isError ? "Ошибка" : "Предупреждение"), systemImage: problem.isError ? "xmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(problem.isError ? Color.red : Color.orange)
                        Text(problem.message).textSelection(.enabled)
                        Text(problem.advice).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if !entry.capabilities.isTextOnly {
                if !model.transcriptionReady {
                    Button("Скачать модели") { Task { await model.checkTranscription(prepare: true) } }
                        .disabled(model.isRecording || model.isBusy || model.diagnosticRunning || model.transcriptionJobs > 0)
                }
                openButton("Отчёт захвата", entry.captureReport)
                if let log = entry.log { openButton("Последний журнал обработки", log) }
                Button("Журналы обработки в Finder") { NSWorkspace.shared.open(entry.rawBase.deletingLastPathComponent()) }
                }
            }
        }
        .formStyle(.grouped)
        .disclosureGroupStyle(FullWidthDisclosureStyle())
    }
}
