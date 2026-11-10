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
            return await self.model.workspace.prepareForRetry(recording)
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
    private var reminder: NSPanel?
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
        model.onOpenTranscript = { [weak self] entry in
            guard let self else { return }
            guard self.model.workspace.admitNavigation() else { return }
            self.model.showTranscript(entry.id)
            self.showWindow()
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

    private func showReminder(_ meeting: MeetingContext) {
        guard !model.isBusy, !model.diagnosticRunning else { return }
        if model.recordingMeetingID == meeting.id {
            model.calendar.acknowledge(meeting)
            return
        }
        reminder?.orderOut(nil)
        reminder = nil
        model.prepareForAutomaticReminder()
        let now = Date()
        for event in model.calendar.events where event.needsReminder(now: now, handled: []) {
            model.calendar.acknowledge(event)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        let candidates = MeetingSelection.orderedCurrent(events: model.calendar.events, now: now)
            .filter { $0.id != model.recordingMeetingID }
        model.reminderMeeting = candidates.first ?? meeting
        let expectedSessionID = model.activeSessionID
        panel.contentView = NSHostingView(rootView: MeetingReminderView(model: model, calendar: model.calendar) { [weak self, weak panel] accept, selected in
            guard let self, let panel, self.reminder === panel else { return }
            panel.orderOut(nil)
            self.reminder = nil
            if accept { self.model.startMeeting(selected, expectedSessionID: expectedSessionID) }
        })
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let y = screen.maxY - 244 - (model.isRecording ? 96 : 0)
        panel.setFrameOrigin(NSPoint(x: screen.maxX - 424, y: max(screen.minY, y)))
        reminder = panel
        Timer.scheduledTimer(withTimeInterval: max(1, min(300, meeting.end.timeIntervalSinceNow)), repeats: false) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let self, let panel, self.reminder === panel else { return }
                panel.orderOut(nil)
                self.reminder = nil
            }
        }
        panel.orderFrontRegardless()
    }

}

struct MeetingReminderView: View {
    @ObservedObject var model: RecorderViewModel
    @ObservedObject var calendar: MeetingCalendar
    let respond: (Bool, MeetingContext?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isRecording ? "Начинается следующая встреча" : "Время встречи").font(.headline)
            Picker("Встреча", selection: $model.reminderMeeting) {
                Text("Без встречи").tag(Optional<MeetingContext>.none)
                ForEach(calendar.events.filter { $0.id != model.recordingMeetingID }) { event in
                    Text(event.start.formatted(date: .omitted, time: .shortened) + " · " + event.summary).tag(Optional(event))
                }
                if let selected = model.reminderMeeting, !calendar.events.contains(selected) { Text(selected.summary).tag(Optional(selected)) }
            }
            if model.isRecording {
                Text("Закроем текущие дорожки и начнём новую запись. Обработка предыдущей продолжится в фоне.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Пропустить") { respond(false, nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button(model.isRecording ? "Завершить и начать новую" : "Начать запись") { respond(true, model.reminderMeeting) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(model.isBusy || model.diagnosticRunning)
            }
        }
        .padding(20)
        .frame(width: 392, height: 212)
        .modifier(MeetingOverlaySurface())
        .padding(4)
    }
}
