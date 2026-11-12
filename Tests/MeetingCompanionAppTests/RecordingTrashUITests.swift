import AppKit
import Combine
import Foundation
import Testing
import SwiftUI
import MeetingCompanionCore
import MeetingCompanionApplication
@testable import MeetingCompanionApp

private struct TrashUIRunner: TranscriptionRunnerProtocol {
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL { throw CocoaError(.userCancelled) }
}
private struct TrashUIExporter: AudioExporterProtocol {
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws { }
}
private final class TrashUIOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let release = DispatchSemaphore(value: 0)
    var count: Int { lock.withLock { calls } }
    func wait() { lock.withLock { calls += 1 }; release.wait() }
}
private actor TrashUIOpenGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func check(_ url: URL) async -> Bool {
        guard url.lastPathComponent == "meeting_b.m4a", !entered else { return false }
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return false
    }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private final class TrashUITransport: TranscriptPlaybackTransport {
    var onEvent: (@MainActor @Sendable (TranscriptPlaybackEvent) -> Void)?
    var stopCount = 0
    var closed: Bool { stopCount > 0 }
    func prepare(url: URL) async throws -> Double { 10 }
    func play() { }
    func pause() { }
    func seek(to seconds: Double) async -> Bool { true }
    func stop() { stopCount += 1 }
    func setRate(_ rate: Float) { }
}

@MainActor private final class TrashUIFixture {
    let root: URL
    let model: RecorderViewModel
    let suite: String
    let a: URL
    let b: URL
    let transport = TrashUITransport()
    init(operation: (@Sendable (URL) throws -> Void)? = nil,
         isProcessing: @escaping @Sendable (URL) async -> Bool = { _ in false }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("trash-ui-" + UUID().uuidString)
        suite = "trash-ui-" + UUID().uuidString
        a = root.appendingPathComponent("meeting_a/meeting_a.m4a")
        b = root.appendingPathComponent("meeting_b/meeting_b.m4a")
        let repository = RecordingHistoryRepository()
        for url in [a, b] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
            try Data().write(to: url)
            for source in ["host", "remote"] {
                try Data([0, 0]).write(to: url.deletingLastPathComponent().appendingPathComponent("raw/" + url.deletingPathExtension().lastPathComponent + "." + source + "_record.wav"))
            }
            _ = try repository.putThrowing(RecordingEntry(recording: url, date: Date().addingTimeInterval(url == a ? -60 : 0),
                title: url.deletingPathExtension().lastPathComponent, phase: .completed))
        }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(root.path, forKey: "recordingsDirectory")
        let processing = ProcessingService(transcriptionRunner: TrashUIRunner(), audioExporter: TrashUIExporter(), historyRepository: repository)
        let transport = self.transport
        let workspace = TranscriptReviewWindowManager(isProcessing: isProcessing, transportFactory: { transport })
        model = RecorderViewModel(processingService: processing, historyRepository: repository, workspace: workspace,
            defaults: defaults, appDataDirectory: root.appendingPathComponent("appData"), startBackgroundServices: false,
            recordingTrashOperation: operation ?? { folder in try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("trashed")) })
    }
    func ready() async throws {
        for _ in 0..<200 where !model.isAttached { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.isAttached)
        await model.history.synchronize()
        model.selectedHistoryURL = a
    }
    func loadReview() async throws -> TranscriptReviewWindowModel {
        let result = a.deletingLastPathComponent().appendingPathComponent("raw/transcripts/res_valid_parakeet_off")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_parakeet_off.json")
        try FileManager.default.copyItem(at: fixture, to: result.appendingPathComponent("result.json"))
        try Data().write(to: result.appendingPathComponent("mix.m4a"))
        await model.history.refresh(root: root)
        let review = try await model.workspace.open(recordingURL: a, title: "Synthetic review")
        for _ in 0..<200 where !review.playbackEnabled { try await Task.sleep(for: .milliseconds(5)) }
        try #require(review.playbackEnabled)
        return review
    }
    func close() {
        model.cancelRecordingTrash()
        model.workspace.externalModal = false
        model.workspace.closeCurrent()
        model.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    func showWorkspace() async throws -> RecorderAppDelegate {
        _ = NSApplication.shared
        _ = model.requestWorkspaceOpen()
        let delegate = RecorderAppDelegate(model: model)
        delegate.setUpPresentation()
        let window = try #require(delegate.window as? WorkspaceWindow)
        window.isKeyboardTarget = { true }
        window.makeKeyAndOrderFront(nil)
        try await settle("library navigation mounts before keyboard input") {
            views(window.contentView).contains { $0.identifier?.rawValue == "workspace-library-navigation" }
        }
        return delegate
    }
    func views(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views($0) }
    }
    func settle(_ label: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<200 where !predicate() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate(), Comment(rawValue: label))
    }
    func key(_ code: UInt16, in window: NSWindow, characters: String = "", repeating: Bool = false,
             modifiers: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: repeating, keyCode: code))
    }
}

