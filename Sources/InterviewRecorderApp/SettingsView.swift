import AppKit
import SwiftUI

struct RecorderSettingsView: View {
    @ObservedObject var model: RecorderViewModel
    let showRecorder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Настройки и диагностика").font(.title2).bold()
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
            Text("Включи звук и скажи несколько слов — уровни видны в основном окне.")
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
        .frame(width: 620, height: 540)
        .onAppear { model.refreshAccess() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refreshAccess()
            model.refreshPreparationProgress()
        }
    }

    private func check(prepare: Bool) {
        Task { await model.checkTranscription(prepare: prepare) }
    }
}
