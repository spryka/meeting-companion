import Foundation
import AppKit
import Testing
import MeetingCompanionCore
import MeetingCompanionApplication
@testable import MeetingCompanionApp

private actor CaptureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

// The Core test target's private mock cannot be imported by App tests.
private final class MockAudioCaptureController: AudioCaptureControllerProtocol, @unchecked Sendable {
    let outputURL: URL
    var duration: TimeInterval = 15
    var suspendStart: (@Sendable () async -> Void)?
    var suspendStop: (@Sendable () async -> Void)?
    var startError = false
    private let lock = NSLock()
    private var mutations = (started: false, stops: 0, muted: false)
    var state: (started: Bool, stops: Int, muted: Bool) { lock.withLock { mutations } }
    init(outputURL: URL) { self.outputURL = outputURL }
    func startCapture() async throws {
        await suspendStart?()
        if startError { throw NSError(domain: "SyntheticCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic unavailable microphone"]) }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: outputURL.path) { try Data("synthetic-original".utf8).write(to: outputURL) }
        lock.withLock { mutations.started = true }
    }
    func stopCapture() async throws -> AudioCaptureStopResult {
        await suspendStop?()
        lock.withLock { mutations.started = false; mutations.stops += 1 }
        return .init(duration: duration, outputURL: outputURL)
    }
    func setMicrophoneMuted(_ muted: Bool) { lock.withLock { mutations.muted = muted } }
    func currentMicrophoneState() -> MicrophoneRecordingState { .receiving }
}

private final class SyntheticTrash: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var paths: [URL] = []
    var fail = false
    var count: Int { lock.withLock { paths.count } }
    init(root: URL) { self.root = root }
    func move(_ url: URL) throws {
        guard url.path.hasPrefix(root.path + "/"), !fail else { throw NSError(domain: "SyntheticTrash", code: 1) }
        lock.withLock { paths.append(url) }
        try FileManager.default.removeItem(at: url)
    }
}

private struct PresentationRunner: TranscriptionRunnerProtocol {
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL { recording.appendingPathExtension("txt") }
}
private struct PresentationExporter: AudioExporterProtocol {
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws {}
}
private final class PresentationLevels: AudioLevelMonitoring, @unchecked Sendable {
    func start() async throws {}
    func stop() async throws {}
}

// Isolation belongs before service construction, even when the exercised guard breaks.
@MainActor func isolatedRecorderModel(
    sessionService: RecordingSessionService? = nil,
    processingService: ProcessingService? = nil,
    historyRepository: RecordingHistoryRepository? = nil,
    workspace: TranscriptReviewWindowManager? = nil,
    defaults: UserDefaults,
    appDataDirectory: URL? = nil,
    startBackgroundServices: Bool = false,
    captureControllerFactory: (@MainActor (URL, String?, AudioCaptureBackend) async throws -> any AudioCaptureControllerProtocol)? = nil,
    shortRecordingTrash: (@Sendable (URL) throws -> Void)? = nil,
    audioLevelMonitorFactory: RecorderViewModel.AudioLevelMonitorFactory? = nil,
    audioCheckTimeoutSleeper: RecorderViewModel.AudioCheckTimeoutSleeper? = nil,
    audioCheckTimeoutDuration: Duration = .seconds(30),
    capsuleTimerScheduler: RecorderViewModel.CapsuleTimerScheduler? = nil
) -> RecorderViewModel {
    precondition(defaults !== UserDefaults.standard && !startBackgroundServices)
    let root = defaults.string(forKey: "recordingsDirectory").map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("isolated-" + UUID().uuidString)
    precondition(root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path)
                 || root.standardizedFileURL.path.hasPrefix("/private/tmp/") || root.standardizedFileURL.path.hasPrefix("/tmp/")
                 || ProcessInfo.processInfo.environment["SOL_NATIVE_ROOT"].map { root.path.hasPrefix($0 + "/") } == true)
    defaults.set(root.path, forKey: "recordingsDirectory")
    defaults.set([String](), forKey: "meetingCalendarIDs")
    let repo = historyRepository ?? RecordingHistoryRepository()
    let processing = processingService ?? ProcessingService(transcriptionRunner: PresentationRunner(), audioExporter: PresentationExporter(), historyRepository: repo)
    return RecorderViewModel(sessionService: sessionService ?? RecordingSessionService(historyRepo: repo), processingService: processing,
        historyRepository: repo, workspace: workspace, defaults: defaults,
        appDataDirectory: appDataDirectory ?? root.appendingPathComponent("appData"), startBackgroundServices: false,
        captureControllerFactory: captureControllerFactory ?? { url, _, _ in MockAudioCaptureController(outputURL: url) },
        shortRecordingTrash: shortRecordingTrash ?? { _ in },
        audioLevelMonitorFactory: audioLevelMonitorFactory ?? { _, _, _ in PresentationLevels() },
        audioCheckTimeoutSleeper: audioCheckTimeoutSleeper, audioCheckTimeoutDuration: audioCheckTimeoutDuration,
        microphoneProvider: { [] }, accessProvider: { [] }, calendarCatalogProvider: { [] },
        capsuleTimerScheduler: capsuleTimerScheduler)
}

