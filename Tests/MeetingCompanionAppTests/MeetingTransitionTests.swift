import Foundation
import AppKit
import Testing
import MeetingCompanionCore
import MeetingCompanionApplication
@testable import MeetingCompanionApp

private final class SafeBox<T>: @unchecked Sendable {
    private var val: T
    private let lock = NSLock()
    init(_ val: T) { self.val = val }
    func get() -> T { lock.withLock { val } }
    func mutate(_ block: (inout T) -> Void) { lock.withLock { block(&val) } }
}

private final class TransitionMockAudioCaptureController: AudioCaptureControllerProtocol, @unchecked Sendable {
    let outputURL: URL
    var duration: TimeInterval = 15
    var startError = false
    var stopError = false
    var onStartCapture: (@Sendable () async -> Void)?
    var onStopCapture: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var isStarted = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func startCapture() async throws {
        await onStartCapture?()
        if startError {
            throw NSError(domain: "SyntheticCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic capture failure"])
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: outputURL.path) {
            try Data("synthetic-audio".utf8).write(to: outputURL)
        }
        lock.withLock { isStarted = true }
    }

    func stopCapture() async throws -> AudioCaptureStopResult {
        await onStopCapture?()
        if stopError {
            throw NSError(domain: "SyntheticCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Synthetic stop failure"])
        }
        lock.withLock { isStarted = false }
        return .init(duration: duration, outputURL: outputURL)
    }

    func setMicrophoneMuted(_ muted: Bool) {}
    func currentMicrophoneState() -> MicrophoneRecordingState { .receiving }
}

@MainActor
private final class TransitionTestHarness {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let model: RecorderViewModel
    var createdControllers: [TransitionMockAudioCaptureController] = []
    var nextControllerDuration: TimeInterval = 15
    var nextControllerStartError = false
    var nextControllerStopError = false
    let trashedURLs = SafeBox<[URL]>([])

    init() throws {
        suite = "transition-test-" + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(root.path, forKey: "recordingsDirectory")
        defaults.set([String](), forKey: "meetingCalendarIDs")

        let trashBox = trashedURLs
        var harnessRef: TransitionTestHarness?
        let model = isolatedRecorderModel(
            defaults: defaults,
            captureControllerFactory: { url, _, _ in
                let controller = TransitionMockAudioCaptureController(outputURL: url)
                controller.duration = harnessRef?.nextControllerDuration ?? 15
                controller.startError = harnessRef?.nextControllerStartError ?? false
                controller.stopError = harnessRef?.nextControllerStopError ?? false
                harnessRef?.createdControllers.append(controller)
                return controller
            },
            shortRecordingTrash: { url in
                trashBox.mutate { $0.append(url) }
            }
        )
        self.model = model
        harnessRef = self
        model.setAttachedForTesting(session: true, processing: true)
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func startInitialRecording(meeting: MeetingContext? = nil, duration: TimeInterval = 15) async throws -> UUID {
        nextControllerDuration = duration
        nextControllerStartError = false
        nextControllerStopError = false
        if let meeting {
            model.selectedMeeting = meeting
        }
        let started = await model.startRecordingIntent()
        #expect(started)
        #expect(model.isRecording)
        let sessionID = try #require(model.activeSessionID)
        return sessionID
    }
}

@Suite @MainActor
struct MeetingTransitionTests {

    @Test
    func test_preStop_staleSession_rejectsAndPreservesRecording() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        let staleID = UUID()
        var receivedOutcome: StartMeetingOutcome?
        let outcome = await h.model.startMeeting(nil, expectedSessionID: staleID, onOutcome: { receivedOutcome = $0 }).value

        guard case .rejected(let reason) = outcome else {
            Issue.record("Expected .rejected, got \(outcome)")
            return
        }
        #expect(receivedOutcome == outcome)
        #expect(reason.contains("устарела") || reason.contains("актуальна") || !reason.isEmpty)
        #expect(h.model.isRecording)
        #expect(h.model.activeSessionID == sessionID)
    }

    @Test
    func test_preStop_deletedMeeting_rejectsAndPreservesRecording() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        let now = Date()
        let meeting = MeetingContext(id: "m_del", calendar: "Test", summary: "Standup",
                                     start: now.addingTimeInterval(-300), end: now.addingTimeInterval(1800))
        h.model.calendar.eventsProviderForTesting = { [] }

