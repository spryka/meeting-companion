import AppKit
import SwiftUI

// AppKit owns the standard controls; unhandled header clicks keep native window dragging.
private final class WorkspaceHeaderHostingView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class WorkspaceHeaderBackgroundView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(ODColors.toolbar).setFill()
        bounds.fill()
        NSColor(ODColors.line).setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

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
final class AppWindowState: NSObject, ObservableObject {
    weak var window: NSWindow?
    private var brandAccessory: NSTitlebarAccessoryViewController?
    private var actionsAccessory: NSTitlebarAccessoryViewController?
    private var headerBackground: WorkspaceHeaderBackgroundView?
    static let capsuleFrameKey = "recordingCapsuleFrame"
    static let recordingCapsuleSize = NSSize(width: 440, height: 64)
    static let overtimeCapsuleHeight: CGFloat = 64
    static let processingCapsuleSize = NSSize(width: 440, height: 64)
    static let workspaceMinimumSize = NSSize(width: 480, height: 500)

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

    static func activationPolicy(for windows: [NSWindow]) -> NSApplication.ActivationPolicy {
        windows.contains { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
            ? .regular : .accessory
    }

    static func refreshActivationPolicy() {
        let policy = activationPolicy(for: NSApp.windows)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    static func configureWorkspaceHeader(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.title = "Meeting Companion"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
    }

    func updateHeader(brand: AnyView, actions: AnyView, width: CGFloat, sidebarWidth: CGFloat,
                      narrow: Bool, showsList: Bool) {
        guard let window else { return }
        func update(_ existing: inout NSTitlebarAccessoryViewController?, edge: NSLayoutConstraint.Attribute,
                    content: AnyView, size: NSSize) {
            if existing == nil {
                let accessory = NSTitlebarAccessoryViewController()
                accessory.layoutAttribute = edge
                let host = WorkspaceHeaderHostingView(rootView: content)
                host.sizingOptions = []
                accessory.view = host
                window.addTitlebarAccessoryViewController(accessory)
                existing = accessory
            }
            let host = existing!.view as! WorkspaceHeaderHostingView
            host.rootView = size.width > 0 ? content : AnyView(EmptyView())
            host.setFrameSize(size)
        }
        let controlsRight = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: window.contentView).maxX }.max() ?? 0
        let brandWidth: CGFloat = narrow && !showsList ? 0 : max(0, (narrow ? width : sidebarWidth) - controlsRight - 16)
        let actionWidth = narrow ? (showsList ? 0 : max(0, width - controlsRight - 12)) : max(0, width - sidebarWidth - 1)
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "workspace-header")
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            toolbar.showsBaselineSeparator = false
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
            window.toolbar = toolbar
        }
        if narrow, !showsList, headerBackground == nil,
           let content = window.contentView, let layoutGuide = window.contentLayoutGuide {
            let background = WorkspaceHeaderBackgroundView()
            background.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(background, positioned: .above, relativeTo: nil)
            // The public layout guide owns the full native row, including the controls' region.
            NSLayoutConstraint.activate([
                background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                background.topAnchor.constraint(equalTo: content.topAnchor),
                NSLayoutConstraint(item: background, attribute: .bottom, relatedBy: .equal,
                                   toItem: layoutGuide, attribute: .top, multiplier: 1, constant: 0)
            ])
            headerBackground = background
        }
        headerBackground?.isHidden = !narrow || showsList
        // Accessories share the native row's bounds, without a toolbar item's inset platter.
        let headerHeight = (window.contentView?.bounds.height ?? window.frame.height) - window.contentLayoutRect.height
        // The accessory owns the existing separator slot; its actions keep their original width.
        let headerActions = narrow ? actions : AnyView(HStack(spacing: 0) {
            Rectangle().fill(ODColors.line).frame(width: 1)
                .allowsHitTesting(false).accessibilityHidden(true)
            actions.frame(width: actionWidth)
        })
        update(&brandAccessory, edge: .left, content: brand, size: NSSize(width: brandWidth, height: max(0, headerHeight)))
        update(&actionsAccessory, edge: .right, content: headerActions, size: NSSize(width: actionWidth + (narrow ? 0 : 1), height: max(0, headerHeight)))
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        Self.configureWorkspaceHeader(window)
        window.minSize = Self.workspaceMinimumSize
    }

}
