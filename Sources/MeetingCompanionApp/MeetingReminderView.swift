import AppKit
import Combine
import Foundation
import MeetingCompanionCore
import SwiftUI

// MARK: - Reminder Floating Panel

final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Date Formatting Helper

func formatMeetingInterval(start: Date, end: Date) -> String {
    let startStr = start.formatted(date: .omitted, time: .shortened)
    let endStr = end.formatted(date: .omitted, time: .shortened)
    let prefix: String
    if Calendar.current.isDateInToday(start) {
        prefix = "Сегодня, "
    } else if Calendar.current.isDateInTomorrow(start) {
        prefix = "Завтра, "
    } else {
        prefix = start.formatted(date: .abbreviated, time: .omitted) + ", "
    }
    return "\(prefix)\(startStr)–\(endStr)"
}

// MARK: - Presenter

@MainActor
final class MeetingReminderPresenter: ObservableObject {
    enum DisplayMode: Equatable, CustomStringConvertible {
        case idle
        case recording
        case terminalError(reason: String)

        var description: String {
            switch self {
            case .idle: return "idle"
            case .recording: return "recording"
            case .terminalError(let reason): return "terminalError(\(reason))"
            }
        }
    }

    @Published var mode: DisplayMode
    @Published var selectedMeeting: MeetingContext?
    @Published var isChooserOpen: Bool = false
    @Published var isTransitioning: Bool = false

    var onLayoutChanged: (() -> Void)?

    private weak var model: RecorderViewModel?
    private weak var calendar: MeetingCalendar?
    private let expectedSessionID: UUID?
    private let onDismiss: () -> Void
    private var observations = Set<AnyCancellable>()

