import AppKit
import SwiftUI
import Combine

@MainActor
final class WorkspaceWindow: NSWindow {
    enum Command: Int, CaseIterable {
        case newRecording, findRecording, togglePlayback, seekBackward, seekForward, refreshLibrary
        var title: String {
            switch self {
            case .newRecording: "Новая запись"
            case .findRecording: "Найти запись"
            case .refreshLibrary: "Обновить библиотеку"
            case .togglePlayback: "Воспроизвести/Пауза"
            case .seekBackward: "Назад на 5 секунд"
            case .seekForward: "Вперёд на 5 секунд"
            }
        }
        var key: String {
            switch self {
            case .newRecording: "n"
            case .findRecording: "f"
            case .refreshLibrary: "r"
            case .togglePlayback: " "
            case .seekBackward: "\u{f702}"
            case .seekForward: "\u{f703}"
            }
        }
        var modifiers: NSEvent.ModifierFlags { self == .newRecording || self == .findRecording || self == .refreshLibrary ? .command : [] }
    }

    let model: RecorderViewModel
    var isKeyboardTarget: () -> Bool = { false }
    private weak var libraryNavigation: WorkspaceNavigationView?
    private weak var transcriptNavigation: WorkspaceNavigationView?
    private weak var preferredNavigation: WorkspaceNavigationView?
    private weak var searchField: NSTextField?
    private var didSetInitialFocus = false
    private var restoringNavigation = false
    private var trashObservation: AnyCancellable?
    private weak var trashReturnFocus: NSResponder?
    private var trashWasBlocking = false
    private var trashCompletionAtOpen: UUID?

