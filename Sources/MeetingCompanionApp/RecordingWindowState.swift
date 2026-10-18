import AppKit
import Combine

@MainActor
final class AppWindowState: ObservableObject {
    weak var window: NSWindow?
    private var normalFrame: NSRect?
    private var normalToolbar: NSToolbar?
    private let normalSize = NSSize(width: 620, height: 460)

    static func activationPolicy(for windows: [NSWindow]) -> NSApplication.ActivationPolicy {
        windows.contains { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
            ? .regular : .accessory
    }

    static func audioCheckVisible(window: NSWindow?, diagnosticsSelected: Bool, applicationHidden: Bool) -> Bool {
        guard let window else { return false }
        return diagnosticsSelected && !applicationHidden && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }

    static func refreshActivationPolicy() {
        let policy = activationPolicy(for: NSApp.windows)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.title = "Meeting Companion"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.minSize = normalSize
    }

    func setCapsuleMode(_ isRecording: Bool, processing: Bool = false) {
        let compactSize = processing ? NSSize(width: 348, height: 140) : NSSize(width: 288, height: 76)
        guard let window else { return }
        defer { Self.refreshActivationPolicy() }

        if isRecording {
            if normalFrame == nil {
                normalFrame = window.frame
                normalToolbar = window.toolbar
            }

            window.styleMask = [.borderless]
            window.toolbar?.isVisible = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.minSize = compactSize
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let origin = NSPoint(
                x: screenFrame.maxX - compactSize.width - 24,
                y: screenFrame.maxY - compactSize.height - 24
            )

            window.level = .floating
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.setFrame(NSRect(origin: origin, size: compactSize), display: true, animate: false)
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = true
            window.level = .normal
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.minSize = normalSize
            window.toolbar = normalToolbar
            window.toolbar?.isVisible = true

            if let normalFrame {
                let restoredFrame = NSRect(
                    x: normalFrame.minX,
                    y: normalFrame.maxY - max(normalFrame.height, normalSize.height),
                    width: max(normalFrame.width, normalSize.width),
                    height: max(normalFrame.height, normalSize.height)
                )
                window.setFrame(restoredFrame, display: false, animate: false)
            } else {
                window.setContentSize(normalSize)
                window.center()
            }
            self.normalFrame = nil
        }
    }
}

