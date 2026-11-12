import AppKit
import Combine
import SwiftUI
import Foundation
import MeetingCompanionApplication
import MeetingCompanionCore
import Testing
@testable import MeetingCompanionApp

@Suite(.serialized) @MainActor final class ReminderPresentationTests {
    private let tempRoot: URL
    private let defaults: UserDefaults
    private let repo: RecordingHistoryRepository
    private let model: RecorderViewModel
    private let calendar: MeetingCalendar

    init() {
        let uniqueID = UUID().uuidString
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-pres-\(uniqueID)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let domain = "test.reminder.presentation.\(uniqueID)"
        defaults = UserDefaults(suiteName: domain)!
        defaults.set(tempRoot.path, forKey: "recordingsDirectory")
        defaults.set([String](), forKey: "meetingCalendarIDs")

        repo = RecordingHistoryRepository()
        let processing = ProcessingService(
            transcriptionRunner: SyntheticRunner(),
            audioExporter: SyntheticExporter(),
            historyRepository: repo
        )

        model = RecorderViewModel(
            sessionService: RecordingSessionService(historyRepo: repo),
            processingService: processing,
            historyRepository: repo,
            workspace: nil,
            defaults: defaults,
            appDataDirectory: tempRoot.appendingPathComponent("appData"),
            startBackgroundServices: false,
            captureControllerFactory: { url, _, _ in SyntheticAudioCapture(outputURL: url) },
            shortRecordingTrash: { _ in }
        )
        model.setAttachedForTesting(session: true, processing: true)
        calendar = model.calendar
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeMeeting(id: String, title: String, startOffset: TimeInterval = 0, duration: TimeInterval = 1800) -> MeetingContext {
        let now = Date()
        return MeetingContext(
            id: id,
            calendar: "Work",
            summary: title,
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + duration),
            agenda: "Test agenda",
            links: [],
            attendees: ["alice@example.com"]
        )
    }

    @Test func candidateListExcludesRecordingMeetingAndRetainsFallback() {
        let m1 = makeMeeting(id: "m1", title: "Meeting 1")
        let m2 = makeMeeting(id: "m2", title: "Meeting 2")
        let mFallback = makeMeeting(id: "mFallback", title: "Retained Fallback")

        calendar.setEventsForTesting([m1, m2])
        model.setRecordingMeetingIDForTesting("m1")

        var dismissed = false
        let presenter = MeetingReminderPresenter(
            model: model,
            calendar: calendar,
            initialMeeting: mFallback,
            expectedSessionID: nil,
            onDismiss: { dismissed = true }
        )

        let candidates = presenter.candidateMeetings
        // m1 is currently recording -> must be excluded
        #expect(!candidates.contains(where: { $0.id == "m1" }))
        // m2 is in calendar -> included
        #expect(candidates.contains(where: { $0.id == "m2" }))
        // mFallback is not in calendar, but was initially selected -> retained
        #expect(candidates.contains(where: { $0.id == "mFallback" }))
        #expect(!dismissed)
    }

    @Test func selectMeetingUpdatesSelectionWithoutStartingRecording() {
        let m1 = makeMeeting(id: "m1", title: "Meeting 1")
        let m2 = makeMeeting(id: "m2", title: "Meeting 2")
        calendar.setEventsForTesting([m1, m2])

        var dismissed = false
        let presenter = MeetingReminderPresenter(
            model: model,
            calendar: calendar,
            initialMeeting: m1,
            expectedSessionID: nil,
            onDismiss: { dismissed = true }
        )

        #expect(presenter.selectedMeeting?.id == "m1")
        #expect(!model.isRecording)

        // Select m2
        presenter.selectMeeting(m2)
        #expect(presenter.selectedMeeting?.id == "m2")
        #expect(model.reminderMeeting?.id == "m2")
        #expect(!model.isRecording)
        #expect(!dismissed)

        // Select nil ("Без встречи")
        presenter.selectMeeting(nil)
        #expect(presenter.selectedMeeting == nil)
        #expect(model.reminderMeeting == nil)
        #expect(!model.isRecording)
        #expect(!dismissed)
    }

    @Test func skipDismissesReminderWithoutStartingRecording() {
        let m1 = makeMeeting(id: "m1", title: "Meeting 1")
        calendar.setEventsForTesting([m1])

        var dismissed = false
        let presenter = MeetingReminderPresenter(
            model: model,
            calendar: calendar,
            initialMeeting: m1,
            expectedSessionID: nil,
            onDismiss: { dismissed = true }
        )

        presenter.skip()
        #expect(dismissed)
        #expect(!model.isRecording)
    }