    init(model: RecorderViewModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        model.workspace.nativeInput = { [weak self] in self?.attachedSheet != nil || NSApp?.modalWindow != nil }
        isKeyboardTarget = { [weak self] in NSApp.isActive && self?.isKeyWindow == true }
        model.libraryRefreshTarget = { [weak self] in
            guard let self else { return false }
            return self.isKeyboardTarget() && self.isVisible && !self.isMiniaturized
        }
        trashObservation = model.$recordingTrash.combineLatest(model.$trashAdmitting).sink { [weak self] presentation, admitting in
            guard let self else { return }
            let blocked = presentation != nil || admitting
            if blocked && !self.trashWasBlocking {
                self.trashReturnFocus = self.firstResponder
                self.trashCompletionAtOpen = model.trashCompletion?.id
            }
            let restore = self.trashWasBlocking && !blocked && self.trashCompletionAtOpen == model.trashCompletion?.id
            self.trashWasBlocking = blocked
            self.canHide = !blocked
            self.standardWindowButton(.closeButton)?.isEnabled = !blocked
            self.standardWindowButton(.miniaturizeButton)?.isEnabled = !blocked
            if restore {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !model.trashOwnsInput, self.isVisible else { return }
                    if let view = self.trashReturnFocus as? NSView, view.window === self, !view.isHiddenOrHasHiddenAncestor,
                       view.acceptsFirstResponder { self.makeFirstResponder(view) }
                    else { self.focusAvailableNavigation() }
                    self.trashReturnFocus = nil
                }
            }
        }
    }

    var admitsNavigationKeys: Bool {
        isKeyboardTarget() && isVisible && !isMiniaturized && attachedSheet == nil
            && model.mainPage == .history && !model.workspace.hasInput
    }

    private var admitsTrashConfirmationKeys: Bool {
        isKeyboardTarget() && isVisible && !isMiniaturized && attachedSheet == nil
            && model.mainPage == .history && !model.workspace.nativeInput()
            && !model.settingsPresented && !model.workspace.externalModal
            && model.workspace.current?.currentDraftIdentity == nil
    }

    func isPaneVisible(_ pane: WorkspaceNavigationView.Pane) -> Bool {
        guard let contentView, contentView.bounds.width <= 767 else { return true }
        return pane == .library ? model.workspaceShowsList : !model.workspaceShowsList
    }

    func allows(_ command: Command) -> Bool {
        guard admitsNavigationKeys else { return false }
        switch command {
        case .newRecording: return model.canStartRecording && !model.workspace.nativeInput()
        case .findRecording: return true
        case .refreshLibrary: return model.canRefreshLibrary
        case .togglePlayback, .seekBackward, .seekForward:
            guard let surface = firstResponder as? WorkspaceNavigationView, surface.window === self,
                  surface.isUsable,
                  !model.workspace.loading, let current = model.workspace.current,
                  current.state.id == model.selectedHistoryURL, !current.state.isClosed else { return false }
            return current.playbackEnabled
        }
    }

    func dispatch(_ command: Command, repeating: Bool = false) {
        guard allows(command) else { return }
        switch command {
        case .newRecording: model.requestRecordingForm()
        case .refreshLibrary:
            if !repeating { model.requestLibraryRefresh() }
        case .findRecording:
            model.workspaceShowsList = true
            model.workspaceSearchRequest = UUID()
        case .togglePlayback:
            if !repeating { model.workspace.current?.togglePlayback() }
        case .seekBackward, .seekForward:
            guard let current = model.workspace.current,
                  let seek = current.requestPlaybackSeek(to: current.playbackSeekPosition + (command == .seekBackward ? -5 : 5)) else { return }
            let request = model.workspaceLoadRequest, result = current.currentResultID
            Task { [weak self, weak current] in
                guard let current else { return }
                guard let self, self.allows(command), self.model.workspaceLoadRequest == request,
                      self.model.workspace.current === current, current.currentResultID == result else { current.cancelPlaybackSeek(seek); return }
                await current.performPlaybackSeek(seek)
            }
        }
    }

    func handleNavigationKey(_ event: NSEvent) -> Bool {
        guard let surface = firstResponder as? WorkspaceNavigationView, surface.isUsable,
              surface.window === self, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        let command: Command
        switch event.keyCode {
        case 51, 117:
            guard surface.pane == .library else { return false }
            if admitsNavigationKeys, !event.isARepeat, let recording = model.selectedHistoryURL {
                Task { [weak self, weak surface] in
                    guard let self, let surface, self.admitsNavigationKeys, surface.isUsable,
                          self.firstResponder === surface, self.model.selectedHistoryURL == recording else { return }
                    await surface.onDeleteKey?()
                }
            }
            return true
        case 49: command = .togglePlayback
        case 123: command = .seekBackward
        case 124: command = .seekForward
        case 125, 126:
            if admitsNavigationKeys { surface.onVerticalKey?(event.keyCode == 125 ? 1 : -1) }
            return true
        default: return false
        }
        dispatch(command, repeating: event.isARepeat)
        return true
    }

    func navigateTranscriptTurn(by direction: Int) {
        navigateTranscriptTurn {
            $0.beginTurnNavigationGesture()
            return $0.requestTurnNavigation(by: direction)
        }
    }

    func navigateTranscriptTurn(to turnID: String) {
        navigateTranscriptTurn { $0.requestTurnNavigation(to: turnID) }
    }

    private func navigateTranscriptTurn(_ request: (TranscriptReviewWindowModel) -> TranscriptReviewWindowModel.TurnNavigation?) {
        guard admitsNavigationKeys, let surface = transcriptNavigation, surface.isUsable,
              firstResponder === surface, !model.workspace.loading,
              let current = model.workspace.current, current.state.id == model.selectedHistoryURL,
              let target = request(current) else { return }
        let load = model.workspaceLoadRequest, result = current.currentResultID
        Task { [weak self, weak current, weak surface] in
            guard let current else { return }
            guard let self, let surface, self.admitsNavigationKeys, surface.isUsable,
                  self.firstResponder === surface, !self.model.workspace.loading,
                  self.model.workspace.current === current, self.model.workspaceLoadRequest == load,
                  current.currentResultID == result else { current.cancelTurnNavigation(target); return }
            await current.performTurnNavigation(target)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let presentation = model.recordingTrash, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
            guard admitsTrashConfirmationKeys else { return false }
            if event.isARepeat { return true }
            if event.keyCode == 53 { model.cancelRecordingTrash() }
            else {
                guard !presentation.pending, presentation.error == nil || presentation.retryAllowed else { return true }
                Task { [weak self] in
                    guard let self, self.admitsTrashConfirmationKeys, self.model.recordingTrash?.id == presentation.id else { return }
                    await self.model.confirmRecordingTrash()
                }
            }
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command {
            let command: Command?
            switch event.keyCode {
            case 45: command = .newRecording
            case 3: command = .findRecording
            case 15: command = .refreshLibrary
            default: command = nil
            }
            if let command {
                if command == .refreshLibrary, !allows(command) { return super.performKeyEquivalent(with: event) }
                dispatch(command, repeating: event.isARepeat)
                return true
            }
        }
        if handleNavigationKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    func makeCommandMenu() -> NSMenu {
        let menu = NSMenu(title: "Запись")
        for command in Command.allCases where command != .refreshLibrary {
            menu.addItem(makeCommandMenuItem(command))
        }
        return menu
    }

    func makeCommandMenuItem(_ command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: #selector(performWorkspaceCommand(_:)), keyEquivalent: command.key)
        item.keyEquivalentModifierMask = command.modifiers
        item.tag = command.rawValue
        item.target = self
        return item
    }

    @objc private func performWorkspaceCommand(_ sender: NSMenuItem) {
        if let command = Command(rawValue: sender.tag) { dispatch(command, repeating: NSApp.currentEvent?.isARepeat == true) }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performWorkspaceCommand(_:)) else { return super.validateMenuItem(item) }
        guard let command = Command(rawValue: item.tag) else { return false }
        return allows(command)
    }

    override func orderOut(_ sender: Any?) {
        guard !model.trashOwnsInput else { return }
        model.workspaceSearchRequest = nil
        super.orderOut(sender)
    }

    override func close() {
        guard !model.trashOwnsInput else { return }
        super.close()
    }

    override func miniaturize(_ sender: Any?) {
        guard !model.trashOwnsInput else { return }
        super.miniaturize(sender)
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place != .out || !model.trashOwnsInput else { return }
        super.order(place, relativeTo: otherWin)
    }

    func registerNavigation(_ surface: WorkspaceNavigationView) {
        if surface.pane == .library { libraryNavigation = surface }
        else { transcriptNavigation = surface }
        if admitsNavigationKeys, !isPaneVisible(.library), let searchField {
            relinquishSearchField(searchField)
        }
        if firstResponder === surface, !surface.isUsable {
            restoringNavigation = true
            makeFirstResponder(nil)
        }
        if !didSetInitialFocus, surface.pane == .library, surface.isUsable {
            initialFirstResponder = surface
            if admitsNavigationKeys { surface.focus() }
        } else if restoringNavigation { focusAvailableNavigation() }
    }

    func trackSearchField(_ field: NSTextField) { searchField = field }

    func relinquishSearchField(_ field: NSTextField) {
        if let editor = firstResponder as? NSTextView, editor.delegate === field {
            relinquishDisappearingResponder(editor)
        } else { relinquishDisappearingResponder(field) }
    }

    func unregisterNavigation(_ surface: WorkspaceNavigationView) {
        if libraryNavigation === surface { libraryNavigation = nil }
        if transcriptNavigation === surface { transcriptNavigation = nil }
        if preferredNavigation === surface { preferredNavigation = nil }
        if initialFirstResponder === surface { initialFirstResponder = nil }
        relinquishDisappearingResponder(surface)
    }

    func relinquishDisappearingResponder(_ responder: NSResponder) {
        if firstResponder === responder {
            restoringNavigation = true
            makeFirstResponder(nil)
            focusAvailableNavigation()
        }
    }

    func didFocusNavigation(_ surface: WorkspaceNavigationView) {
        preferredNavigation = surface
        didSetInitialFocus = true
        restoringNavigation = false
    }

    func focusAvailableNavigation() {
        guard admitsNavigationKeys else { return }
        let target = [preferredNavigation, libraryNavigation, transcriptNavigation].compactMap { $0 }.first { $0.isUsable }
        if let target { target.focus() }
    }

    func recoverNavigationFocus() {
        guard admitsNavigationKeys else { return }
        if let responder = firstResponder, responder !== self {
            guard let view = responder as? NSView else { return }
            if view.window === self, !view.isHiddenOrHasHiddenAncestor, view.acceptsFirstResponder {
                restoringNavigation = false
                return
            }
        }
        focusAvailableNavigation()
    }

    override func becomeKey() {
        super.becomeKey()
        model.objectWillChange.send()
        if !didSetInitialFocus { focusAvailableNavigation() }
        else { recoverNavigationFocus() }
    }

    override func resignKey() {
        model.workspace.current?.endTurnNavigationGesture()
        super.resignKey()
        model.objectWillChange.send()
    }
}

