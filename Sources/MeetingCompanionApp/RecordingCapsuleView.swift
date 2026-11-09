import SwiftUI
import MeetingCompanionCore
import MeetingCompanionApplication

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

struct ProcessingStationSymbol: View {
    let state: ProcessingProgressSnapshot.State
    let size: CGFloat
    var body: some View {
        Group {
            if state == .skipped || state == .failed || state == .warning {
                RoundedRectangle(cornerRadius: size > 8 ? 4 : 1)
                    .fill(ODColors.warning)
                    .overlay(Text("!").font(.system(size: size > 8 ? 14 : 8, weight: .bold)).foregroundStyle(ODColors.surface))
            } else if state == .completed {
                Circle().fill(ODColors.green)
                    .overlay { if size > 8 { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(ODColors.surface) } }
            } else if state == .current {
                Circle().fill(ODColors.accent)
                    .overlay(Circle().stroke(ODColors.surface, lineWidth: 2).padding(2))
                    .overlay(Circle().stroke(ODColors.accent, lineWidth: 1).padding(-2))
            } else {
                Circle().stroke(ODColors.muted.opacity(0.5), lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ProcessingCapsuleView: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        let snapshot = viewModel.capsuleProgress
        let title = viewModel.lastRecordingTitle.isEmpty ? "Обработка записи" : viewModel.lastRecordingTitle
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ODColors.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .help(title).accessibilityLabel(title)
                Text(status(snapshot))
                    .font(.system(size: 11))
                    .foregroundStyle(ODColors.muted)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    if let snapshot {
                        ForEach(Array(snapshot.route.enumerated()), id: \.element) { index, station in
                            ProcessingStationSymbol(state: snapshot.states[station] ?? .future, size: 8)
                            if index < snapshot.route.count - 1 {
                                Rectangle().fill(ODColors.track).frame(height: 2)
                            }
                        }
                    }
                }
                .frame(height: 12)
                .padding(.top, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(snapshot.map { "\($0.current?.title ?? "В очереди"), \($0.countText). " + $0.warnings.joined(separator: ". ") } ?? "Подготовка обработки")
            }
            .frame(minWidth: 44, maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle()).gesture(WindowDragGesture())
            Button(isCompleted ? "Открыть" : "Подробнее") {
                if isCompleted { viewModel.openResults() } else { viewModel.showProcessingDetails() }
            }
            .font(.system(size: 13))
            .buttonStyle(.borderless)
            .foregroundStyle(ODColors.accent)
            .popover(isPresented: Binding(get: { viewModel.processingNavigationNotice != nil }, set: { if !$0 { viewModel.processingNavigationNotice = nil } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(viewModel.processingNavigationNotice ?? "").textSelection(.enabled)
                    Button("Понятно") { viewModel.processingNavigationNotice = nil }
                }.padding(16).frame(width: 280)
            }
        }
        .padding(.leading, 32).padding(.trailing, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 24).fill(ODColors.surface)
            .gesture(WindowDragGesture())
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(ODColors.line, lineWidth: 1)))
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
    private var isCompleted: Bool { if case .completed = viewModel.transcriptionState { true } else { false } }
    private func status(_ snapshot: ProcessingProgressSnapshot?) -> String {
        switch viewModel.transcriptionState {
        case .completed: viewModel.transcriptionWarnings.isEmpty && snapshot?.warnings.isEmpty != false ? "Готово" : "Готово · есть замечание"
        case .failed: "Не удалось обработать"
        default: snapshot?.countText ?? "Подготовка обработки…"
        }
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