@MainActor private final class RecordingFixture {
    let root: URL
    let suite = "handoff-" + UUID().uuidString
    let defaults: UserDefaults
    let repo = RecordingHistoryRepository()
    let session: RecordingSessionService
    let model: RecorderViewModel
    let trash: SyntheticTrash

    init(factory: (@MainActor (URL, String?, AudioCaptureBackend) async throws -> any AudioCaptureControllerProtocol)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(root.path, forKey: "recordingsDirectory")
        defaults.set([String](), forKey: "meetingCalendarIDs")
        defaults.set("missing-synthetic-mic", forKey: "selectedMicrophoneID")
        session = RecordingSessionService(historyRepo: repo)
        trash = SyntheticTrash(root: root)
        let trash = trash
        let processing = ProcessingService(transcriptionRunner: PresentationRunner(), audioExporter: PresentationExporter(), historyRepository: repo)
        model = isolatedRecorderModel(sessionService: session, processingService: processing, historyRepository: repo,
            defaults: defaults, startBackgroundServices: false, captureControllerFactory: factory ?? { url, _, _ in MockAudioCaptureController(outputURL: url) },
            shortRecordingTrash: { try trash.move($0) }, audioLevelMonitorFactory: { _, _, _ in PresentationLevels() })
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func output(_ name: String) throws -> URL {
        let stem = "meeting_" + name
        let folder = root.appendingPathComponent(stem)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(stem + ".m4a")
        try Data("synthetic-original".utf8).write(to: url)
        for source in ["host", "remote"] {
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("raw/\(stem).\(source)_record.wav"))
        }
        return url
    }
    func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(predicate(), "Bounded synthetic observation timed out")
    }
    func start(_ name: String) async throws -> MockAudioCaptureController {
        let capture = MockAudioCaptureController(outputURL: try output(name))
        _ = try await session.start(controller: capture, outputURL: capture.outputURL)
        try await wait { self.model.isRecording && self.model.lastFileURL == capture.outputURL }
        return capture
    }
}

@Suite @MainActor struct RecordingPresentationTests {
    @Test(arguments: [3.0, 15.0]) func settings30SavedFormCaptureActionIsBlocked(duration: Double) async throws {
        let f = try RecordingFixture(); defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        let capture = try await f.start("settings-saved-action")
        capture.duration = duration
        f.model.elapsed = duration
        let sessionID = try #require(f.model.activeSessionID)
        let form = FullRecorderView(viewModel: f.model, showSettings: {})
        let saved = form.recordingAction.perform
        #expect(f.model.presentSettings())
        #expect(!(await saved()))
        #expect(capture.state.stops == 0 && f.model.isRecording && f.model.activeSessionID == sessionID)
        f.model.toggleMicrophoneMute(sessionID: sessionID)
        try await f.wait { f.model.microphoneMuted }
        #expect(capture.state.muted)
        if f.model.isRecording {
            let accepted = duration < 10 ? await f.model.cancelRecordingIntent(sessionID: sessionID) : await f.model.stopRecordingIntent(sessionID: sessionID)
            #expect(accepted) // Independent capsule/status path stays allowed under Settings.
            #expect(capture.state.stops == 1)
        }
        f.model.dismissSettings()
    }

