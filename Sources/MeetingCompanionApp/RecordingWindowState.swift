import AppKit
import Combine

@MainActor
final class AppWindowState: ObservableObject {
    weak var window: NSWindow?
    private var normalFrame: NSRect?
    private let normalSize = NSSize(width: 680, height: 560)
    private let compactSize = NSSize(width: 288, height: 76)

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.title = "Meeting Companion"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.minSize = normalSize
    }

    func setRecordingMode(_ isRecording: Bool) {
        guard let window else { return }

        if isRecording {
            if normalFrame == nil {
                normalFrame = window.frame
            }

            window.styleMask = [.borderless]
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

