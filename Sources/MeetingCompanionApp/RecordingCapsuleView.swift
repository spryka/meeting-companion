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
                        .fixedSize(horizontal: true, vertical: false)
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
                    Button("Детали") { showingError = true }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .fixedSize()
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
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(ODColors.red)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        let duration = formatElapsedMinutes(viewModel.elapsed)
                        Text(duration)
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                            .tracking(-0.35)
                            .fixedSize()
                            .accessibilityLabel("Длительность записи: \(duration)")

                        VStack(alignment: .leading, spacing: 0) {
                            let title = viewModel.lastRecordingTitle.isEmpty ? "Новая запись" : viewModel.lastRecordingTitle
                            Text(title)
                                .font(.system(size: 12, weight: .medium))
                                .help(title)
                            if let subtitle {
                                Text(subtitle.text)
                                    .font(.system(size: 10))
                                    .foregroundStyle(subtitleColor)
                                    .help(subtitle.fullText)
                                    .accessibilityLabel(subtitle.fullText)
                            }
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(ODColors.ink)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())

                    HStack(spacing: 4) {
                        Button {
                            viewModel.toggleMicrophoneMute(sessionID: sessionID)
                        } label: {
                            ODIconView(viewModel.microphoneMuted ? .mute : .mic,
                                       color: viewModel.microphoneMuted ? ODColors.warning : ODColors.ink, size: 18)
                                .frame(width: 40, height: 40)
                                .background(viewModel.microphoneMuted ? ODColors.warningBg : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(viewModel.microphoneMuted ? "Включить запись микрофона" : "Отключить запись микрофона")
                        .help(viewModel.microphoneMuted ? "Включить запись микрофона" : "Не записывать мой микрофон")

                        Button {
                            if cancelShort {
                                Task { await viewModel.cancelRecordingIntent(sessionID: sessionID) }
                            } else {
                                Task { await viewModel.stopRecordingIntent(sessionID: sessionID) }
                            }
                        } label: {
                            ODIconView(cancelShort ? .close : .stop, color: ODColors.red, size: 18)
                                .frame(width: 40, height: 40)
                                .background(ODColors.redBg, in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(cancelShort ? "Отменить короткую запись" : "Остановить запись")
                        .help(cancelShort ? "Отменить короткую запись" : "Остановить запись")
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                if viewModel.showsOvertimeReminder {
                    HStack(spacing: 8) {
                        Text(viewModel.overtimeMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(ODColors.warning)
                        Button("+15 мин", action: viewModel.postponeOvertimeReminder)
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.bordered)
                            .help("Убрать напоминание на 15 минут. Запись продолжится.")
                    }
                }
            }
            .padding(.horizontal, 11)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        }
    }

    private var subtitle: (text: String, fullText: String)? {
        if viewModel.isBusy || viewModel.sessionStopping { return ("Сохранение…", "Сохранение записи") }
        if viewModel.microphoneState == .missing { return ("Микрофон пропал", viewModel.microphoneCaptureHint) }
        if viewModel.microphoneMuted { return ("Микрофон выкл.", "Микрофон выключен") }
        if viewModel.mutedMicrophoneActivity { return ("Микрофон выкл.", "Микрофон не записывается") }
        if viewModel.microphoneState == .silent { return ("Давно нет звука", viewModel.microphoneCaptureHint) }
        return nil
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
        let label = status(snapshot)
        HStack(spacing: 8) {
            ODIconView(.wave, color: ODColors.accent, size: 18)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ODColors.ink)
                    .lineLimit(1)
                    .help(title)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(ODColors.muted)
                    .lineLimit(1)
                    .help(label)
                    .accessibilityHint((snapshot?.warnings ?? []).joined(separator: ". "))
            }
            .frame(minWidth: 44, maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle()).gesture(WindowDragGesture())
            Button {
                if isCompleted { viewModel.openResults() } else { viewModel.showProcessingDetails() }
            } label: {
                Text(isCompleted ? "Открыть" : "Подробнее")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ODColors.accent)
            .popover(isPresented: Binding(get: { viewModel.processingNavigationNotice != nil }, set: { if !$0 { viewModel.processingNavigationNotice = nil } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(viewModel.processingNavigationNotice ?? "").textSelection(.enabled)
                    Button("Понятно") { viewModel.processingNavigationNotice = nil }
                }.padding(16).frame(width: 280)
            }
        }
        .padding(.horizontal, 11)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
    private var isCompleted: Bool { if case .completed = viewModel.transcriptionState { true } else { false } }
    private func status(_ snapshot: ProcessingProgressSnapshot?) -> String {
        switch viewModel.transcriptionState {
        case .completed: viewModel.transcriptionWarnings.isEmpty && snapshot?.warnings.isEmpty != false ? "Готово" : "Готово · есть замечание"
        case .failed: "Не удалось обработать"
        default:
            if let snapshot, let station = snapshot.current {
                "\(snapshot.countText) · \(station.title)"
            } else {
                snapshot?.countText ?? "Подготовка обработки…"
            }
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
            } else if viewModel.showsProcessingCapsule {
                ProcessingCapsuleView(viewModel: viewModel)
            } else {
                CompactRecordingView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(ODColors.surface).gesture(WindowDragGesture()))
        .overlay {
            Capsule()
                .strokeBorder(viewModel.showsOvertimeReminder ? ODColors.warning : ODColors.line,
                              lineWidth: viewModel.showsOvertimeReminder ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .padding(AppWindowState.capsuleInset)
    }
}