    @Test func settings30CalendarExpiryPreservesUserTitle() async throws {
        let suite = "settings30-title-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = isolatedRecorderModel(defaults: defaults)
        let now = Date()
        let first = MeetingContext(id: "first", calendar: "synthetic", summary: "Первая встреча", start: now.addingTimeInterval(-100), end: now.addingTimeInterval(100))
        let next = MeetingContext(id: "next", calendar: "synthetic", summary: "Следующая встреча", start: now.addingTimeInterval(-10), end: now.addingTimeInterval(200))
        var clockedSelection = MeetingSelection()
        clockedSelection.refresh(events: [first, next], now: now)
        #expect(clockedSelection.meeting?.id == first.id)
        model.calendar.events = [first]
        #expect(model.selectedMeeting?.id == "first")
        var title = RecordingFormTitle(text: first.summary)
        title.edit("Мой заголовок") // Same value operation bound by the real TextField.
        #expect(model.presentSettings())
        clockedSelection.refresh(events: [first, next], now: now.addingTimeInterval(150))
        model.calendar.events = [try #require(clockedSelection.meeting)] // Actual subscription receives the controlled boundary's new context.
        #expect(model.selectedMeeting?.id == "next")
        title.meetingChanged(model.selectedMeeting) // Same rule bound by actual form onChange.
        #expect(title.text == "Мой заголовок")
        clockedSelection.refresh(events: [first, next], now: now.addingTimeInterval(300))
        #expect(clockedSelection.meeting == nil)
        model.calendar.events = []
        #expect(model.selectedMeeting == nil)
        title.meetingChanged(model.selectedMeeting)
        #expect(title.text == "Мой заголовок")
        var automatic = RecordingFormTitle(text: first.summary)
        automatic.meetingChanged(next)
        #expect(automatic.text == next.summary)
        automatic.meetingChanged(nil)
        #expect(automatic.text == "Новая встреча")
        model.dismissSettings()
    }

    @Test func solTerminalCloseHidesWithoutClearingErrorOrAudio() async throws {
        let f = try RecordingFixture(); defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        let capture = try await f.start("terminal-close")
        let bytes = try Data(contentsOf: capture.outputURL)
        _ = try await f.session.stop(elapsed: 15, expectedSessionID: f.model.activeSessionID)
        try await f.wait { !f.model.isRecording && !f.model.sessionStopping }
        f.model.recordingSaveError = "Synthetic save failure"
        #expect(f.model.showsRecordingCapsule)
        f.model.dismissCapsule()
        #expect(!f.model.showsRecordingCapsule)
        #expect(f.model.recordingSaveError == "Synthetic save failure")
        #expect(try Data(contentsOf: capture.outputURL) == bytes)
    }
    @Test func solCustomTitleKeepsNoMeetingAndPersistsDisplayMetadata() async throws {
        let f = try RecordingFixture(); defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        f.model.selectedMeeting = nil
        f.model.mainPage = .recording
        let form = FullRecorderView(viewModel: f.model, showSettings: {}, title: "Моё название")
        #expect(await form.recordingAction.perform())
        #expect(f.model.mainPage == .history)
        for _ in 0..<20 { await Task.yield() }
        #expect(f.model.lastRecordingTitle == "Моё название")
        let url = try #require(f.model.lastFileURL)
        let entry = RecordingEntry.load(recording: url)
        #expect(entry.displayTitle == "Моё название")
        #expect(f.model.recordingMeetingID == nil)
        #expect(!FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("context.json").path))
        #expect(f.defaults.dictionary(forKey: "handledMeetings") == nil)
        let id = try #require(f.model.activeSessionID)
        f.model.toggleMicrophoneMute(sessionID: id)
        try await f.wait { f.model.microphoneMuted }
        #expect(f.model.lastRecordingTitle == "Моё название")
        _ = try await f.session.stop(elapsed: 15, expectedSessionID: id)
    }
    @Test func handoffMatchingMenuMuteAndSaveReachSameController() async throws {
        let f = try RecordingFixture(); defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        let capture = try await f.start("matching")
        f.model.elapsed = 15
        let original = try Data(contentsOf: capture.outputURL)
        let delegate = RecorderAppDelegate(model: f.model, presentWorkspace: {})
        let menu = StatusMenu.build(model: f.model, appUpdater: AppUpdater(defaults: f.defaults), target: delegate)
        let mute = try #require(menu.items.first { $0.title == "Выключить микрофон" })
        delegate.toggleMicrophoneMuteAction(mute)
        try await f.wait { f.model.microphoneMuted }
        #expect(capture.state.muted && capture.state.started && capture.state.stops == 0)
        let fresh = StatusMenu.build(model: f.model, appUpdater: AppUpdater(defaults: f.defaults), target: delegate)
        delegate.toggleMicrophoneMuteAction(try #require(fresh.items.first { $0.title == "Включить микрофон" }))
        try await f.wait { !f.model.microphoneMuted }
        #expect(!capture.state.muted)
        delegate.stopRecordingAction(try #require(menu.items.first { $0.title == "Остановить запись" }))
        try await f.wait { !f.model.isRecording && !f.model.isBusy }
        #expect(capture.state.stops == 1 && !capture.state.started && f.trash.count == 0)
        #expect(try Data(contentsOf: capture.outputURL) == original)
    }

    @Test func handoffExplicitCancellationFailureRetainsOriginalsAndError() async throws {
        let f = try RecordingFixture(); defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        let capture = try await f.start("trash_failure")
        let original = try Data(contentsOf: capture.outputURL)
        f.model.elapsed = 9; f.trash.fail = true
        let action = FullRecorderView(viewModel: f.model, showSettings: {}).recordingAction
        #expect(action.title == "Отменить короткую запись")
        #expect(await action.perform() == false)
        #expect(try Data(contentsOf: capture.outputURL) == original)
        #expect(f.model.recordingSaveError != nil && f.model.errorMessage != nil && !f.model.recordingCancelled)
        #expect(f.trash.count == 0)
    }

    @Test(arguments: ["menu-stop", "menu-cancel", "menu-mute", "nil-stop", "nil-cancel", "nil-mute", "form", "idle-form"])
    func handoffRetainedCallbacksCannotMutateSuccessor(route: String) async throws {
        let f = try RecordingFixture(); defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        let idleAction = FullRecorderView(viewModel: f.model, showSettings: {}).recordingAction
        let a = try await f.start("a")
        let idA = try #require(f.model.activeSessionID)
        f.model.elapsed = route.contains("cancel") ? 9 : 15
        let menu = StatusMenu.build(model: f.model, appUpdater: AppUpdater(defaults: f.defaults), target: nil)
        let retained = menu.items.first { $0.title == (route.contains("cancel") ? "Отменить короткую запись" : route.contains("mute") ? "Выключить микрофон" : "Остановить запись") }
        let formAction = FullRecorderView(viewModel: f.model, showSettings: {}).recordingAction
        _ = try await f.session.stop(elapsed: 15, expectedSessionID: idA)
        try await f.wait { !f.model.isRecording }
        let b = try await f.start("b")
        let idB = try #require(f.model.activeSessionID)
        f.model.elapsed = route.contains("cancel") ? 9 : 15
        let before = try Data(contentsOf: b.outputURL)
        let delegate = RecorderAppDelegate(model: f.model, presentWorkspace: {})
        switch route {
        case "menu-stop": delegate.stopRecordingAction(try #require(retained))
        case "menu-cancel": delegate.cancelRecordingAction(try #require(retained))
        case "menu-mute": delegate.toggleMicrophoneMuteAction(try #require(retained))
        case "nil-stop": delegate.stopRecordingAction()
        case "nil-cancel": delegate.cancelRecordingAction()
        case "nil-mute": delegate.toggleMicrophoneMuteAction()
        case "form": #expect(await formAction.perform() == false)
        default: #expect(await idleAction.perform() == false)
        }
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(b.state.started && b.state.stops == 0 && !b.state.muted, "Retained \(route) must leave B controller unchanged")
        #expect(f.model.isRecording && f.model.activeSessionID == idB && !f.model.microphoneMuted)
        #expect(!f.model.isBusy && f.model.recordingSaveError == nil)
        #expect(try Data(contentsOf: b.outputURL) == before)
        #expect(f.trash.count == 0 && a.state.stops == 1)
        if await f.session.isRecording { _ = try await f.session.stop(elapsed: 15, expectedSessionID: idB) }
    }

    @Test func handoffTrayPresentsExistingFormAndFailedStartRetainsIt() async throws {
        var seenMicrophone: String?
        let f = try RecordingFixture(factory: { url, mic, _ in
            seenMicrophone = mic
            let capture = MockAudioCaptureController(outputURL: url); capture.startError = true; return capture
        })
        defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        var presentations = 0, successfulStarts = 0
        f.model.onRecordingStarted = { successfulStarts += 1 }
        let delegate = RecorderAppDelegate(model: f.model, presentWorkspace: { presentations += 1 })
        let menu = StatusMenu.build(model: f.model, appUpdater: AppUpdater(defaults: f.defaults), target: delegate)
        let item = try #require(menu.items.first { $0.title == "Новая запись" })
        #expect(item.action == #selector(RecorderAppDelegate.startRecordingAction))
        delegate.startRecordingAction()
        #expect(presentations == 1 && f.model.mainPage == .recording)
        #expect(!f.model.isRecording && !f.model.isBusy)
        let action = FullRecorderView(viewModel: f.model, showSettings: {}).recordingAction
        #expect(action.title == "Начать запись")
        #expect(await action.perform() == false)
        try await f.wait { !f.model.isBusy }
        #expect(seenMicrophone == "missing-synthetic-mic")
        #expect(f.model.errorMessage?.contains("Synthetic unavailable microphone") == true)
        #expect(f.model.mainPage == .recording && !f.model.isRecording && f.model.elapsed == 0)
        #expect(successfulStarts == 0 && !f.model.sessionStarting)
    }

    @Test(arguments: [false, true])
    func handoffAdmittedStartExplainedBeforeServiceAndCleared(fail: Bool) async throws {
        let gate = CaptureGate()
        let f = try RecordingFixture(factory: { url, _, _ in
            await gate.wait()
            let capture = MockAudioCaptureController(outputURL: url); capture.startError = fail; return capture
        })
        defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        let action = FullRecorderView(viewModel: f.model, showSettings: {}).recordingAction
        let start = Task { await action.perform() }
        for _ in 0..<500 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await gate.waiting)
        #expect(await f.session.currentSnapshot.phase == .idle, "Suspended before service.start")
        let menu = StatusMenu.build(model: f.model, appUpdater: AppUpdater(defaults: f.defaults), target: nil)
        #expect(menu.items.contains { $0.title == "Запуск записи…" })
        #expect(f.model.sessionStarting && !f.model.canStartRecording && f.model.preventsTermination)
        await gate.open()
        #expect(await start.value == !fail)
        try await f.wait { !f.model.sessionStarting && !f.model.isBusy }
        #expect(f.model.isRecording == !fail)
        if !fail { _ = try await f.session.stop(elapsed: 15, expectedSessionID: f.model.activeSessionID) }
    }

    @Test(arguments: [false, true])
    func handoffActualCapsuleHostShowsCaptureTransitions(previousTerminal: Bool) async throws {
        let f = try RecordingFixture(); defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        if previousTerminal {
            let old = try f.output("old")
            _ = try f.repo.putThrowing(RecordingEntry.load(recording: old))
            await f.model.history.synchronize(); f.model.lastFileURL = old
            f.model.transcribeLastRecording()
            try await f.wait { if case .completed = f.model.transcriptionState { return true }; return false }
        }
        let controller = RecordingCapsuleController(model: f.model, defaults: f.defaults)
        defer { controller.hideCapsule() }
        let panel = try #require(controller.panel)
        let capture = MockAudioCaptureController(outputURL: try f.output("transition"))
        let gate = CaptureGate(); capture.suspendStart = { await gate.wait() }
        let start = Task { try await f.session.start(controller: capture, outputURL: capture.outputURL) }
        try await f.wait { f.model.sessionStarting }
        #expect(RecordingCapsuleHostView(viewModel: f.model).captureTransitionText == "Запуск записи…")
        #expect(!f.model.showsProcessingCapsule)
        f.model.dismissCapsule()
        #expect(!f.model.capsuleDismissed)
        let startingMenu = StatusMenu.build(model: f.model, appUpdater: AppUpdater(defaults: f.defaults), target: nil)
        #expect(!startingMenu.items.contains { ["Новая запись", "Остановить запись", "Отменить короткую запись", "Выключить микрофон"].contains($0.title) })
        try await f.wait { panel.isVisible }
        await gate.open(); let snapshot = try await start.value
        try await f.wait { f.model.isRecording }
        capture.suspendStop = { await gate.wait() }
        let stop = Task { try await f.session.stop(elapsed: 15, expectedSessionID: snapshot.sessionID) }
        try await f.wait { f.model.sessionStopping }
        #expect(RecordingCapsuleHostView(viewModel: f.model).captureTransitionText == "Сохранение записи…")
        #expect(!f.model.showsProcessingCapsule && panel.isVisible)
        f.model.dismissCapsule()
        #expect(!f.model.capsuleDismissed)
        let savingMenu = StatusMenu.build(model: f.model, appUpdater: AppUpdater(defaults: f.defaults), target: nil)
        #expect(!savingMenu.items.contains { ["Новая запись", "Остановить запись", "Отменить короткую запись", "Выключить микрофон"].contains($0.title) })
        await gate.open(); _ = try await stop.value
    }

    @Test(arguments: [9.0, 10.0])
    func handoffFormSpaceHasExplicitShortIntent(seconds: Double) async throws {
        let f = try RecordingFixture(); defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        let capture = try await f.start("boundary")
        f.model.elapsed = seconds; capture.duration = seconds
        let action = FullRecorderView(viewModel: f.model, showSettings: {}).recordingAction
        #expect(action.title == (seconds < 10 ? "Отменить короткую запись" : "Остановить запись"))
        #expect(await action.perform())
        try await f.wait { !f.model.isRecording && !f.model.sessionStopping }
        #expect(f.trash.count == (seconds < 10 ? 1 : 0))
        #expect(capture.state.stops == 1 && !f.model.isRecording)
    }

    @Test func handoffRetainedOrdinaryStopCannotBecomeCancellation() async throws {
        let f = try RecordingFixture(); defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        let capture = try await f.start("retained")
        f.model.elapsed = 10
        let action = FullRecorderView(viewModel: f.model, showSettings: {}).recordingAction
        f.model.elapsed = 9
        #expect(await action.perform() == false)
        #expect(capture.state.started && capture.state.stops == 0 && f.trash.count == 0)
        if await f.session.isRecording { _ = try await f.session.stop(elapsed: 15, expectedSessionID: f.model.activeSessionID) }
    }

    @Test func handoffOldCancellationTimeoutCannotHideSuspendedStart() async throws {
        let gate = CaptureGate()
        let f = try RecordingFixture(factory: { url, _, _ in await gate.wait(); return MockAudioCaptureController(outputURL: url) })
        defer { f.cleanup() }
        try await f.wait { f.model.isAttached }
        _ = try await f.start("cancelled")
        let controller = RecordingCapsuleController(model: f.model, defaults: f.defaults)
        defer { controller.hideCapsule() }
        let panel = try #require(controller.panel)
        f.model.elapsed = 9
        #expect(await f.model.cancelRecordingIntent(sessionID: f.model.activeSessionID))
        #expect(f.model.recordingCancelled)
        try await f.wait { !f.model.isRecording && !f.model.sessionStopping }
        let start = Task { await f.model.startRecordingIntent() }
        for _ in 0..<500 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await gate.waiting)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(!f.model.capsuleDismissed, "A feedback timeout must not dismiss B admission")
        #expect(f.model.sessionStarting)
        #expect(panel.isVisible)
        await gate.open(); #expect(await start.value)
        _ = try await f.session.stop(elapsed: 15, expectedSessionID: f.model.activeSessionID)
    }

    @Test func independentCapsulePanelPropertiesAndCoexistence() async throws {
        let suite = "test-capsule-properties-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)

        let controller = RecordingCapsuleController(model: model, defaults: defaults)
        let panel = try #require(controller.panel, "RecordingCapsuleController must create an independent NSPanel")

        #expect(panel.styleMask.contains(.nonactivatingPanel), "Capsule must be a non-activating panel")
        #expect(panel.styleMask.contains(.borderless), "Capsule must be borderless")
        #expect(panel.level == .floating, "Capsule must float above standard windows")
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces), "Capsule must join all spaces")
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary), "Capsule must support full screen auxiliary")
        #expect(panel.isMovableByWindowBackground, "Capsule must be draggable by window background")

        // Workspace window remains titled and resizable and does not transform into a borderless capsule
        let workspaceWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        workspaceWindow.isReleasedWhenClosed = false
        #expect(workspaceWindow.styleMask.contains(.titled))
        #expect(workspaceWindow.styleMask != .borderless)

        // Both hosts can coexist without closing or transforming each other
        controller.showCapsule()
        #expect(AppWindowState.activationPolicy(for: [workspaceWindow, panel]) == .accessory)
        workspaceWindow.orderFront(nil)
        #expect(AppWindowState.activationPolicy(for: [workspaceWindow, panel]) == .regular)
        #expect(panel.isVisible, "Capsule remains visible")
        #expect(workspaceWindow.isVisible, "Workspace remains visible simultaneously")

        controller.hideCapsule()
        workspaceWindow.orderOut(nil)
        #expect(AppWindowState.activationPolicy(for: [workspaceWindow, panel]) == .accessory)
    }

