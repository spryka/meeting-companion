import SwiftUI
import MeetingCompanionCore

struct CompactRecordingView: View {
    @ObservedObject var viewModel: RecorderViewModel
    @State private var showingError = false

    var body: some View {
        let sessionID = viewModel.activeSessionID
        let cancelShort = viewModel.showsCancelRecording

        if viewModel.recordingSaveError != nil || viewModel.recordingCancelled {
            HStack(spacing: 12) {
                Image(systemName: viewModel.recordingSaveError != nil ? "exclamationmark.triangle.fill" : "xmark.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(viewModel.recordingSaveError != nil ? ODColors.red : ODColors.muted)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.recordingSaveError != nil ? "Ошибка сохранения" : "Запись отменена")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ODColors.ink)
                    Text(viewModel.recordingSaveError ?? "Короткая запись не сохранена")
                        .help(viewModel.recordingSaveError ?? "Короткая запись не сохранена")
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.recordingSaveError != nil ? ODColors.red : ODColors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(minWidth: 44, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

                if viewModel.recordingSaveError != nil {
                    Button("Подробности") { showingError = true }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingError) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Ошибка сохранения").font(.headline)
                                Text(viewModel.recordingSaveError ?? "").textSelection(.enabled)
                                Text("Доступное исходное аудио и журнал не удаляются. Открой папку записи для восстановления.")
                                    .foregroundStyle(.secondary)
                                if viewModel.lastFileURL != nil {
                                    Button("Показать файлы", action: viewModel.revealLastFile)
                                }
                            }.padding(20).frame(width: 380)
                        }
                }

                Button("Закрыть") {
                    viewModel.dismissCapsule()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ODColors.hover, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(ODColors.surface)
                    .gesture(WindowDragGesture())
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(ODColors.line, lineWidth: 1)
                    )
            )
        } else {
            HStack(spacing: 8) {
            // Recording dot
            Circle()
                .fill(ODColors.red)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            // Timer (24px, tabular nums, tracking -0.7px)
            Text(viewModel.elapsedText)
                .font(.system(size: 20, weight: .medium))
                .monospacedDigit()
                .tracking(-0.7)
                .lineLimit(1)
                        .truncationMode(.tail)
                .foregroundStyle(ODColors.ink)
                .accessibilityLabel("Длительность записи: \(viewModel.elapsedText)")
                .fixedSize(horizontal: true, vertical: false)
                .gesture(WindowDragGesture())

            // Title & subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.lastRecordingTitle.isEmpty ? "Новая запись" : viewModel.lastRecordingTitle)
                    .help(viewModel.lastRecordingTitle.isEmpty ? "Новая запись" : viewModel.lastRecordingTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ODColors.ink)
                    .lineLimit(1)
                        .truncationMode(.tail)

                Text(subtitleText)
                    .help(subtitleText)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                        .truncationMode(.tail)
            }
            .frame(minWidth: 44, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            if viewModel.showsOvertimeReminder {
                Button(action: viewModel.postponeOvertimeReminder) {
                    Text("+15 мин")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ODColors.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(ODColors.hover, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Убрать напоминание на 15 минут. Запись продолжится.")
            }

            // Mic Button (36x36 rounded rect, radius 8px)
            Button {
                viewModel.toggleMicrophoneMute(sessionID: sessionID)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(viewModel.microphoneMuted ? ODColors.warningBg : ODColors.surface)
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(viewModel.microphoneMuted ? Color.clear : ODColors.line, lineWidth: 1)
                    ODIconView(
                        viewModel.microphoneMuted ? .mute : .mic,
                        color: viewModel.microphoneMuted ? ODColors.warning : ODColors.ink,
                        size: 16
                    )
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.microphoneMuted ? "Включить запись микрофона" : "Отключить запись микрофона")
            .help(viewModel.microphoneMuted ? "Включить запись микрофона" : "Не записывать мой микрофон")

            // Stop Button (36x36 rounded rect, radius 8px, red-bg)
            Button {
                if cancelShort {
                    Task { await viewModel.cancelRecordingIntent(sessionID: sessionID) }
                } else {
                    Task { await viewModel.stopRecordingIntent(sessionID: sessionID) }
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ODColors.redBg)
                    ODIconView(
                        cancelShort ? .close : .stop,
                        color: ODColors.red,
                        size: 16
                    )
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(cancelShort ? "Отменить короткую запись" : "Остановить запись")
            .help(cancelShort ? "Отменить короткую запись" : "Остановить запись")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(ODColors.surface)
                .gesture(WindowDragGesture())
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(ODColors.line, lineWidth: 1)
                )
        )
        .overlay {
            if viewModel.showsOvertimeReminder {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(ODColors.warning, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        }
    }

    private var subtitleText: String {
        if viewModel.recordingSaveError != nil {
            return "Ошибка сохранения"
        } else if viewModel.isBusy || viewModel.sessionStopping {
            return "Сохранение…"
        } else if viewModel.showsOvertimeReminder {
            return viewModel.overtimeMessage
        } else if viewModel.microphoneState == .missing {
            return "Микрофон отключён · системный звук записывается"
        } else if viewModel.microphoneMuted {
            return "Микрофон выключен · системный звук записывается"
        } else if viewModel.mutedMicrophoneActivity {
            return "Микрофон не записывается"
        } else if !viewModel.microphoneCaptureHint.isEmpty {
            return viewModel.microphoneCaptureHint
        } else {
            return "Микрофон и звук системы"
        }
    }

    private var subtitleColor: Color {
        if viewModel.recordingSaveError != nil || viewModel.microphoneState == .missing {
            return ODColors.red
        } else if viewModel.microphoneMuted || viewModel.showsOvertimeReminder {
            return ODColors.warning
        } else {
            return ODColors.muted
        }
    }
}

struct ProcessingCapsuleView: View {
    @ObservedObject var viewModel: RecorderViewModel

    static func fraction(for progress: TranscriptionProgress) -> Double? {
        progress.stage == .warning ? nil : progress.stageFraction
    }

    var body: some View {
        HStack(spacing: 12) {
            switch viewModel.transcriptionState {
            case .running(let progress):
                ODIconView(.wave, color: ODColors.accent, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.lastRecordingTitle.isEmpty ? "Обработка записи" : viewModel.lastRecordingTitle)
                        .help(viewModel.lastRecordingTitle.isEmpty ? "Обработка записи" : viewModel.lastRecordingTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ODColors.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let progress {
                        let stepText = progress.step.flatMap { step in progress.steps.map { "Этап \(step) из \($0) · " } } ?? ""
                        Text("\(stepText)\(progress.text)")
                            .help("\(stepText)\(progress.text)")
                            .font(.system(size: 11))
                            .foregroundStyle(ODColors.muted)
                            .lineLimit(1)
                        .truncationMode(.tail)
                        if let fraction = Self.fraction(for: progress) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(ODColors.track).frame(height: 4)
                                    Capsule().fill(ODColors.accent).frame(width: geo.size.width * fraction, height: 4)
                                }
                            }
                            .frame(height: 4)
                        }
                    } else {
                        Text(viewModel.transcriptionStatus)
                            .help(viewModel.transcriptionStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(ODColors.muted)
                            .lineLimit(1)
                        .truncationMode(.tail)
                    }
                }
                .frame(minWidth: 44, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

                Button(action: viewModel.dismissCapsule) {
                    ZStack {
                        Circle().fill(ODColors.surface)
                        Circle().strokeBorder(ODColors.line, lineWidth: 1)
                        ODIconView(.close, color: ODColors.muted, size: 14)
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help("Скрыть")

            case .completed:
                ODIconView(.check, color: ODColors.green, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.lastRecordingTitle.isEmpty ? "Запись завершена" : viewModel.lastRecordingTitle)
                        .help(viewModel.lastRecordingTitle.isEmpty ? "Запись завершена" : viewModel.lastRecordingTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ODColors.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(viewModel.transcriptionWarnings.isEmpty ? "Транскрипт готов" : "Текст готов с замечаниями")
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.transcriptionWarnings.isEmpty ? ODColors.green : ODColors.warning)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(minWidth: 44, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

                Button(action: viewModel.openResults) {
                    Text("Открыть")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ODColors.primaryButtonForeground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(ODColors.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                Button(action: viewModel.dismissCapsule) {
                    ZStack {
                        Circle().fill(ODColors.surface)
                        Circle().strokeBorder(ODColors.line, lineWidth: 1)
                        ODIconView(.close, color: ODColors.muted, size: 14)
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help("Закрыть")

            case .failed(let message):
                ODIconView(.warning, color: ODColors.red, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.lastRecordingTitle.isEmpty ? "Ошибка обработки" : viewModel.lastRecordingTitle)
                        .help(viewModel.lastRecordingTitle.isEmpty ? "Ошибка обработки" : viewModel.lastRecordingTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ODColors.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(message)
                        .help(message)
                        .font(.system(size: 11))
                        .foregroundStyle(ODColors.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(minWidth: 44, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

                Button(action: viewModel.transcribeLastRecording) {
                    Text("Повторить")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ODColors.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(ODColors.hover, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.transcriptionJobs > 0)

                Button(action: viewModel.dismissCapsule) {
                    ZStack {
                        Circle().fill(ODColors.surface)
                        Circle().strokeBorder(ODColors.line, lineWidth: 1)
                        ODIconView(.close, color: ODColors.muted, size: 14)
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

            case .idle:
                Text("Запись сохранена")
                    .font(.system(size: 12))
                    .foregroundStyle(ODColors.muted)
                Spacer()
                Button(action: viewModel.dismissCapsule) {
                    ODIconView(.close, color: ODColors.muted, size: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(ODColors.surface)
                .gesture(WindowDragGesture())
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(ODColors.line, lineWidth: 1)
                )
        )
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

struct RecordingCapsuleHostView: View {
    @ObservedObject var viewModel: RecorderViewModel

    var captureTransitionText: String? {
        if viewModel.sessionStarting { return "Запуск записи…" }
        if viewModel.sessionStopping { return "Сохранение записи…" }
        return nil
    }

    var body: some View {
        Group {
            if let text = captureTransitionText {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ODColors.ink)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(ODColors.surface)
                        .gesture(WindowDragGesture())
                        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(ODColors.line, lineWidth: 1))
                )
            } else if viewModel.showsProcessingCapsule {
                ProcessingCapsuleView(viewModel: viewModel)
            } else {
                CompactRecordingView(viewModel: viewModel)
            }
        }
        .padding(2)
    }
}
