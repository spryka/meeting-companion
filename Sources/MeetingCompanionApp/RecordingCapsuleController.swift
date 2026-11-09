import AppKit
import Combine
import SwiftUI
import MeetingCompanionCore

@MainActor
final class RecordingCapsuleController: NSObject, NSWindowDelegate {
    private let model: RecorderViewModel
    private let defaults: UserDefaults
    private(set) var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    init(model: RecorderViewModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        super.init()
        setupPanel()
        setupObservations()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.showsProcessingCapsule }

    private func setupPanel() {
        let initialSize = AppWindowState.recordingCapsuleSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let hostView = NSHostingView(rootView: RecordingCapsuleHostView(viewModel: model))
        // Panel geometry belongs to this controller, not transient SwiftUI intrinsic sizes.
        hostView.sizingOptions = []
        panel.contentView = hostView

        let targetFrame = targetFrame(for: initialSize)
        panel.setFrame(targetFrame, display: false)
        self.panel = panel

        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleWindowMoved()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleScreenParametersChanged()
                }
            }
            .store(in: &cancellables)
    }

    private func setupObservations() {
        model.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                self?.syncVisibilityAndSize()
            }
        }.store(in: &cancellables)
    }

    func showCapsule() {
        guard let panel else { return }
        model.capsuleDismissed = false
        if !model.isCapsuleVisible {
            model.isCapsuleVisible = true
        }
        syncSize(animated: false)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hideCapsule() {
        guard let panel else { return }
        if model.isCapsuleVisible {
            model.isCapsuleVisible = false
        }
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func syncVisibilityAndSize() {
        guard let panel else { return }
        let shouldShow = model.showsRecordingCapsule && !model.capsuleDismissed
        if shouldShow {
            if !model.isCapsuleVisible {
                model.isCapsuleVisible = true
            }
            syncSize(animated: true)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        } else {
            if model.isCapsuleVisible {
                model.isCapsuleVisible = false
            }
            if panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }

    private func syncSize(animated: Bool) {
        guard let panel else { return }
        let targetSize: NSSize
        if model.showsProcessingCapsule {
            targetSize = AppWindowState.processingCapsuleSize
        } else if model.showsOvertimeReminder {
            targetSize = NSSize(width: AppWindowState.recordingCapsuleSize.width, height: AppWindowState.overtimeCapsuleHeight)
        } else {
            targetSize = AppWindowState.recordingCapsuleSize
        }

        let currentFrame = panel.frame
        if currentFrame.size != targetSize {
            let newY = currentFrame.maxY - targetSize.height
            let newFrame = NSRect(x: currentFrame.minX, y: newY, width: targetSize.width, height: targetSize.height)
            let screens = NSScreen.screens.map(\.visibleFrame)
            let clamped = AppWindowState.visibleCapsuleFrame(newFrame, screens: screens)
            panel.setFrame(clamped, display: true, animate: animated && !model.showsProcessingCapsule)
        }
    }

    private func targetFrame(for size: NSSize) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        if let saved = defaults.string(forKey: AppWindowState.capsuleFrameKey) {
            let parsed = NSRectFromString(saved)
            if parsed.width > 0 && parsed.height > 0 {
                let rect = NSRect(origin: parsed.origin, size: size)
                return AppWindowState.visibleCapsuleFrame(rect, screens: screens)
            }
        }
        let primaryScreen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = primaryScreen.midX - (size.width / 2)
        let y = primaryScreen.maxY - size.height - 20
        let defaultRect = NSRect(x: x, y: y, width: size.width, height: size.height)
        return AppWindowState.visibleCapsuleFrame(defaultRect, screens: screens)
    }

    private func handleWindowMoved() {
        guard let panel else { return }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let clamped = AppWindowState.visibleCapsuleFrame(panel.frame, screens: screens)
        if clamped != panel.frame {
            panel.setFrame(clamped, display: true)
        }
        defaults.set(NSStringFromRect(clamped), forKey: AppWindowState.capsuleFrameKey)
    }

    private func handleScreenParametersChanged() {
        guard let panel else { return }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let clamped = AppWindowState.visibleCapsuleFrame(panel.frame, screens: screens)
        if clamped != panel.frame {
            panel.setFrame(clamped, display: true)
            defaults.set(NSStringFromRect(clamped), forKey: AppWindowState.capsuleFrameKey)
        }
    }
}
