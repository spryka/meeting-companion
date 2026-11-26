import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Reminder Floating Panel

final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var cardView: NSView? { (contentView as? ReminderSurfaceHost)?.hostingView ?? contentView }
    var reminderView: NSHostingView<MeetingReminderView>? { cardView as? NSHostingView<MeetingReminderView> }
    var cardFrame: NSRect {
        guard let cardView else { return frame }
        return convertToScreen(cardView.convert(cardView.bounds, to: nil))
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Placement already clamps the card; transparent shadow paint may extend beyond visibleFrame.
        contentView is ReminderSurfaceHost ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    static func reminderFrame(fittingSize: NSSize, screen: NSRect, capsule: NSRect?) -> NSRect {
        let width = min(360, max(0, screen.width - 32))
        var height = min(max(0, screen.height - 32), fittingSize.height)
        let x = screen.maxX - width - 16
        var y = screen.maxY - height - 16
        if let capsule {
            let frame = NSRect(x: x, y: y, width: width, height: height)
            if frame.intersects(capsule) {
                let below = max(0, capsule.minY - screen.minY - 24)
                let above = max(0, screen.maxY - capsule.maxY - 24)
                if below >= height || below >= above {
                    height = min(height, below)
                    y = capsule.minY - height - 8
                } else {
                    height = min(height, above)
                    y = capsule.maxY + 8
                }
            }
        }
        y = max(screen.minY + 16, min(screen.maxY - height - 16, y))
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

final class ReminderSurfaceHost: NSView {
    let hostingView: NSView
    private let radius: CGFloat
    private let shadows = [CALayer(), CALayer()]

    static func paintFrame(for card: NSRect) -> NSRect {
        NSRect(x: card.minX - 80, y: card.minY - 104, width: card.width + 160, height: card.height + 184)
    }

    init(hostingView: NSView, radius: CGFloat) {
        self.hostingView = hostingView
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for shadow in shadows { layer?.addSublayer(shadow) }
        addSubview(hostingView)
        updateShadows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hostingView.frame = NSRect(x: 80, y: 104, width: max(0, bounds.width - 160), height: max(0, bounds.height - 184))
        updateShadows()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadows()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hostingView.frame.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    private func updateShadows() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? CGColor(gray: 0, alpha: 1) : CGColor(srgbRed: 36/255.0, green: 52/255.0, blue: 74/255.0, alpha: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, shadow) in shadows.enumerated() {
            shadow.frame = bounds
            shadow.shadowPath = CGPath(roundedRect: hostingView.frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
            shadow.shadowColor = color
            shadow.shadowOpacity = index == 0 ? (dark ? 0.333 : 0.102) : (dark ? 0.2 : 0.039)
            // CSS blur is twice the Gaussian standard deviation used by Core Animation.
            shadow.shadowRadius = index == 0 ? 40 : 4
            shadow.shadowOffset = CGSize(width: 0, height: index == 0 ? -24 : -2)
        }
        CATransaction.commit()
    }
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

// MARK: - Compact presentation

// SwiftUI rounds a Text's native line box; CSS leading must use that measured box.
private struct ReminderLineLayout: Layout {
    let height: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let dimensions = subviews[0].dimensions(in: proposal)
        return CGSize(width: dimensions.width,
            height: dimensions[.lastTextBaseline] - dimensions[.firstTextBaseline] + height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let proposal = ProposedViewSize(width: bounds.width, height: nil)
        let dimensions = subviews[0].dimensions(in: proposal)
        let singleLineHeight = dimensions.height - (dimensions[.lastTextBaseline] - dimensions[.firstTextBaseline])
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (height - singleLineHeight) / 2), proposal: proposal)
    }
}

private struct ReminderLineBox: ViewModifier {
    let size: CGFloat
    let height: CGFloat
    @Environment(\.displayScale) private var scale
    func body(content: Content) -> some View {
        let font = NSFont.systemFont(ofSize: size)
        let nativeHeight = ceil((font.ascender - font.descender + font.leading) * scale) / scale
        ReminderLineLayout(height: height) { content.lineSpacing(max(0, height - nativeHeight)) }
    }
}

extension View {
    func reminderLineBox(size: CGFloat, height: CGFloat) -> some View {
        modifier(ReminderLineBox(size: size, height: height))
    }
}

private enum ReminderColors {
    static let hover = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0x30/255.0, green: 0x38/255.0, blue: 0x44/255.0, alpha: 1)
                  : NSColor(srgbRed: 0xed/255.0, green: 0xf1/255.0, blue: 0xf6/255.0, alpha: 1)
    })
    static let primaryInk = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0x15/255.0, green: 0x24/255.0, blue: 0x3b/255.0, alpha: 1) : .white
    })
    static let recording = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0xff/255.0, green: 0x9a/255.0, blue: 0xa8/255.0, alpha: 1)
                  : NSColor(srgbRed: 0xb8/255.0, green: 0x2d/255.0, blue: 0x3d/255.0, alpha: 1)
    })
}

