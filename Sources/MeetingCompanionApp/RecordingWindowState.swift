import AppKit
import Combine

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "Системная"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var value: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppWindowState: ObservableObject {
    weak var window: NSWindow?
    private var normalFrame: NSRect?
    private var normalToolbar: NSToolbar?
    private let defaults: UserDefaults
    private var observers: [AnyCancellable] = []
    private var positioning = false
    private static let capsuleFrameKey = "recordingCapsuleFrame"
    static let recordingCapsuleSize = NSSize(width: 384, height: 88)
    static let overtimeCapsuleHeight: CGFloat = 132
    private let normalSize = NSSize(width: 900, height: 560)

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func visibleCapsuleFrame(_ frame: NSRect, screens: [NSRect]) -> NSRect {
        guard !screens.isEmpty else { return frame }
        let screen = screens.max { left, right in
            func overlap(_ screen: NSRect) -> CGFloat {
                let intersection = frame.intersection(screen)
                return intersection.isNull ? 0 : intersection.width * intersection.height
            }
            let leftArea = overlap(left), rightArea = overlap(right)
            if leftArea != rightArea { return leftArea < rightArea }
            func distance(_ screen: NSRect) -> CGFloat {
                let dx = max(screen.minX - frame.midX, 0, frame.midX - screen.maxX)
                let dy = max(screen.minY - frame.midY, 0, frame.midY - screen.maxY)
                return dx * dx + dy * dy
            }
            return distance(left) > distance(right)
        }!
        return NSRect(x: min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - frame.width)),
                      y: min(max(frame.minY, screen.minY), max(screen.minY, screen.maxY - frame.height)),
                      width: frame.width, height: frame.height)
    }

    private func saveCapsulePosition() {
        guard normalFrame != nil, !positioning, let window else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: Self.capsuleFrameKey)
    }

    private func keepCapsuleVisible() {
        guard normalFrame != nil, !positioning, let window else { return }
        let frame = Self.visibleCapsuleFrame(window.frame, screens: NSScreen.screens.map(\.visibleFrame))
        if frame != window.frame { window.setFrame(frame, display: true, animate: false) }
        saveCapsulePosition()
    }

    static func activationPolicy(for windows: [NSWindow]) -> NSApplication.ActivationPolicy {
        windows.contains { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
            ? .regular : .accessory
    }

    static func settingsPageVisible(window: NSWindow?, pageSelected: Bool, applicationHidden: Bool) -> Bool {
        guard let window else { return false }
        return pageSelected && !applicationHidden && window.isVisible && !window.isMiniaturized
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
        observers = [
            NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: window)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.saveCapsulePosition() } },
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.keepCapsuleVisible() } }
        ]
    }

    func setCapsuleMode(_ isRecording: Bool, processing: Bool = false, overtime: Bool = false) {
        let compactSize = processing ? NSSize(width: 348, height: 140) :
            NSSize(width: Self.recordingCapsuleSize.width, height: overtime ? Self.overtimeCapsuleHeight : Self.recordingCapsuleSize.height)
        guard let window else { return }
        positioning = true
        defer { positioning = false; Self.refreshActivationPolicy() }

        if isRecording {
            var previousCapsule = normalFrame == nil ? defaults.string(forKey: Self.capsuleFrameKey).map(NSRectFromString) : window.frame
            if let frame = previousCapsule,
               ![frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
                || frame.width <= 0 || frame.height <= 0 { previousCapsule = nil }
            if normalFrame == nil {
                normalFrame = window.frame
                normalToolbar = window.toolbar
            }

            window.styleMask = [.borderless]
            window.isMovableByWindowBackground = true
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
            let requested = previousCapsule.map {
                NSRect(x: $0.minX, y: $0.maxY - compactSize.height, width: compactSize.width, height: compactSize.height)
            } ?? NSRect(origin: origin, size: compactSize)
            let frame = Self.visibleCapsuleFrame(requested, screens: NSScreen.screens.map(\.visibleFrame))
            window.setFrame(frame, display: true, animate: false)
            defaults.set(NSStringFromRect(window.frame), forKey: Self.capsuleFrameKey)
            window.orderFrontRegardless()
        } else {
            let toolbar = window.toolbar ?? normalToolbar
            window.orderOut(nil)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isMovableByWindowBackground = false
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = true
            window.level = .normal
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.minSize = normalSize
            // Changing the style mask detaches the toolbar; keep SwiftUI's current instance.
            window.toolbar = toolbar
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