    init(
        model: RecorderViewModel,
        calendar: MeetingCalendar,
        initialMeeting: MeetingContext?,
        expectedSessionID: UUID?,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.calendar = calendar
        self.expectedSessionID = expectedSessionID
        self.onDismiss = onDismiss
        self.selectedMeeting = initialMeeting
        self.mode = model.isRecording ? .recording : .idle
        model.objectWillChange.merge(with: calendar.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    var isRecording: Bool {
        model?.isRecording ?? false
    }

    var currentRecordingTitle: String {
        guard let model else { return "Без встречи" }
        if let id = model.recordingMeetingID,
           let event = calendar?.events.first(where: { $0.id == id }) {
            return event.summary.isEmpty ? "Встреча" : event.summary
        }
        return model.lastRecordingTitle.isEmpty ? "Без встречи" : model.lastRecordingTitle
    }

    var currentRecordingElapsedText: String {
        model?.elapsedText ?? "00:00"
    }

    var isShortRecording: Bool {
        guard let model, model.isRecording else { return false }
        return model.elapsed < 10
    }

    var explanationText: String {
        if isShortRecording {
            return "Текущая запись короче 10 секунд будет отменена. Затем начнём новую."
        } else {
            return "Завершим текущую запись и начнём новую. Обработка предыдущей продолжится в фоне."
        }
    }

    var candidateMeetings: [MeetingContext] {
        guard let calendar else { return [] }
        let recordingID = model?.recordingMeetingID
        var list = calendar.events.filter { $0.id != recordingID }
        if let selected = selectedMeeting, !list.contains(where: { $0.id == selected.id }) {
            list.append(selected)
        }
        return list
    }

    func selectMeeting(_ meeting: MeetingContext?) {
        selectedMeeting = meeting
        model?.reminderMeeting = meeting
        isChooserOpen = false
        onLayoutChanged?()
    }

    func skip() {
        guard !isTransitioning else { return }
        isChooserOpen = false
        onDismiss()
    }

    func accept() {
        guard !isTransitioning, let model else { return }
        isChooserOpen = false
        isTransitioning = true

        let selected = selectedMeeting
        let sessionID = expectedSessionID

        model.startMeeting(selected, expectedSessionID: sessionID) { [weak self] outcome in
            guard let self else { return }
            self.isTransitioning = false
            switch outcome {
            case .started:
                self.onDismiss()
            case .rejected(let reason), .failed(let reason):
                self.mode = .terminalError(reason: reason)
                self.onLayoutChanged?()
            }
        }
    }

    func dismissError() {
        onDismiss()
    }
}

// MARK: - Meeting Chooser Popover View

struct MeetingChooserPopoverView: View {
    @ObservedObject var presenter: MeetingReminderPresenter
    @FocusState private var focusedIndex: Int?

    private var allOptions: [MeetingContext?] {
        let meetings: [MeetingContext?] = presenter.candidateMeetings.map { Optional($0) }
        return meetings + [nil]
    }

    var body: some View {
        ScrollViewReader { scroll in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(presenter.candidateMeetings.enumerated()), id: \.element.id) { index, meeting in
                            optionRow(
                                meeting: meeting,
                                isSelected: presenter.selectedMeeting?.id == meeting.id,
                                isFocused: focusedIndex == index
                            ) {
                                presenter.selectMeeting(meeting)
                            }
                            .focused($focusedIndex, equals: index)
                            .id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 340)

                Divider()
                    .background(ODColors.line)

                // Fixed "Без встречи" option
                optionRow(
                    meeting: nil,
                    isSelected: presenter.selectedMeeting == nil,
                    isFocused: focusedIndex == presenter.candidateMeetings.count
                ) {
                    presenter.selectMeeting(nil)
                }
                .focused($focusedIndex, equals: presenter.candidateMeetings.count)
            }
            .frame(width: 360)
            .padding(.vertical, 8)
            .background(ODColors.surface)
            .onKeyPress(.downArrow) {
                let count = allOptions.count
                if count > 0 {
                    focusedIndex = ((focusedIndex ?? -1) + 1) % count
                }
                return .handled
            }
            .onKeyPress(.upArrow) {
                let count = allOptions.count
                if count > 0 {
                    focusedIndex = ((focusedIndex ?? 0) - 1 + count) % count
                }
                return .handled
            }
            .onKeyPress(.return) {
                commitFocused()
                return .handled
            }
            .onKeyPress(.space) {
                commitFocused()
                return .handled
            }
            .onKeyPress(.escape) {
                presenter.isChooserOpen = false
                return .handled
            }
            .onChange(of: focusedIndex) { _, index in
                if let index, index < presenter.candidateMeetings.count {
                    scroll.scrollTo(index, anchor: .center)
                }
            }
            .task {
                focusSelection()
                if let focusedIndex { scroll.scrollTo(focusedIndex, anchor: .center) }
            }
            .onChange(of: presenter.candidateMeetings) { _, _ in focusSelection() }
        }
    }

    private func focusSelection() {
        if let selected = presenter.selectedMeeting {
            focusedIndex = presenter.candidateMeetings.firstIndex { $0.id == selected.id } ?? 0
        } else {
            focusedIndex = presenter.candidateMeetings.count
        }
    }

    private func commitFocused() {
        let options = allOptions
        guard let focusedIndex, options.indices.contains(focusedIndex) else { return }
        presenter.selectMeeting(options[focusedIndex])
    }

    @ViewBuilder
    private func optionRow(
        meeting: MeetingContext?,
        isSelected: Bool,
        isFocused: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Group {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(ODColors.accent)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting?.summary ?? "Без встречи")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ODColors.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(meeting.map { formatMeetingInterval(start: $0.start, end: $0.end) } ?? "Новая запись без привязки к календарю")
                        .font(.system(size: 12))
                        .foregroundStyle(ODColors.muted)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .background(isFocused ? ODColors.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityLabel(meeting?.summary ?? "Без встречи")
    }
}

// MARK: - Main Meeting Reminder View

struct MeetingReminderView: View {
    @ObservedObject var presenter: MeetingReminderPresenter
    @FocusState private var chooserFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    contentHeader
                    if case .terminalError(let reason) = presenter.mode {
                        terminalErrorContent(reason: reason)
                    } else {
                        if presenter.mode == .recording {
                            recordingContextBox
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            actionsArea
        }
        .padding(24)
        .frame(width: 440)
        .modifier(MeetingOverlaySurface(capsule: false))
        .onChange(of: presenter.explanationText) { _, _ in presenter.onLayoutChanged?() }
    }

