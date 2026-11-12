import AppKit
import Combine
import SwiftUI
import MeetingCompanionCore
import MeetingCompanionApplication

@MainActor
final class RecorderAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let historyRepository = RecordingHistoryRepository()
    private lazy var sessionService = RecordingSessionService(historyRepo: historyRepository)
    private lazy var processingService: ProcessingService = ProcessingService(
        transcriptionRunner: PlatformTranscriptionRunner(),
        audioExporter: PlatformAudioExporter(),
        historyRepository: historyRepository,
        retryAdmission: { [weak self] recording in
            guard let self else { return false }
            return await self.model.prepareRecordingRetry(recording)
        }
    )
    private lazy var model = RecorderViewModel(
        sessionService: sessionService,
        processingService: processingService,
        historyRepository: historyRepository
    )
    private(set) var capsuleController: RecordingCapsuleController!
    private(set) var window: NSWindow!
    private weak var settingsReturnFocus: NSResponder?
    private weak var settingsFocusWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private(set) var reminder: NSPanel?
    private var recordingObserver: AnyCancellable?
    private var busyObserver: AnyCancellable?
    private var updateObserver: AnyCancellable?
    private lazy var appUpdater = AppUpdater(defaults: model.defaults)
    private var workspacePresenter: (() -> Void)?
    private var updateChecker: (() -> Void)?

    convenience init(model: RecorderViewModel, presentWorkspace: @escaping () -> Void = {}, checkForUpdates: (() -> Void)? = nil) {
        self.init()
        self.model = model
        self.workspacePresenter = presentWorkspace
        self.updateChecker = checkForUpdates
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpPresentation()
        installWorkspaceCommands()
        busyObserver = model.$isBusy.dropFirst().filter { !$0 }.sink { [weak self] _ in
            Task { @MainActor in self?.model.calendar.recheckReminders() }
        }
        model.calendar.onMeeting = { [weak self] meeting in self?.showReminder(meeting) }
        do { try AppLoginItem().configureIfNeeded(defaults: model.defaults) }
        catch { model.errorMessage = "Автозапуск: " + error.localizedDescription }
        showWindow()
        Task { await model.calendar.start() }
        configureUpdatePolicy(appUpdater)
        updateObserver = model.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.appUpdater.refreshReadyMessage() }
        }
        do { try appUpdater.start() }
        catch { NSLog("Meeting Companion updater unavailable: %@", error.localizedDescription) }
    }

    func configureUpdatePolicy(_ updater: AppUpdater) {
        updater.isBusy = { [weak self] in self?.model.preventsTermination ?? true }
        updater.isCheckBusy = { [weak self] in self?.model.preventsSettingsOperation ?? true }
    }

    func installWorkspaceCommands() {
        guard let menu = NSApp.mainMenu, let workspace = window as? WorkspaceWindow else { return }
        let item = NSMenuItem(title: "Запись", action: nil, keyEquivalent: "")
        item.submenu = workspace.makeCommandMenu()
        menu.addItem(item)
        let view = menu.items.first { $0.title == "Вид" || $0.title == "View" }
            ?? NSMenuItem(title: "Вид", action: nil, keyEquivalent: "")
        view.title = "Вид"
        if view.submenu == nil { view.submenu = NSMenu(title: "Вид") }
        view.submenu?.addItem(workspace.makeCommandMenuItem(.refreshLibrary))
        if view.menu == nil { menu.addItem(view) }
    }

    func setUpPresentation() {
        guard window == nil else { return }
        workspacePresenter = nil
        model.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        model.onSettingsVisibilityChange = { [weak self] in
            guard let self else { return }
            self.updatePreviewVisibility()
            if !self.model.settingsPresented {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.model.settingsPresented, let host = self.settingsFocusWindow,
                          host.isVisible, !host.isMiniaturized else { return }
                    let restored = (self.settingsReturnFocus as? NSView).map { target in
                        target.window === host && !target.isHiddenOrHasHiddenAncestor && target.acceptsFirstResponder
                            && host.makeFirstResponder(target) && host.firstResponder === target
                    } ?? false
                    if !restored {
                        if let workspace = host as? WorkspaceWindow { workspace.focusAvailableNavigation() }
                        else { host.makeFirstResponder(host.contentView) }
                    }
                    self.settingsReturnFocus = nil
                }
            }
        }
        NSApp.appearance = model.appearance.value
        NSApp.setActivationPolicy(.accessory)
        window = WorkspaceWindow(model: model)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = AppWindowState.workspaceMinimumSize
        AppWindowState.configureWorkspaceHeader(window)
        window.contentView = NSHostingView(rootView: ContentView(viewModel: model) { [weak self] in self?.showSettings() }.defaultAppStorage(model.defaults))
        window.center()
        capsuleController = RecordingCapsuleController(model: model, defaults: model.defaults)
        model.onRecordingStarted = { [weak self] in
            guard self?.model.trashOwnsInput != true else { return }
            self?.window.orderOut(nil)
            self?.model.setWindowVisible(false)
            self?.updatePreviewVisibility()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        recordingObserver = Publishers.CombineLatest3(model.$isRecording, model.$microphoneMuted, model.$transcriptionJobs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording, muted, jobs in
                self?.updateStatusIcon(isRecording: recording, microphoneMuted: muted, isProcessing: jobs > 0)
            }
        model.onPresentWorkspace = { [weak self] in
            self?.showWindow()
        }
    }

    @objc func statusClicked() {
        guard let button = statusItem.button else { return }
        let menu = makeStatusMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    func makeStatusMenu() -> NSMenu { StatusMenu.build(model: model, appUpdater: appUpdater, target: self) }

    @objc func showSettings() {
        if !model.settingsPresented {
            let host = window?.attachedSheet ?? window
            settingsFocusWindow = host
            settingsReturnFocus = host?.firstResponder
        }
        _ = model.presentSettings()
        presentWorkspace()
    }

    @objc func openRecordings() {
        model.mainPage = .history
        showWindow()
    }

    @objc func startRecordingAction() {
        guard model.requestRecordingForm() else { return }
        showWindow()
    }
    @objc func stopRecordingAction(_ sender: NSMenuItem? = nil) {
        let sessionID = sender?.representedObject as? UUID
        Task { await model.stopRecordingIntent(sessionID: sessionID) }
    }
    @objc func cancelRecordingAction(_ sender: NSMenuItem? = nil) {
        let sessionID = sender?.representedObject as? UUID
        Task { await model.cancelRecordingIntent(sessionID: sessionID) }
    }
    @objc func toggleMicrophoneMuteAction(_ sender: NSMenuItem? = nil) {
        let sessionID = sender?.representedObject as? UUID
        model.toggleMicrophoneMute(sessionID: sessionID)
    }
    @objc func showCapsuleAction() {
        capsuleController?.showCapsule()
    }

    @objc func quit() { NSApp.terminate(nil) }
    @objc func checkForUpdates() {
        if let updateChecker { updateChecker() } else { appUpdater.check() }
    }

    static func showWorkspace(_ model: RecorderViewModel,
                              load: (RecorderViewModel.WorkspaceLoadRequest) -> Void,
                              present: () -> Void) {
        if let request = model.requestWorkspaceOpen() { load(request) }
        present()
    }

    @objc func showWindow() {
        Self.showWorkspace(model, load: { request in
            Task { _ = await self.model.loadWorkspace(request) }
        }, present: { self.presentWorkspace() })
    }

    private func presentWorkspace() {
        if let workspacePresenter { workspacePresenter(); return }
        if window.styleMask.contains(.titled) { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        updatePreviewVisibility()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.admitWindowClose(isWorkspace: sender === window) else { return false }
        sender.orderOut(nil)
        if sender === window {
            model.setWindowVisible(false)
        }
        updatePreviewVisibility()
        return false
    }

    func windowWillBeginSheet(_ notification: Notification) {
        guard let host = notification.object as? WorkspaceWindow, host === window else { return }
        host.model.workspace.current?.invalidateQueuedPlaybackSeek()
    }

    func windowDidEndSheet(_ notification: Notification) {
        guard let host = notification.object as? WorkspaceWindow, host === window else { return }
        DispatchQueue.main.async { [weak host] in host?.recoverNavigationFocus() }
    }

    private func updatePreviewVisibility() {
        AppWindowState.refreshActivationPolicy()
        let appHidden = NSApp?.isHidden ?? false
        let isMainWindowVisible = !appHidden && window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
        let visible = isMainWindowVisible && window?.attachedSheet?.isVisible != false
        updateSettingsPresentationVisibility(workspaceVisible: visible)
        let isTitledMainWindowVisible = isMainWindowVisible && window?.styleMask.contains(.titled) == true
        model.calendar.setMainWindowVisible(isTitledMainWindowVisible)
    }

    func updateSettingsPresentationVisibility(workspaceVisible: Bool) {
        let section = workspaceVisible && model.settingsPresented ? model.settingsPage : nil
        updateAudioPreviewVisibility(workspaceVisible: workspaceVisible, settingsSection: section)
        model.calendar.setCalendarSettingsVisible(section == .calendar)
    }

    func updateAudioPreviewVisibility(workspaceVisible: Bool, settingsSection: RecorderSettingsView.Page?) {
        model.setWindowVisible(workspaceVisible)
        model.setRecordingFormVisible(workspaceVisible && model.mainPage == .recording && !model.settingsPresented)
        let checkPage = settingsSection == .recording || settingsSection == .diagnostics
        model.setAudioCheckVisible(checkPage, section: checkPage ? settingsSection : nil)
    }

    func windowWillClose(_ notification: Notification) {
        updatePreviewVisibility()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updatePreviewVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { updatePreviewVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePreviewVisibility() }
    func applicationDidHide(_ notification: Notification) { updatePreviewVisibility() }
    func applicationDidUnhide(_ notification: Notification) { updatePreviewVisibility() }

    private func updateStatusIcon(isRecording: Bool, microphoneMuted: Bool, isProcessing: Bool) {
        let (symbolName, description): (String, String)
        if isRecording {
            if microphoneMuted {
                symbolName = "mic.slash.circle"
                description = "Идёт запись (микрофон выключен)"
            } else {
                symbolName = "mic.circle.fill"
                description = "Идёт запись"
            }
        } else if isProcessing {
            symbolName = "mic.badge.ellipsis"
            description = "Обработка записи"
        } else {
            symbolName = "mic.circle"
            description = "Meeting Companion"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
    }


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !model.workspace.admitNavigation() { showWindow(); return .terminateCancel }
        if model.preventsTermination {
            showWindow()
            let alert = NSAlert()
            alert.messageText = "Meeting Companion ещё работает"
            alert.informativeText = "Дождись завершения записи, транскрибации или диагностики перед выходом."
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    private func dismissReminder() {
        guard let panel = reminder else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        reminder = nil
    }

    func showReminder(_ meeting: MeetingContext) {
        guard !model.isBusy, !model.diagnosticRunning else { return }
        if model.recordingMeetingID == meeting.id {
            model.calendar.acknowledge(meeting)
            return
        }
        dismissReminder()
        model.prepareForAutomaticReminder()
        let now = Date()
        for event in model.calendar.events where event.needsReminder(now: now, handled: []) {
            model.calendar.acknowledge(event)
        }
        let candidates = MeetingSelection.orderedCurrent(events: model.calendar.events, now: now)
            .filter { $0.id != model.recordingMeetingID }
        let initialMeeting = candidates.first ?? meeting
        model.reminderMeeting = initialMeeting
        let expectedSessionID = model.activeSessionID

        let panel = ReminderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let presenter = MeetingReminderPresenter(
            model: model,
            calendar: model.calendar,
            initialMeeting: initialMeeting,
            expectedSessionID: expectedSessionID,
            onDismiss: { [weak self, weak panel] in
                guard let self, let panel, self.reminder === panel else { return }
                self.dismissReminder()
            }
        )

        let rootView = MeetingReminderView(presenter: presenter)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hostingView

        let layoutPanel = { [weak self, weak panel, weak hostingView] in
            guard let self, let panel, let hostingView else { return }
            let targetSize = hostingView.fittingSize
            let screen = self.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let width: CGFloat = 440
            var height = max(200, min(screen.height - 32, targetSize.height))
            let x = screen.maxX - width - 16
            var y = screen.maxY - height - 16

            if let capsulePanel = self.capsuleController?.panel, capsulePanel.isVisible {
                let capsuleFrame = capsulePanel.frame
                let reminderRect = NSRect(x: x, y: y, width: width, height: height)
                if reminderRect.intersects(capsuleFrame) {
                    let below = max(0, capsuleFrame.minY - screen.minY - 24)
                    let above = max(0, screen.maxY - capsuleFrame.maxY - 24)
                    if below >= height || below >= above {
                        height = min(height, below)
                        y = capsuleFrame.minY - height - 8
                    } else {
                        height = min(height, above)
                        y = capsuleFrame.maxY + 8
                    }
                }
            }
            y = max(screen.minY + 16, min(screen.maxY - height - 16, y))
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }

        layoutPanel()
        presenter.onLayoutChanged = {
            DispatchQueue.main.async { layoutPanel() }
        }

        reminder = panel
        Timer.scheduledTimer(withTimeInterval: max(1, min(300, meeting.end.timeIntervalSinceNow)), repeats: false) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let self, let panel, self.reminder === panel else { return }
                self.dismissReminder()
            }
        }
        panel.orderFrontRegardless()
    }

}