    @Test func durationFormattingAcrossBoundaries() {
        // R03: MM:SS under an hour, H:MM:SS at and above 1 hour, supporting up to 8:00:00 without clipping
        #expect(formatClock(0) == "00:00")
        #expect(formatClock(59) == "00:59")
        #expect(formatClock(3599) == "59:59")
        #expect(formatClock(3600) == "1:00:00")
        #expect(formatClock(3661) == "1:01:01")
        #expect(formatClock(28800) == "8:00:00")
    }

    @Test func statusMenuBuildsRequiredStateMatrix() throws {
        let suite = "test-status-menu-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)
        let updater = AppUpdater(defaults: defaults)

        // 1. Initial attachment incomplete: false idle prevented
        let menuInitial = StatusMenu.build(model: model, appUpdater: updater, target: nil)
        #expect(!menuInitial.items.isEmpty, "Status menu must not be empty")
        let titlesInitial = menuInitial.items.map(\.title)
        #expect(titlesInitial.contains("Подключение к службам…") || titlesInitial.contains("Инициализация…"))
        #expect(titlesInitial.contains("Библиотека"))
        #expect(titlesInitial.contains("Настройки…"))
        #expect(titlesInitial.contains("Выйти"))

        // Simulate attached state
        model.setAttachedForTesting(session: true, processing: true)

        // 2. Idle state: "Новая запись" and "Библиотека" available; no active stop/cancel/mute
        let menuIdle = StatusMenu.build(model: model, appUpdater: updater, target: nil)
        let titlesIdle = menuIdle.items.map(\.title)
        #expect(titlesIdle.contains("Новая запись"), "Idle menu must contain 'Новая запись'")
        #expect(titlesIdle.contains("Библиотека"), "Idle menu must contain 'Библиотека'")
        #expect(!titlesIdle.contains("Остановить запись"), "Idle menu must not contain 'Остановить запись'")
        #expect(!titlesIdle.contains("Отменить короткую запись"), "Idle menu must not contain cancel")
        #expect(!titlesIdle.contains("Выключить микрофон"), "Idle menu must not contain mute")

        let settingsItem = try #require(menuIdle.items.first { $0.title == "Настройки…" })
        #expect(settingsItem.keyEquivalent == ",")
        let quitItem = try #require(menuIdle.items.first { $0.title == "Выйти" })
        #expect(quitItem.keyEquivalent == "q")

        // 3. Recording state (< 10 seconds): duration, short cancel, mute, show capsule, library
        model.isRecording = true
        model.elapsed = 5
        let menuRecordingShort = StatusMenu.build(model: model, appUpdater: updater, target: nil)
        let titlesRecordingShort = menuRecordingShort.items.map(\.title)
        #expect(titlesRecordingShort.contains { $0.starts(with: "Запись:") })
        #expect(titlesRecordingShort.contains("Отменить короткую запись"))
        #expect(titlesRecordingShort.contains("Выключить микрофон"))
        #expect(titlesRecordingShort.contains("Показать капсулу"))
        #expect(titlesRecordingShort.contains("Библиотека"))
        #expect(!titlesRecordingShort.contains("Новая запись"))

        // 4. Recording state (>= 10 seconds): normal stop
        model.elapsed = 15
        let menuRecordingNormal = StatusMenu.build(model: model, appUpdater: updater, target: nil)
        let titlesRecordingNormal = menuRecordingNormal.items.map(\.title)
        #expect(titlesRecordingNormal.contains("Остановить запись"))
        #expect(!titlesRecordingNormal.contains("Отменить короткую запись"))

        // 5. Recording state with muted microphone
        model.setMicrophoneMutedForTesting(true)
        let menuMuted = StatusMenu.build(model: model, appUpdater: updater, target: nil)
        let titlesMuted = menuMuted.items.map(\.title)
        #expect(titlesMuted.contains("Включить микрофон"))
    }