    @Test func explanatoryTextDifferentiatesShortAndNormalRecording() {
        let m1 = makeMeeting(id: "m1", title: "Next Meeting")
        calendar.setEventsForTesting([m1])

        var dismissed = false
        let presenter = MeetingReminderPresenter(
            model: model,
            calendar: calendar,
            initialMeeting: m1,
            expectedSessionID: nil,
            onDismiss: { dismissed = true }
        )

        // When idle:
        #expect(presenter.mode == .idle)

        // When recording and elapsed < 10:
        model.isRecording = true
        model.elapsed = 5
        #expect(presenter.isShortRecording)
        #expect(presenter.explanationText == "Текущая запись короче 10 секунд будет отменена. Затем начнём новую.")

        // Boundary: 9 seconds
        model.elapsed = 9.9
        #expect(presenter.isShortRecording)
        #expect(presenter.explanationText == "Текущая запись короче 10 секунд будет отменена. Затем начнём новую.")

        // Boundary: 10 seconds -> normal recording
        model.elapsed = 10.0
        #expect(!presenter.isShortRecording)
        #expect(presenter.explanationText == "Завершим текущую запись и начнём новую. Обработка предыдущей продолжится в фоне.")

        // 45 seconds -> normal recording
        model.elapsed = 45.0
        #expect(!presenter.isShortRecording)
        #expect(presenter.explanationText == "Завершим текущую запись и начнём новую. Обработка предыдущей продолжится в фоне.")
        #expect(!dismissed)
    }

    @Test func rejectionTransitionsToTerminalErrorWithReasonAndDismissAvailable() async {
        let m1 = makeMeeting(id: "m1", title: "Meeting 1")
        calendar.setEventsForTesting([m1])

        // Block navigation via workspace modal
        model.workspace.settingsInput = { true }

        var dismissed = false
        let presenter = MeetingReminderPresenter(
            model: model,
            calendar: calendar,
            initialMeeting: m1,
            expectedSessionID: nil,
            onDismiss: { dismissed = true }
        )

        #expect(presenter.mode == .idle)

        // Accept should trigger startMeeting, which will be rejected because navigation is blocked
        presenter.accept()

        // Wait for startMeeting Task to settle
        for _ in 0..<100 where presenter.isTransitioning {
            try? await Task.sleep(for: .milliseconds(5))
        }

        if case .terminalError(let reason) = presenter.mode {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("Expected mode to be terminalError, but got \(presenter.mode)")
        }

        #expect(!dismissed)

        // User clicks "Закрыть" in terminal error
        presenter.dismissError()
        #expect(dismissed)
    }

    @Test func staleSessionRejectionTransitionsToTerminalErrorWithoutStopping() async {
        let m1 = makeMeeting(id: "m1", title: "Meeting 1")
        calendar.setEventsForTesting([m1])

        let activeID = UUID()
        model.activeSessionID = activeID
        model.isRecording = true

        var dismissed = false
        // Stale expectedSessionID does not match activeSessionID
        let staleID = UUID()
        let presenter = MeetingReminderPresenter(
            model: model,
            calendar: calendar,
            initialMeeting: m1,
            expectedSessionID: staleID,
            onDismiss: { dismissed = true }
        )

        #expect(presenter.mode == .recording)

        presenter.accept()

        for _ in 0..<100 where presenter.isTransitioning {
            try? await Task.sleep(for: .milliseconds(5))
        }

        if case .terminalError(let reason) = presenter.mode {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("Expected terminalError on stale session, got \(presenter.mode)")
        }

        // Active session must NOT be stopped!
        #expect(model.isRecording)
        #expect(model.activeSessionID == activeID)
        #expect(!dismissed)
    }

    @Test func viewGeometryIsConsistentAcrossStates() {
        let m1 = makeMeeting(id: "m1", title: "Meeting 1")
        calendar.setEventsForTesting([m1])

        let presenter = MeetingReminderPresenter(
            model: model,
            calendar: calendar,
            initialMeeting: m1,
            expectedSessionID: nil,
            onDismiss: {}
        )

        let idleHosting = NSHostingView(rootView: MeetingReminderView(presenter: presenter))
        let idleSize = idleHosting.fittingSize
        #expect(idleSize.width == 440)
        #expect(idleSize.height > 150)

        // Switch to recording mode
        model.isRecording = true
        model.elapsed = 15
        let recordingPresenter = MeetingReminderPresenter(
            model: model,
            calendar: calendar,
            initialMeeting: m1,
            expectedSessionID: nil,
            onDismiss: {}
        )
        let recordingHosting = NSHostingView(rootView: MeetingReminderView(presenter: recordingPresenter))
        let recordingSize = recordingHosting.fittingSize
        #expect(recordingSize.width == 440)
        // Recording state has extra context box, so it should be taller than idle
        #expect(recordingSize.height > idleSize.height)

        // Switch to terminal error
        recordingPresenter.mode = .terminalError(reason: "Не удалось остановить сессию")
        let errorHosting = NSHostingView(rootView: MeetingReminderView(presenter: recordingPresenter))
        let errorSize = errorHosting.fittingSize
        #expect(errorSize.width == 440)
    }

