import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class RecorderAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = RecorderViewModel()
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var reminder: NSPanel?
    private var recordingObserver: AnyCancellable?
    private var busyObserver: AnyCancellable?
    private let appUpdater = AppUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = model.appearance.value
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: ContentView(viewModel: model) { [weak self] in self?.showSettings() })
        window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        recordingObserver = model.$isRecording.sink { [weak self] recording in
            self?.statusItem.button?.image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "mic.circle",
                                                     accessibilityDescription: recording ? "Идёт запись" : "Meeting Companion")
        }
        busyObserver = model.$isBusy.dropFirst().filter { !$0 }.sink { [weak self] _ in
            Task { @MainActor in self?.model.calendar.recheckReminders() }
        }
        model.calendar.onMeeting = { [weak self] meeting in self?.showReminder(meeting) }
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            do {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            } catch { model.errorMessage = "Автозапуск: " + error.localizedDescription }
        }
        showWindow()
        Task { await model.calendar.start() }
        appUpdater.isBusy = { [weak self] in self?.model.preventsTermination ?? true }
        do { try appUpdater.start() }
        catch { NSLog("Meeting Companion updater unavailable: %@", error.localizedDescription) }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem.button {
            let menu = NSMenu()
            menu.addItem(withTitle: "Открыть Meeting Companion", action: #selector(showWindow), keyEquivalent: "")
            menu.addItem(withTitle: "Настройки и диагностика…", action: #selector(showSettings), keyEquivalent: "")
            let login = menu.addItem(withTitle: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(.separator())
            menu.addItem(withTitle: appUpdater.menuTitle, action: #selector(checkForUpdates), keyEquivalent: "")
            menu.addItem(withTitle: "Выйти", action: #selector(quit), keyEquivalent: "")
            for item in menu.items { item.target = self }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else { showWindow() }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            settings.contentMinSize = NSSize(width: 580, height: 400)
            settings.title = "Настройки"
            settings.isReleasedWhenClosed = false
            settings.delegate = self
            let controller = RecorderSettingsView.makeController(model: model)
            controller.onSelectionChange = { [weak self] in self?.updatePreviewVisibility() }
            settings.contentViewController = controller
            settings.toolbarStyle = .preference
            settings.center()
            settingsWindow = settings
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        updatePreviewVisibility()
    }

    @objc private func openRecordings() {
        model.mainPage = .history
        showWindow()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            model.errorMessage = "Автозапуск: " + error.localizedDescription
            showWindow()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc func checkForUpdates() { appUpdater.check() }

    @objc private func showWindow() {
        model.mainWindowRequested = true
        if window.styleMask.contains(.titled) { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updatePreviewVisibility()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        if sender === window {
            if !model.isRecording { model.dismissCapsule() }
            model.mainWindowRequested = false
            model.setWindowVisible(false)
        }
        updatePreviewVisibility()
        return false
    }

    private func updatePreviewVisibility() {
        AppWindowState.refreshActivationPolicy()
        let selected = (settingsWindow?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex
        model.setAudioCheckVisible(AppWindowState.settingsPageVisible(window: settingsWindow,
            pageSelected: selected == RecorderSettingsView.Page.allCases.firstIndex(of: .diagnostics),
            applicationHidden: NSApp.isHidden))
        model.setWindowVisible(!NSApp.isHidden && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        model.calendar.setMainWindowVisible(!NSApp.isHidden && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible) && window.styleMask.contains(.titled)
            && !model.showsRecordingCapsule && !model.showsProcessingCapsule)
        model.calendar.setCalendarSettingsVisible(AppWindowState.settingsPageVisible(window: settingsWindow,
            pageSelected: selected == RecorderSettingsView.Page.allCases.firstIndex(of: .calendar),
            applicationHidden: NSApp.isHidden))
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updatePreviewVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { updatePreviewVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePreviewVisibility() }
    func applicationDidHide(_ notification: Notification) { updatePreviewVisibility() }
    func applicationDidUnhide(_ notification: Notification) { updatePreviewVisibility() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        if !model.isRecording { model.dismissCapsule() }
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
        panel.contentView = NSHostingView(rootView: MeetingReminderView(model: model, calendar: model.calendar) { [weak self, weak panel] accept, selected in
            guard let self, let panel, self.reminder === panel else { return }
            panel.orderOut(nil)
            self.reminder = nil
            if accept { self.model.startMeeting(selected) }
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