    @Test func staleMenuActionGuardSeparateIntents() async throws {
        let suite = "test-stale-dispatch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)

        // Idle state: stopRecordingIntent and cancelRecordingIntent must be rejected without toggling/starting
        #expect(!model.isRecording)
        let stoppedWhenIdle = await model.stopRecordingIntent()
        #expect(!stoppedWhenIdle, "stopRecordingIntent must fail when idle")
        #expect(!model.isRecording, "stopRecordingIntent must not start recording")

        let cancelledWhenIdle = await model.cancelRecordingIntent()
        #expect(!cancelledWhenIdle, "cancelRecordingIntent must fail when idle")
        #expect(!model.isRecording, "cancelRecordingIntent must not start recording")

        // Simulate recording state
        model.isRecording = true
        let startedWhenRecording = await model.startRecordingIntent()
        #expect(!startedWhenRecording, "startRecordingIntent must fail when already recording")
        #expect(model.isRecording, "startRecordingIntent must not stop active recording")
    }

    @Test func preventsTerminationGuardsBusyOperations() throws {
        let suite = "test-prevents-term-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)

        // Before attachment, termination is prevented to avoid premature exit during launch
        #expect(model.preventsTermination)

        model.setAttachedForTesting(session: true, processing: true)
        // In clean idle, termination is allowed
        #expect(!model.preventsTermination)

        // Recording prevents termination
        model.isRecording = true
        #expect(model.preventsTermination)
        model.isRecording = false

        // Processing jobs prevent termination
        model.transcriptionJobs = 1
        #expect(model.preventsTermination)
        model.transcriptionJobs = 0

        // Diagnostics running prevents termination
        model.setLocalDiagnosticRunningForTesting(true)
        #expect(model.preventsTermination)
        model.setLocalDiagnosticRunningForTesting(false)

        #expect(!model.preventsTermination)
    }

