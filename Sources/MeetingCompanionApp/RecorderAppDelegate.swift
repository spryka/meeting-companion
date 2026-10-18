import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class RecorderAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    private let model = RecorderViewModel()
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var reminder: NSPanel?
    private var recordingObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let toolbar = NSToolbar(identifier: "RecorderToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
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
        model.calendar.onMeeting = { [weak self] meeting in self?.showReminder(meeting) }
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            do {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            } catch { model.errorMessage = "Автозапуск: " + error.localizedDescription }
        }
        showWindow()
        Task { await model.calendar.start() }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem.button {
            let menu = NSMenu()
            menu.addItem(withTitle: "Открыть Meeting Companion", action: #selector(showWindow), keyEquivalent: "")
            menu.addItem(withTitle: "Настройки и диагностика…", action: #selector(showSettings), keyEquivalent: "")
            let login = menu.addItem(withTitle: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(.separator())
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

    private static let recordingsItem = NSToolbarItem.Identifier("Recordings")
    private static let settingsItem = NSToolbarItem.Identifier("Settings")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.recordingsItem, Self.settingsItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.recordingsItem || identifier == Self.settingsItem else { return nil }
        let recordings = identifier == Self.recordingsItem
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = recordings ? "Записи" : "Настройки"
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: recordings ? "folder" : "gearshape", accessibilityDescription: item.label)
        item.target = self
        item.action = recordings ? #selector(openRecordings) : #selector(showSettings)
        return item
    }

    @objc private func openRecordings() { model.openFolder() }

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

    @objc private func showWindow() {
        if window.styleMask.contains(.titled) { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updatePreviewVisibility()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        if sender === window {
            if !model.isRecording { model.dismissCapsule() }
            model.setWindowVisible(false)
        }
        updatePreviewVisibility()
        return false
    }

    private func updatePreviewVisibility() {
        AppWindowState.refreshActivationPolicy()
        let selected = (settingsWindow?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex
        model.setAudioCheckVisible(AppWindowState.audioCheckVisible(window: settingsWindow,
            diagnosticsSelected: selected == RecorderSettingsView.Page.allCases.firstIndex(of: .diagnostics),
            applicationHidden: NSApp.isHidden))
        model.setWindowVisible(!NSApp.isHidden && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
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
        if model.isRecording || model.isBusy || model.diagnosticRunning || model.transcriptionJobs > 0 {
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
        guard reminder == nil else { return }
        if model.isRecording || model.isBusy || model.diagnosticRunning {
            model.calendar.acknowledge(meeting)
            return
        }
        model.calendar.acknowledge(meeting)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 348, height: 134),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: MeetingReminderView(meeting: meeting) { [weak self] accept in
            guard let self else { return }
            self.reminder?.orderOut(nil)
            self.reminder = nil
            if accept && !self.model.isRecording && !self.model.isBusy && !self.model.diagnosticRunning {
                self.model.selectedMeeting = meeting
                self.showWindow()
                self.model.toggleRecording()
            }
        })
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        panel.setFrameOrigin(NSPoint(x: screen.maxX - 372, y: screen.maxY - 158))
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
    let meeting: MeetingContext
    let respond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(meeting.summary).font(.headline).lineLimit(2)
            HStack {
                Button("Пропустить") { respond(false) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Начать запись") { respond(true) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(20)
        .frame(width: 340, height: 126)
        .modifier(MeetingOverlaySurface())
        .padding(4)
    }
}
