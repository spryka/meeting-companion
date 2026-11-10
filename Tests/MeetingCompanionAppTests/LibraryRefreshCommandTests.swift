import Foundation
import Combine
import Testing
import MeetingCompanionCore
@testable import MeetingCompanionApplication
@testable import MeetingCompanionApp

@Suite(.serialized) @MainActor
struct LibraryRefreshCommandTests {
    @Test func statusMenuFormRouteRechecksNativeInput() async throws {
        let fixture = try RefreshCommandFixture(repository: RecordingHistoryRepository())
        defer { fixture.close() }
        try await fixture.ready()
        var presentations = 0
        let delegate = RecorderAppDelegate(model: fixture.model, presentWorkspace: { presentations += 1 })
        fixture.model.workspace.nativeInput = { true }
        delegate.startRecordingAction()
        #expect(fixture.model.mainPage == .history)
        #expect(presentations == 0)
        fixture.model.workspace.nativeInput = { false }
        delegate.startRecordingAction()
        #expect(fixture.model.mainPage == .recording)
        #expect(presentations == 1)
        #expect(!fixture.model.isRecording)
    }

    @Test(arguments: ["none", "processing", "modal"])
    func refreshPhaseChangeReusesCurrentWithoutLoadingFlash(blocker: String) async throws {
        let gate = RefreshProcessingGate()
        let workspace = TranscriptReviewWindowManager(isProcessing: { _ in await gate.check() },
            transportFactory: { RefreshTestTransport() })
        let repository = RecordingHistoryRepository()
        let fixture = try RefreshCommandFixture(repository: repository, workspace: workspace)
        defer { Task { await gate.release() }; fixture.close() }
        try await fixture.ready()
        let recording = fixture.root.appendingPathComponent("meeting_phase/meeting_phase.m4a")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
        try Data().write(to: recording)
        try Data("Synthetic saved text".utf8).write(to: recording.deletingPathExtension().appendingPathExtension("sources.transcript.txt"))
        var entry = RecordingEntry(recording: recording, date: Date(), title: "Saved", phase: .completed)
        _ = try repository.putThrowing(entry)
        await fixture.model.history.synchronize()
        let initial = try #require(fixture.model.showTranscript(recording))
        #expect(await fixture.model.loadWorkspace(initial))
        let current = try #require(workspace.current)
        entry.phase = .failed
        _ = try RecordingHistoryRepository().putThrowing(entry)
        #expect(fixture.model.requestLibraryRefresh())
        for _ in 0..<200 where fixture.model.libraryRefreshPending { try await Task.sleep(for: .milliseconds(5)) }
        let request = fixture.model.workspaceLoadRequest
        #expect(request.phase == .failed)
        #expect(request != initial)
        var loadingStates: [Bool] = []
        let observation = workspace.$loading.sink { loadingStates.append($0) }
        defer { observation.cancel() }
        await gate.block(processing: blocker == "processing")
        let reload = Task { await fixture.model.loadWorkspace(request) }
        for _ in 0..<200 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await gate.entered)
        #expect(!workspace.loading)
        if blocker == "modal" { workspace.externalModal = true }
        await gate.release()
        let loaded = await reload.value
        #expect(loaded == (blocker == "none"))
        #expect(!loadingStates.contains(true))
        #expect(workspace.current === current)
    }

    @Test func refreshCommandHasNativeLabelAndShortcut() throws {
        let command = try #require(WorkspaceWindow.Command.allCases.first { $0.title == "Обновить библиотеку" })
        #expect(command.key == "r")
        #expect(command.modifiers == .command)
    }

    @Test func recordingFormCommandOpensFormWithoutStartingCapture() async throws {
        let fixture = try RefreshCommandFixture(repository: RecordingHistoryRepository())
        defer { fixture.close() }
        try await fixture.ready()
        #expect(fixture.model.requestRecordingForm())
        #expect(fixture.model.mainPage == .recording)
        #expect(!fixture.model.isRecording)
        #expect(!fixture.model.sessionStarting)
    }

    @Test(arguments: ["settings", "native", "external", "busy"])
    func recordingFormCommandRechecksGuards(blocker: String) async throws {
        let fixture = try RefreshCommandFixture(repository: RecordingHistoryRepository())
        defer { fixture.close() }
        try await fixture.ready()
        switch blocker {
        case "settings": #expect(fixture.model.presentSettings())
        case "native": fixture.model.workspace.nativeInput = { true }
        case "external": fixture.model.workspace.externalModal = true
        default: fixture.model.isBusy = true
        }
        #expect(!fixture.model.requestRecordingForm())
        #expect(fixture.model.mainPage == .history)
        #expect(!fixture.model.isRecording)
    }

    @Test func rootChangeInvalidatesScanBeforeDeferredNewLoadStarts() async throws {
        let repository = RecordingHistoryRepository()
        let fixture = try RefreshCommandFixture(repository: repository)
        let oldRecording = fixture.root.appendingPathComponent("meeting_old/meeting_old.m4a")
        try FileManager.default.createDirectory(at: oldRecording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: oldRecording)
        let newRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let gate = RefreshScanGate()
        let enumerate = repository.historyEnumerator
        repository.historyEnumerator = { directory, handler in
            gate.waitForFirstScan()
            return enumerate(directory, handler)
        }
        defer {
            gate.release.signal()
            fixture.close()
            try? FileManager.default.removeItem(at: newRoot)
        }
        try await fixture.ready()
        #expect(fixture.model.requestLibraryRefresh())
        for _ in 0..<200 where gate.scanCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(gate.scanCount == 1)
        let oldScanFinished = DispatchSemaphore(value: 0)
        _ = repository.addSubscriber { _ in oldScanFinished.signal() }
        fixture.model.outputDirectory = newRoot
        gate.release.signal()
        // Hold MainActor so the old scan publishes before the new root's deferred Task can run.
        func finishOldScanSynchronously() -> DispatchTimeoutResult { oldScanFinished.wait(timeout: .now() + 3) }
        let finished = finishOldScanSynchronously()
        try #require(finished == .success)
        #expect(!repository.snapshot().entries.contains { $0.id == RecordingEntry.canonicalURL(oldRecording) })
        for _ in 0..<200 where fixture.model.libraryRefreshPending || !fixture.model.history.initialLoadComplete {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.model.history.entries.isEmpty)
    }

    @Test func rootChangeLoadsNewRootAndDiscardsOldDataAndError() async throws {
        let repository = RecordingHistoryRepository()
        let fixture = try RefreshCommandFixture(repository: repository)
        let newRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let newRecording = newRoot.appendingPathComponent("meeting_new/meeting_new.m4a")
        try FileManager.default.createDirectory(at: newRecording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: newRecording)
        let gate = RefreshScanGate()
        let enumerate = repository.historyEnumerator
        let oldRoot = fixture.model.outputDirectory
        repository.historyEnumerator = { directory, handler in
            if directory == oldRoot { gate.waitForFirstScan(); return nil }
            return enumerate(directory, handler)
        }
        defer {
            gate.release.signal()
            fixture.close()
            try? FileManager.default.removeItem(at: newRoot)
        }
        try await fixture.ready()
        fixture.model.history.reportError("Existing save error")
        #expect(fixture.model.requestLibraryRefresh())
        for _ in 0..<200 where gate.scanCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(gate.scanCount == 1)
        fixture.model.outputDirectory = newRoot
        for _ in 0..<200 where fixture.model.history.entry(newRecording) == nil || fixture.model.history.loading {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.model.history.entry(newRecording) != nil)
        #expect(!fixture.model.history.loading)
        gate.release.signal()
        for _ in 0..<200 where fixture.model.libraryRefreshPending { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!fixture.model.libraryRefreshPending)
        #expect(fixture.model.history.entries.map(\.id) == [newRecording])
        #expect(fixture.model.history.refreshError == nil)
        #expect(fixture.model.history.refreshCompletion == nil)
        #expect(fixture.model.history.error == "Existing save error")
    }

    @Test func successfulManualRefreshKeepsSelectionAndUnrelatedError() async throws {
        let fixture = try RefreshCommandFixture(repository: RecordingHistoryRepository())
        defer { fixture.close() }
        try await fixture.ready()
        let recording = fixture.root.appendingPathComponent("meeting_saved/meeting_saved.m4a")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: recording)
        fixture.model.selectedHistoryURL = recording
        fixture.model.history.reportError("Existing save error")
        #expect(fixture.model.requestLibraryRefresh())
        #expect(!fixture.model.requestLibraryRefresh())
        for _ in 0..<200 where fixture.model.libraryRefreshPending { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!fixture.model.libraryRefreshPending)
        #expect(fixture.model.history.entry(recording) != nil)
        #expect(fixture.model.selectedHistoryURL == recording)
        #expect(fixture.model.history.refreshError == nil)
        #expect(fixture.model.history.refreshCompletion != nil)
        #expect(fixture.model.history.error == "Existing save error")
    }

    @Test func deferredManualRefreshDoesNotDuplicateAutomaticScan() async throws {
        let gate = RefreshScanGate()
        let repository = RecordingHistoryRepository()
        let enumerate = repository.historyEnumerator
        repository.historyEnumerator = { directory, handler in
            gate.waitForFirstScan()
            return enumerate(directory, handler)
        }
        let fixture = try RefreshCommandFixture(repository: repository)
        defer { gate.release.signal(); fixture.close() }
        try await fixture.ready()
        #expect(fixture.model.requestLibraryRefresh())
        let release = Task { @MainActor in
            for _ in 0..<200 where fixture.model.libraryRefreshPending {
                try await Task.sleep(for: .milliseconds(5))
            }
            gate.release.signal()
        }
        await fixture.model.history.refresh(root: fixture.root)
        try await release.value
        #expect(gate.scanCount == 1)
        #expect(fixture.model.history.refreshCompletion == nil)
        #expect(!fixture.model.history.loading)
        #expect(!fixture.model.libraryRefreshPending)
    }

    @Test func duplicateManualRequestsAndLateBlockedCallbackDoNotScan() async throws {
        let gate = RefreshScanGate()
        let repository = RecordingHistoryRepository()
        let enumerate = repository.historyEnumerator
        repository.historyEnumerator = { directory, handler in
            gate.waitForFirstScan()
            return enumerate(directory, handler)
        }
        let fixture = try RefreshCommandFixture(repository: repository)
        defer { gate.release.signal(); fixture.close() }
        try await fixture.ready()
        #expect(fixture.model.requestLibraryRefresh())
        #expect(!fixture.model.requestLibraryRefresh())
        fixture.model.workspace.externalModal = true
        for _ in 0..<200 where fixture.model.libraryRefreshPending {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!fixture.model.libraryRefreshPending)
        #expect(gate.scanCount == 0)
        fixture.model.workspace.externalModal = false
        await Task.yield()
        #expect(gate.scanCount == 0)
    }
}