    @ViewBuilder
    private var contentHeader: some View {
        switch presenter.mode {
        case .terminalError:
            VStack(alignment: .leading, spacing: 8) {
                Text("Не удалось начать запись")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(ODColors.ink)
            }
        case .idle, .recording:
            VStack(alignment: .leading, spacing: 0) {
                Text(presenter.mode == .recording ? "Начинается следующая встреча" : "Встреча начинается")
                    .font(.system(size: 13, weight: .medium))
                    .odLineBox(size: 13, height: 19.5)
                    .foregroundStyle(ODColors.muted)

                Text(presenter.selectedMeeting?.summary ?? "Без встречи")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.6)
                    .odLineBox(size: 28, height: 33.6)
                    .foregroundStyle(ODColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                Text(presenter.selectedMeeting.map { formatMeetingInterval(start: $0.start, end: $0.end) } ?? "Новая запись без привязки к календарю")
                    .font(.system(size: 16))
                    .odLineBox(size: 16, height: 24)
                    .foregroundStyle(ODColors.muted)
                    .monospacedDigit()
                    .padding(.top, 8)

                Button {
                    presenter.isChooserOpen.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("Другая встреча")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: presenter.isChooserOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(ODColors.ink)
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($chooserFocused)
                .onKeyPress(.space) {
                    presenter.isChooserOpen = true
                    return .handled
                }
                .onKeyPress(.return) {
                    presenter.isChooserOpen = true
                    return .handled
                }
                .frame(minHeight: 36)
                .padding(.top, 16)
                .popover(isPresented: $presenter.isChooserOpen, arrowEdge: .bottom) {
                    MeetingChooserPopoverView(presenter: presenter)
                        .onDisappear {
                            DispatchQueue.main.async { chooserFocused = true }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func terminalErrorContent(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reason)
                .font(.system(size: 14))
                .foregroundStyle(ODColors.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var recordingContextBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .background(ODColors.line)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(nsColor: .systemRed))
                        .frame(width: 8, height: 8)

                    Text("Сейчас записывается")
                        .font(.system(size: 13, weight: .medium))
                        .odLineBox(size: 13, height: 19.5)
                        .foregroundStyle(ODColors.muted)
                }

                HStack(spacing: 6) {
                    Text(presenter.currentRecordingTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ODColors.ink)
                        .lineLimit(1)

                    Text("·")
                        .foregroundStyle(ODColors.muted)

                    Text(presenter.currentRecordingElapsedText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ODColors.ink)
                        .monospacedDigit()
                }
                .odLineBox(size: 15, height: 22.5)
            }
            .padding(.vertical, 12)

            Divider()
                .background(ODColors.line)

            Text(presenter.explanationText)
                .font(.system(size: 14))
                .odLineBox(size: 14, height: 21)
                .foregroundStyle(ODColors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var actionsArea: some View {
        switch presenter.mode {
        case .terminalError:
            Button {
                presenter.dismissError()
            } label: {
                Text("Закрыть").frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(ODButtonStyle(primary: true))

        case .idle:
            VStack(spacing: 16) {
                Divider().background(ODColors.line)
                HStack {
                    Button("Пропустить") {
                        presenter.skip()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ODColors.ink)
                    .frame(minHeight: 44)

                    Spacer()

                    Button {
                        presenter.accept()
                    } label: {
                        Text("Начать запись").padding(.horizontal, 4).frame(minHeight: 28)
                    }
                    .buttonStyle(ODButtonStyle(primary: true))
                    .disabled(presenter.isTransitioning)
                }
            }

        case .recording:
            VStack(spacing: 8) {
                Button {
                    presenter.accept()
                } label: {
                    Text("Завершить и начать новую").frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(ODButtonStyle(primary: true))
                .disabled(presenter.isTransitioning)

                Button("Пропустить") {
                    presenter.skip()
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ODColors.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }
}