@Suite(.serialized) @MainActor struct RecordingTrashUITests {
    @Test func modalRejectedLoadDoesNotAllowTrashBeforePreview() async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        let original = try await f.loadReview()
        try FileManager.default.copyItem(at: f.a.deletingLastPathComponent().appendingPathComponent("raw/transcripts"),
            to: f.b.deletingLastPathComponent().appendingPathComponent("raw/transcripts"))
        await f.model.history.refresh(root: f.root)
        f.model.selectLibraryRecording(f.b)
        #expect(f.model.presentSettings())
        #expect(!(await f.model.loadWorkspace(f.model.workspaceLoadRequest)))
        f.model.dismissSettings()
        #expect(f.model.workspace.current === original && !f.model.workspace.loading)
        #expect(!(await f.model.requestRecordingTrash(f.b)))
        f.model.cancelRecordingTrash()
        f.model.selectLibraryRecording(f.b)
        #expect(await f.model.loadWorkspace(f.model.workspaceLoadRequest))
        #expect(f.model.workspace.current?.state.id == f.b)
        #expect(await f.model.requestRecordingTrash(f.b))
    }

    @Test func unreadableTranscriptStillAllowsTrashAfterLoadFinishes() async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        _ = try await f.loadReview()
        let result = f.b.deletingLastPathComponent().appendingPathComponent("raw/transcripts/res_broken_parakeet_off")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: result.appendingPathComponent("result.json"))
        await f.model.history.refresh(root: f.root)
        f.model.selectLibraryRecording(f.b)
        _ = await f.model.loadWorkspace(f.model.workspaceLoadRequest)
        #expect(!f.model.workspace.loading && !f.model.workspace.hasInput)
        #expect(await f.model.requestRecordingTrash(f.b))
        #expect(f.model.recordingTrash?.target.recording == f.b)
    }

    @Test func selectedRequestMustFinishBeforeTrashCanOwnInput() async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        let original = try await f.loadReview()
        try FileManager.default.copyItem(at: f.a.deletingLastPathComponent().appendingPathComponent("raw/transcripts"),
            to: f.b.deletingLastPathComponent().appendingPathComponent("raw/transcripts"))
        await f.model.history.refresh(root: f.root)
        let first = try #require(f.model.requestWorkspaceOpen())
        #expect(await f.model.loadWorkspace(first))
        // Arrow selection uses this route before SwiftUI starts its .task(id:).
        f.model.selectLibraryRecording(f.b)
        #expect(!f.model.workspace.loading && f.model.workspace.current === original)
        let admitted = await f.model.requestRecordingTrash(f.b)
        #expect(!admitted && f.model.recordingTrash == nil)
        f.model.cancelRecordingTrash()
        #expect(await f.model.loadWorkspace(f.model.workspaceLoadRequest))
        #expect(f.model.workspace.current?.state.id == f.b)
        #expect(await f.model.requestRecordingTrash(f.b))
    }

    @Test func pendingEnterCannotBecomeRetryWhenFailureFinishes() async throws {
        let gate = TrashUIOperationGate()
        gate.release.signal(); gate.release.signal()
        let f = try TrashUIFixture(operation: { _ in gate.wait(); throw CocoaError(.fileWriteNoPermission) })
        defer { gate.release.signal(); f.close() }
        try await f.ready()
        let window = WorkspaceWindow(model: f.model)
        window.isReleasedWhenClosed = false
        window.isKeyboardTarget = { true }
        window.orderFront(nil)
        defer { window.close() }
        #expect(await f.model.requestRecordingTrash(f.a))
        let enter = try f.key(36, in: window)
        var pressedDuringPending = false
        let observation = f.model.$recordingTrash.sink { next in
            guard !pressedDuringPending, next?.pending == false, next?.retryAllowed == true,
                  f.model.recordingTrash?.pending == true else { return }
            // @Published sends before assignment: the key arrives while still pending.
            pressedDuringPending = true
            #expect(window.performKeyEquivalent(with: enter))
        }
        defer { observation.cancel() }
        await f.model.confirmRecordingTrash()
        try await Task.sleep(for: .milliseconds(40))
        #expect(pressedDuringPending && gate.count == 1)
        #expect(f.model.recordingTrash?.pending == false && f.model.recordingTrash?.retryAllowed == true)
        #expect(FileManager.default.fileExists(atPath: f.a.path))
    }

    @Test func pendingProcessingCheckBlocksTrashWithoutLosingSelectedOpen() async throws {
        let gate = TrashUIOpenGate()
        let f = try TrashUIFixture(isProcessing: { await gate.check($0) })
        defer { f.close() }
        try await f.ready()
        let original = try await f.loadReview()
        try FileManager.default.copyItem(at: f.a.deletingLastPathComponent().appendingPathComponent("raw/transcripts"),
            to: f.b.deletingLastPathComponent().appendingPathComponent("raw/transcripts"))
        await f.model.history.refresh(root: f.root)
        let request = try #require(f.model.showTranscript(f.b))
        let opening = Task { await f.model.loadWorkspace(request) }
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.entered)
        #expect(f.model.workspace.loading)
        #expect(f.model.workspace.current === original)
        #expect(!(await f.model.requestRecordingTrash(f.b)))
        await gate.release()
        let opened = await opening.value
        f.model.cancelRecordingTrash()
        #expect(opened)
        #expect(f.model.selectedHistoryURL == f.b && f.model.workspace.current?.state.id == f.b)
        #expect(!f.model.workspace.loading && f.model.recordingTrash == nil)
    }

    @Test func pendingRetainsModalAndRowAndExecutesOnlyOnceOffMainActor() async throws {
        let gate = TrashUIOperationGate()
        let f = try TrashUIFixture(operation: { folder in
            #expect(!Thread.isMainThread)
            gate.wait()
            try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("trashed"))
        }); defer { f.close() }
        try await f.ready()
        #expect(await f.model.requestRecordingTrash(f.a))
        let pending = Task { await f.model.confirmRecordingTrash() }
        for _ in 0..<200 where gate.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.count == 1)
        #expect(f.model.recordingTrash?.pending == true && f.model.workspace.hasInput)
        #expect(f.model.history.entry(f.a) != nil)
        f.model.cancelRecordingTrash()
        await f.model.confirmRecordingTrash()
        #expect(gate.count == 1 && f.model.recordingTrash != nil)
        #expect(!f.model.admitWindowClose(isWorkspace: true))
        let work = UUID()
        #expect(!f.model.historyRepository.reserveWork(f.a, id: work))
        f.model.historyRepository.releaseWork(f.a, id: work)
        gate.release.signal()
        await pending.value
        #expect(f.model.recordingTrash == nil && f.model.history.entry(f.a) == nil)
    }

    @Test func draftsArePreservedAndOldReviewClosesBeforeSuccessfulMove() async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        let review = try await f.loadReview()
        let turn = try #require(review.rows.first?.id)
        review.openTextEditing(for: turn)
        review.updateDraftText("Unsaved synthetic input")
        #expect(!(await f.model.requestRecordingTrash(f.a)))
        #expect(review.activeTextDraft?.text == "Unsaved synthetic input")
        review.cancelTextDraft()
        #expect(await f.model.requestRecordingTrash(f.a))
        review.openTextEditing(for: turn)
        #expect(review.activeTextDraft == nil)
        await f.model.confirmRecordingTrash()
        #expect(review.state.isClosed && f.model.workspace.current == nil && f.transport.closed)
        #expect(f.model.history.entry(f.a) == nil)
    }

    @Test func failedMoveReopensGuardedReviewUnderSameModal() async throws {
        let f = try TrashUIFixture(operation: { _ in throw CocoaError(.fileWriteNoPermission) }); defer { f.close() }
        try await f.ready()
        let previous = try await f.loadReview()
        #expect(await f.model.requestRecordingTrash(f.a))
        await f.model.confirmRecordingTrash()
        #expect(previous.state.isClosed)
        let reopened = try #require(f.model.workspace.current)
        #expect(reopened !== previous && !reopened.state.isClosed)
        #expect(f.model.workspace.hasInput && f.model.recordingTrash?.retryAllowed == true)
        let turn = try #require(reopened.rows.first?.id)
        reopened.openTextEditing(for: turn)
        #expect(reopened.activeTextDraft == nil)
    }

    @Test func deletingUnselectedRecordKeepsReviewAndPlayback() async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        let review = try await f.loadReview()
        let stops = f.transport.stopCount
        #expect(await f.model.requestRecordingTrash(f.b))
        await f.model.confirmRecordingTrash()
        #expect(f.model.workspace.current === review && !review.state.isClosed && f.transport.stopCount == stops)
        #expect(f.model.selectedHistoryURL == f.a)
    }

    @Test func confirmationBlocksNavigationSettingsAndNativeCloseHide() async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        let window = WorkspaceWindow(model: f.model)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        #expect(await f.model.requestRecordingTrash(f.a))
        let original = f.model.recordingTrash?.id
        #expect(f.model.workspace.hasInput)
        #expect(!f.model.admitWindowClose(isWorkspace: true))
        #expect(!f.model.presentSettings())
        await #expect(throws: Error.self) { try await f.model.renameRecording(f.a, displayTitle: "Must stay unchanged") }
        #expect(f.model.history.entry(f.a)?.effectiveTitle == "meeting_a")
        f.model.selectedHistoryURL = f.b
        f.model.mainPage = .recording
        #expect(f.model.selectedHistoryURL == f.a && f.model.mainPage == .history)
        #expect(!(await f.model.requestRecordingTrash(f.b)))
        #expect(f.model.recordingTrash?.id == original)
        window.orderOut(nil); window.order(.out, relativeTo: 0); window.setIsVisible(false); window.miniaturize(nil); window.close()
        #expect(window.isVisible && !window.canHide)
        f.model.cancelRecordingTrash()
        #expect(!f.model.workspace.hasInput)
        #expect(f.model.selectedHistoryURL == f.a)
        #expect(FileManager.default.fileExists(atPath: f.a.path))
    }

    @Test func unsavedOrExternalInputIsNeverBypassed() async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        f.model.workspace.externalModal = true
        #expect(!(await f.model.requestRecordingTrash(f.a)))
        #expect(f.model.recordingTrash == nil && f.model.workspace.externalModal)
        f.model.workspace.externalModal = false
        #expect(f.model.presentSettings())
        #expect(!(await f.model.requestRecordingTrash(f.a)))
        #expect(f.model.settingsPresented)
        f.model.dismissSettings()
    }

    @Test func successClearsOnlyDeletedSelectionAndUnknownOutcomeKeepsModal() async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        #expect(await f.model.requestRecordingTrash(f.b))
        await f.model.confirmRecordingTrash()
        #expect(f.model.selectedHistoryURL == f.a && f.model.recordingTrash == nil)
        #expect(f.model.history.entry(f.b) == nil)
        #expect(await f.model.requestRecordingTrash(f.a))
        await f.model.confirmRecordingTrash()
        #expect(f.model.selectedHistoryURL == nil && f.model.history.entries.isEmpty)
        let uncertain = try TrashUIFixture(operation: { folder in
            try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("trashed"))
            throw CocoaError(.fileWriteUnknown)
        }); defer { uncertain.close() }
        try await uncertain.ready()
        #expect(await uncertain.model.requestRecordingTrash(uncertain.a))
        await uncertain.model.confirmRecordingTrash()
        #expect(uncertain.model.recordingTrash?.error != nil)
        #expect(uncertain.model.workspace.hasInput)
        #expect(uncertain.model.history.entry(uncertain.a) == nil)
        #expect(uncertain.model.recordingTrash?.retryAllowed == false)
    }

    @Test func failureKeepsRowAndModalUntilCancel() async throws {
        let f = try TrashUIFixture(operation: { _ in throw CocoaError(.fileWriteNoPermission) }); defer { f.close() }
        try await f.ready()
        #expect(await f.model.requestRecordingTrash(f.a))
        await f.model.confirmRecordingTrash()
        #expect(f.model.recordingTrash?.error != nil && f.model.recordingTrash?.retryAllowed == true)
        #expect(f.model.history.entry(f.a) != nil && f.model.workspace.hasInput)
        f.model.cancelRecordingTrash()
        #expect(!f.model.workspace.hasInput && f.model.selectedHistoryURL == f.a)
    }

    @Test(arguments: [UInt16(36), UInt16(53), UInt16(76)])
    func enterConfirmsAndEscapeCancels(code: UInt16) async throws {
        _ = NSApplication.shared
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        let window = WorkspaceWindow(model: f.model)
        window.isReleasedWhenClosed = false
        window.isKeyboardTarget = { true }
        window.orderFront(nil)
        defer { window.close() }
        #expect(await f.model.requestRecordingTrash(f.a))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: code == 53 ? "\u{1b}" : "\r", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        #expect(window.performKeyEquivalent(with: event))
        try await f.settle("confirmation resolves") { f.model.recordingTrash == nil }
        let sourceRemains = FileManager.default.fileExists(atPath: f.a.path)
        #expect(sourceRemains == (code == 53))
    }

    @Test(arguments: ["inactive", "hidden", "sheet", "repeat"])
    func confirmationEnterRespectsWindowAndRepeatGuards(blocker: String) async throws {
        _ = NSApplication.shared
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        let window = WorkspaceWindow(model: f.model)
        window.isReleasedWhenClosed = false
        window.isKeyboardTarget = { true }
        if blocker != "hidden" { window.orderFront(nil) }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.endSheet(sheet); f.model.cancelRecordingTrash(); window.close() }
        #expect(await f.model.requestRecordingTrash(f.a))
        let id = f.model.recordingTrash?.id
        if blocker == "inactive" { window.isKeyboardTarget = { false } }
        if blocker == "sheet" { window.beginSheet(sheet, completionHandler: nil) }
        _ = window.performKeyEquivalent(with: try f.key(36, in: window, repeating: blocker == "repeat"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(f.model.recordingTrash?.id == id && f.model.recordingTrash?.pending == false)
        #expect(FileManager.default.fileExists(atPath: f.a.path))
    }

    @Test func appAcceptedPendingEnqueueAlreadyBlocksTrash() async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        f.model.retryRecording(f.a)
        #expect(!(await f.model.requestRecordingTrash(f.a)))
        #expect(f.model.recordingTrash == nil)
        for _ in 0..<200 where await f.model.processingService.totalJobCount > 0 { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func knownFailureRetriesOnlyAfterAnotherExplicitConfirmation() async throws {
        final class FailOnce: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            var count: Int { lock.withLock { calls } }
            func run(_ folder: URL) throws {
                let first = lock.withLock { calls += 1; return calls == 1 }
                if first { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("trashed"))
            }
        }
        let operation = FailOnce()
        let f = try TrashUIFixture(operation: { try operation.run($0) }); defer { f.close() }
        try await f.ready()
        #expect(await f.model.requestRecordingTrash(f.a))
        await f.model.confirmRecordingTrash()
        #expect(operation.count == 1 && f.model.recordingTrash?.retryAllowed == true)
        await Task.yield()
        #expect(operation.count == 1)
        await f.model.confirmRecordingTrash()
        #expect(operation.count == 2 && f.model.recordingTrash == nil && f.model.history.entry(f.a) == nil)
    }

}