    @Test func capsuleObservationSettlesIdempotently() async throws {
        let suite = "test-capsule-settling-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)
        let controller = RecordingCapsuleController(model: model, defaults: defaults)
        _ = controller.panel

        model.setAttachedForTesting(session: true, processing: true)
        // Allow initial attachment and snapshots to settle
        for _ in 0..<10 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        var postSettlePublications = 0
        let cancellable = model.objectWillChange.sink {
            postSettlePublications += 1
        }
        defer { cancellable.cancel() }

        // RM-007-01: Idle state must produce zero feedback publications
        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(postSettlePublications == 0, "Idle capsule observation must produce zero publications once settled; got \(postSettlePublications)")

        // RM-007-01: Visible state settles cleanly
        postSettlePublications = 0
        controller.showCapsule()
        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(postSettlePublications <= 3, "Visible capsule observation must settle quickly; got \(postSettlePublications)")

        // RM-007-01: Dismissed state settles cleanly
        postSettlePublications = 0
        controller.hideCapsule()
        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(postSettlePublications <= 3, "Dismissed capsule observation must settle quickly; got \(postSettlePublications)")
    }

    @Test func independentCapsuleCoexistsWithProductionWorkspace() throws {
        let suite = "test-capsule-coexist-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)
        let controller = RecordingCapsuleController(model: model, defaults: defaults)
        let panel = try #require(controller.panel)

        model.isRecording = true
        controller.showCapsule()
        #expect(panel.isVisible)
        #expect(model.showsRecordingCapsule)

        // Production showWorkspace command sets mainWindowRequested
        RecorderAppDelegate.showWorkspace(model, load: { _ in }, present: { })

        // RM-007-03: Capsule must remain active and visible when workspace opens
        #expect(model.showsRecordingCapsule, "Capsule must remain active when workspace opens")
    }