@MainActor
final class WorkspaceNavigationView: NSView, ObservableObject {
    enum Pane: String { case library, transcript }
    let pane: Pane
    var isNavigationEnabled = true
    var onVerticalKey: ((Int) -> Void)?
    var onDeleteKey: (@MainActor () async -> Void)?
    private weak var owner: WorkspaceWindow?
    var isUsable: Bool {
        isNavigationEnabled && (window as? WorkspaceWindow)?.isPaneVisible(pane) == true
            && bounds.width > 0 && bounds.height > 0 && !isHiddenOrHasHiddenAncestor
    }
    init(_ pane: Pane) {
        self.pane = pane
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("workspace-\(pane.rawValue)-navigation")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(pane == .library ? "Список записей" : "Текст транскрипта")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { isUsable }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func focus() {
        guard isUsable, let window = window as? WorkspaceWindow, window.admitsNavigationKeys else { return }
        window.makeFirstResponder(self)
    }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        (window as? WorkspaceWindow)?.didFocusNavigation(self)
        return true
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, pane == .transcript { owner?.model.workspace.current?.endTurnNavigationGesture() }
        return accepted
    }
    override func keyUp(with event: NSEvent) {
        if pane == .transcript, event.keyCode == 125 || event.keyCode == 126 {
            owner?.model.workspace.current?.endTurnNavigationGesture()
            return
        }
        super.keyUp(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let next = window as? WorkspaceWindow
        if owner !== next { owner?.unregisterNavigation(self); owner = next }
        owner?.registerNavigation(self)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { owner?.unregisterNavigation(self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        owner?.registerNavigation(self)
    }
    override func keyDown(with event: NSEvent) {
        if let window = window as? WorkspaceWindow, window.handleNavigationKey(event) { return }
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        super.keyDown(with: event)
    }
}

struct WorkspaceNavigationFocus: NSViewRepresentable {
    let surface: WorkspaceNavigationView
    var visible = true
    var onVerticalKey: ((Int) -> Void)? = nil
    var onDeleteKey: (@MainActor () async -> Void)? = nil
    func makeNSView(context: Context) -> WorkspaceNavigationView { surface }
    func updateNSView(_ view: WorkspaceNavigationView, context: Context) {
        view.isNavigationEnabled = visible && context.environment.isEnabled
        view.onVerticalKey = onVerticalKey
        view.onDeleteKey = onDeleteKey
        (view.window as? WorkspaceWindow)?.registerNavigation(view)
    }
}

struct WorkspaceSearchField: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var model: RecorderViewModel

    final class Field: NSTextField {
        var focus: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? WorkspaceWindow)?.trackSearchField(self)
            focus?()
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow, let host = window as? WorkspaceWindow {
                host.relinquishSearchField(self)
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WorkspaceSearchField
        init(_ parent: WorkspaceSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.placeholderString = "Поиск по встречам и тексту"
        field.setAccessibilityLabel("Поиск по встречам и тексту")
        field.identifier = NSUserInterfaceItemIdentifier("workspace-library-search")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.focus = { [weak field, weak model] in
            guard let request = model?.workspaceSearchRequest, let field, field.window != nil else { return }
            DispatchQueue.main.async { [weak field, weak model] in
                guard let model, model.workspaceSearchRequest == request else { return }
                model.workspaceSearchRequest = nil
                guard let field, let window = field.window as? WorkspaceWindow,
                      window.allows(.findRecording) else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
        field.focus?()
    }
}