extension WorkspaceKeyboardTests {
    @Test(arguments: ["first", "middle", "last", "single"], [UInt16(125), UInt16(126)])
    func arrowsContinueCleanupAfterDeletion(position: String, arrow: UInt16) async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        _ = try await f.loadReview()
        let c = f.root.appendingPathComponent("meeting_c/meeting_c.m4a")
        let extra = position == "single" ? [] : [c]
        for recording in extra {
            try FileManager.default.createDirectory(at: recording.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
            try Data().write(to: recording)
            for source in ["host", "remote"] {
                try Data([0, 0]).write(to: recording.deletingLastPathComponent().appendingPathComponent("raw/meeting_c.\(source)_record.wav"))
            }
            _ = try f.model.historyRepository.putThrowing(RecordingEntry(recording: recording, date: Date().addingTimeInterval(-120),
                title: "meeting_c", phase: .completed))
        }
        for recording in [f.b] + extra {
            try FileManager.default.copyItem(at: f.a.deletingLastPathComponent().appendingPathComponent("raw/transcripts"),
                to: recording.deletingLastPathComponent().appendingPathComponent("raw/transcripts"))
        }
        await f.model.history.refresh(root: f.root)
        let delegate = try await f.showWorkspace()
        let window = try #require(delegate.window as? WorkspaceWindow)
        defer { f.model.cancelRecordingTrash(); window.close() }
        let library = try #require(f.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        #expect(window.makeFirstResponder(library))
        window.sendEvent(try f.key(126, in: window))
        try await f.settle("first setup arrow opens B") {
            f.model.selectedHistoryURL == f.b && f.model.workspace.current?.state.id == f.b && !f.model.workspace.loading
        }
        if position == "middle" || position == "last" { window.sendEvent(try f.key(125, in: window)) }
        if position == "last" {
            try await f.settle("middle selection opens before continuing to last") {
                f.model.selectedHistoryURL == f.a && f.model.workspace.current?.state.id == f.a && !f.model.workspace.loading
            }
            window.sendEvent(try f.key(125, in: window))
        }
        let target = position == "middle" ? f.a : position == "last" ? c : f.b
        let next = position == "middle" ? c : f.a
        #expect(f.model.selectedHistoryURL == target)
        #expect(f.model.history.entry(target) != nil)
        try await f.settle("arrow selection opens deletion target") {
            f.model.selectedHistoryURL == target && f.model.workspace.current?.state.id == target && !f.model.workspace.loading
        }
        _ = window.performKeyEquivalent(with: try f.key(51, in: window))
        try await f.settle("Delete opens confirmation") { f.model.recordingTrash?.target.recording == target }
        _ = window.performKeyEquivalent(with: try f.key(36, in: window))
        try await f.settle("deletion focuses remaining neighbor without selection") {
            f.model.recordingTrash == nil && f.model.selectedHistoryURL == nil && f.model.workspace.current == nil
                && (window.firstResponder as? NSButton)?.accessibilityLabel() == next.deletingPathExtension().lastPathComponent
        }
        window.sendEvent(try f.key(arrow, in: window))
        try await f.settle("arrow immediately opens the focused neighbor") {
            f.model.selectedHistoryURL == next && f.model.workspace.current?.state.id == next && !f.model.workspace.loading
        }
        #expect(window.firstResponder === library)
        _ = window.performKeyEquivalent(with: try f.key(51, in: window))
        try await f.settle("keyboard cleanup can continue without Space or mouse") {
            f.model.recordingTrash?.target.recording == next
        }
        f.model.cancelRecordingTrash()
        #expect(!FileManager.default.fileExists(atPath: target.path) && FileManager.default.fileExists(atPath: next.path))
    }