private final class RefreshScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0
    let release = DispatchSemaphore(value: 0)
    var scanCount: Int { lock.withLock { scans } }
    func waitForFirstScan() {
        let first = lock.withLock { scans += 1; return scans == 1 }
        if first { _ = release.wait(timeout: .now() + 5) }
    }
}

@MainActor private final class RefreshCommandFixture {
    let root: URL
    let model: RecorderViewModel
    private let suite = "refresh-command-" + UUID().uuidString
    init(repository: RecordingHistoryRepository, workspace: TranscriptReviewWindowManager? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(root.path, forKey: "recordingsDirectory")
        model = RecorderViewModel(historyRepository: repository, workspace: workspace, defaults: defaults,
            appDataDirectory: root.appendingPathComponent("appData"), startBackgroundServices: false)
        model.libraryRefreshTarget = { true }
        model.mainPage = .history
    }
    func ready() async throws {
        for _ in 0..<200 where !model.isAttached { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.isAttached)
    }
    func close() {
        model.workspace.externalModal = false
        model.workspace.closeCurrent()
        model.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RefreshProcessingGate {
    private var blocked = false
    private var processing = false
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func block(processing: Bool) { blocked = true; self.processing = processing }
    func check() async -> Bool {
        guard blocked else { return false }
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return processing
    }
    func release() { blocked = false; continuation?.resume(); continuation = nil }
}

@MainActor private final class RefreshTestTransport: TranscriptPlaybackTransport {
    var onEvent: (@MainActor @Sendable (TranscriptPlaybackEvent) -> Void)?
    func prepare(url: URL) async throws -> Double { 10 }
    func play() {}
    func pause() {}
    func seek(to seconds: Double) async -> Bool { true }
    func stop() {}
    func setRate(_ rate: Float) {}
}
