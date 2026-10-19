import AppKit

@main struct Check {
    @MainActor static func main() {
        _ = NSApplication.shared
        let suite = "check-recording-window-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let external = NSRect(x: -1600, y: 600, width: 384, height: 88)
        precondition(AppWindowState.visibleCapsuleFrame(external, screens: [primary, secondary]) == external)
        let recovered = AppWindowState.visibleCapsuleFrame(external, screens: [primary])
        precondition(primary.contains(recovered) && recovered.minX == 0)
        let bottomRight = NSRect(x: 1350, y: -50, width: 348, height: 140)
        let fitted = AppWindowState.visibleCapsuleFrame(bottomRight, screens: [primary])
        precondition(primary.contains(fitted) && fitted.maxX == primary.maxX && fitted.minY == 0)
        precondition(AppWindowState.visibleCapsuleFrame(external, screens: []) == external)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 620, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "CheckRecorderToolbar")
        window.toolbarStyle = .unified
        precondition(AppWindowState.activationPolicy(for: [window]) == .accessory)
        window.orderFront(nil)
        precondition(AppWindowState.activationPolicy(for: [window]) == .regular)
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        let original = window.frame
        let state = AppWindowState(defaults: defaults)
        state.attach(window)
        state.setCapsuleMode(true)
        precondition(window.styleMask == .borderless)
        precondition(window.isMovableByWindowBackground)
        precondition(window.toolbar?.isVisible != true)
        precondition(AppWindowState.activationPolicy(for: [window]) == .accessory)
        settings.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        precondition(AppWindowState.settingsPageVisible(window: settings, pageSelected: true, applicationHidden: false)
            == settings.occlusionState.contains(.visible))
        precondition(!AppWindowState.settingsPageVisible(window: settings, pageSelected: false, applicationHidden: false))
        precondition(!AppWindowState.settingsPageVisible(window: settings, pageSelected: true, applicationHidden: true))
        precondition(!AppWindowState.settingsPageVisible(window: nil, pageSelected: true, applicationHidden: false))
        precondition(AppWindowState.activationPolicy(for: [window, settings]) == .regular)
        settings.orderOut(nil)
        precondition(!AppWindowState.settingsPageVisible(window: settings, pageSelected: true, applicationHidden: false))
        precondition(AppWindowState.activationPolicy(for: [window, settings]) == .accessory)
        precondition(window.level == .floating && window.isVisible)
        precondition(window.frame.size == AppWindowState.recordingCapsuleSize)
        let screen = window.screen!.visibleFrame
        let moved = NSRect(x: (screen.midX - 192).rounded(), y: (screen.midY - 44).rounded(), width: 384, height: 88)
        window.setFrame(moved, display: true)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        precondition(NSRectFromString(defaults.string(forKey: "recordingCapsuleFrame")!) == moved)
        state.setCapsuleMode(true, processing: true)
        precondition(window.styleMask == .borderless && window.isVisible)
        precondition(window.frame.size == NSSize(width: 348, height: 140))
        precondition(window.frame.minX == moved.minX && window.frame.maxY == moved.maxY)
        state.setCapsuleMode(false)
        precondition(!window.isVisible, "Saving must never reopen the main window")
        precondition(window.styleMask.contains(.titled) && window.level == .normal)
        precondition(!window.isMovableByWindowBackground)
        precondition(window.toolbar?.isVisible == true)
        precondition(window.frame == original)
        state.setCapsuleMode(true)
        precondition(window.frame == moved, "Recording must restore the saved capsule position")
        let offscreen = NSRect(x: 100000, y: 100000, width: 384, height: 88)
        window.setFrame(offscreen, display: false)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) })
        state.setCapsuleMode(false)
        precondition(!window.isVisible && window.frame == original)
        let saved = NSRectFromString(defaults.string(forKey: "recordingCapsuleFrame")!)
        let restored = AppWindowState(defaults: defaults)
        restored.attach(window)
        restored.setCapsuleMode(true)
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) })
        precondition(window.frame == saved, "A new window state must restore the previous position")
        restored.setCapsuleMode(false)
        defaults.set("invalid rectangle", forKey: "recordingCapsuleFrame")
        restored.setCapsuleMode(true)
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) })
        restored.setCapsuleMode(false)
        print("Recording window: Dock/Cmd+Tab, draggable capsules, saved position, mode changes, screen recovery and hidden restore passed")
    }
}