private struct ReminderButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? (enabled ? ReminderColors.primaryInk : ODColors.muted) : ODColors.ink)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .circular)
                    .fill(primary ? (enabled ? (hovering ? ODColors.accentHover : ODColors.accent) : ReminderColors.hover)
                          : (hovering || configuration.isPressed ? ReminderColors.hover : .clear))
                    .shadow(color: .black.opacity(primary && enabled ? 0.067 : 0), radius: 2, y: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .circular))
            .onHover { hovering = $0 }
    }
}

private struct ReminderSymbol: Shape {
    var check = false
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = check
            ? [CGPoint(x: 5, y: 12), CGPoint(x: 9, y: 16), CGPoint(x: 19, y: 6)]
            : [CGPoint(x: 7, y: 10), CGPoint(x: 12, y: 15), CGPoint(x: 17, y: 10)]
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width / 24, y: rect.minY + $0.y * rect.height / 24) })
        return path
    }
}

// MARK: - Separate chooser

struct MeetingChooserPopoverView: View {
    @ObservedObject var presenter: MeetingReminderPresenter
    var width: CGFloat = 336
    var height: CGFloat = 420
    @FocusState private var focusedIndex: Int?

    private var allOptions: [MeetingContext?] {
        presenter.candidateMeetings.map { Optional($0) } + [nil]
    }

