import AppKit

@main struct Check {
    @MainActor static func main() {
        _ = NSApplication.shared
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
        let state = AppWindowState()
        state.attach(window)
        state.setCapsuleMode(true)
        precondition(window.styleMask == .borderless)
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
        precondition(window.frame.size == NSSize(width: 288, height: 76))
        state.setCapsuleMode(true, processing: true)
        precondition(window.styleMask == .borderless && window.isVisible)
        precondition(window.frame.size == NSSize(width: 348, height: 140))
        state.setCapsuleMode(false)
        precondition(!window.isVisible, "Saving must never reopen the main window")
        precondition(window.styleMask.contains(.titled) && window.level == .normal)
        precondition(window.toolbar?.isVisible == true)
        precondition(window.frame == original)
        state.setCapsuleMode(true)
        state.setCapsuleMode(false)
        precondition(!window.isVisible && window.frame == original)
        print("Dock/Cmd+Tab follows regular windows; recording window: recording/processing capsules, hidden restore and repeated recording passed")
    }
}