    @Test(arguments: [UInt16(51), UInt16(117)])
    func selectedRecordingCanBeCleanedWithKeyboard(code: UInt16) async throws {
        let gate = TrashUIOperationGate()
        let f = try TrashUIFixture(operation: { folder in
            gate.wait()
            try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("trashed"))
        })
        defer { gate.release.signal(); f.close() }
        try await f.ready()
        _ = try await f.loadReview()
        try FileManager.default.copyItem(at: f.a.deletingLastPathComponent().appendingPathComponent("raw/transcripts"),
            to: f.b.deletingLastPathComponent().appendingPathComponent("raw/transcripts"))
        await f.model.history.refresh(root: f.root)
        let delegate = try await f.showWorkspace()
        let window = try #require(delegate.window as? WorkspaceWindow)
        defer { f.model.cancelRecordingTrash(); window.close() }
        let library = try #require(f.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        #expect(window.makeFirstResponder(library))
        #expect(window.performKeyEquivalent(with: try f.key(126, in: window)))
        try await f.settle("arrows open B before deletion") {
            f.model.selectedHistoryURL == f.b && f.model.workspace.current?.state.id == f.b && !f.model.workspace.loading
        }
        let otherTrash = try #require(f.views(window.contentView).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Переместить запись meeting_a в Корзину" })
        let otherEnabled = otherTrash.isEnabled
        #expect(!otherEnabled)
        #expect(window.performKeyEquivalent(with: try f.key(code, in: window)))
        try await f.settle("Delete opens selected B confirmation") { f.model.recordingTrash?.target.recording == f.b }
        #expect(gate.count == 0 && FileManager.default.fileExists(atPath: f.b.path))
        _ = window.performKeyEquivalent(with: try f.key(36, in: window, repeating: true))
        #expect(gate.count == 0)
        _ = window.performKeyEquivalent(with: try f.key(36, in: window))
        _ = window.performKeyEquivalent(with: try f.key(36, in: window))
        try await f.settle("Enter starts exactly one pending move") { gate.count == 1 }
        _ = window.performKeyEquivalent(with: try f.key(53, in: window))
        #expect(f.model.recordingTrash?.pending == true && gate.count == 1)
        gate.release.signal()
        try await f.settle("successful move leaves no selection and focuses A") {
            f.model.recordingTrash == nil && f.model.selectedHistoryURL == nil
                && (window.firstResponder as? NSButton)?.accessibilityLabel() == "meeting_a"
        }
        window.sendEvent(try f.key(49, in: window, characters: " "))
        window.sendEvent(try f.key(49, in: window, characters: " ", type: .keyUp))
        try await f.settle("Space opens focused neighbor for preview") {
            f.model.selectedHistoryURL == f.a && f.model.workspace.current?.state.id == f.a && !f.model.workspace.loading
        }
        _ = window.performKeyEquivalent(with: try f.key(code, in: window))
        try await f.settle("next keyboard confirmation targets A") { f.model.recordingTrash?.target.recording == f.a }
        _ = window.performKeyEquivalent(with: try f.key(53, in: window))
        #expect(f.model.recordingTrash == nil && FileManager.default.fileExists(atPath: f.a.path) && gate.count == 1)
    }

    @Test(arguments: ["search", "editor", "sheet", "inactive", "hidden", "repeat", "modifier", "noSelection", "staleFocus", "staleSelection"])
    func deletionKeysRespectNativeInputAndRecheckAdmission(blocker: String) async throws {
        let f = try TrashUIFixture(); defer { f.close() }
        try await f.ready()
        let review = try await f.loadReview()
        let delegate = try await f.showWorkspace()
        let window = try #require(delegate.window as? WorkspaceWindow)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.endSheet(sheet); review.cancelTextDraft(); f.model.cancelRecordingTrash(); window.close() }
        let library = try #require(f.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        let search = try #require(f.views(window.contentView).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-library-search" })
        try await f.settle("load ready") { !f.model.workspace.loading }
        #expect(window.makeFirstResponder(library))
        switch blocker {
        case "search": search.selectText(nil)
        case "editor": review.openTextEditing(for: try #require(review.rows.first).id); review.updateDraftText("Keep draft")
        case "sheet": window.beginSheet(sheet, completionHandler: nil)
        case "inactive": window.isKeyboardTarget = { false }
        case "hidden": window.orderOut(nil)
        case "noSelection": f.model.selectedHistoryURL = nil
        default: break
        }
        let event = try f.key(51, in: window, characters: "\u{7f}", repeating: blocker == "repeat",
            modifiers: blocker == "modifier" ? .command : [])
        if blocker == "search" {
            let editor = try #require(search.currentEditor() as? NSTextView)
            editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(!window.performKeyEquivalent(with: event))
            window.sendEvent(event)
            #expect(editor.string == "ab")
        } else { _ = window.performKeyEquivalent(with: event) }
        if blocker == "staleFocus" { search.selectText(nil) }
        if blocker == "staleSelection" { f.model.selectedHistoryURL = f.b }
        try await Task.sleep(for: .milliseconds(40))
        #expect(f.model.recordingTrash == nil && !f.model.trashAdmitting)
        #expect(FileManager.default.fileExists(atPath: f.a.path) && FileManager.default.fileExists(atPath: f.b.path))
        if blocker == "editor" { #expect(review.activeTextDraft?.text == "Keep draft") }
    }

    @Test(arguments: [false, true])
    func nativeSheetBlocksTrashAdmissionAndConfirmation(confirmFirst: Bool) async throws {
        _ = NSApplication.shared
        let f = try TrashUIFixture()
        defer { f.close() }
        try await f.ready()
        let review = try await f.loadReview()
        let window = WorkspaceWindow(model: f.model)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        var finishExport: ((NSApplication.ModalResponse, URL?) -> Void)?
        defer {
            window.endSheet(sheet)
            finishExport?(.cancel, nil)
            f.model.cancelRecordingTrash()
            window.close()
        }
        if confirmFirst { #expect(await f.model.requestRecordingTrash(f.a)) }
        if confirmFirst { window.beginSheet(sheet, completionHandler: nil) }
        else {
            review.requestExport(savePanelRunner: { _, completion in
                finishExport = completion
                window.beginSheet(sheet)
            })
            #expect(review.activeExportRequest != nil)
        }
        #expect(window.attachedSheet === sheet)
        if confirmFirst { await f.model.confirmRecordingTrash() }
        else { #expect(!(await f.model.requestRecordingTrash(f.a))) }
        #expect(f.model.workspace.current === review && !review.state.isClosed)
        #expect(FileManager.default.fileExists(atPath: f.a.path))
        #expect(f.model.history.entry(f.a) != nil && window.attachedSheet === sheet)
        if confirmFirst { #expect(f.model.recordingTrash?.error != nil) }
        else { #expect(f.model.recordingTrash == nil && review.activeExportRequest != nil) }
    }

    @Test func nativeSelectedRowActionsAndSuccessFocusDoNotSelectNeighbor() async throws {
        _ = NSApplication.shared
        let f = try TrashUIFixture()
        defer { f.close() }
        try await f.ready()
        _ = try await f.loadReview()
        _ = f.model.requestWorkspaceOpen()
        let delegate = RecorderAppDelegate(model: f.model)
        delegate.setUpPresentation()
        let window = try #require(delegate.window as? WorkspaceWindow)
        window.isKeyboardTarget = { true }
        window.makeKeyAndOrderFront(nil)
        defer { f.model.cancelRecordingTrash(); window.close() }
        func views(_ view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap { views($0) }
        }
        func button(_ label: String) -> NSButton? {
            views(window.contentView).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }
        }
        func settle(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
            try #require(condition(), Comment(rawValue: message))
        }
        try await settle("neighbor rendered") { button("meeting_b") != nil }
        let neighbor = try #require(button("meeting_b"))
        #expect(neighbor.canBecomeKeyView)
        #expect(neighbor.bounds.width > 0 && neighbor.bounds.height > 0)
        #expect(window.makeFirstResponder(neighbor))
        let unselectedTrash = try #require(button("Переместить запись meeting_b в Корзину"))
        let unselectedEnabled = unselectedTrash.isEnabled
        #expect(!unselectedEnabled)
        window.recalculateKeyViewLoop()
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        for _ in 0..<6 {
            window.sendEvent(tab)
            if (window.firstResponder as? NSButton)?.accessibilityLabel() == "Переместить запись meeting_a в Корзину" { break }
        }
        try await settle("Tab skips unselected trash and reaches selected action") { (window.firstResponder as? NSButton)?.accessibilityLabel() == "Переместить запись meeting_a в Корзину" }
        #expect(f.model.selectedHistoryURL == f.a && f.model.workspace.current?.state.id == f.a)
        try await settle("selected workspace load finishes before Trash") { !f.model.workspace.loading }
        window.sendEvent(try f.key(51, in: window, characters: "\u{7f}"))
        try await settle("selected row Delete opens confirmation") { f.model.recordingTrash?.target.recording == f.a }
        await f.model.confirmRecordingTrash()
        try await settle("success focuses neighbor without opening") { (window.firstResponder as? NSButton)?.accessibilityLabel() == "meeting_b" }
        #expect(f.model.selectedHistoryURL == nil && f.model.workspace.current == nil)
        #expect(f.model.history.entries.map(\.id) == [f.b])
    }

}

extension RecordingTrashUITests {
    @Test func nativeTrashWorkspace() async throws {
        guard let destination = ProcessInfo.processInfo.environment["MC_TRASH_UI_ROOT"] else { return }
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let outcome = ProcessInfo.processInfo.environment["MC_TRASH_UI_OUTCOME"] ?? "native"
        let f = try TrashUIFixture(operation: { folder in
            if outcome == "pending-error" {
                try Data().write(to: output.appendingPathComponent("operation-started"))
                for _ in 0..<1200 {
                    if FileManager.default.fileExists(atPath: output.appendingPathComponent("release-operation").path) { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                throw CocoaError(.fileWriteNoPermission)
            }
            var result: NSURL?
            try FileManager.default.trashItem(at: folder, resultingItemURL: &result)
            let evidence = try JSONSerialization.data(withJSONObject: ["source": folder.path, "trash": result?.path ?? ""])
            try evidence.write(to: output.appendingPathComponent("native-trash.json"))
            try evidence.write(to: output.appendingPathComponent("native-trash-" + folder.lastPathComponent + ".json"))
        }); defer { f.close() }
        try await f.ready()
        _ = try await f.loadReview()
        if outcome == "pending-error" {
            let busy = f.root.appendingPathComponent("meeting_busy/meeting_busy.m4a")
            try FileManager.default.createDirectory(at: busy.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
            try await f.model.history.putThrowing(RecordingEntry(recording: busy, date: Date(), title: "Busy synthetic", phase: .processing))
            let flat = f.root.appendingPathComponent("meeting_flat.m4a")
            try Data().write(to: flat)
            await f.model.history.put(RecordingEntry.load(recording: flat), persist: false)
        }
        try await f.model.history.rename(f.a, displayTitle: String(repeating: "Длинное название встречи · ", count: 4))
        f.model.appearance = ProcessInfo.processInfo.environment["MC_TRASH_UI_DARK"] == "1" ? .dark : .light
        _ = f.model.requestWorkspaceOpen()
        NSApplication.shared.setActivationPolicy(.regular)
        let delegate = RecorderAppDelegate(model: f.model)
        delegate.setUpPresentation()
        let window = try #require(delegate.window)
        window.title = "Trash recording — synthetic UAT"
        window.setFrame(NSRect(x: 100, y: 150, width: 1100, height: 760), display: true)
        NSApp.finishLaunching()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { f.model.cancelRecordingTrash(); window.orderOut(nil); window.close() }
        try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
            "executable": ProcessInfo.processInfo.arguments[0], "bundleID": Bundle.main.bundleIdentifier ?? "",
            "root": f.root.path, "a": f.a.path, "b": f.b.path])
            .write(to: output.appendingPathComponent("host.json"))
        for _ in 0..<6000 {
            if FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Finder restoration must be found by the same normal scan, without a custom recovery path.
        await f.model.history.refresh(root: f.root)
        try JSONSerialization.data(withJSONObject: ["entries": f.model.history.entries.map { $0.id.path }])
            .write(to: output.appendingPathComponent("final-scan.json"))
    }
}
