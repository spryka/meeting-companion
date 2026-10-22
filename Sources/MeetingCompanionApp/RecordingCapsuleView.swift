import SwiftUI
import MeetingCompanionCore

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
                            .foregroundStyle(viewModel.microphoneMuted || viewModel.microphoneState == .missing ? Color.red : Color.primary)
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
                !viewModel.microphoneCaptureHint.isEmpty ? viewModel.microphoneCaptureHint :
                viewModel.mutedMicrophoneActivity ? "Микрофон не записывается" :
                viewModel.microphoneMuted ? "Микрофон выключен · системный звук записывается" : " ")
                .font(.caption2)
                .foregroundStyle(viewModel.microphoneState == .missing ? Color.red :
                    viewModel.microphoneMuted || viewModel.microphoneState != .receiving ? Color.orange : Color.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .help(viewModel.recordingSaveError ?? (viewModel.microphoneState == .missing
                    ? "Данные микрофона не поступают. Системный звук продолжает записываться; проверьте подключение и выбранный микрофон."
                    : viewModel.microphoneCaptureHint))
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
                if let progress {
                    TranscriptionProgressView(progress: progress)
                } else {
                    Text(viewModel.transcriptionStatus).font(.caption).lineLimit(2)
                }
            case .completed:
                Label(viewModel.transcriptionWarnings.isEmpty ? "Транскрипт готов" : "Текст готов с предупреждениями",
                      systemImage: viewModel.transcriptionWarnings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(viewModel.transcriptionWarnings.isEmpty ? Color.secondary : Color.orange)
                Button("Открыть результаты", action: viewModel.openResults)
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

struct TranscriptionProgressView: View {
    let progress: TranscriptionProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let step = progress.step, let steps = progress.steps, let completed = progress.completedSteps {
                HStack {
                    Text("Обработка записи")
                    Spacer(minLength: 4)
                    Text("Этап \(step) из \(steps)").monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption)
                VStack(spacing: 4) {
                    bar(Double(completed) / Double(steps), color: Color(nsColor: .systemBlue), height: 6)
                        .accessibilityLabel("Завершено этапов")
                        .accessibilityValue("\(completed) из \(steps)")
                    if let fraction = progress.stageFraction {
                        bar(fraction, color: Color(nsColor: .systemPink), height: 2)
                            .accessibilityLabel("Текущий этап")
                            .accessibilityValue("\(progress.completed) из \(progress.total)")
                    }
                }
            }
            Text(progress.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func bar(_ fraction: Double, color: Color, height: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Color(nsColor: .controlColor))
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: geometry.size.width * fraction)
                }
        }.frame(height: height)
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