    var body: some View {
        ScrollViewReader { scroll in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(presenter.candidateMeetings.enumerated()), id: \.element.id) { index, meeting in
                            optionRow(meeting: meeting, index: index)
                                .focused($focusedIndex, equals: index)
                                .id(index)
                        }
                    }
                    .padding(4)
                }
                Rectangle().fill(ODColors.line).frame(height: 1)
                optionRow(meeting: nil, index: presenter.candidateMeetings.count)
                    .focused($focusedIndex, equals: presenter.candidateMeetings.count)
                    .padding(4)
            }
            .padding(1)
            .frame(width: width, height: height)
            .background(ODColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .circular))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .circular))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(ODColors.line, lineWidth: 1))
            .onKeyPress(.downArrow) {
                focusedIndex = ((focusedIndex ?? -1) + 1) % allOptions.count
                return .handled
            }
            .onKeyPress(.upArrow) {
                focusedIndex = ((focusedIndex ?? 0) - 1 + allOptions.count) % allOptions.count
                return .handled
            }
            .onKeyPress(.return) { commitFocused(); return .handled }
            .onKeyPress(.space) { commitFocused(); return .handled }
            .onKeyPress(.escape) { presenter.isChooserOpen = false; return .handled }
            .onChange(of: focusedIndex) { _, index in
                if let index, index < presenter.candidateMeetings.count { scroll.scrollTo(index, anchor: .center) }
            }
            .task {
                focusSelection()
                if let focusedIndex { scroll.scrollTo(focusedIndex, anchor: .center) }
            }
            .onChange(of: presenter.candidateMeetings) { _, _ in focusSelection() }
        }
    }

    private func focusSelection() {
        focusedIndex = presenter.selectedMeeting.flatMap { selected in
            presenter.candidateMeetings.firstIndex { $0.id == selected.id }
        } ?? (presenter.selectedMeeting == nil ? presenter.candidateMeetings.count : 0)
    }

    private func commitFocused() {
        let options = allOptions
        guard let focusedIndex, options.indices.contains(focusedIndex) else { return }
        presenter.selectMeeting(options[focusedIndex])
    }

    private func optionRow(meeting: MeetingContext?, index: Int) -> some View {
        let selected = presenter.selectedMeeting?.id == meeting?.id
        return Button { presenter.selectMeeting(meeting) } label: {
            HStack(spacing: 12) {
                ReminderSymbol(check: true)
                    .stroke(ODColors.accent, style: StrokeStyle(lineWidth: 1.7 * 16 / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 16)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting?.summary ?? "Без встречи")
                        .font(.system(size: 13))
                        .reminderLineBox(size: 13, height: 18.2)
                        .foregroundStyle(ODColors.ink)
                    Text(meeting.map { formatMeetingInterval(start: $0.start, end: $0.end) } ?? "Новая запись без привязки к календарю")
                        .font(.system(size: 12))
                        .reminderLineBox(size: 12, height: 16.8)
                        .offset(y: -1)
                        .foregroundStyle(ODColors.muted)
                        .monospacedDigit()
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(focusedIndex == index ? ReminderColors.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(ReminderButtonStyle())
        .focusable()
        .disabled(presenter.isTransitioning)
        .accessibilityLabel(meeting?.summary ?? "Без встречи")
        .accessibilityValue(selected ? "Выбрано" : "")
    }
}

// A child panel avoids NSPopover's extra chrome and keeps the reminder frame unchanged.
private struct MeetingChooserAnchor: NSViewRepresentable {
    @ObservedObject var presenter: MeetingReminderPresenter
    let restoreFocus: () -> Void

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.presenter = presenter
        view.restoreFocus = restoreFocus
        if presenter.isChooserOpen { view.showChooser() } else { view.dismissChooser() }
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.dismissChooser(restoreFocus: false) }

    final class Anchor: NSView {
        weak var presenter: MeetingReminderPresenter?
        var restoreFocus: (() -> Void)?
        private var panel: ReminderPanel?
        private var localMonitor: Any?
        private var globalMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { dismissChooser(restoreFocus: false) }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            panel?.appearance = effectiveAppearance
        }

        func showChooser() {
            guard panel == nil, let parent = window, let presenter else { return }
            let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
            let width = min(336, max(0, screen.width - 32))
            let height = min(420, max(0, screen.height - 32))
            let anchor = parent.convertToScreen(convert(bounds, to: nil))
            let below = anchor.minY - screen.minY - 24
            let above = screen.maxY - anchor.maxY - 24
            let y = below >= height || below >= above ? anchor.minY - height - 8 : anchor.maxY + 8
            let frame = NSRect(x: max(screen.minX + 16, min(anchor.minX, screen.maxX - width - 16)).rounded(),
                y: max(screen.minY + 16, min(y, screen.maxY - height - 16)).rounded(), width: width, height: height)
            let chooser = ReminderPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            chooser.isOpaque = false
            chooser.appearance = parent.effectiveAppearance
            chooser.backgroundColor = .clear
            chooser.hasShadow = false
            chooser.isReleasedWhenClosed = false
            chooser.hidesOnDeactivate = false
            chooser.collectionBehavior = parent.collectionBehavior
            chooser.level = parent.level
            let host = NSHostingView(rootView: MeetingChooserPopoverView(presenter: presenter, width: width, height: height))
            host.sizingOptions = []
            chooser.contentView = ReminderSurfaceHost(hostingView: host, radius: 12)
            chooser.setFrame(ReminderSurfaceHost.paintFrame(for: frame), display: true)
            parent.addChildWindow(chooser, ordered: .above)
            panel = chooser
            chooser.makeKeyAndOrderFront(nil)
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.window === self.panel, let card = self.panel?.cardView,
                   card.bounds.contains(card.convert(event.locationInWindow, from: nil)) { return event }
                if self.convert(self.bounds, to: nil).contains(event.locationInWindow), event.window === self.window { return event }
                self.closeFromOutside()
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeFromOutside() }
            }
        }

        private func closeFromOutside() {
            presenter?.isChooserOpen = false
            dismissChooser(restoreFocus: false)
            restoreFocus?()
        }

        func dismissChooser(restoreFocus shouldRestore: Bool = true) {
            guard let panel else { return }
            let wasKey = panel.isKeyWindow
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            localMonitor = nil
            globalMonitor = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            self.panel = nil
            if shouldRestore {
                if wasKey { window?.makeKey() }
                restoreFocus?()
            }
        }
    }
}

// MARK: - Main reminder