    @Test func chooserPopoverDimensionsAreBounded() {
        let events = (1...15).map { makeMeeting(id: "m\($0)", title: "Meeting \($0)") }
        calendar.setEventsForTesting(events)

        let presenter = MeetingReminderPresenter(
            model: model,
            calendar: calendar,
            initialMeeting: events.first,
            expectedSessionID: nil,
            onDismiss: {}
        )

        let chooserHosting = NSHostingView(rootView: MeetingChooserPopoverView(presenter: presenter))
        let chooserSize = chooserHosting.fittingSize
        #expect(chooserSize.width == 360)
        #expect(chooserSize.height <= 440)
    }

    @Test func openReminderPublishesElapsedAndCalendarChanges() {
        let meeting = makeMeeting(id: "next", title: "Next")
        let presenter = MeetingReminderPresenter(model: model, calendar: calendar,
            initialMeeting: meeting, expectedSessionID: nil, onDismiss: {})
        var changes = 0
        let observation = presenter.objectWillChange.sink { changes += 1 }
        model.isRecording = true
        model.elapsed = 9
        let beforeThreshold = changes
        model.elapsed = 10
        #expect(changes > beforeThreshold, "An open reminder must redraw elapsed and the short-recording explanation")
        let beforeCalendar = changes
        calendar.setEventsForTesting([meeting])
        #expect(changes > beforeCalendar, "An open chooser must redraw calendar candidates")
        withExtendedLifetime(observation) {}
    }

