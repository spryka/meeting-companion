import AppKit
import Foundation
import Testing
import MeetingCompanionCore
import MeetingCompanionApplication
@testable import MeetingCompanionApp

private final class FeedbackRunner: TranscriptionRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var progress: (@Sendable (TranscriptionProgress) -> Void)?
    var waiting: Bool { lock.withLock { continuation != nil } }
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation; progress = onProgress }
        }
        return recording.deletingPathExtension().appendingPathExtension("sources.transcript.txt")
    }
    func finish(warning: String? = nil) {
        let pending = lock.withLock {
            let pending = (continuation, progress)
            continuation = nil; progress = nil
            return pending
        }
        if let warning { pending.1?(.init(stage: .warning, channel: "remote", completed: 0, total: 0, warning: warning)) }
        pending.0?.resume()
    }
}

private struct FeedbackExporter: AudioExporterProtocol {
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws { }
}

@MainActor private final class FeedbackAdmission {
    weak var model: RecorderViewModel?
    var attempts = 0
}

@MainActor private final class FeedbackFixture {
    let root: URL
    let a: URL
    let b: URL
    let suite = "recording-feedback-" + UUID().uuidString
    let runner = FeedbackRunner()
    let admission = FeedbackAdmission()
    let model: RecorderViewModel
    let delegate: RecorderAppDelegate
    let window: WorkspaceWindow
    let warning = "Synthetic voice warning belonging to A"

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        a = root.appendingPathComponent("meeting_a/meeting_a.m4a")
        b = root.appendingPathComponent("meeting_b/meeting_b.m4a")
        let repository = RecordingHistoryRepository()
        for recording in [a, b] {
            let folder = recording.deletingLastPathComponent(), stem = recording.deletingPathExtension().lastPathComponent
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
            try Data().write(to: recording)
            for source in ["host", "remote"] {
                try Data([0, 0]).write(to: folder.appendingPathComponent("raw/\(stem).\(source)_record.wav"))
            }
            try Data("Saved synthetic text \(stem)".utf8).write(to: recording.deletingPathExtension().appendingPathExtension("sources.transcript.txt"))
            _ = try repository.putThrowing(RecordingEntry(recording: recording, date: Date(), title: stem, phase: .completed))
        }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(root.path, forKey: "recordingsDirectory")
        let admission = admission
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: FeedbackExporter(), historyRepository: repository,
            retryAdmission: { @MainActor [admission] recording in
                admission.attempts += 1
                return await admission.model?.prepareRecordingRetry(recording) ?? false
            })
        model = isolatedRecorderModel(processingService: service, historyRepository: repository, defaults: defaults)
        admission.model = model
        delegate = RecorderAppDelegate(model: model)
        delegate.setUpPresentation()
        window = try #require(delegate.window as? WorkspaceWindow)
        window.isKeyboardTarget = { true }
        window.makeKeyAndOrderFront(nil)
    }

    func settle(_ message: String, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            window.contentView?.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), Comment(rawValue: message))
    }

    func open(_ recording: URL) async throws {
        try await settle("services attach") { model.isAttached }
        model.selectLibraryRecording(recording)
        try await settle("selected saved text opens") {
            model.workspace.current?.state.id == recording && !model.workspace.loading
        }
        try await Task.sleep(for: .milliseconds(40))
    }

    func finishJobForA() async throws {
        model.retryRecording(a)
        try await settle("synthetic job starts") { runner.waiting && model.transcriptionJobs > 0 }
        runner.finish(warning: warning)
        try await settle("terminal event is observed") { model.transcriptionJobs == 0 && model.history.entry(a)?.phase == .completed }
        try await Task.sleep(for: .milliseconds(40))
    }

    func visibleText() -> String {
        RecordingHistoryView(model: model, history: model.history, workspace: model.workspace, showSettings: {}).feedbackError ?? ""
    }

    func capture(_ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["FEEDBACK_UI_ROOT"] else { return }
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
    }

    func close() {
        runner.finish()
        model.workspace.closeCurrent()
        window.close(); window.contentView = nil
        model.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) @MainActor struct RecordingFeedbackTests {
    @Test func switchingRecordingsDoesNotCarryAnotherWarning() async throws {
        let f = try FeedbackFixture(); defer { f.close() }
        try await f.open(f.a)
        let text = f.a.deletingPathExtension().appendingPathExtension("sources.transcript.txt")
        let original = try Data(contentsOf: text)
        try await f.finishJobForA()
        try await f.settle("A warning is visible at A") { f.visibleText().contains(f.warning) }
        try await f.open(f.b)
        try f.capture("warning-belongs-to-A-while-B-open")
        try await f.settle("A warning must leave B's native UI") { !f.visibleText().contains(f.warning) }
        try await f.open(f.a)
        try await f.settle("A retains its own feedback") { f.visibleText().contains(f.warning) }
        try f.capture("own-warning-visible-at-A")
        #expect(try Data(contentsOf: text) == original)
        #expect(f.model.history.entry(f.a)?.problems.contains { $0.message.contains(f.warning) } == true)
    }

    @Test(arguments: [false, true])
    func lateBackgroundWarningDoesNotPolluteOtherSelection(emptySelection: Bool) async throws {
        let f = try FeedbackFixture(); defer { f.close() }
        try await f.open(f.b)
        if emptySelection { f.model.selectedHistoryURL = nil }
        let selection = f.model.selectedHistoryURL, current = f.model.workspace.current
        try await f.finishJobForA()
        #expect(!f.visibleText().contains(f.warning))
        #expect(f.model.selectedHistoryURL == selection && f.model.workspace.current === current)
        try await f.open(f.a)
        try await f.settle("late feedback remains available at A") { f.visibleText().contains(f.warning) }
    }

    @Test func globalLibraryErrorSurvivesRecordSpecificFeedback() async throws {
        let f = try FeedbackFixture(); defer { f.close() }
        try await f.open(f.b)
        let global = "Synthetic library directory is unavailable"
        let localB = "Synthetic command failure belonging to B"
        f.model.history.reportError(global)
        f.model.history.reportError(localB, recording: f.b)
        try await f.settle("global library error is visible") { f.visibleText().contains(global) }
        try await f.finishJobForA()
        try await f.settle("initial library scan finishes") { !f.model.history.loading }
        let current = f.model.workspace.current
        try #require(f.model.requestLibraryRefresh())
        try await f.settle("manual refresh finishes") { !f.model.libraryRefreshPending }
        #expect(f.model.history.refreshError == nil && f.model.history.refreshCompletion != nil)
        #expect(f.model.selectedHistoryURL == f.b && f.model.workspace.current === current)
        #expect(f.visibleText().contains(global))
        #expect(f.visibleText().contains(localB))
        #expect(!f.visibleText().contains(f.warning))
        try await f.open(f.a)
        #expect(f.visibleText().contains(global) && f.visibleText().contains(f.warning))
        #expect(!f.visibleText().contains(localB))
    }

    @Test func successfulRetryClearsOnlyItsPreviousTransientFeedback() async throws {
        let f = try FeedbackFixture(); defer { f.close() }
        try await f.open(f.a)
        try await f.finishJobForA()
        try #require(f.visibleText().contains(f.warning))
        let global = "Synthetic library failure retained across retry"
        f.model.history.reportError(global)
        f.model.retryRecording(f.a)
        try await f.settle("retry starts") { f.runner.waiting && f.model.transcriptionJobs > 0 }
        f.runner.finish()
        try await f.settle("clean retry finishes") { f.model.transcriptionJobs == 0 && f.model.history.entry(f.a)?.phase == .completed }
        #expect(f.visibleText().contains(global) && !f.visibleText().contains(f.warning))
    }

    @Test func rejectedRetryRetainsItsPreviousTransientFeedback() async throws {
        let f = try FeedbackFixture(); defer { f.close() }
        try await f.open(f.a)
        try await f.finishJobForA()
        let attempts = f.admission.attempts
        f.model.retryRecording(f.a)
        f.model.presentSettings()
        try await f.settle("retry reaches modal admission") { f.admission.attempts > attempts }
        try await f.settle("rejected retry settles") { !f.model.isAdmittingProcessing && f.model.transcriptionJobs == 0 }
        #expect(f.model.settingsPresented)
        #expect(!f.runner.waiting)
        #expect(f.visibleText().contains(f.warning))
        f.model.dismissSettings()
    }

    @Test func recordMutationFailureBelongsToItsRecording() async throws {
        let f = try FeedbackFixture(); defer { f.close() }
        try await f.open(f.a)
        f.model.workspace.closeCurrent()
        let metadata = f.a.deletingLastPathComponent().appendingPathComponent("raw/meeting_a.processing.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        await f.model.history.update(f.a) { $0.title = "Unsaved synthetic title" }
        let warning = f.visibleText()
        try #require(!warning.isEmpty, "Failed metadata mutation must report feedback")
        try await f.settle("metadata error belongs at A") { f.visibleText().contains(warning) }
        try await f.open(f.b)
        try await f.settle("metadata error cannot belong to B") { !f.visibleText().contains(warning) }
    }
}
