import AppKit

@main struct Check {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 680, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let original = window.frame
        let state = AppWindowState()
        state.attach(window)
        state.setRecordingMode(true)
        precondition(window.styleMask == .borderless)
        precondition(window.level == .floating && window.isVisible)
        precondition(window.frame.size == NSSize(width: 288, height: 76))
        state.setRecordingMode(false)
        precondition(!window.isVisible, "Saving must never reopen the main window")
        precondition(window.styleMask.contains(.titled) && window.level == .normal)
        precondition(window.frame == original)
        state.setRecordingMode(true)
        state.setRecordingMode(false)
        precondition(!window.isVisible && window.frame == original)
        print("Recording window: capsule geometry, hidden restore and repeated recording passed")
    }
}