    @Test(arguments: ["skip", "replacement", "timeout"])
    func productionReminderUsesContentHeightAndReleasesAfterDismissal(_ dismissal: String) async throws {
        _ = NSApplication.shared
        let meeting = makeMeeting(id: "next", title: "Next meeting", startOffset: -60,
            duration: dismissal == "timeout" ? 60.1 : 1800)
        calendar.setEventsForTesting([meeting])
        model.isRecording = true
        model.elapsed = 15
        let delegate = RecorderAppDelegate(model: model)
        defer {
            (delegate.reminder?.contentView as? NSHostingView<MeetingReminderView>)?.rootView.presenter.skip()
        }
        weak var releasedPanel: NSPanel?
        weak var releasedPresenter: MeetingReminderPresenter?
        weak var releasedChooser: NSWindow?
        var panel: NSPanel?
        var host: NSHostingView<MeetingReminderView>?
        var oldLayout: (() -> Void)?
        try autoreleasepool {
            delegate.showReminder(meeting)
            panel = try #require(delegate.reminder)
            host = try #require(panel?.contentView as? NSHostingView<MeetingReminderView>)
            let reference = NSHostingView(rootView: host!.rootView)
            let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
            if let path = ProcessInfo.processInfo.environment["REMINDER_NATIVE_ROOT"] {
                try snapshot(host!, path: path, name: "recording-panel-" + dismissal)
            }
            #expect(panel!.frame.height == max(200, min(screenHeight - 32, reference.fittingSize.height)))
            #expect(host!.fittingSize.height > 200)
            releasedPanel = panel
            releasedPresenter = host!.rootView.presenter
            oldLayout = host!.rootView.presenter.onLayoutChanged
        }
        if ProcessInfo.processInfo.environment["REMINDER_NATIVE_ROOT"] != nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.finishLaunching()
            host!.rootView.presenter.isChooserOpen = true
            try await Task.sleep(for: .milliseconds(150))
            releasedChooser = panel?.childWindows?.first { $0.isVisible }
            #expect(releasedChooser != nil, "The dismissal regression must exercise an actually open chooser")
        }
        autoreleasepool {
            switch dismissal {
            case "skip":
                host!.rootView.presenter.skip()
                #expect(delegate.reminder == nil)
            case "replacement":
                delegate.showReminder(meeting)
                #expect(delegate.reminder !== panel)
            default: break
            }
            host = nil
            panel = nil
        }
        for _ in 0..<200 where releasedPanel != nil || releasedPresenter != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(releasedPanel == nil, "Dismissed panels must not be retained by the layout callback")
        #expect(releasedPresenter == nil)
        #expect(releasedChooser?.isVisible != true)
        if dismissal == "replacement", let replacement = delegate.reminder {
            let frame = replacement.frame
            oldLayout?()
            try await Task.sleep(for: .milliseconds(50))
            #expect(delegate.reminder === replacement && replacement.frame == frame && replacement.isVisible)
        }
    }

    @discardableResult
    private func snapshot(_ host: NSView, path: String, name: String) throws -> NSBitmapImageRep {
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
        return bitmap
    }

    private func expectFullWidthBluePrimary(_ bitmap: NSBitmapImageRep) {
        var widestBlueRow = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            var bluePixels = 0
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.8, color.blueComponent > 0.4,
                   color.blueComponent > color.redComponent + 0.12,
                   color.blueComponent > color.greenComponent + 0.12 {
                    bluePixels += 2
                }
            }
            widestBlueRow = max(widestBlueRow, bluePixels)
        }
        #expect(Double(widestBlueRow) >= Double(bitmap.pixelsWide) * 0.8,
            "The rendered primary background must be blue across the card's content width")
    }

    @Test func nativeChooserScrollsToKeyboardSelectionAndRestoresFocus() async throws {
        guard let path = ProcessInfo.processInfo.environment["REMINDER_NATIVE_ROOT"] else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let events = (1...15).map { makeMeeting(id: "m\($0)", title: "Meeting \($0)", startOffset: -60) }
        calendar.setEventsForTesting(events)
        let delegate = RecorderAppDelegate(model: model)
        delegate.showReminder(events[0])
        let panel = try #require(delegate.reminder)
        let host = try #require(panel.contentView as? NSHostingView<MeetingReminderView>)
        let presenter = host.rootView.presenter
        defer { presenter.isChooserOpen = false; presenter.skip() }
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        try snapshot(host, path: path, name: "idle-panel")

        func openChooser() async throws -> NSWindow {
            presenter.isChooserOpen = true
            try await Task.sleep(for: .milliseconds(150))
            let popover = panel.childWindows?.first { $0.isVisible }
            return try #require(popover)
        }
        func key(_ code: UInt16, _ characters: String, in window: NSWindow, phase: NSEvent.EventType = .keyDown) throws {
            let event = try #require(NSEvent.keyEvent(with: phase, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }
        let parentFrame = panel.frame
        let chooser = try await openChooser()
        #expect(panel.frame == parentFrame)
        for _ in 0..<14 {
            try key(125, "\u{f701}", in: chooser)
            try await Task.sleep(for: .milliseconds(15))
        }
        try snapshot(try #require(chooser.contentView), path: path, name: "chooser-last-row")
        try key(36, "\r", in: chooser)
        try await Task.sleep(for: .milliseconds(100))
        #expect(presenter.selectedMeeting?.id == "m15")
        #expect(!presenter.isChooserOpen)
        let reopened = try await openChooser()
        try snapshot(try #require(reopened.contentView), path: path, name: "chooser-reopened")
        try key(53, "\u{1b}", in: reopened)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!presenter.isChooserOpen)
        #expect(presenter.selectedMeeting?.id == "m15")
        try key(49, " ", in: panel)
        try key(49, " ", in: panel, phase: .keyUp)
        try await Task.sleep(for: .milliseconds(150))
        #expect(presenter.isChooserOpen, "Focus must return to the chooser button after dismissal")
        let finalChooser = try #require(panel.childWindows?.first { $0.isVisible })
        try key(126, "\u{f700}", in: finalChooser)
        try await Task.sleep(for: .milliseconds(15))
        try key(49, " ", in: finalChooser)
        try key(49, " ", in: finalChooser, phase: .keyUp)
        try await Task.sleep(for: .milliseconds(100))
        #expect(presenter.selectedMeeting?.id == "m14")
        #expect(!presenter.isChooserOpen)
        #expect(!model.isRecording)
    }

    @Test func nativeReminderUpdatesElapsedAndLongContent() async throws {
        guard let path = ProcessInfo.processInfo.environment["REMINDER_NATIVE_ROOT"] else { return }
        _ = NSApplication.shared
        try #require(await model.startRecordingIntent(customTitle: "Планирование"))
        try await Task.sleep(for: .milliseconds(50))
        let start = try #require(Calendar.current.date(bySettingHour: 12, minute: 30, second: 0, of: Date()))
        let meeting = MeetingContext(id: "next", calendar: "Synthetic", summary: "Агент B2C",
            start: start, end: start.addingTimeInterval(1800))
        calendar.setEventsForTesting([meeting])
        model.elapsed = 9
        let delegate = RecorderAppDelegate(model: model)
        delegate.setUpPresentation()
        delegate.showReminder(meeting)
        let panel = try #require(delegate.reminder)
        let host = try #require(panel.contentView as? NSHostingView<MeetingReminderView>)
        defer { host.rootView.presenter.skip() }
        panel.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.isRecording && host.rootView.presenter.isShortRecording)
        try snapshot(host, path: path, name: "recording-9s-light")
        model.elapsed = 10
        panel.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.isRecording && !host.rootView.presenter.isShortRecording)
        try snapshot(host, path: path, name: "recording-10s-dark")
        model.elapsed = 42 * 60 + 18
        panel.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(100))
        let recordingBitmap = try snapshot(host, path: path, name: "reference-recording-native")
        expectFullWidthBluePrimary(recordingBitmap)
        #expect(panel.frame.height > 450 && panel.frame.height < 500)
        panel.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        expectFullWidthBluePrimary(try snapshot(host, path: path, name: "reference-recording-native-dark"))
        delegate.capsuleController.showCapsule()
        let screen = try #require(NSScreen.main?.visibleFrame)
        let capsule = try #require(delegate.capsuleController.panel)
        capsule.setFrameOrigin(NSPoint(x: screen.maxX - capsule.frame.width - 16,
            y: screen.maxY - capsule.frame.height - 16))
        let long = makeMeeting(id: "long", title: String(repeating: "Очень длинное название встречи ", count: 50))
        host.rootView.presenter.selectMeeting(long)
        try await Task.sleep(for: .milliseconds(150))
        #expect(panel.frame.height <= (NSScreen.main?.visibleFrame.height ?? 900) - 32)
        #expect(!panel.frame.intersects(capsule.frame), "Tall reminders must fit beside the actual visible capsule")
        try snapshot(host, path: path, name: "recording-long-content")
        capsule.setFrameOrigin(NSPoint(x: capsule.frame.minX, y: screen.minY + 16))
        host.rootView.presenter.onLayoutChanged?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(screen.contains(panel.frame) && !panel.frame.intersects(capsule.frame))
        try snapshot(host, path: path, name: "recording-capsule-bottom")
        model.elapsed = 9
        #expect(await model.cancelRecordingIntent(sessionID: model.activeSessionID))
        delegate.capsuleController.hideCapsule()
        delegate.window.close()
        host.rootView.presenter.skip()
        delegate.showReminder(meeting)
        let idlePanel = try #require(delegate.reminder)
        idlePanel.appearance = NSAppearance(named: .aqua)
        let idleHost = try #require(idlePanel.contentView as? NSHostingView<MeetingReminderView>)
        try await Task.sleep(for: .milliseconds(100))
        try snapshot(idleHost, path: path, name: "reference-idle-native")
        #expect(idlePanel.frame.height > 260 && idlePanel.frame.height < 310)
        idlePanel.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        try snapshot(idleHost, path: path, name: "reference-idle-native-dark")
        idlePanel.appearance = NSAppearance(named: .aqua)
        model.workspace.settingsInput = { true }
        idleHost.rootView.presenter.accept()
        try await Task.sleep(for: .milliseconds(100))
        let errorBitmap = try snapshot(idleHost, path: path, name: "terminal-error-native")
        expectFullWidthBluePrimary(errorBitmap)
        model.workspace.settingsInput = { false }
        idleHost.rootView.presenter.dismissError()
    }
}

// Synthetic fixtures
private final class SyntheticAudioCapture: AudioCaptureControllerProtocol, @unchecked Sendable {
    let outputURL: URL
    init(outputURL: URL) { self.outputURL = outputURL }
    func startCapture() async throws {}
    func stopCapture() async throws -> AudioCaptureStopResult {
        .init(duration: 15, outputURL: outputURL)
    }
    func setMicrophoneMuted(_ muted: Bool) {}
    func currentMicrophoneState() -> MicrophoneRecordingState { .receiving }
}

private struct SyntheticRunner: TranscriptionRunnerProtocol {
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL { recording.appendingPathExtension("txt") }
}

private struct SyntheticExporter: AudioExporterProtocol {
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws {}
}
