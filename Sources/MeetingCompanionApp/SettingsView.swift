import AppKit
import SwiftUI
import MeetingCompanionCore

struct RecorderSettingsView: View {
    @ObservedObject var model: RecorderViewModel
    let showRecorder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Настройки и диагностика").font(.title2).bold()
            VStack(alignment: .leading, spacing: 6) {
                Picker("Захват системного звука", selection: $model.captureBackend) {
                    Text("ScreenCaptureKit").tag(AudioCaptureBackend.screenCaptureKit)
                    Text("Core Audio Tap (экспериментальный)").tag(AudioCaptureBackend.coreAudioTap)
                }
                .disabled(model.isRecording || model.isBusy || model.isCheckingAudio || model.diagnosticRunning)
                Text(model.captureBackend == .screenCaptureKit
                    ? "Только звук, без видеозаписи. Стандартный режим macOS."
                    : "Без захвата экрана. Возможны сбои аудиоустройств; длительные записи пока не проверены.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CalendarSettingsView(calendar: model.calendar)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Папка записей").font(.headline)
                    Text(model.outputDirectory.path).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button("Выбрать…", action: model.chooseFolder)
                    .disabled(model.isRecording || model.isBusy || model.diagnosticRunning)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.diagnosticAccess) { access in
                    HStack {
                        Circle().fill(access.state == .granted ? Color.green : access.state == .pending ? .orange : .red)
                            .frame(width: 9, height: 9).accessibilityHidden(true)
                        Text(access.name + ": " + access.message).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Button("Разрешения macOS") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                }
                Button("Проверить уровни звука", action: showRecorder)
            }
            Text("В основном окне нажми «Проверить звук», включи звук и скажи несколько слов.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Проверить всё") { check(prepare: false) }
                Button("Скачать модели") { check(prepare: true) }
                if model.diagnosticRunning { ProgressView().controlSize(.small) }
                if let startedAt = model.diagnosticStartedAt {
                    Text(startedAt, style: .timer).monospacedDigit().font(.caption)
                }
            }
            .disabled(model.diagnosticRunning || model.isRecording || model.isBusy || model.transcriptionJobs > 0)
            Button("Сбросить кэш…") { Task { await model.resetCache() } }
                .disabled(!model.canResetCache)
            Text("Первоначальная загрузка может занять несколько минут, при медленном соединении — дольше. После неё распознавание русской речи работает без интернета; записи никуда не отправляются.")
                .font(.caption).foregroundStyle(.secondary)
            if let progress = model.preparationProgress {
                HStack {
                    Text("Файлы подготовки: " + ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file))
                    Spacer()
                    if let changed = progress.lastModified {
                        Text("Последнее изменение:")
                        Text(changed, style: .relative)
                    }
                }
                .font(.caption).monospacedDigit()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.diagnosticReport).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .id("diagnostic-log")
                }
                .onChange(of: model.diagnosticReport) { _, _ in
                    proxy.scrollTo("diagnostic-log", anchor: .bottom)
                }
            }
        }
        .padding(22)
        .frame(width: 620, height: 820)
        .onAppear {
            model.refreshAccess()
            model.calendar.refresh()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refreshAccess()
            model.refreshPreparationProgress()
        }
    }

    private func check(prepare: Bool) {
        Task { await model.checkTranscription(prepare: prepare) }
    }
}

private struct CalendarSettingsView: View {
    @ObservedObject var calendar: MeetingCalendar

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Календари встреч").font(.headline)
            if calendar.calendars.isEmpty {
                Text(calendar.message.isEmpty ? "Нет доступных календарей." : calendar.message)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(calendar.calendars, id: \.calendarIdentifier) { item in
                            Toggle(item.title + " · " + item.source.title, isOn: Binding(
                                get: { calendar.isSelected(item) },
                                set: { calendar.select(item, enabled: $0) }
                            ))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 100)
            }
            Toggle("Напоминать только о встречах со ссылкой на созвон", isOn: $calendar.requireCallLink)
            Text("Ссылки ищутся в URL, месте и описании встречи. Для очных встреч отключи фильтр или начни запись вручную.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
