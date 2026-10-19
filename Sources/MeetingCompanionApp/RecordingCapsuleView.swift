import SwiftUI

struct CompactRecordingView: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 10) {
                Circle()
                    .fill(viewModel.recordingSaveError == nil ? Color.red : Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(viewModel.recordingSaveError == nil ? "Идёт запись" : "Ошибка сохранения")
                Text(viewModel.elapsedText)
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 130, alignment: .leading)
                Spacer(minLength: 0)
                if !viewModel.isBusy && viewModel.recordingSaveError == nil {
                    CompactLevelMetersView(levels: viewModel.levels).frame(width: 56)
                    Button(action: viewModel.toggleMicrophoneMute) {
                        Image(systemName: viewModel.microphoneMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundStyle(viewModel.microphoneMuted ? Color.red : Color.primary)
                            .frame(width: 18, height: 18)
                    }
                    .tint(viewModel.microphoneMuted ? .red : .primary)
                    .help(viewModel.microphoneMuted ? "Включить запись микрофона" : "Не записывать мой микрофон")
                    .accessibilityLabel(viewModel.microphoneMuted ? "Включить запись микрофона" : "Отключить запись микрофона")
                }
                Group {
                    if viewModel.isBusy {
                        ProgressView().controlSize(.small).accessibilityLabel("Сохранение записи")
                    } else if viewModel.recordingSaveError != nil {
                        Button { viewModel.recordingSaveError = nil } label: { Image(systemName: "xmark") }
                            .help("Закрыть. Исходные файлы и повторная обработка доступны в основном окне.")
                            .accessibilityLabel("Закрыть сообщение об ошибке")
                    } else {
                        Button(action: viewModel.toggleRecording) { Image(systemName: "stop.fill") }
                            .tint(.red).help("Остановить запись").accessibilityLabel("Остановить запись")
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered).buttonBorderShape(.circle)
            Text(viewModel.recordingSaveError != nil ? "Ошибка сохранения" :
                viewModel.isBusy ? "Сохранение…" :
                viewModel.mutedMicrophoneActivity ? "Микрофон не записывается" :
                viewModel.microphoneMuted ? "Микрофон выключен · системный звук записывается" : " ")
                .font(.caption2)
                .foregroundStyle(viewModel.microphoneMuted ? .orange : .secondary)
                .lineLimit(1)
                .help(viewModel.recordingSaveError ?? "")
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(MeetingOverlaySurface(capsule: true))
        .padding(4)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

struct ProcessingCapsuleView: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(viewModel.lastRecordingTitle).font(.headline).lineLimit(1)
                Spacer()
                if !viewModel.transcriptionWarnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(viewModel.transcriptionWarnings.joined(separator: "\n"))
                        .accessibilityLabel("Есть предупреждения о записи или обработке")
                }
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
                        .accessibilityLabel(progress.stage == .speakers ? "Обработано слов" : "Обработано окон")
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