struct MeetingReminderView: View {
    @ObservedObject var presenter: MeetingReminderPresenter
    var width: CGFloat = 360
    @FocusState private var chooserFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .vertical) {
                textContent
                ScrollView(.vertical) { textContent }
            }
            actionsArea.fixedSize(horizontal: false, vertical: true)
        }
        .padding(17) // Border 1 + inner padding 16, inside the outer frame.
        .frame(width: width)
        .modifier(MeetingOverlaySurface(capsule: false))
        .onChange(of: presenter.isShortRecording) { _, _ in presenter.onLayoutChanged?() }
        .onChange(of: presenter.currentRecordingTitle) { _, _ in presenter.onLayoutChanged?() }
        .onChange(of: presenter.currentRecordingElapsedText) { _, _ in presenter.onLayoutChanged?() }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .terminalError(let reason) = presenter.mode {
                Text("Не удалось начать запись")
                    .font(Font(NSFont.systemFont(ofSize: 21, weight: NSFont.Weight(rawValue: 0.33))))
                    .reminderLineBox(size: 21, height: 26.25)
                    .foregroundStyle(ODColors.ink)
                Text(reason)
                    .font(.system(size: 12))
                    .reminderLineBox(size: 12, height: 18)
                    .foregroundStyle(ODColors.muted)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            } else {
                Text(presenter.mode == .recording ? "Следующая встреча" : "Встреча начинается")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(0.12)
                    .reminderLineBox(size: 12, height: 16.8)
                    .offset(y: -0.5)
                    .foregroundStyle(ODColors.muted)
                VStack(alignment: .leading, spacing: 6) {
                    Text(presenter.selectedMeeting?.summary ?? "Без встречи")
                        .font(Font(NSFont.systemFont(ofSize: 21, weight: NSFont.Weight(rawValue: 0.33))))
                        .tracking(-0.4)
                        .reminderLineBox(size: 21, height: 26.25)
                        .offset(y: 0.5)
                        .foregroundStyle(ODColors.ink)
                    Text(presenter.selectedMeeting.map { formatMeetingInterval(start: $0.start, end: $0.end) } ?? "Новая запись без привязки к календарю")
                        .font(.system(size: 13))
                        .reminderLineBox(size: 13, height: 19.5)
                        .offset(y: 0.5)
                        .monospacedDigit()
                        .foregroundStyle(ODColors.muted)
                }
                .padding(.top, 8)
                if presenter.mode == .recording {
                    recordingContext.padding(.top, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var recordingContext: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(ODColors.line).frame(height: 1)
            HStack(spacing: 8) {
                Circle().fill(ReminderColors.recording).frame(width: 6, height: 6)
                (Text("Сейчас: ") + Text(presenter.currentRecordingTitle).font(Font(NSFont.systemFont(ofSize: 12, weight: NSFont.Weight(rawValue: 0.245))))
                    .foregroundColor(ODColors.ink) + Text(" · \(presenter.currentRecordingElapsedText.replacingOccurrences(of: ":", with: "\u{2060}:\u{2060}"))"))
                    .font(.system(size: 12))
                    .reminderLineBox(size: 12, height: 18)
                    .foregroundStyle(ODColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 10)
            if presenter.isShortRecording {
                Text("Запись короче 10 секунд будет отменена")
                    .font(.system(size: 12))
                    .reminderLineBox(size: 12, height: 18)
                    .foregroundStyle(ODColors.muted)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var actionsArea: some View {
        if case .terminalError = presenter.mode {
            primaryButton("Закрыть", action: presenter.dismissError)
        } else {
            VStack(spacing: 4) {
                primaryButton(presenter.mode == .recording ? "Завершить и начать новую" : "Начать запись", action: presenter.accept)
                HStack(spacing: 8) {
                    Button { presenter.isChooserOpen.toggle() } label: {
                        HStack(spacing: 4) {
                            Text("Другая встреча")
                                .font(.system(size: 12, weight: .medium))
                                .reminderLineBox(size: 12, height: 18)
                            ReminderSymbol()
                                .stroke(style: StrokeStyle(lineWidth: 1.7 * 16 / 24, lineCap: .round, lineJoin: .round))
                                .frame(width: 16, height: 16)
                                .rotationEffect(.degrees(presenter.isChooserOpen ? 180 : 0))
                        }
                        .padding(.vertical, 8).padding(.horizontal, 4)
                        .frame(minHeight: 36)
                        .background(presenter.isChooserOpen ? ReminderColors.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(ReminderButtonStyle())
                    .focusable()
                    .focused($chooserFocused)
                    .onKeyPress(.space) { presenter.isChooserOpen = true; return .handled }
                    .onKeyPress(.return) { presenter.isChooserOpen = true; return .handled }
                    .background(MeetingChooserAnchor(presenter: presenter) { chooserFocused = true })
                    .accessibilityValue(presenter.isChooserOpen ? "Раскрыто" : "Закрыто")
                    Spacer(minLength: 0)
                    Button(action: presenter.skip) {
                        Text("Пропустить")
                            .font(Font(NSFont.systemFont(ofSize: presenter.mode == .recording ? 13 : 12, weight: NSFont.Weight(rawValue: 0.245))))
                            .reminderLineBox(size: presenter.mode == .recording ? 13 : 12, height: presenter.mode == .recording ? 19.5 : 18)
                            .padding(.vertical, 8).padding(.horizontal, 4)
                            .frame(minHeight: presenter.mode == .recording ? 40 : 36)
                    }
                    .buttonStyle(ReminderButtonStyle())
                }
            }
            .disabled(presenter.isTransitioning)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font(NSFont.systemFont(ofSize: 13, weight: NSFont.Weight(rawValue: 0.245))))
                .reminderLineBox(size: 13, height: 19.5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 9)
                .padding(.horizontal, presenter.mode == .recording ? 8 : 12)
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(ReminderButtonStyle(primary: true))
        .disabled(presenter.isTransitioning)
    }
}