    @Test func capsuleVisibilityDuringStoppingAndShortCancel() throws {
        let suite = "test-capsule-stopping-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)

        // RM-007-07: Stopping phase must keep capsule visible
        model.isRecording = false
        model.setSessionStoppingForTesting(true)
        #expect(model.showsRecordingCapsule, "Capsule must remain visible while stopping/saving capture")
    }

    @Test func openResultsRejectsUnknownTargetWithoutPresenting() throws {
        let suite = "test-openresults-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)

        var presented = false
        model.onPresentWorkspace = { presented = true }

        let sampleURL = URL(fileURLWithPath: "/tmp/fake-recording.m4a")
        model.lastFileURL = sampleURL
        model.openResults()

        // Real admitted Open/presentation is covered by capsule28OwnedOpenUsesRealTarget.
        #expect(!presented, "An absent target must not admit an Open request")
    }

    @Test func levelsDeliveredWhenCapsuleVisibleWithoutWorkspaceWindow() throws {
        let suite = "test-levels-capsule-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)

        model.setWindowVisible(false)
        model.isCapsuleVisible = true
        model.isRecording = true

        // RM-007-05: levels delivered when capsule is visible
        model.handleLevels(mic: 0.6, system: 0.8)
        model.levels.flush()
        #expect(model.levels.system > 0, "System audio level must be delivered when capsule is visible")
        #expect(model.levels.mic > 0, "Mic audio level must be delivered when capsule is visible")

        // Mute zeros only mic
        model.setMicrophoneMutedForTesting(true)
        model.handleLevels(mic: 0.6, system: 0.8)
        model.levels.flush()
        #expect(model.levels.mic == 0, "Mute must zero mic level")
        #expect(model.levels.system > 0, "Mute must not zero system level")
    }