        var receivedOutcome: StartMeetingOutcome?
        let outcome = await h.model.startMeeting(meeting, expectedSessionID: sessionID, onOutcome: { receivedOutcome = $0 }).value

        guard case .rejected(let reason) = outcome else {
            Issue.record("Expected .rejected, got \(outcome)")
            return
        }
        #expect(receivedOutcome == outcome)
        #expect(reason.contains("Встреча изменилась или удалена"))
        #expect(h.model.isRecording)
        #expect(h.model.activeSessionID == sessionID)
    }

    @Test
    func test_preStop_changedMeetingWithSameID_rejectsAndPreservesRecording() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        let now = Date()
        let original = MeetingContext(id: "m_mod", calendar: "Test", summary: "Old Summary",
                                      start: now.addingTimeInterval(-300), end: now.addingTimeInterval(1800))
        let modified = MeetingContext(id: "m_mod", calendar: "Test", summary: "Renamed Summary",
                                      start: now.addingTimeInterval(-300), end: now.addingTimeInterval(1800))
        h.model.calendar.eventsProviderForTesting = { [modified] }

        var receivedOutcome: StartMeetingOutcome?
        let outcome = await h.model.startMeeting(original, expectedSessionID: sessionID, onOutcome: { receivedOutcome = $0 }).value

        guard case .rejected(let reason) = outcome else {
            Issue.record("Expected .rejected, got \(outcome)")
            return
        }
        #expect(receivedOutcome == outcome)
        #expect(reason.contains("Встреча изменилась или удалена"))
        #expect(h.model.isRecording)
        #expect(h.model.activeSessionID == sessionID)
    }

    @Test
    func test_preStop_modalOrForeignInput_rejects() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        h.model.workspace.settingsInput = { true }

        var receivedOutcome: StartMeetingOutcome?
        let outcome = await h.model.startMeeting(nil, expectedSessionID: sessionID, onOutcome: { receivedOutcome = $0 }).value

        guard case .rejected(let reason) = outcome else {
            Issue.record("Expected .rejected, got \(outcome)")
            return
        }
        #expect(receivedOutcome == outcome)
        #expect(reason.contains("ввод") || reason.contains("Сохраните или отмените"))
        #expect(h.model.isRecording)
        #expect(h.model.activeSessionID == sessionID)
    }

    @Test
    func test_duplicateAccept_synchronouslyRejectsSecondAttempt() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        var firstOutcome: StartMeetingOutcome?
        var secondOutcome: StartMeetingOutcome?

        let task1 = h.model.startMeeting(nil, expectedSessionID: sessionID, onOutcome: { firstOutcome = $0 })
        let task2 = h.model.startMeeting(nil, expectedSessionID: sessionID, onOutcome: { secondOutcome = $0 })

        let out2 = await task2.value
        guard case .rejected = out2 else {
            Issue.record("Expected second call to be rejected immediately, got \(out2)")
            return
        }
        #expect(secondOutcome == out2)

        let out1 = await task1.value
        #expect(out1 == .started)
        #expect(firstOutcome == .started)
    }

    @Test
    func test_stopFailure_doesNotStartNewRecording() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        h.createdControllers.last?.stopError = true

        var receivedOutcome: StartMeetingOutcome?
        let outcome = await h.model.startMeeting(nil, expectedSessionID: sessionID, onOutcome: { receivedOutcome = $0 }).value

        guard case .failed(let reason) = outcome else {
            Issue.record("Expected .failed, got \(outcome)")
            return
        }
        #expect(receivedOutcome == outcome)
        #expect(reason.contains("stop") || reason.contains("Synthetic stop failure") || reason.contains("Не удалось"))
        #expect(!h.model.isRecording)
    }

    @Test
    func test_heldStop_settingsOrModalOpened_rejectsAndDoesNotStartNewCapture() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        h.model.onAfterStopRecordingInMeetingTransitionForTesting = {
            h.model.workspace.settingsInput = { true }
        }

        var receivedOutcome: StartMeetingOutcome?
        let outcome = await h.model.startMeeting(nil, expectedSessionID: sessionID, onOutcome: { receivedOutcome = $0 }).value

        guard case .rejected = outcome else {
            Issue.record("Expected .rejected on held stop with modal, got \(outcome)")
            return
        }
        #expect(receivedOutcome == outcome)
        #expect(!h.model.isRecording)
        #expect(h.model.activeSessionID == nil)
    }

    @Test
    func test_heldStop_meetingDeletedOrChanged_rejectsAndDoesNotStartNewCapture() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        let now = Date()
        let meeting = MeetingContext(id: "m_held", calendar: "Test", summary: "Sync",
                                     start: now.addingTimeInterval(-300), end: now.addingTimeInterval(1800))
        var currentCalendarEvents = [meeting]
        h.model.calendar.eventsProviderForTesting = { currentCalendarEvents }

        h.model.onAfterStopRecordingInMeetingTransitionForTesting = {
            currentCalendarEvents = []
        }

        var receivedOutcome: StartMeetingOutcome?
        let outcome = await h.model.startMeeting(meeting, expectedSessionID: sessionID, onOutcome: { receivedOutcome = $0 }).value

        guard case .rejected(let reason) = outcome else {
            Issue.record("Expected .rejected on deleted meeting during stop, got \(outcome)")
            return
        }
        #expect(receivedOutcome == outcome)
        #expect(reason.contains("Встреча изменилась или удалена"))
        #expect(!h.model.isRecording)
    }

    @Test
    func test_heldStop_foreignSessionStarted_rejectsAndDoesNotStopForeignSession() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        var foreignSessionID: UUID?
        h.model.onAfterStopRecordingInMeetingTransitionForTesting = {
            let started = await h.model.startRecordingIntent()
            #expect(started)
            foreignSessionID = h.model.activeSessionID
        }

        var receivedOutcome: StartMeetingOutcome?
        let outcome = await h.model.startMeeting(nil, expectedSessionID: sessionID, onOutcome: { receivedOutcome = $0 }).value

        guard case .rejected = outcome else {
            Issue.record("Expected .rejected when foreign session started during stop, got \(outcome)")
            return
        }
        #expect(receivedOutcome == outcome)
        #expect(h.model.isRecording)
        #expect(h.model.activeSessionID == foreignSessionID)
    }

    @Test
    func test_shortBoundary_cancelsRecordingUnder10Seconds() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording(duration: 5)
        h.model.elapsed = 5

        let outcome = await h.model.startMeeting(nil, expectedSessionID: sessionID).value
        #expect(outcome == .started)
        #expect(h.model.isRecording)
        #expect(!h.trashedURLs.get().isEmpty)
    }

    @Test
    func test_shortBoundary_preservesRecordingAtOrOver10Seconds() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording(duration: 15)
        h.model.elapsed = 15

        let outcome = await h.model.startMeeting(nil, expectedSessionID: sessionID).value
        #expect(outcome == .started)
        #expect(h.model.isRecording)
        #expect(h.trashedURLs.get().isEmpty)
    }

    @Test
    func test_startFailure_reportsFailureAndLeavesRecordingInactive() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        h.nextControllerStartError = true

        var receivedOutcome: StartMeetingOutcome?
        let outcome = await h.model.startMeeting(nil, expectedSessionID: sessionID, onOutcome: { receivedOutcome = $0 }).value

        guard case .failed = outcome else {
            Issue.record("Expected .failed when startRecording fails, got \(outcome)")
            return
        }
        #expect(receivedOutcome == outcome)
        #expect(!h.model.isRecording)
    }

    @Test
    func test_successfulTransition_startsNewRecording() async throws {
        let h = try TransitionTestHarness()
        defer { h.tearDown() }
        let sessionID = try await h.startInitialRecording()

        let now = Date()
        let nextMeeting = MeetingContext(id: "m_next", calendar: "Test", summary: "Next Meeting",
                                         start: now.addingTimeInterval(-100), end: now.addingTimeInterval(1800))
        h.model.calendar.eventsProviderForTesting = { [nextMeeting] }

        var receivedOutcome: StartMeetingOutcome?
        let outcome = await h.model.startMeeting(nextMeeting, expectedSessionID: sessionID, onOutcome: { receivedOutcome = $0 }).value

        #expect(outcome == .started)
        #expect(receivedOutcome == .started)
        #expect(h.model.isRecording)
        #expect(h.model.activeSessionID != sessionID)
        #expect(h.model.selectedMeeting?.id == nextMeeting.id)
    }
}