    @Test func statusMenuMatrixPreservesCapturePriority() throws {
        let suite = "test-status-menu-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)
        let updater = AppUpdater(defaults: defaults)

        model.setAttachedForTesting(session: true, processing: true)

        // Starting state
        model.setSessionStartingForTesting(true)
        let startingMenu = StatusMenu.build(model: model, appUpdater: updater, target: nil)
        #expect(startingMenu.items.first?.title.contains("Запуск записи") == true)

        // Recording with background processing (capture priority)
        model.setSessionStartingForTesting(false)
        model.isRecording = true
        model.elapsed = 15
        model.transcriptionJobs = 2
        let recMenu = StatusMenu.build(model: model, appUpdater: updater, target: nil)
        #expect(recMenu.items.first?.title.contains("Запись:") == true)
        #expect(recMenu.items.contains { $0.title.contains("Остановить запись") })

        // Stopping state
        model.isRecording = false
        model.setSessionStoppingForTesting(true)
        let stopMenu = StatusMenu.build(model: model, appUpdater: updater, target: nil)
        #expect(stopMenu.items.first?.title.contains("Сохранение записи") == true)

        // Admitting state
        model.setSessionStoppingForTesting(false)
        model.setIsAdmittingProcessingForTesting(true)
        let admittingMenu = StatusMenu.build(model: model, appUpdater: updater, target: nil)
        #expect(admittingMenu.items.first?.title.contains("Проверка допуска") == true)
    }

}
