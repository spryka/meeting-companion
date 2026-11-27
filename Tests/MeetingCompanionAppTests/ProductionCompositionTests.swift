import Foundation
import Combine
import os
import AppKit
import AVFoundation
import SwiftUI
import Testing
import MeetingCompanionCore
import MeetingCompanionApplication
import MeetingCompanionPlatform
@testable import MeetingCompanionApp

@MainActor private final class Capsule24Clock {
    struct Deadline {
        let due: TimeInterval
        let timer: Timer
        let action: @MainActor () -> Void
    }
    var now: TimeInterval = 0
    var deadlines: [Deadline] = []
    func schedule(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in }
        deadlines.append(.init(due: now + interval, timer: timer, action: action))
        return timer
    }
    func advance(_ interval: TimeInterval) {
        now += interval
        for deadline in deadlines where deadline.due <= now && deadline.timer.isValid {
            deadline.timer.invalidate()
            deadline.action()
        }
    }
}

private actor Capsule24Admission {
    private var continuation: CheckedContinuation<Bool, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(returning: true); continuation = nil }
}

private actor Capsule24Runner: TranscriptionRunnerProtocol {
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: (@Sendable (TranscriptionProgress) -> Void)?
    var waiting: Bool { continuation != nil }
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        progress = onProgress
        try await withCheckedThrowingContinuation { continuation = $0 }
        return recording.deletingPathExtension().appendingPathExtension("txt")
    }
    func emit(_ value: TranscriptionProgress) { progress?(value) }
    func finish(failed: Bool = false) {
        if failed { continuation?.resume(throwing: NSError(domain: "Capsule24Synthetic", code: 1)) }
        else { continuation?.resume() }
        continuation = nil
    }
}

private actor Capsule28OpenGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var waiting: Bool { continuation != nil }
    func wait() async {
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { released = true; continuation?.resume(); continuation = nil }
    func hold() { released = false }
}

@MainActor struct Capsule24Tests {
    private func capsuleCenterAlpha(_ model: RecorderViewModel) throws -> CGFloat {
        let size = AppWindowState.processingCapsuleSize
        let renderer = ImageRenderer(content: RecordingCapsuleHostView(viewModel: model)
            .frame(width: size.width, height: size.height))
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(origin: .zero, size: size))
        renderer.render { _, draw in draw(context) }
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent
    }

    private func settle(_ message: String = "Bounded synthetic service observation timed out", _ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await predicate(), Comment(rawValue: message))
    }

    // Run in an isolated test process when exercising native settings controls.
    private func exerciseRetentionSwitches(_ model: RecorderViewModel, defaults: UserDefaults) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        model.settingsPage = .recording
        try #require(model.presentSettings())
        let host = NSHostingView(rootView: SettingsShell(model: model).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 1000)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func switches(_ view: NSView) -> [NSSwitch] {
            if let control = view as? NSSwitch { return [control] }
            return view.subviews.flatMap(switches)
        }
        let toggles = switches(host)
        try #require(toggles.count == 2)
        toggles[0].performClick(nil)
        toggles[1].performClick(nil)
        // A page change tears down the recording controls before the ordinary Done button is pressed.
        model.settingsPage = .general
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // The ordinary Done button in the settings footer.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try #require(NSEvent.mouseEvent(with: type,
                location: NSPoint(x: host.bounds.width - 58, y: 30), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(click)
        }
        try await settle { !model.settingsPresented }
    }

    @Test func retentionStartsAfterSuccessfulSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let suite = "retention-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let repository = RecordingHistoryRepository()
        func addMeeting(_ date: Date) throws -> URL {
            let url = try RecordingPaths.makeOutputURL(outputDirectory: root, date: date)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
            _ = try repository.putThrowing(RecordingEntry(recording: url, date: date, title: "Тест", phase: .completed))
            return url
        }
        let old = try addMeeting(Date().addingTimeInterval(-300 * 86400))
        let new = try addMeeting(Date())
        let recent = try addMeeting(Date().addingTimeInterval(-20 * 86400))
        let folder = recent.deletingLastPathComponent()
        let version = folder.appendingPathComponent("raw/transcripts/res_valid_parakeet_off")
        let manager = FileManager.default
        try manager.createDirectory(at: version, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_parakeet_off.json")
        try manager.copyItem(at: fixture, to: version.appendingPathComponent("result.json"))
        try Data("Синтетический текст".utf8).write(to: version.appendingPathComponent("transcript.txt"))
        do {
            let file = try AVAudioFile(forWriting: version.appendingPathComponent("mix.m4a"), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64000))
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength))
            try file.write(from: buffer)
        }
        let mix = version.appendingPathComponent("mix.m4a")
        let encoded = try Data(contentsOf: mix)
        #expect(try verifyRetentionMix(mix, expectedDuration: 4))
        #expect(try !verifyRetentionMix(mix, expectedDuration: 8))
        for damaged in [Data(), Data("Это не AAC".utf8), Data(encoded.prefix(encoded.count / 2))] {
            try damaged.write(to: mix)
            #expect((try? verifyRetentionMix(mix, expectedDuration: 4)) != true)
        }
        try encoded.write(to: mix)
        _ = try repository.updateThrowing(recent) { $0.duration = 4 }
        let before = TranscriptEditsRepository(recordingDirectory: folder)
        let doc = try #require(try TranscriptResultStorage(recordingURL: recent).currentDocument())
        _ = try before.loadEdits(resultID: doc.resultID)
        _ = try before.saveTurnOverride(resultID: doc.resultID, turnID: doc.turns[0].id, text: "Сохранённая правка", displayName: nil)
        before.releaseWriteLock()
        let svc = ProcessingService(transcriptionRunner: DiagnosticRunner(), audioExporter: Exporter(), historyRepository: repository)
        let model = isolatedRecorderModel(processingService: svc, historyRepository: repository, defaults: defaults, startBackgroundServices: false)
        try await settle { model.isAttached }
        let key = try #require(RecordingRetention.preferenceKey(for: root))
        let policy = RecordingRetention(sourceDays: 14, meetingMonths: 6)
        #expect(model.retentionPolicy(key: key) == RecordingRetention())
        let preview = try await model.retentionPreview(policy, root: root)
        #expect(preview.filter { $0.action == .meeting }.map(\.target.recording) == [old])
        #expect(preview.filter { $0.action == .sources }.map(\.target.recording) == [recent])
        #expect(model.retentionPolicy(key: key) == RecordingRetention())
        if ProcessInfo.processInfo.environment["RETENTION_NATIVE_SETTINGS_TEST"] == "1" {
            try await exerciseRetentionSwitches(model, defaults: defaults)
        } else {
            try #require(model.presentSettings())
            model.retentionDraft = (key, policy)
            model.settingsPage = .general
            #expect(model.retentionPolicy(key: key) == RecordingRetention())
            model.dismissSettings()
        }
        try #require(!model.settingsPresented && model.retentionPolicy(key: key) == policy)
        let otherRoot = root.appendingPathComponent("другая библиотека")
        try manager.createDirectory(at: otherRoot, withIntermediateDirectories: false)
        try #require(model.presentSettings())
        model.retentionDraft = (key, RecordingRetention(sourceDays: 7, meetingMonths: 8))
        model.outputDirectory = otherRoot
        model.dismissSettings()
        #expect(model.retentionDraft == nil)
        let otherKey = try #require(RecordingRetention.preferenceKey(for: otherRoot))
        #expect(model.retentionPolicy(key: otherKey) == RecordingRetention())
        #expect(throws: Error.self) { try model.saveRetention(policy, key: key) }
        model.scheduleRetention(afterSaving: new)
        #expect(!model.retentionRunning)
        model.outputDirectory = root
        #expect(model.retentionPolicy(key: key) == policy)
        await model.history.refresh(root: root)

        let failed = try addMeeting(Date().addingTimeInterval(-60))
        let finished = OSAllocatedUnfairLock(initialState: false)
        let saved = OSAllocatedUnfairLock(initialState: [URL]())
        await svc.addEventHandler { event in
            switch event {
            case .recordingSaved(let url): saved.withLock { $0.append(url) }
            case .completed(let job, _, _), .failed(let job, _, _):
                if job.recordingURL == failed { finished.withLock { $0 = true } }
            default: break
            }
        }
        try manager.removeItem(at: failed)
        _ = await svc.enqueue(recordingURL: failed, settings: .init(parakeet: false, echoCancellation: false),
                              stoppedCapture: SyntheticSavedCapture(outputURL: failed, fileSize: 0))
        try await settle { finished.withLock { $0 } }
        #expect(saved.withLock { $0.isEmpty })
        #expect(manager.fileExists(atPath: old.path) && !model.retentionRunning)

        // A directory at the writer-lock path causes a real I/O failure on this meeting only.
        let blocked = try addMeeting(Date().addingTimeInterval(-280 * 86400))
        let blockedFolder = blocked.deletingLastPathComponent()
        let blockedLock = TranscriptEditsRepository(recordingDirectory: blockedFolder).lockURL()
        try manager.createDirectory(at: blockedLock, withIntermediateDirectories: false)
        _ = await svc.enqueue(recordingURL: new, settings: .init(parakeet: false, echoCancellation: false),
                              stoppedCapture: SyntheticSavedCapture(outputURL: new))
        try await settle("Не удалена просроченная встреча") { !FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path) }
        try await settle("Не удалены исходники") { !model.retentionRunning && !manager.fileExists(atPath: recent.path) }
        #expect(manager.fileExists(atPath: new.path))
        try await settle { repository.entry(new)?.phase == .completed }
        let notice = try #require(model.retentionError)
        #expect(notice.contains(blockedFolder.lastPathComponent))
        let library = RecordingHistoryView(model: model, history: model.history, workspace: model.workspace, showSettings: {})
        #expect(library.feedbackError?.contains(notice) == true)
        #expect(model.history.entry(old) == nil && model.history.entry(blocked) != nil)
        #expect(try Data(contentsOf: blocked) == Data([1]))
        let review = try await model.workspace.open(recordingURL: recent, title: "Тест")
        try await settle("Плеер редактора не открыл готовый микс") { review.playbackDuration >= 3.9 }
        await review.seekPlayback(to: 1)
        #expect(abs(review.playbackPosition - 1) < 0.15)
        let export = root.appendingPathComponent("export.txt")
        review.requestExport(savePanelRunner: { _, done in done(.OK, export) })
        #expect(try String(contentsOf: export, encoding: .utf8).contains("Сохранённая правка"))
        model.workspace.closeCurrent()
    }

    @Test func queuedProgressPresentationReportsWaiting() {
        let job = ProcessingJob(recordingURL: URL(fileURLWithPath: "/synthetic/queued/queued.m4a"), settings: .init(parakeet: true, echoCancellation: true))
        let snapshot = ProcessingProgressSnapshot(job: job)
        let details = ProcessingDetailsView(snapshot: snapshot, entry: RecordingEntry.load(recording: job.recordingURL), retry: {})
        #expect(snapshot.countText == "В очереди · 6 этапов")
        #expect(details.phaseTitle == "В очереди" && details.activityText == "Ожидает начала обработки.")
        #expect(snapshot.current == nil && snapshot.localFraction == nil)
    }

    @Test func processingFailedRetryDetailsOverrideActualPriorCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("processing-prior-" + UUID().uuidString), folder = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("a.m4a"), text = folder.appendingPathComponent("a.sources.transcript.txt")
        for path in ["a.m4a", "raw/a.host_record.wav", "raw/a.remote_record.wav"] { try Data().write(to: folder.appendingPathComponent(path)) }
        try Data("Synthetic previous committed text".utf8).write(to: text)
        let suite = "processing-prior-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(root.path, forKey: "recordingsDirectory")
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository(), runner = Capsule24Runner()
        var entry = RecordingEntry.load(recording: url); entry.phase = .completed
        repo.put(entry, persist: false)
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter(), historyRepository: repo)
        let model = isolatedRecorderModel(processingService: service, historyRepository: repo, defaults: defaults)
        try await settle { model.isAttached }
        let initial = try #require(model.showTranscript(url))
        #expect(await model.loadWorkspace(initial))
        #expect(model.workspace.current?.legacyText == "Synthetic previous committed text")
        _ = await service.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false))
        try await settle { await runner.waiting }
        await runner.emit(.init(stage: .gigaam, channel: "host", completed: 1, total: 3))
        await runner.finish(failed: true)
        try await settle { model.capsuleProgress?.failure != nil && model.transcriptionJobs == 0 }
        model.showProcessingDetails()
        #expect(await model.loadWorkspace(model.workspaceLoadRequest))
        let failedEntry = try #require(model.history.entry(url))
        let view = RecordingHistoryView(model: model, history: model.history, workspace: model.workspace, showSettings: {})
        #expect(view.processingDetails(for: failedEntry)?.failure != nil, "New failed job details take priority over cached old transcript")
        #expect(!model.showsProcessingCapsule)
        #expect(model.workspace.current?.legacyText == "Synthetic previous committed text")
        #expect(try String(contentsOf: text, encoding: .utf8) == "Synthetic previous committed text")
        #expect(failedEntry.capabilities.canRetry)
    }

    @Test(arguments: [false, true])
    func rejectedRetryShowsAdmissionFailureAndPreservesSavedTranscript(usesAdmission: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("a.m4a")
        for path in ["a.m4a", "raw/a.host_record.wav", "raw/a.remote_record.wav"] {
            try Data().write(to: folder.appendingPathComponent(path))
        }
        let savedText = "Previously saved text"
        let text = folder.appendingPathComponent("a.sources.transcript.txt")
        try Data(savedText.utf8).write(to: text)
        let suite = "retry-admission-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")

        let repo = RecordingHistoryRepository(), runner = Capsule24Runner()
        var entry = RecordingEntry.load(recording: url)
        entry.phase = .completed
        repo.put(entry, persist: false)
        let coordinator = VoiceLearningCoordinator(catalogue: .init(applicationDataDirectory: root))
        let admission = Capsule24Admission()
        let retryAdmission: (@Sendable (URL) async -> Bool)?
        if usesAdmission { retryAdmission = { _ in await admission.wait() } }
        else { retryAdmission = nil }
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter(), historyRepository: repo,
                                        retryAdmission: retryAdmission, voiceLearning: coordinator)
        let model = isolatedRecorderModel(processingService: service, historyRepository: repo, defaults: defaults)
        let writer = TranscriptEditsRepository(recordingDirectory: folder)
        try writer.acquireWriteLock()
        defer { writer.releaseWriteLock() }
        let otherWriter = TranscriptEditsRepository(recordingDirectory: folder)
        var reason: String?
        do { try otherWriter.acquireWriteLock() }
        catch { reason = error.localizedDescription }
        let failure = try #require(reason)

        try await settle { model.isAttached && model.history.entry(url) != nil }
        model.retryRecording(url)
        if usesAdmission {
            try await settle { await admission.waiting && model.isAdmittingProcessing }
            await admission.open()
        }
        try await settle { model.transcriptionState != .running(nil) && model.processingRoutes[url] != nil }
        #expect(model.transcriptionState == .failed(failure))
        #expect(model.capsuleProgress?.failure == failure)
        model.showProcessingDetails()
        #expect(await model.loadWorkspace(model.workspaceLoadRequest))
        let preserved = try #require(model.history.entry(url))
        let view = RecordingHistoryView(model: model, history: model.history, workspace: model.workspace, showSettings: {})
        #expect(view.feedbackError == failure)
        #expect(view.processingDetails(for: preserved) == nil)
        #expect(model.workspace.current?.legacyText == savedText)
        #expect(preserved.phase == .completed)
        #expect(try String(contentsOf: text, encoding: .utf8) == savedText)
        #expect(await !runner.waiting)
    }

    @Test(arguments: [false, true])
    func firstRecordingReconcilesNewLibraryRoot(failFirst: Bool) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("Meetings")
        let suite = "first-library-recording-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: parent)
        }
        defaults.set(root.path, forKey: "recordingsDirectory")
        defaults.set(true, forKey: "localVoiceIdentityEnabled")
        defaults.set([String](), forKey: "meetingCalendarIDs")
        let appData = parent.appendingPathComponent("appData")
        let coordinator = VoiceLearningCoordinator(catalogue: .init(applicationDataDirectory: appData))
        var failNextCapture = failFirst
        let model = RecorderViewModel(voiceLearning: coordinator, defaults: defaults, appDataDirectory: appData,
                                      startBackgroundServices: false, captureControllerFactory: { url, _, _ in
            if failNextCapture {
                failNextCapture = false
                throw CocoaError(.fileWriteUnknown)
            }
            return Capture(output: url)
        },
                                      microphoneProvider: { [] }, accessProvider: { [] }, calendarCatalogProvider: { [] })
        await model.history.refresh(root: root)
        #expect(!coordinator.canMatchVoices)
        try await settle { model.isAttached }
        _ = await model.startMeeting(nil, expectedSessionID: nil).value
        if failFirst {
            #expect(!model.isRecording)
            #expect(coordinator.canMatchVoices)
            _ = await model.startMeeting(nil, expectedSessionID: nil).value
        }
        #expect(model.isRecording)
        #expect(coordinator.canMatchVoices)
    }

    enum CapsuleHandoffScenario: CaseIterable, Sendable { case queuedRecording, captureFailure, earlyDetails }

    @Test(arguments: CapsuleHandoffScenario.allCases)
    func processingDetailsHandsOffCapsuleWithoutRestartingJob(_ scenario: CapsuleHandoffScenario) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("processing-details-" + UUID().uuidString)
        let folder = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("a.m4a")
        for path in ["a.m4a", "raw/a.host_record.wav", "raw/a.remote_record.wav"] { try Data().write(to: folder.appendingPathComponent(path)) }
        let otherFolder = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherFolder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        let other = otherFolder.appendingPathComponent("other.m4a")
        for path in ["other.m4a", "raw/other.host_record.wav", "raw/other.remote_record.wav"] {
            try Data().write(to: otherFolder.appendingPathComponent(path))
        }
        let suite = "processing-details-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(root.path, forKey: "recordingsDirectory")
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository(), runner = Capsule24Runner()
        repo.put(RecordingEntry.load(recording: url), persist: false)
        repo.put(RecordingEntry.load(recording: other), persist: false)
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter(), historyRepository: repo)
        let capture = Capsule28OpenGate()
        let model = isolatedRecorderModel(processingService: service, historyRepository: repo, defaults: defaults,
                                         captureControllerFactory: { _, _, _ in
            await capture.wait()
            throw CocoaError(.fileWriteUnknown)
        })
        let controller = RecordingCapsuleController(model: model, defaults: defaults)
        defer { controller.hideCapsule() }
        let panel = try #require(controller.panel)
        var presentations = 0
        model.onPresentWorkspace = { presentations += 1 }
        try await settle { model.isAttached && model.history.entry(url) != nil }
        if scenario == .earlyDetails {
            model.retryRecording(url)
            model.showProcessingDetails() // Synchronous action before enqueue reaches the service.
            #expect(!model.showsProcessingCapsule)
            try await settle { await runner.waiting && model.capsuleProgress != nil }
            let firstID = try #require(model.capsuleProgress?.jobID)
            #expect(!model.showsProcessingCapsule)
            model.retryRecording(other)
            try await settle { model.transcriptionJobs == 2 }
            await runner.finish()
            try await settle { await runner.waiting && model.lastFileURL == other && model.transcriptionJobs == 1 }
            let otherProgress = TranscriptionProgress(stage: .gigaam, channel: "host", completed: 1, total: 3)
            await runner.emit(otherProgress)
            try await settle { model.capsuleProgress?.local == otherProgress }
            model.retryRecording(url)
            try await settle { model.transcriptionJobs == 2 }
            await runner.finish()
            try await settle { await runner.waiting && model.lastFileURL == url && model.capsuleProgress.map { $0.jobID != firstID } == true }
            #expect(model.showsProcessingCapsule, "A new attempt gets its own capsule")
            await runner.finish()
            try await settle { model.transcriptionJobs == 0 }
            return
        }
        let job = await service.enqueue(recordingURL: url, settings: .init(parakeet: true, echoCancellation: true))
        try await settle { await runner.waiting && model.capsuleProgress?.jobID == job.id && panel.isVisible }
        model.selectedHistoryURL = other
        model.echoCancellation = false
        await runner.emit(.init(stage: .gigaam, channel: "remote", completed: 52, total: 153))
        try await settle { model.capsuleProgress?.local?.completed == 52 }
        #expect(model.selectedHistoryURL == other && model.capsuleProgress?.route.count == 6)
        #expect(model.presentSettings())
        model.showProcessingDetails()
        #expect(model.selectedHistoryURL == other && presentations == 0 && model.processingNavigationNotice != nil)
        #expect(model.showsProcessingCapsule)
        model.dismissSettings()
        model.workspace.externalModal = true
        model.showProcessingDetails()
        #expect(model.selectedHistoryURL == other && presentations == 0)
        #expect(model.showsProcessingCapsule)
        model.workspace.externalModal = false
        let visibleAlpha = try capsuleCenterAlpha(model)
        #expect(visibleAlpha == 1)
        model.showProcessingDetails()
        #expect(model.selectedHistoryURL == url && model.processingNavigationNotice == nil)
        #expect(!model.showsProcessingCapsule)
        let hiddenAlpha = try capsuleCenterAlpha(model)
        #expect(hiddenAlpha == 0, "The host must already be transparent while the panel is being hidden")
        #expect(model.admitWindowClose(isWorkspace: true))
        #expect(model.capsuleProgress?.local?.completed == 52)
        #expect(await service.totalJobCount == 1)
        #expect(presentations == 1 && model.capsuleProgress?.jobID == job.id)
        try await settle { !panel.isVisible }
        if scenario == .captureFailure {
            let start = Task { await model.startRecordingIntent(customTitle: "Synthetic failed capture") }
            try await settle { await capture.waiting && model.sessionStarting }
            await runner.finish()
            try await settle { model.transcriptionJobs == 0 && model.processingRoutes[url]?.terminal == true }
            await capture.open()
            #expect(await start.value == false)
            #expect(model.capsuleProgress?.jobID == job.id)
            #expect(!model.showsRecordingCapsule)
            try await settle { !panel.isVisible }
            return
        }
        model.retryRecording(other)
        #expect(!model.showsRecordingCapsule, "B entering the queue must leave the active A capsule hidden")
        try await settle { model.transcriptionJobs == 2 && model.capsuleProgress?.jobID == job.id }
        #expect(!model.showsProcessingCapsule)
        #expect(!panel.isVisible)
        await runner.finish()
        try await settle { await runner.waiting && model.lastFileURL == other && panel.isVisible }
        #expect(model.processingRoutes[url]?.terminal == true)
        #expect(model.showsProcessingCapsule)
        await runner.finish()
        try await settle { model.transcriptionJobs == 0 && model.capsuleProgress?.terminal == true }

        let retry = await service.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false))
        try await settle { await runner.waiting && model.capsuleProgress?.jobID == retry.id }
        #expect(retry.id != job.id && model.showsProcessingCapsule)
        await runner.finish()
        try await settle { model.transcriptionJobs == 0 }
    }

    @Test func processingCapsuleRejectsManualDismiss() async throws {
        let suite = "progress-dismiss-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults)
        try await settle { model.isAttached }
        let url = URL(fileURLWithPath: defaults.string(forKey: "recordingsDirectory")!).appendingPathComponent("a/a.m4a")
        var entry = RecordingEntry.load(recording: url)
        entry.phase = .processing
        repo.put(entry, persist: false)
        await model.history.synchronize()
        model.lastFileURL = url
        model.syncProcessingPresentation(url)
        #expect(model.showsProcessingCapsule)
        model.dismissCapsule()
        #expect(model.showsProcessingCapsule, "Processing has no manual dismissal command")
        entry.phase = .failed
        repo.put(entry, persist: false)
        await model.history.synchronize()
        model.syncProcessingPresentation(url)
        model.capsuleDismissed = false
        model.dismissCapsule()
        #expect(model.showsProcessingCapsule, "Terminal processing also has no manual dismissal command")
    }

    @Test(arguments: ["pending", "running", "foreign", "cancelled", "idle", "handoff"])
    func reset31CurrentCommitAdmission(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reset31-" + UUID().uuidString)
        let recordings = root.appendingPathComponent("recordings")
        let folder = recordings.appendingPathComponent("saved"), appData = root.appendingPathComponent("appData")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["saved.m4a", "raw/saved.host_record.wav", "raw/saved.remote_record.wav"] {
            try Data().write(to: folder.appendingPathComponent(name)) // Path placeholders only, no PCM.
        }
        let url = folder.appendingPathComponent("saved.m4a"), repo = RecordingHistoryRepository()
        var savedEntry = RecordingEntry.load(recording: url)
        savedEntry.phase = .completed
        try #require(savedEntry.capabilities.canRetry, "Synthetic raw pair must be eligible before reset test")
        try repo.putThrowing(savedEntry)
        let suite = "reset31-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(recordings.path, forKey: "recordingsDirectory")
        let runner = Capsule24Runner(), admission = Capsule24Admission(), confirmation = Capsule24Admission(), clock = Capsule24Clock()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter(), historyRepository: repo,
            retryAdmission: { _ in await admission.wait() })
        let model = isolatedRecorderModel(processingService: service, historyRepository: repo, defaults: defaults,
            appDataDirectory: appData, capsuleTimerScheduler: { clock.schedule($0, $1) })
        await model.history.synchronize()
        try await settle { model.isAttached }
        model.transcriptionReady = true
        model.lastFileURL = url
        model.syncProcessingPresentation(url)
        let resets = OSAllocatedUnfairLock(initialState: 0)
        if scenario == "handoff" {
            model.retryRecording(url) // Actual accepted App command, before its async service handoff can run.
            #expect(!model.canResetCache)
            var confirmations = 0
            await model.performCacheReset(in: appData, resetOperation: { _, _ in resets.withLock { $0 += 1 } }, confirmation: { _ in
                confirmations += 1; return true
            })
            #expect(confirmations == 0 && resets.withLock { $0 } == 0 && model.transcriptionReady)
            try await settle { await admission.waiting }
            await admission.open()
            try await settle { await runner.waiting }
            await runner.finish()
            try await settle { model.transcriptionJobs == 0 && model.canResetCache }
            return
        }
        #expect(model.presentSettings())
        let reset = Task {
            await model.performCacheReset(in: appData, resetOperation: { _, _ in resets.withLock { $0 += 1 } }, confirmation: { _ in
                await confirmation.wait()
            })
        }
        try await settle { await confirmation.waiting }
        #expect(model.isResettingCache && model.diagnosticRunning && model.preventsTermination)
        var pending: Task<ProcessingJob, Never>?
        if scenario == "pending" || scenario == "running" {
            pending = Task { await service.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false)) }
            try await settle { await admission.waiting && model.isAdmittingProcessing }
            if scenario == "running" {
                await admission.open()
                try await settle { await runner.waiting }
                let progress = TranscriptionProgress(stage: .gigaam, completed: 52, total: 153)
                await runner.emit(progress)
                try await settle { model.transcriptionState == .running(progress) }
            }
        } else if scenario == "foreign" { model.workspace.externalModal = true }
        else if scenario == "cancelled" { reset.cancel() }
        model.diagnosticReport = "KEEP_CURRENT_FEEDBACK"
        model.preparationProgress = .init(bytes: 12, fileCount: 2)
        model.recordingSaveError = "KEEP_CAPTURE_FEEDBACK"
        let state = model.transcriptionState, progress = model.history.progress[url]
        let preparation = model.preparationProgress, visible = model.showsRecordingCapsule
        await confirmation.open()
        await reset.value
        #expect(!model.isResettingCache)
        if scenario == "idle" {
            #expect(resets.withLock { $0 } == 1 && !model.transcriptionReady && model.transcriptionState == .idle)
            #expect(model.diagnosticReport.contains("Кэш сброшен"))
        } else {
            #expect(resets.withLock { $0 } == 0 && model.transcriptionReady)
            #expect(model.transcriptionState == state && model.history.progress[url] == progress)
            #expect(model.preparationProgress == preparation && model.diagnosticReport == "KEEP_CURRENT_FEEDBACK")
            #expect(model.recordingSaveError == "KEEP_CAPTURE_FEEDBACK" && model.showsRecordingCapsule == visible)
        }
        if scenario == "pending" {
            #expect(model.isAdmittingProcessing && model.diagnosticRunning == false)
            await admission.open()
            try await settle { await runner.waiting }
        }
        if pending != nil {
            await runner.finish()
            _ = await pending?.value
            try await settle { model.transcriptionJobs == 0 }
        }
        model.workspace.externalModal = false
        model.dismissSettings()
    }

    @Test(arguments: [false, true]) func settings29PreloadedOpenRejectsLateModal(settings: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings29-" + UUID().uuidString)
        let folder = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("saved.m4a")
        try Data("Synthetic saved A".utf8).write(to: folder.appendingPathComponent("saved.sources.transcript.txt"))
        let repo = RecordingHistoryRepository()
        var entry = RecordingEntry.load(recording: url); entry.phase = .completed
        try repo.putThrowing(entry)
        let suite = "settings29-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let gate = Capsule28OpenGate(), clock = Capsule24Clock()
        let workspace = TranscriptReviewWindowManager(isProcessing: { _ in await gate.wait(); return false },
            transportFactory: { BufferingPresentationTransport() })
        let model = isolatedRecorderModel(historyRepository: repo, workspace: workspace, defaults: defaults,
            capsuleTimerScheduler: { clock.schedule($0, $1) })
        await model.history.synchronize()
        try await settle { model.isAttached }
        await gate.open()
        let request = try #require(model.showTranscript(url))
        await model.loadWorkspace(request)
        let currentA = try #require(workspace.current)
        #expect(currentA.legacyText == "Synthetic saved A" && workspace.failure == nil)
        model.lastFileURL = url
        model.syncProcessingPresentation(url)
        model.onPresentWorkspace = {} // No NSApplication or native window in this regression.
        await gate.hold()
        model.openResults()
        try await settle { await gate.waiting }
        if settings { #expect(model.presentSettings()) }
        else { workspace.externalModal = true }
        await gate.open()
        for _ in 0..<100 { await Task.yield() }
        #expect(workspace.current === currentA && workspace.failure == nil)
        #expect(!model.capsuleDismissed && model.showsProcessingCapsule)
        if settings { model.dismissSettings() }
        else { workspace.externalModal = false }
        model.openResults()
        try await settle { model.capsuleDismissed }
        #expect(workspace.current === currentA)
        workspace.closeCurrent()
    }

    @Test(arguments: ["admitted", "modal", "missing", "deleted", "capture", "job", "generation", "failedCaptureAfterOpen"])
    func capsule28OwnedOpenUsesRealTarget(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capsule28-" + UUID().uuidString)
        let folder = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("saved.m4a")
        let text = folder.appendingPathComponent("saved.sources.transcript.txt")
        try Data("Synthetic contained saved text".utf8).write(to: text)
        let repo = RecordingHistoryRepository()
        var entry = RecordingEntry.load(recording: url)
        entry.phase = .completed
        try repo.putThrowing(entry)
        let suite = "capsule28-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let gate = Capsule28OpenGate(), runner = Capsule24Runner(), clock = Capsule24Clock()
        let workspace = TranscriptReviewWindowManager(isProcessing: { _ in await gate.wait(); return false },
            transportFactory: { BufferingPresentationTransport() })
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter(), historyRepository: repo)
        let failCapture = scenario == "failedCaptureAfterOpen"
        let admitted = scenario == "admitted" || failCapture
        let captureGate = Capsule28OpenGate()
        let model = isolatedRecorderModel(processingService: service, historyRepository: repo, workspace: workspace, defaults: defaults,
            captureControllerFactory: { output, _, _ in
                if failCapture {
                    await captureGate.wait()
                    throw CocoaError(.fileWriteUnknown)
                }
                return Capture(output: output, duration: 3)
            },
            shortRecordingTrash: { _ in }, capsuleTimerScheduler: { clock.schedule($0, $1) })
        let controller = admitted ? RecordingCapsuleController(model: model, defaults: defaults) : nil
        defer { controller?.hideCapsule() }
        await model.history.synchronize()
        try await settle { model.isAttached }
        model.lastFileURL = url
        model.syncProcessingPresentation(url)
        #expect(model.showsProcessingCapsule && !model.capsuleDismissed)
        if let controller {
            let panel = try #require(controller.panel)
            try await settle { panel.isVisible }
            let visibleAlpha = try capsuleCenterAlpha(model)
            #expect(visibleAlpha == 1)
        }
        var presented = 0
        model.onPresentWorkspace = { presented += 1 }
        if scenario == "modal" { workspace.externalModal = true }
        if scenario == "missing" { model.lastFileURL = root.appendingPathComponent("missing/missing.m4a") }
        if scenario == "deleted" { try FileManager.default.removeItem(at: text) }
        model.openResults()
        if scenario == "modal" || scenario == "missing" {
            for _ in 0..<20 { await Task.yield() }
            #expect(presented == 0 && !model.capsuleDismissed)
            #expect(workspace.current == nil)
            workspace.externalModal = false
            return
        }
        try await settle { await gate.waiting }
        #expect(presented == 1 && !model.capsuleDismissed)
        if scenario == "capture" {
            #expect(await model.startRecordingIntent(customTitle: "Concurrent synthetic capture"))
        } else if scenario == "job" {
            let other = root.appendingPathComponent("other/other.m4a")
            try FileManager.default.createDirectory(at: other.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
            for name in ["other.m4a", "raw/other.host_record.wav", "raw/other.remote_record.wav"] {
                try Data().write(to: other.deletingLastPathComponent().appendingPathComponent(name))
            }
            var otherEntry = RecordingEntry.load(recording: other); otherEntry.phase = .completed
            try repo.putThrowing(otherEntry)
            await model.history.synchronize()
            model.retryRecording(other)
            try await settle { await runner.waiting }
        } else if scenario == "generation" {
            model.syncProcessingPresentation(url) // A new actual terminal presentation owns a new deadline.
        }
        await gate.open()
        try await settle { workspace.current?.state.id == url || workspace.failure != nil }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.capsuleDismissed == admitted)
        if let controller {
            let panel = try #require(controller.panel)
            let hiddenAlpha = try capsuleCenterAlpha(model)
            #expect(hiddenAlpha == 0)
            try await settle { !panel.isVisible }
            if failCapture {
                let start = Task { await model.startRecordingIntent(customTitle: "Synthetic failed capture") }
                try await settle { await captureGate.waiting && model.sessionStarting && panel.isVisible }
                await captureGate.open()
                #expect(await start.value == false)
                #expect(model.capsuleDismissed && !model.showsRecordingCapsule)
                try await settle { !panel.isVisible }
            }
        }
        if scenario == "deleted" { #expect(workspace.failure != nil && workspace.current == nil) }
        else { #expect(workspace.current?.legacyText != nil) }
        if scenario == "capture", let session = model.activeSessionID {
            model.elapsed = 3
            #expect(await model.cancelRecordingIntent(sessionID: session))
        }
        if scenario == "job" { await runner.finish(); try await settle { model.transcriptionJobs == 0 } }
        workspace.closeCurrent()
    }

    @Test(arguments: [false, true], [false, true])
    func capsule26OwnedShortCancelExpiresOverHeldProcessing(hidden: Bool, progressDuringFeedback: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capsule26-" + UUID().uuidString)
        let folder = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = folder.appendingPathComponent("saved.m4a"), text = folder.appendingPathComponent("saved.txt")
        for path in ["saved.m4a", "raw/saved.host_record.wav", "raw/saved.remote_record.wav"] {
            try Data().write(to: folder.appendingPathComponent(path)) // Empty placeholders, no PCM.
        }
        let originalText = Data("Synthetic B original text".utf8)
        try originalText.write(to: text)
        let suite = "capsule26-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let repo = RecordingHistoryRepository(), runner = Capsule24Runner(), clock = Capsule24Clock()
        try repo.putThrowing(.init(recording: b, date: Date(), title: "Held B", phase: .completed))
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter(), historyRepository: repo)
        let model = isolatedRecorderModel(processingService: service, historyRepository: repo, defaults: defaults,
            captureControllerFactory: { url, _, _ in Capture(output: url, duration: 3) },
            shortRecordingTrash: { url in
                precondition(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
                try FileManager.default.removeItem(at: url)
            }, capsuleTimerScheduler: { clock.schedule($0, $1) })
        await model.history.synchronize()
        try await settle { model.isAttached }
        model.retryRecording(b)
        try await settle { await runner.waiting }
        let initial = TranscriptionProgress(stage: .gigaam, completed: 52, total: 153)
        await runner.emit(initial)
        try await settle { model.transcriptionState == .running(initial) && model.transcriptionJobs == 1 }
        for _ in 0..<20 { await Task.yield() }

        #expect(await model.startRecordingIntent(customTitle: "Concurrent A"))
        let a = try #require(model.lastFileURL), sessionA = try #require(model.activeSessionID)
        model.elapsed = 3
        #expect(await model.cancelRecordingIntent(sessionID: sessionA))
        try await settle { !model.isRecording && !model.sessionStopping && model.activeSessionID == nil }
        #expect(model.recordingCancelled && model.transcriptionJobs == 1)
        let feedback = try #require(clock.deadlines.last)
        #expect(feedback.due == clock.now + 2)
        if hidden { model.dismissCapsule() }
        let resumed = progressDuringFeedback ? TranscriptionProgress(stage: .gigaam, completed: 53, total: 153) : initial
        if progressDuringFeedback {
            await runner.emit(resumed)
            try await settle { model.history.progress[b] == resumed }
            for _ in 0..<20 { await Task.yield() }
            #expect(model.recordingCancelled && feedback.timer.isValid)
        }
        clock.advance(1)
        #expect(model.recordingCancelled)
        clock.advance(1) // No B progress is emitted here or required to resume B.
        #expect(!model.recordingCancelled && model.lastFileURL == b)
        #expect(model.transcriptionState == .running(resumed) && model.transcriptionJobs == 1)
        #expect(!model.capsuleDismissed && model.showsProcessingCapsule)
        #expect(await runner.waiting)
        feedback.action() // A delivered callback cannot act again after presentation ownership changes.
        #expect(!model.recordingCancelled && !model.capsuleDismissed)
        await runner.emit(.init(stage: .gigaam, completed: 54, total: 153))
        try await settle { model.transcriptionState == .running(.init(stage: .gigaam, completed: 54, total: 153)) }
        #expect(!model.capsuleDismissed)
        await runner.finish()
        try await settle { model.transcriptionJobs == 0 && clock.deadlines.count >= 2 }
        #expect(clock.deadlines.last?.due == clock.now + 60)
        feedback.action()
        #expect(!model.capsuleDismissed)
        clock.advance(59)
        #expect(!model.capsuleDismissed)
        clock.advance(1)
        #expect(model.capsuleDismissed && !model.showsRecordingCapsule)
        #expect(repo.entry(a) == nil && !FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: text) == originalText)
        for source in ["host", "remote"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("raw/saved.\(source)_record.wav").path))
        }
    }

    @Test func capsule25ActualShortCancelThenRetryRetiresFeedbackAndStaleCallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capsule25-" + UUID().uuidString)
        let folder = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = folder.appendingPathComponent("saved.m4a"), text = folder.appendingPathComponent("saved.txt")
        // Empty path placeholders only: no new audio/PCM, decoder, exporter or transport.
        for path in ["saved.m4a", "raw/saved.host_record.wav", "raw/saved.remote_record.wav"] {
            try Data().write(to: folder.appendingPathComponent(path))
        }
        let originalText = Data("Synthetic B saved text".utf8)
        try originalText.write(to: text)
        let repo = RecordingHistoryRepository()
        try repo.putThrowing(.init(recording: saved, date: Date(), title: "Saved B", phase: .completed))
        let suite = "capsule25-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let runner = Capsule24Runner(), admission = Capsule24Admission(), clock = Capsule24Clock()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter(), historyRepository: repo,
            retryAdmission: { _ in await admission.wait() })
        let model = isolatedRecorderModel(processingService: service, historyRepository: repo, defaults: defaults,
            captureControllerFactory: { url, _, _ in Capture(output: url, duration: 3) },
            shortRecordingTrash: { url in
                precondition(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
                try FileManager.default.removeItem(at: url)
            }, capsuleTimerScheduler: { clock.schedule($0, $1) })
        await model.history.synchronize()
        try await settle { model.isAttached }
        #expect(await model.startRecordingIntent(customTitle: "Synthetic A"))
        let a = try #require(model.lastFileURL), sessionA = try #require(model.activeSessionID)
        model.elapsed = 3
        #expect(await model.cancelRecordingIntent(sessionID: sessionA))
        try await settle { !model.isRecording && !model.sessionStopping && model.activeSessionID == nil }
        #expect(model.recordingCancelled && model.showsRecordingCapsule && !model.showsProcessingCapsule)
        #expect(repo.entry(a) == nil && !FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path))
        let stale = try #require(clock.deadlines.last)
        #expect(stale.due == clock.now + 2)

        model.retryRecording(saved)
        try await settle { await admission.waiting && model.isAdmittingProcessing }
        #expect(!model.recordingCancelled && model.showsProcessingCapsule)
        #expect(!stale.timer.isValid && model.transcriptionState == .running(nil))
        clock.advance(2)
        stale.action() // Explicitly deliver the already queued callback after Timer invalidation.
        #expect(!model.capsuleDismissed && model.showsProcessingCapsule)
        await admission.open()
        try await settle { await runner.waiting }
        let progress = TranscriptionProgress(stage: .gigaam, completed: 52, total: 153)
        await runner.emit(progress)
        try await settle { model.transcriptionState == .running(progress) }
        stale.action()
        #expect(!model.recordingCancelled && !model.capsuleDismissed && model.showsProcessingCapsule)
        model.dismissCapsule()
        await runner.emit(.init(stage: .gigaam, completed: 53, total: 153))
        try await settle { model.history.progress[saved]?.completed == 53 }
        #expect(!model.capsuleDismissed && model.showsProcessingCapsule)
        await runner.finish()
        try await settle { model.transcriptionJobs == 0 && repo.entry(saved)?.phase == .completed }

        // A newer real short cancellation owns its own feedback/deadline, without a new job.
        #expect(await model.startRecordingIntent(customTitle: "Synthetic C"))
        let sessionC = try #require(model.activeSessionID)
        #expect(sessionC != sessionA)
        model.elapsed = 3
        #expect(await model.cancelRecordingIntent(sessionID: sessionC))
        try await settle { !model.isRecording && !model.sessionStopping && model.activeSessionID == nil }
        #expect(model.recordingCancelled && !model.capsuleDismissed && model.showsRecordingCapsule)
        stale.action()
        #expect(model.recordingCancelled && !model.capsuleDismissed && model.showsRecordingCapsule)
        clock.advance(1)
        #expect(model.recordingCancelled && model.showsRecordingCapsule)
        clock.advance(1)
        #expect(!model.recordingCancelled && model.capsuleDismissed && !model.showsRecordingCapsule)
        #expect(try Data(contentsOf: text) == originalText)
        for source in ["host", "remote"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("raw/saved.\(source)_record.wav").path))
        }
    }

    @Test func capsule24NativeProgressUsesCurrentStageWithoutOptionalSteps() throws {
        let native = try #require(TranscriptionProgress(line: Data("MEETING_PROGRESS {\"stage\":\"gigaam\",\"channel\":\"remote\",\"completed\":52,\"total\":153}".utf8)))
        #expect(ProcessingDetailsView.fraction(for: native) == native.stageFraction)
        let unknown = try #require(TranscriptionProgress(line: Data("MEETING_PROGRESS {\"stage\":\"gigaam\",\"completed\":0,\"total\":0}".utf8)))
        #expect(ProcessingDetailsView.fraction(for: unknown) == nil)
        let optional = TranscriptionProgress(stage: .gigaam, completed: 52, total: 153, step: 2, steps: 7)
        #expect(ProcessingDetailsView.fraction(for: optional) == native.stageFraction)
        #expect(ProcessingDetailsView.fraction(for: .init(stage: .warning, completed: 0, total: 1, warning: "synthetic")) == nil)
    }

    @Test func capsule24RealQueuedRetryRejectsOldDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capsule24-queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = RecordingHistoryRepository()
        func recording(_ name: String) throws -> URL {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
            for path in ["\(name).m4a", "raw/\(name).host_record.wav", "raw/\(name).remote_record.wav"] {
                try Data().write(to: folder.appendingPathComponent(path))
            }
            let url = folder.appendingPathComponent(name + ".m4a")
            try repo.putThrowing(.init(recording: url, date: Date(), title: name, phase: .completed))
            return url
        }
        let first = try recording("first"), queued = try recording("queued")
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let runner = Capsule24Runner(), clock = Capsule24Clock()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter(), historyRepository: repo)
        let model = isolatedRecorderModel(processingService: service, historyRepository: repo, defaults: defaults,
            capsuleTimerScheduler: { clock.schedule($0, $1) })
        await model.history.synchronize()
        try await settle { model.isAttached }
        model.retryRecording(first)
        try await settle { await runner.waiting && model.capsuleProgress?.terminal == false }
        model.lastFileURL = queued
        model.syncProcessingPresentation(queued)
        let stale = try #require(clock.deadlines.last)
        model.retryRecording(queued)
        try await settle { repo.entry(queued)?.phase == .queued && model.transcriptionJobs == 2 }
        clock.advance(60); stale.action()
        #expect(!model.capsuleDismissed && model.showsProcessingCapsule)
        await runner.finish()
        try await settle { await runner.waiting && model.lastFileURL == queued && model.transcriptionJobs == 1 }
        stale.action()
        #expect(!model.capsuleDismissed && model.showsProcessingCapsule)
        await runner.finish()
        try await settle { model.transcriptionJobs == 0 }
    }

    @Test(arguments: [false, true])
    func capsule24RetryOwnsDeadlineAndReminderPreservesWorking(failed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capsule24-" + UUID().uuidString)
        let folder = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = folder.appendingPathComponent("meeting.m4a")
        // Empty path placeholders only: no PCM generated, copied, decoded or played.
        for path in ["meeting.m4a", "raw/meeting.host_record.wav", "raw/meeting.remote_record.wav"] {
            try Data().write(to: folder.appendingPathComponent(path))
        }
        try Data("Synthetic saved text".utf8).write(to: folder.appendingPathComponent("meeting.txt"))
        let suite = "capsule24-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let repo = RecordingHistoryRepository()
        try repo.putThrowing(.init(recording: recording, date: Date(), title: "Synthetic", phase: failed ? .failed : .completed))
        let runner = Capsule24Runner(), admission = Capsule24Admission(), clock = Capsule24Clock()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter(), historyRepository: repo,
            retryAdmission: { _ in await admission.wait() })
        let model = isolatedRecorderModel(processingService: service, historyRepository: repo,
            defaults: defaults, capsuleTimerScheduler: { clock.schedule($0, $1) })
        await model.history.synchronize()
        try await settle { model.isAttached }
        model.lastFileURL = recording
        model.syncProcessingPresentation(recording)
        let old = try #require(clock.deadlines.last)
        model.retryRecording(recording)
        try await settle { await admission.waiting && model.isAdmittingProcessing }
        #expect(!old.timer.isValid)
        clock.advance(60)
        old.action() // An already enqueued callback must also be harmless after invalidation.
        #expect(!model.capsuleDismissed && model.showsProcessingCapsule)
        #expect(model.transcriptionState == .running(nil))
        await admission.open()
        try await settle { await runner.waiting }
        let progress = try #require(TranscriptionProgress(line: Data("MEETING_PROGRESS {\"stage\":\"gigaam\",\"completed\":52,\"total\":153}".utf8)))
        await runner.emit(progress)
        try await settle { model.transcriptionState == .running(progress) }
        old.action()
        #expect(!model.capsuleDismissed)
        model.capsuleDismissed = false
        model.prepareForAutomaticReminder() // The actual delegate calls this same action.
        #expect(!model.capsuleDismissed && model.showsProcessingCapsule)
        model.dismissCapsule()
        await runner.emit(.init(stage: .gigaam, completed: 53, total: 153))
        try await settle { model.history.progress[recording]?.completed == 53 }
        #expect(!model.capsuleDismissed && model.showsProcessingCapsule)
        await runner.finish(failed: failed)
        try await settle { clock.deadlines.count >= 2 && model.transcriptionJobs == 0 }
        let terminal = try #require(clock.deadlines.last)
        #expect(terminal.due == clock.now + 60 && !model.capsuleDismissed)
        let previousJob = try #require(model.capsuleProgress)
        #expect(previousJob.terminal)

        model.retryRecording(recording)
        #expect(model.transcriptionState == .running(nil))
        #expect(model.capsuleProgress == nil, "Retry must not present the previous terminal job")
        try await settle { await admission.waiting && model.isAdmittingProcessing }
        #expect(model.capsuleProgress == nil)
        terminal.action()
        #expect(!model.capsuleDismissed)
        await admission.open()
        try await settle { await runner.waiting }
        await runner.emit(progress)
        try await settle { model.transcriptionState == .running(progress) && model.capsuleProgress?.current == .recognition }
        #expect(model.capsuleProgress?.jobID != previousJob.jobID)
        await runner.finish(failed: failed)
        try await settle { clock.deadlines.count >= 3 && model.transcriptionJobs == 0 }
        // Same URL, new terminal job: an older job's delivered callback cannot dismiss it.
        terminal.action()
        #expect(!model.capsuleDismissed)
        clock.advance(59)
        #expect(!model.capsuleDismissed)
        clock.advance(1)
        #expect(model.capsuleDismissed)
        // The same callback must also respect a newer capture transition / other URL.
        model.capsuleDismissed = false
        model.setSessionStartingForTesting(true)
        clock.deadlines.last?.action()
        #expect(!model.capsuleDismissed)
        model.setSessionStartingForTesting(false)
        model.lastFileURL = folder.appendingPathComponent("other.m4a")
        clock.deadlines.last?.action()
        #expect(!model.capsuleDismissed)
    }
}

private struct SyntheticSavedCapture: StoppedCaptureProtocol {
    let outputURL: URL
    let duration: Double = 10
    var fileSize = 1
    func finish() async -> RecordingResult { .init(outputURL: outputURL, duration: duration, fileSize: fileSize, warnings: []) }
}

private struct Exporter: AudioExporterProtocol {
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws {}
}
private struct Runner: TranscriptionRunnerProtocol {
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) {
        try await Task.sleep(for: .seconds(30)); return ("checked", true)
    }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        try await Task.sleep(for: .seconds(30)); return recording
    }
}
private actor DiagnosticRunner: TranscriptionRunnerProtocol {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func finish() { continuation?.resume(); continuation = nil }
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) {
        onOutput?("Проверка файла 2/10: gigaam/weights.fp16.safetensors (SHA-256)…")
        await withCheckedContinuation { continuation = $0 }
        return ("Все файлы проверены.", true)
    }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL { recording }
}
private struct Capture: AudioCaptureControllerProtocol {
    let output: URL
    var duration: TimeInterval = 15
    func startCapture() async throws {}
    func stopCapture() async throws -> AudioCaptureStopResult { .init(duration: duration, outputURL: output) }
    func setMicrophoneMuted(_ muted: Bool) {}
    func currentMicrophoneState() -> MicrophoneRecordingState { .receiving }
}
private actor HeldPresentationRunner: TranscriptionRunnerProtocol {
    private var progress: (@Sendable (TranscriptionProgress) -> Void)?
    var started: Bool { progress != nil }
    func emit(_ value: TranscriptionProgress) { progress?(value) }
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        progress = onProgress
        defer { progress = nil }
        try await Task.sleep(for: .seconds(20))
        return recording
    }
}
@MainActor private final class BufferingPresentationTransport: TranscriptPlaybackTransport {
    var onEvent: (@MainActor @Sendable (TranscriptPlaybackEvent) -> Void)?
    var pendingPlay = false
    var duration: Double = 1
    func prepare(url: URL) async throws -> Double { duration }
    func play() { pendingPlay = true }
    func pause() { pendingPlay = false; onEvent?(.playing(false)) }
    func seek(to seconds: Double) async -> Bool { true }
    func stop() { pendingPlay = false }
    func releaseBuffer() { if pendingPlay { onEvent?(.playing(true)) } }
}
@Suite @MainActor struct ProductionCompositionTests {
    @Test(arguments: [true, false])
    func librarySelectionRestoresLoadAfterSettingsReopen(sameRecording: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-reopen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = RecordingHistoryRepository()
        var recordings: [URL] = [], texts: [URL] = []
        for name in ["a", "b"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let recording = folder.appendingPathComponent(name + ".m4a")
            let text = folder.appendingPathComponent(name + ".sources.transcript.txt")
            try Data("Saved synthetic text \(name)".utf8).write(to: text)
            var entry = RecordingEntry.load(recording: recording); entry.phase = .completed
            repo.put(entry, persist: false)
            recordings.append(recording); texts.append(text)
        }
        let original = try texts.map { try Data(contentsOf: $0) }
        let suite = "library-reopen-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults)
        await model.history.synchronize()
        let initial = try #require(model.showTranscript(recordings[0]))
        #expect(await model.loadWorkspace(initial))
        #expect(model.workspace.current?.legacyText == "Saved synthetic text a")
        #expect(model.admitWindowClose(isWorkspace: true))
        #expect(!model.workspaceLoadRequest.requested)
        #expect(model.presentSettings())
        model.dismissSettings()
        model.workspaceShowsList = true
        let index = sameRecording ? 0 : 1
        model.selectLibraryRecording(recordings[index])
        let request = model.workspaceLoadRequest
        #expect(request.requested, "A visible library selection must restore the invalidated load request")
        #expect(await model.loadWorkspace(request))
        #expect(model.workspace.current?.legacyText == "Saved synthetic text \(index == 0 ? "a" : "b")")
        #expect(model.workspaceShowsList, "Arrow selection must retain the narrow library pane")
        #expect(await model.processingService.totalJobCount == 0)
        #expect(try texts.map { try Data(contentsOf: $0) } == original)
        model.workspace.closeCurrent()
    }

    @Test func librarySelectionPreservesModalAndRealDraftAdmission() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let recording = root.appendingPathComponent("meeting.m4a")
        let suite = "library-admission-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let workspace = TranscriptReviewWindowManager(transportFactory: { BufferingPresentationTransport() })
        let model = isolatedRecorderModel(workspace: workspace, defaults: defaults)
        await model.history.put(RecordingEntry.load(recording: recording), persist: false)
        let initial = try #require(model.showTranscript(recording))
        #expect(await model.loadWorkspace(initial))
        let editor = try #require(workspace.current)
        defer { model.dismissSettings(); editor.cancelTextDraft(); workspace.externalModal = false; workspace.closeCurrent() }
        let other = root.deletingLastPathComponent().appendingPathComponent("other/other.m4a")
        let request = model.workspaceLoadRequest
        #expect(model.presentSettings())
        model.selectLibraryRecording(other)
        #expect(model.workspaceLoadRequest == request && model.selectedHistoryURL == recording)
        model.dismissSettings()
        workspace.externalModal = true
        model.selectLibraryRecording(other)
        #expect(model.workspaceLoadRequest == request && model.selectedHistoryURL == recording)
        workspace.externalModal = false
        editor.openTextEditing(for: "turn_1")
        editor.updateDraftText("Keep actual draft")
        model.selectLibraryRecording(other)
        #expect(model.workspaceLoadRequest == request && model.selectedHistoryURL == recording)
        #expect(editor.activeTextDraft?.text == "Keep actual draft" && workspace.current === editor)
        #expect(await model.processingService.totalJobCount == 0)
    }

    @Test func recordingEligibilityUnderSettingsDoesNotPublishOrMutateCurrent() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let suite = "keyboard-eligibility-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let workspace = TranscriptReviewWindowManager(transportFactory: { BufferingPresentationTransport() })
        let model = isolatedRecorderModel(workspace: workspace, defaults: defaults)
        defer { model.dismissSettings(); workspace.closeCurrent() }
        model.setAttachedForTesting(session: true, processing: true)
        let recording = root.appendingPathComponent("meeting.m4a")
        await model.history.put(RecordingEntry.load(recording: recording), persist: false)
        let request = try #require(model.showTranscript(recording))
        #expect(await model.loadWorkspace(request))
        let current = try #require(workspace.current)
        model.mainPage = .recording
        #expect(model.canStartRecording)
        #expect(model.presentSettings())
        let error = current.error, notice = workspace.commandNotice
        var publications = 0
        let observer = model.objectWillChange.sink { publications += 1 }
        defer { observer.cancel() }
        for _ in 0..<4 { #expect(!model.canStartRecording) }
        #expect(publications == 0)
        #expect(current.error == error && workspace.commandNotice == notice)
    }

    @Test func settings29UnderlayCallbacksAndDraftAdmission() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("meeting.m4a")
        let repo = RecordingHistoryRepository()
        _ = repo.put(RecordingEntry.load(recording: url), persist: false)
        let suite = "settings29-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let workspace = TranscriptReviewWindowManager(transportFactory: { BufferingPresentationTransport() })
        let model = isolatedRecorderModel(historyRepository: repo, workspace: workspace, defaults: defaults)
        await model.history.synchronize()
        let request = try #require(model.showTranscript(url))
        #expect(await model.loadWorkspace(request))
        let editor = try #require(workspace.current)
        #expect(model.presentSettings())
        #expect(!(await model.loadWorkspace(request)))
        var copied = 0
        editor.copySavedText { _ in copied += 1; return true }
        editor.openTextEditing(for: "turn_1")
        editor.openSpeakerAssignment(for: "turn_1")
        editor.setPlaybackRate(2)
        #expect(copied == 0 && editor.activeTextDraft == nil && editor.activeDraft == nil && editor.playbackRate == 1)
        model.workspaceShowsList = true
        #expect(!model.workspaceShowsList)
        model.setEditorFollowing(false) // The Settings control itself remains available.
        #expect(!model.isEditorFollowing)
        model.dismissSettings()
        editor.copySavedText { _ in copied += 1; return true }
        #expect(copied == 1)
        editor.openTextEditing(for: "turn_1")
        editor.updateDraftText("Keep actual input")
        #expect(!model.presentSettings() && editor.activeTextDraft?.text == "Keep actual input")
        editor.cancelTextDraft()
        #expect(model.presentSettings())
        model.dismissSettings()
        workspace.closeCurrent()
    }

    @Test func owner22SpeakerVerbatimReopenIsNoOp() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let manager = TranscriptReviewWindowManager()
        let editor = try await manager.open(recordingURL: root.appendingPathComponent("meeting.m4a"), title: "Fixture")
        defer { editor.close(); editor.state.close() }
        editor.openSpeakerAssignment(for: "turn_1")
        editor.updateDraftName(" Алиса ")
        editor.confirmGroupAssignment(confirmation: try #require(editor.activeDraft?.pendingConfirmation))
        let edits = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/edits.json")
        let saved = try Data(contentsOf: edits)
        editor.openSpeakerAssignment(for: "turn_1")
        #expect(editor.activeDraft?.inputName == " Алиса ")
        #expect(editor.activeDraft?.pendingConfirmation?.affectedTurnsCount == 0)
        #expect(editor.activeDraft?.pendingConfirmation?.willReplaceManual == false)
        #expect(try Data(contentsOf: edits) == saved)
    }
    @Test(arguments: ["text", "speaker"])
    func solRepairOpeningEditorCancelsBufferedPlayIntent(kind: String) async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        // A contained file admits the actual controller; synthetic transport never decodes/plays it.
        try Data([0]).write(to: root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/mix.m4a"))
        let state = try await TranscriptWindowCoordinator().openWindow(for: root.appendingPathComponent("meeting.m4a")).state
        let transport = BufferingPresentationTransport()
        let editor = try await TranscriptReviewWindowModel(state: state, transportFactory: { transport })
        defer { editor.close(); state.close() }
        for _ in 0..<500 { if editor.playbackState == .ready { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(editor.playbackState == .ready)
        editor.togglePlayback()
        #expect(transport.pendingPlay && editor.playbackState == .ready)
        if kind == "text" { editor.openTextEditing(for: "turn_1") }
        else { editor.openSpeakerAssignment(for: "turn_1") }
        #expect(!transport.pendingPlay)
        transport.releaseBuffer()
        #expect(editor.playbackState == .ready && !editor.follow.isFollowing)
        #expect(editor.activeTextDraft != nil || editor.activeDraft != nil)
    }
    @Test func solRepairMissingCurrentMixSettlesWaveformAndKeepsEditor() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let state = try await TranscriptWindowCoordinator().openWindow(for: root.appendingPathComponent("meeting.m4a")).state
        let editor = try await TranscriptReviewWindowModel(state: state)
        defer { editor.close(); state.close() }
        for _ in 0..<500 {
            if editor.playbackState == .failed { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(editor.playbackState == .failed)
        #expect(editor.waveform == nil && editor.waveformMessage == nil)
        #expect(editor.playbackMessage?.contains("отсутствует, повреждён или недоступен") == true)
        #expect(editor.currentResultID == "res_valid_parakeet_off" && !editor.rows.isEmpty)
        editor.openTextEditing(for: "turn_1")
        #expect(editor.activeTextDraft != nil && !state.isClosed)
    }

    @Test func solRepairProcessingSnapshotsKeepCustomDisplayTitle() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try sources(in: root)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.deletingLastPathComponent().path, forKey: "recordingsDirectory")
        defaults.set([String](), forKey: "meetingCalendarIDs")
        let repo = RecordingHistoryRepository()
        let runner = HeldPresentationRunner()
        let processing = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter(), historyRepository: repo)
        let url = root.appendingPathComponent("meeting.m4a")
        var entry = RecordingEntry(recording: url, date: Date(), title: "Raw calendar title", phase: .failed)
        entry.displayTitle = "Custom display title"
        try repo.putThrowing(entry)
        let model = isolatedRecorderModel(processingService: processing, historyRepository: repo,
            defaults: defaults, startBackgroundServices: false)
        await model.history.synchronize()
        for _ in 0..<500 { if model.isAttached { break }; try await Task.sleep(for: .milliseconds(1)) }
        for _ in 0..<2 { // ordinary enqueue and subsequent retry use the same production snapshots
            let job = await processing.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false))
            for _ in 0..<500 { if await runner.started { break }; try await Task.sleep(for: .milliseconds(1)) }
            let progress = TranscriptionProgress(stage: .gigaam, completed: 1, total: 3)
            await runner.emit(progress)
            for _ in 0..<500 {
                if model.history.progress[url] == progress { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            for _ in 0..<20 { await Task.yield() }
            #expect(model.transcriptionJobs == 1 && model.lastFileURL == url)
            #expect(model.history.progress[url] == progress)
            #expect(model.lastRecordingTitle == "Custom display title")
            #expect(repo.entry(url)?.title == "Raw calendar title" && repo.entry(url)?.displayTitle == "Custom display title")
            await processing.cancel(jobID: job.id)
            for _ in 0..<500 { if model.transcriptionJobs == 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        }
    }

    @Test func solSpeakerLivePreviewNeverWritesAndOnlyFreshConfirmCommits() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let manager = TranscriptReviewWindowManager()
        let editor = try await manager.open(recordingURL: root.appendingPathComponent("meeting.m4a"), title: "Fixture")
        defer { editor.close(); editor.state.close() }
        let url = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/edits.json")
        let before = try? Data(contentsOf: url)
        editor.openSpeakerAssignment(for: "turn_1")
        editor.updateDraftName("Первое имя")
        let old = try #require(editor.activeDraft?.pendingConfirmation, "Typing must produce live preview")
        editor.selectDraftScope(.allVoiceGroup)
        let group = try #require(editor.activeDraft?.pendingConfirmation)
        #expect(group.preview != nil && group.id != old.id)
        editor.selectCalendarAttendee("Другое имя")
        let fresh = try #require(editor.activeDraft?.pendingConfirmation)
        #expect(fresh.confirmedName == "Другое имя" && fresh.id != group.id)
        #expect((try? Data(contentsOf: url)) == before)
        editor.confirmGroupAssignment(confirmation: old)
        #expect((try? Data(contentsOf: url)) == before && editor.activeDraft != nil)
        editor.confirmGroupAssignment(confirmation: fresh)
        #expect((try? Data(contentsOf: url)) != before && editor.activeDraft == nil)
        editor.openSpeakerAssignment(for: "turn_1")
        #expect(editor.activeDraft?.pendingConfirmation?.affectedTurnsCount == 0)
        editor.selectDraftScope(.allVoiceGroup)
        #expect(editor.activeDraft?.pendingConfirmation?.affectedTurnsCount == 0)
        editor.updateDraftName("   ")
        #expect(editor.activeDraft?.pendingConfirmation == nil && editor.activeDraft?.inputName == "   ")
    }
    @Test func solSingleTurnPreviewReportsNoOpAndReplacement() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let state = try await TranscriptWindowCoordinator().openWindow(for: root.appendingPathComponent("meeting.m4a")).state
        let editor = try await TranscriptReviewWindowModel(state: state)
        defer { editor.close(); state.close() }
        for name in ["Имя", "Имя", "Другое имя"] {
            editor.openSpeakerAssignment(for: "turn_1")
            editor.updateDraftName(name)
            editor.saveSpeakerAssignment()
            let preview = try #require(editor.activeDraft?.pendingConfirmation)
            let previous = editor.rows.first { $0.id == "turn_1" }!
            #expect(preview.affectedTurnsCount == (previous.hasManualName && previous.name == name ? 0 : 1))
            #expect(preview.willReplaceManual == (previous.hasManualName && previous.name != name))
            editor.confirmGroupAssignment(confirmation: preview)
        }
    }

    @Test func remainingScopeKeepsProtectedNameWithoutExplicitReplacement() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let state = try await TranscriptWindowCoordinator().openWindow(for: root.appendingPathComponent("meeting.m4a")).state
        let session = try #require(state.session)
        _ = try session.assignSpeakerName(turnID: "turn_1", displayName: "Сохранённое имя")
        let editor = try await TranscriptReviewWindowModel(state: state)
        defer { editor.close(); state.close() }

        editor.openSpeakerAssignment(for: "turn_1")
        editor.updateDraftName("Новое имя")
        editor.selectDraftScope(.allVoiceGroup)
        let preview = try #require(editor.activeDraft?.pendingConfirmation?.preview)
        #expect(preview.affectedTurnIDs.isEmpty)
        #expect(preview.replacedTurnIDs == ["turn_1"])
        #expect(preview.replacedManualAssignmentsCount == 0)
        let draftID = try #require(editor.activeDraft?.id)
        editor.setDraftReplaceManual(true, draftID: draftID)
        let replacement = try #require(editor.activeDraft?.pendingConfirmation)
        #expect(replacement.preview?.affectedTurnIDs == ["turn_1"])
        #expect(replacement.willReplaceManual)
        editor.confirmGroupAssignment(confirmation: replacement)
        #expect(editor.rows.first { $0.id == "turn_1" }?.name == "Новое имя")
    }
    @Test(arguments: ["one", "remaining"])
    func solSpeakerRecheckNeverCommits(scope: String) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let manager = TranscriptReviewWindowManager()
        let editor = try await manager.open(recordingURL: root.appendingPathComponent("meeting.m4a"), title: "Fixture")
        defer { editor.close(); editor.state.close() }
        let url = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/edits.json")
        let before = try? Data(contentsOf: url)
        var saved = 0
        editor.onSaved = { saved += 1 }
        editor.openSpeakerAssignment(for: "turn_1")
        editor.updateDraftName("Новое имя")
        if scope == "remaining" { editor.selectDraftScope(.allVoiceGroup) }
        editor.saveSpeakerAssignment()
        let first = try #require(editor.activeDraft?.pendingConfirmation)
        editor.saveSpeakerAssignment() // historical preview-only entry point; normal UI now recomputes live
        #expect((try? Data(contentsOf: url)) == before)
        #expect(saved == 0 && editor.activeDraft != nil)
        let fresh = try #require(editor.activeDraft?.pendingConfirmation)
        #expect(fresh.id != first.id)
        editor.confirmGroupAssignment(confirmation: first)
        #expect((try? Data(contentsOf: url)) == before)
        editor.confirmGroupAssignment(confirmation: fresh)
        #expect(saved == 1 && editor.activeDraft == nil)
        #expect((try? Data(contentsOf: url)) != before)
    }
    @Test(arguments: ["text", "speaker", "rename"])
    func repair3HostCommandPresentsInputWithoutLoading(input: String) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("meeting.m4a")
        let repo = RecordingHistoryRepository()
        _ = repo.put(RecordingEntry.load(recording: url), persist: false)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)
        await model.history.synchronize(); model.selectedHistoryURL = url
        var loads: [RecorderViewModel.WorkspaceLoadRequest] = []
        var presentations = 0
        // The actual status/Dock/rejected-quit command supplies native callbacks here.
        RecorderAppDelegate.showWorkspace(model, load: { loads.append($0) }, present: { presentations += 1 })
        #expect(presentations == 1 && loads.count == 1)
        await model.loadWorkspace(try #require(loads.first))
        let editor = try #require(model.workspace.current)
        let session = try #require(editor.state.session)
        defer {
            model.workspace.externalModal = false
            editor.cancelTextDraft(); editor.cancelDraft()
            _ = model.admitWindowClose(isWorkspace: true)
        }
        switch input {
        case "text": editor.openTextEditing(for: "turn_1"); editor.updateDraftText("KEEP TEXT INPUT")
        case "speaker": editor.openSpeakerAssignment(for: "turn_1"); editor.updateDraftName("KEEP NAME INPUT")
        default: model.workspace.externalModal = true // same flag held by the existing rename sheet
        }
        let key = model.workspaceLoadRequest
        let textDraft = editor.activeTextDraft, nameDraft = editor.activeDraft
        let playback = editor.playbackState
        let mainRequested = model.mainWindowRequested
        #expect(model.workspace.hasInput)
        RecorderAppDelegate.showWorkspace(model, load: { loads.append($0) }, present: { presentations += 1 })
        #expect(presentations == 2)
        #expect(loads.count == 1)
        #expect(model.workspaceLoadRequest == key && model.selectedHistoryURL == url)
        #expect(model.mainWindowRequested == mainRequested)
        #expect(model.workspace.current === editor && editor.state.session === session && !session.isClosed)
        #expect(editor.activeTextDraft == textDraft && editor.activeDraft == nameDraft)
        #expect(model.workspace.externalModal == (input == "rename"))
        #expect(editor.playbackState == playback && model.workspace.hasInput)
    }

    @Test func repair2HostReopenAndHiddenRefreshUseProductionRequest() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("meeting.m4a")
        let repo = RecordingHistoryRepository()
        _ = repo.put(RecordingEntry.load(recording: url), persist: false)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = isolatedRecorderModel(historyRepository: repo, defaults: defaults, startBackgroundServices: false)
        await model.history.synchronize()
        model.selectedHistoryURL = url
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let bytes = try Dictionary(uniqueKeysWithValues: files.map { ($0, try Data(contentsOf: $0)) })
        let initial = try #require(model.requestWorkspaceOpen()) // same command called by status/Dock showWindow
        let initialPhase = try #require(initial.phase)
        await model.loadWorkspace(initial) // same loader/key as host task
        let old = try #require(model.workspace.current)
        let oldSession = try #require(old.state.session)
        old.openTextEditing(for: "turn_1"); old.updateDraftText("KEEP HOST INPUT")
        #expect(!model.admitWindowClose(isWorkspace: true))
        #expect(model.requestWorkspaceOpen() == nil)
        #expect(model.workspace.current === old && old.activeTextDraft?.text == "KEEP HOST INPUT")
        old.cancelTextDraft()
        #expect(model.admitWindowClose(isWorkspace: false))
        #expect(model.workspace.current === old)
        #expect(model.admitWindowClose(isWorkspace: true))
        let closed = model.workspaceLoadRequest
        #expect(closed != initial)
        #expect(oldSession.isClosed && old.playbackState == .closed)
        await model.loadWorkspace(initial) // stale already scheduled task after close
        #expect(model.workspace.current == nil)
        for jobs in [1, 2, 0] {
            model.transcriptionJobs = jobs // field updated by production processing snapshot route
            var entry = try #require(repo.entry(url)); entry.phase = jobs == 0 ? initialPhase : .interrupted
            _ = repo.put(entry, persist: false)
            await model.history.synchronize()
            await model.loadWorkspace(model.workspaceLoadRequest) // background phase/job key update while retained host is hidden
            #expect(model.workspace.current == nil && model.workspace.coordinator.openWindows.isEmpty)
            #expect(old.state.isClosed && old.playbackState == .closed)
        }
        let reopenedRequest = try #require(model.requestWorkspaceOpen())
        #expect(reopenedRequest != initial && reopenedRequest != closed)
        #expect(reopenedRequest.url == initial.url && reopenedRequest.phase == initial.phase && reopenedRequest.jobs == initial.jobs)
        await model.loadWorkspace(reopenedRequest)
        let reopened = try #require(model.workspace.current)
        #expect(reopened !== old && !reopened.state.isReadOnly && reopened.state.session !== oldSession)
        #expect(model.selectedHistoryURL == url)
        await model.loadWorkspace(initial) // superseded host task cannot replace the reopened session
        #expect(model.workspace.current === reopened)
        #expect(model.admitWindowClose(isWorkspace: true))
        for (file, data) in bytes { #expect(try Data(contentsOf: file) == data) }
    }

    @Test func repair2HostCloseRejectsAlreadyAdmittedLoad() async throws {
        actor Gate {
            var resume: CheckedContinuation<Void, Never>?
            let entered: AsyncStream<Void>.Continuation
            init(_ entered: AsyncStream<Void>.Continuation) { self.entered = entered }
            func check() async -> Bool { await withCheckedContinuation { resume = $0; entered.yield(()) }; return false }
            func release() { resume?.resume(); resume = nil }
        }
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("meeting.m4a")
        let repo = RecordingHistoryRepository(); _ = repo.put(RecordingEntry.load(recording: url), persist: false)
        let (entered, continuation) = AsyncStream<Void>.makeStream(); let gate = Gate(continuation)
        let workspace = TranscriptReviewWindowManager(isProcessing: { _ in await gate.check() })
        let suite = UUID().uuidString; let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = isolatedRecorderModel(historyRepository: repo, workspace: workspace, defaults: defaults, startBackgroundServices: false)
        await model.history.synchronize(); model.selectedHistoryURL = url
        let request = try #require(model.requestWorkspaceOpen())
        let pending = Task { await model.loadWorkspace(request) }
        for await _ in entered { break }
        #expect(model.admitWindowClose(isWorkspace: true))
        await gate.release(); await pending.value
        #expect(workspace.current == nil && workspace.coordinator.openWindows.isEmpty)
    }

    @Test func repairMainCloseRouteDisposesReviewOnlyAfterCancel() async throws {
        let root = try fixtureRoot(), captureRoot = try fixtureRoot(), jobRoot = try fixtureRoot()
        defer {
            for folder in [root, captureRoot, jobRoot] { try? FileManager.default.removeItem(at: folder) }
        }
        try published("res_valid_parakeet_off", in: root)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = RecordingHistoryRepository()
        let captureService = RecordingSessionService(historyRepo: repository)
        let processing = ProcessingService(transcriptionRunner: Runner(), audioExporter: Exporter(), historyRepository: repository)
        let captureURL = captureRoot.appendingPathComponent("meeting.m4a")
        _ = try await captureService.start(controller: Capture(output: captureURL), outputURL: captureURL)
        try sources(in: jobRoot)
        let jobURL = jobRoot.appendingPathComponent("meeting.m4a")
        _ = repository.put(RecordingEntry.load(recording: jobURL))
        let job = await processing.enqueue(recordingURL: jobURL, settings: .init(parakeet: false, echoCancellation: false))
        let model = isolatedRecorderModel(sessionService: captureService, processingService: processing, historyRepository: repository, defaults: defaults, startBackgroundServices: false)
        let url = root.appendingPathComponent("meeting.m4a")
        let editor = try await model.workspace.open(recordingURL: url, title: "Current")
        let session = try #require(editor.state.session)
        editor.openTextEditing(for: try #require(editor.rows.first?.id))
        #expect(model.admitWindowClose(isWorkspace: false))
        #expect(!model.admitWindowClose(isWorkspace: true))
        #expect(!editor.state.isClosed && editor.activeTextDraft != nil)
        editor.cancelTextDraft()
        #expect(model.admitWindowClose(isWorkspace: false))
        #expect(model.workspace.current === editor)
        #expect(model.admitWindowClose(isWorkspace: true))
        #expect(editor.state.isClosed && session.isClosed && editor.playbackState == .closed)
        #expect(model.workspace.current == nil && model.workspace.coordinator.openWindows.isEmpty)
        let reopened = try await model.workspace.open(recordingURL: url, title: "Fresh")
        #expect(reopened !== editor && reopened.state.session !== session && !reopened.state.isReadOnly)
        model.workspace.closeCurrent()
        #expect(await captureService.isRecording)
        #expect(await processing.isProcessing(recordingURL: jobURL))
        await processing.cancel(jobID: job.id)
        _ = try await captureService.stop(elapsed: 15, expectedSessionID: (await captureService.currentSnapshot).sessionID)
    }

    @Test(arguments: ["close", "newOpen", "modal", "stateClose"])
    func repairFinalProcessingAwaitRejectsStalePublish(action: String) async throws {
        actor Gate {
            var calls = 0
            var resume: CheckedContinuation<Void, Never>?
            let entered: AsyncStream<Void>.Continuation
            init(_ entered: AsyncStream<Void>.Continuation) { self.entered = entered }
            func check() async -> Bool {
                calls += 1
                if calls == 2 { await withCheckedContinuation { resume = $0; entered.yield(()) } }
                return false
            }
            func release() { resume?.resume(); resume = nil }
        }
        let root = try fixtureRoot(), other = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        try published("res_valid_parakeet_off", in: root); try published("res_valid_parakeet_off", in: other)
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let gate = Gate(continuation)
        let manager = TranscriptReviewWindowManager(isProcessing: { _ in await gate.check() })
        let first = Task { try? await manager.open(recordingURL: root.appendingPathComponent("meeting.m4a"), title: "Old") }
        for await _ in entered { break }
        let unpublished = try #require(manager.coordinator.openWindows.values.first)
        let session = try #require(unpublished.session)
        var newer: Task<TranscriptReviewWindowModel?, Never>?
        switch action {
        case "close": manager.closeCurrent()
        case "stateClose": unpublished.close()
        case "newOpen":
            newer = Task { try? await manager.open(recordingURL: other.appendingPathComponent("meeting.m4a"), title: "New") }
            // The injected status check gives an explicit event before the newer request waits for the old one.
            while await gate.calls < 3 { await Task.yield() }
        default: manager.externalModal = true
        }
        await gate.release()
        let old = await first.value
        _ = await newer?.value
        #expect(old == nil)
        #expect(unpublished.isClosed && session.isClosed)
        if action == "newOpen" { #expect(manager.current?.state.recordingURL == other.appendingPathComponent("meeting.m4a")) }
        else { #expect(manager.current == nil) }
        manager.externalModal = false; manager.closeCurrent()
    }

    @Test func repairHostAdmitsNarrowWorkspace() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = AppWindowState()
        host.attach(window)
        #expect(window.minSize.width < 760 && window.minSize.width >= 480)
        #expect(!window.isVisible)
    }

    @Test func repairExplicitOpenShowsNarrowDetailIncludingSameSelection() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)
        let url = root.appendingPathComponent("meeting.m4a")
        model.selectedHistoryURL = url // initial auto-selection leaves library visible
        #expect(model.workspaceShowsList)
        model.showTranscript(url) // shared command used by capsule and explicit AppDelegate open
        #expect(!model.workspaceShowsList && model.selectedHistoryURL == url && model.mainWindowRequested)
        model.workspaceShowsList = true // normal narrow back
        model.showTranscript(url)
        #expect(!model.workspaceShowsList)
        model.workspaceShowsList = true
        model.workspace.externalModal = true
        model.showTranscript(root.appendingPathComponent("other.m4a"))
        #expect(model.workspaceShowsList && model.selectedHistoryURL == url)
    }

    @Test func repairSearchDistinguishesMissingFromStatFailure() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("flat")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let entry = RecordingEntry.load(recording: parent.appendingPathComponent("meeting.m4a"))
        let missing = await Task.detached { RecordingSearch.scan(query: "missing", entries: [entry]) }.value
        #expect(missing.matches.isEmpty && missing.failures.isEmpty)
        try FileManager.default.removeItem(at: parent)
        try Data("synthetic non-directory parent".utf8).write(to: parent)
        let failed = await Task.detached { RecordingSearch.scan(query: "missing", entries: [entry]) }.value
        #expect(failed.matches.isEmpty && failed.failures.count == 1)
    }

    @Test(arguments: ["text", "name"])
    func repairExportAndCopyUseSavedSnapshotWithLiveDraft(draftKind: String) async throws {
        let root = try fixtureRoot(), output = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: output) }
        try published("res_valid_parakeet_off", in: root)
        let manager = TranscriptReviewWindowManager()
        let editor = try await manager.open(recordingURL: root.appendingPathComponent("meeting.m4a"), title: "Saved export")
        editor.openTextEditing(for: "turn_1"); editor.updateDraftText("SAVED VERBATIM TEXT"); editor.saveTextEditing()
        editor.openSpeakerAssignment(for: "turn_1"); editor.updateDraftName("SAVED NAME"); editor.saveSpeakerAssignment(); editor.confirmGroupAssignment()
        let editsURL = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/edits.json")
        let savedBytes = try Data(contentsOf: editsURL)
        if draftKind == "text" { editor.openTextEditing(for: "turn_1"); editor.updateDraftText("LIVE DRAFT NEVER EXPORTED") }
        else { editor.openSpeakerAssignment(for: "turn_1"); editor.updateDraftName("LIVE DRAFT NEVER EXPORTED") }
        let identity = editor.currentDraftIdentity
        let target = output.appendingPathComponent("saved.txt")
        editor.requestExport(savePanelRunner: { _, completion in completion(.OK, target) })
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text.contains("SAVED VERBATIM TEXT") && text.contains("SAVED NAME") && !text.contains("LIVE DRAFT"))
        #expect(editor.currentDraftIdentity == identity && editor.exportNotice?.contains("черновик исключён") == true)
        var copied: String?
        editor.copySavedText { copied = $0; return true }
        #expect(copied == text)
        editor.copySavedText { _ in false }
        #expect(editor.error != nil)
        #expect(editor.currentDraftIdentity == identity)
        #expect(try Data(contentsOf: editsURL) == savedBytes)
        editor.cancelTextDraft(); editor.cancelDraft()
        var frozenCompletion: ((NSApplication.ModalResponse, URL?) -> Void)?
        editor.requestExport(savePanelRunner: { _, completion in frozenCompletion = completion })
        editor.openTextEditing(for: "turn_1"); editor.updateDraftText("NEWER SAVED TEXT"); editor.saveTextEditing()
        let frozenTarget = output.appendingPathComponent("frozen.txt")
        frozenCompletion?(.OK, frozenTarget)
        let frozen = try String(contentsOf: frozenTarget, encoding: .utf8)
        #expect(frozen.contains("SAVED VERBATIM TEXT") && !frozen.contains("NEWER SAVED TEXT"))
        #expect(editor.rows.first?.text == "NEWER SAVED TEXT")
        manager.closeCurrent()
    }

    @Test func repairExportRequestIdentityCancelFailuresAndProtectedWrites() async throws {
        let root = try fixtureRoot(), output = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: output) }
        try published("res_valid_parakeet_off", in: root)
        let manager = TranscriptReviewWindowManager()
        let recording = root.appendingPathComponent("meeting.m4a")
        let editor = try await manager.open(recordingURL: recording, title: "Export identity")
        let cancelled = output.appendingPathComponent("cancelled.txt")
        editor.requestExport(savePanelRunner: { _, completion in completion(.cancel, cancelled) })
        #expect(editor.activeExportRequest == nil && editor.error == nil && !FileManager.default.fileExists(atPath: cancelled.path))
        var old: ((NSApplication.ModalResponse, URL?) -> Void)?, current: ((NSApplication.ModalResponse, URL?) -> Void)?
        editor.requestExport(savePanelRunner: { _, completion in old = completion })
        let oldID = editor.activeExportRequest?.id
        editor.requestExport(savePanelRunner: { _, completion in current = completion })
        #expect(editor.activeExportRequest?.id != oldID)
        let stale = output.appendingPathComponent("stale.txt"), target = output.appendingPathComponent("current.txt")
        old?(.OK, stale)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        current?(.OK, target)
        #expect(editor.error == nil && editor.activeExportRequest == nil && FileManager.default.fileExists(atPath: target.path))
        try Data("double callback sentinel".utf8).write(to: target)
        current?(.OK, target)
        #expect(try Data(contentsOf: target) == Data("double callback sentinel".utf8))
        editor.requestExport(savePanelRunner: { _, completion in old = completion })
        let result = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/result.json")
        let original = try Data(contentsOf: result)
        try FileManager.default.removeItem(at: result)
        editor.requestExport(savePanelRunner: { _, _ in Issue.record("Failed preparation must not open panel") })
        #expect(editor.error != nil && editor.activeExportRequest == nil)
        try original.write(to: result)
        old?(.OK, stale)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let failed = output.appendingPathComponent("absent-parent/failed.txt")
        editor.requestExport(savePanelRunner: { _, completion in completion(.OK, failed) })
        #expect(editor.error != nil && editor.activeExportRequest == nil && !FileManager.default.fileExists(atPath: failed.path))
        #expect(editor.exportNotice?.contains("успешно") != true)
        let source = root.appendingPathComponent("raw/meeting.host_record.wav")
        try Data("synthetic source sentinel".utf8).write(to: source)
        editor.openTextEditing(for: "turn_1"); editor.updateDraftText("Saved protected"); editor.saveTextEditing()
        let edits = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/edits.json")
        for protected in [result, edits, source] {
            let before = try Data(contentsOf: protected)
            editor.requestExport(savePanelRunner: { _, completion in completion(.OK, protected) }, overwriteConsentHandler: { _ in true })
            #expect(editor.error != nil)
            #expect(try Data(contentsOf: protected) == before)
        }
        editor.requestExport(savePanelRunner: { _, completion in old = completion })
        manager.closeCurrent()
        let fresh = try await manager.open(recordingURL: recording, title: "Fresh")
        old?(.OK, stale)
        #expect(fresh !== editor && !FileManager.default.fileExists(atPath: stale.path))
        var late: ((NSApplication.ModalResponse, URL?) -> Void)?
        fresh.requestExport(savePanelRunner: { _, completion in late = completion })
        manager.closeCurrent(); late?(.OK, stale)
        #expect(!FileManager.default.fileExists(atPath: stale.path) && !fresh.canExport)
    }

    @Test func repairExportOverwriteConsentBindsTargetAndRevalidatesReentrancy() async throws {
        let root = try fixtureRoot(), output = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: output) }
        try published("res_valid_parakeet_off", in: root)
        let manager = TranscriptReviewWindowManager()
        let recording = root.appendingPathComponent("meeting.m4a")
        let editor = try await manager.open(recordingURL: recording, title: "Consent")
        let target = output.appendingPathComponent("existing.txt")
        let sentinel = Data("EXISTING FILE".utf8)
        try sentinel.write(to: target)
        var asked: URL?
        editor.requestExport(savePanelRunner: { _, completion in completion(.OK, target) }, overwriteConsentHandler: { asked = $0; return false })
        #expect(asked == target.standardizedFileURL && editor.activeExportRequest == nil)
        #expect(try Data(contentsOf: target) == sentinel)
        editor.requestExport(savePanelRunner: { _, completion in completion(.OK, target) }, overwriteConsentHandler: { $0 == target.standardizedFileURL })
        #expect(editor.error == nil)
        #expect(try Data(contentsOf: target) != sentinel)
        try sentinel.write(to: target)
        var replacement: ((NSApplication.ModalResponse, URL?) -> Void)?
        editor.requestExport(savePanelRunner: { _, completion in completion(.OK, target) }, overwriteConsentHandler: { _ in
            editor.requestExport(savePanelRunner: { _, completion in replacement = completion })
            return true
        })
        #expect(editor.activeExportRequest != nil)
        #expect(try Data(contentsOf: target) == sentinel)
        let replacementTarget = output.appendingPathComponent("replacement.txt")
        replacement?(.OK, replacementTarget)
        #expect(FileManager.default.fileExists(atPath: replacementTarget.path))
        editor.requestExport(savePanelRunner: { _, completion in completion(.OK, target) }, overwriteConsentHandler: { _ in manager.closeCurrent(); return true })
        #expect(editor.state.isClosed)
        #expect(try Data(contentsOf: target) == sentinel)
    }

    @Test func workspaceModalRejectsCloseWithoutDeferredPrompt() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let state = try await TranscriptWindowCoordinator().openWindow(for: root.appendingPathComponent("meeting.m4a")).state
        let editor = try await TranscriptReviewWindowModel(state: state)
        editor.openTextEditing(for: try #require(editor.rows.first?.id))
        editor.updateDraftText("Keep this draft")
        var authorized = false
        var rejected = false
        editor.requestWindowClose(onAuthorizedClose: { authorized = true }, onCancelled: { rejected = true })
        #expect(!authorized && rejected)
        #expect(editor.activeTextDraft?.text == "Keep this draft")
        editor.cancelTextDraft()
        editor.requestWindowClose(onAuthorizedClose: { authorized = true })
        #expect(authorized)
        editor.close(); state.close()
    }

    @Test func workspaceSearchReadsSavedEditsAndReportsReadErrors() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let recording = root.appendingPathComponent("meeting.m4a")
        let repo = TranscriptEditsRepository(recordingDirectory: root)
        _ = try repo.saveTurnOverride(resultID: "res_valid_parakeet_off", turnID: "turn_1", text: "Особенный сохранённый текст", displayName: "Уникальное имя")
        repo.releaseWriteLock()
        let entry = RecordingEntry.load(recording: recording)
        let textResult = await Task.detached { RecordingSearch.scan(query: "особенный", entries: [entry]) }.value
        #expect(textResult.matches.map(\.id) == [recording])
        let nameResult = await Task.detached { RecordingSearch.scan(query: "уникальное", entries: [entry]) }.value
        #expect(nameResult.matches.count == 1)
        try Data("broken".utf8).write(to: root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/edits.json"))
        let failed = await Task.detached { RecordingSearch.scan(query: "missing", entries: [entry]) }.value
        #expect(failed.matches.isEmpty)
        #expect(failed.failures.count == 1)
    }

    @Test func workspaceSearchRejectsOlderGeneration() async throws {
        let search = RecordingSearch(scan: { query, _ in
            if query == "old" { try? await Task.sleep(for: .milliseconds(80)) }
            return .init(matches: [], failures: [query])
        })
        let old = Task { await search.update(query: "old", entries: []) }
        await Task.yield()
        await search.update(query: "new", entries: [])
        await old.value
        #expect(search.result.failures == ["new"])
    }

    @Test func workspaceOwnsOneSessionAndBlocksProgrammaticCommands() async throws {
        let root = try fixtureRoot(); let other = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        try published("res_valid_parakeet_off", in: root); try published("res_valid_parakeet_off", in: other)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)
        let url = root.appendingPathComponent("meeting.m4a")
        model.selectedHistoryURL = url
        let editor = try await model.workspace.open(recordingURL: url, title: "Current")
        let same = try await model.workspace.open(recordingURL: url, title: "Again")
        #expect(editor === same)
        editor.openTextEditing(for: try #require(editor.rows.first?.id))
        model.mainPage = .recording; model.selectedHistoryURL = other.appendingPathComponent("meeting.m4a")
        _ = await FullRecorderView(viewModel: model, showSettings: {}).recordingAction.perform()
        model.startMeeting(nil, expectedSessionID: nil); model.retryRecording(url)
        #expect(model.mainPage == .history && model.selectedHistoryURL == url)
        #expect(model.preventsTermination && !model.isRecording)
        #expect(await model.processingService.totalJobCount == 0)
        #expect(!(await model.workspace.prepareForRetry(url)))
        await #expect(throws: Error.self) { try await model.workspace.open(recordingURL: other.appendingPathComponent("meeting.m4a"), title: "Blocked") }
        #expect(editor.activeTextDraft != nil)
        editor.cancelTextDraft()
        _ = try await model.workspace.open(recordingURL: other.appendingPathComponent("meeting.m4a"), title: "Next")
        #expect(editor.state.isClosed && editor.state.session == nil)
        #expect(model.workspace.coordinator.openWindows.count == 1)
        model.workspace.closeCurrent()
    }

    @Test func workspaceLateOpenCannotReplaceNewSelection() async throws {
        let first = try fixtureRoot(); let second = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try published("res_valid_parakeet_off", in: first); try published("res_valid_parakeet_off", in: second)
        let a = first.appendingPathComponent("meeting.m4a"), b = second.appendingPathComponent("meeting.m4a")
        let manager = TranscriptReviewWindowManager(isProcessing: { url in
            if url == a { try? await Task.sleep(for: .milliseconds(80)) }; return false
        })
        let old = Task { try? await manager.open(recordingURL: a, title: "Old") }
        await Task.yield()
        _ = try await manager.open(recordingURL: b, title: "New")
        _ = await old.value
        #expect(manager.current?.state.id == b)
        #expect(manager.coordinator.openWindows.count == 1)
        manager.closeCurrent()
    }

    @Test func workspaceCloseInvalidatesPendingOpen() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let manager = TranscriptReviewWindowManager(isProcessing: { _ in
            continuation.yield(())
            try? await Task.sleep(for: .milliseconds(80))
            return false
        })
        let opening = Task { try? await manager.open(recordingURL: root.appendingPathComponent("meeting.m4a"), title: "Closing") }
        for await _ in entered { break }
        manager.closeCurrent()
        _ = await opening.value
        #expect(manager.current == nil)
        #expect(manager.coordinator.openWindows.isEmpty)
        #expect(!manager.loading)
    }

    @Test func workspaceSyntheticEightHourTextReopensWithoutAudioOrModels() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let resultURL = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/result.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
        var words: [[String: Any]] = [], baseline: [[String: Any]] = [], turns: [[String: Any]] = []
        for n in 0..<5760 {
            let speaker = n.isMultiple(of: 2) ? "spk_h1" : "spk_r1"
            let start = Double(n * 5)
            words.append(["id": "w\(n)", "speakerID": speaker, "start": start, "end": start + 4, "text": "Синтетическая реплика \(n)"])
            baseline.append(["id": "b\(n)", "speakerID": speaker, "start": start, "end": start + 4, "text": "Синтетическая реплика \(n)"])
            turns.append(["id": "t\(n)", "speakerID": speaker, "start": start, "end": start + 4, "wordIDs": ["w\(n)"]])
        }
        json["words"] = words; json["baselineWords"] = baseline; json["turns"] = turns
        json["playback"] = ["status": "unavailable", "mixPath": NSNull()]
        json["warnings"] = [["code": "playback_mix_failed", "sourceID": NSNull(), "message": "Synthetic no audio"]]
        try JSONSerialization.data(withJSONObject: json).write(to: resultURL)
        let original = try Data(contentsOf: resultURL)
        let manager = TranscriptReviewWindowManager()
        let clock = ContinuousClock(); let start = clock.now
        let model = try await manager.open(recordingURL: root.appendingPathComponent("meeting.m4a"), title: "8h synthetic")
        let elapsed = start.duration(to: clock.now)
        print("W08 synthetic 5760 turns open: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(model.rows.count == 5760 && model.rows.last?.start == 28795)
        model.openTextEditing(for: "t5759"); model.updateDraftText("Последняя сохранённая реплика"); model.saveTextEditing()
        #expect(model.activeTextDraft == nil)
        manager.closeCurrent()
        let reopened = try await manager.open(recordingURL: root.appendingPathComponent("meeting.m4a"), title: "8h reopen")
        #expect(reopened.rows.last?.text == "Последняя сохранённая реплика")
        #expect(try Data(contentsOf: resultURL) == original)
        manager.closeCurrent()
    }

    @Test func workspaceFlatSearchReadsOnlyOwnContainedTXT() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let flatURL = root.appendingPathComponent("neighbour.m4a")
        let txt = root.appendingPathComponent("neighbour.sources.transcript.txt")
        try Data("Собственный сохранённый TXT".utf8).write(to: txt)
        let flat = RecordingEntry.load(recording: flatURL)
        let own = await Task.detached { RecordingSearch.scan(query: "собственный", entries: [flat]) }.value
        #expect(own.matches.count == 1 && own.failures.isEmpty)
        let shared = await Task.detached { RecordingSearch.scan(query: "Добрый", entries: [flat]) }.value
        #expect(shared.matches.isEmpty)
        try FileManager.default.removeItem(at: txt)
        try FileManager.default.createSymbolicLink(at: txt, withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("missing-outside.txt"))
        let failed = await Task.detached { RecordingSearch.scan(query: "missing", entries: [flat]) }.value
        #expect(failed.matches.isEmpty)
        #expect(failed.failures.count == 1)
    }

    @Test func diagnosticProgressSurvivesBusySnapshotsAndShowsCompletion() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let runner = DiagnosticRunner()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: Exporter())
        defaults.set([String](), forKey: "meetingCalendarIDs")
        let model = isolatedRecorderModel(processingService: service, defaults: defaults, startBackgroundServices: false)
        for _ in 0..<200 { if model.canResetCache { break }; try await Task.sleep(for: .milliseconds(5)) }
        let checking = Task { await model.checkTranscription(prepare: false) }
        for _ in 0..<200 { if await runner.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<100 { await Task.yield() }
        #expect(model.diagnosticReport.contains("weights.fp16.safetensors"))
        #expect(model.diagnosticStatusText == "Проверка моделей…")
        #expect(model.diagnosticSummary?.contains("weights.fp16.safetensors") == true)
        let job = await service.enqueue(recordingURL: root.appendingPathComponent("meeting.m4a"),
            settings: .init(parakeet: false, echoCancellation: false))
        for _ in 0..<100 { await Task.yield() }
        #expect(model.diagnosticReport.contains("weights.fp16.safetensors"), "Busy snapshots must not overwrite worker output")
        await service.cancel(jobID: job.id)
        await runner.finish()
        await checking.value
        for _ in 0..<100 { await Task.yield() }
        #expect(model.transcriptionReady)
        #expect(model.diagnosticReport.contains("Все файлы проверены."))
        #expect(model.diagnosticReport.contains("Транскрибация готова."))
        #expect(!model.diagnosticRunning)
        #expect(model.diagnosticStatusText == "Готово")
        #expect(model.diagnosticSummary == "Транскрибация готова.")
    }

    @Test func flatNeighboursCannotUseSharedStructuredResultOrMutateMetadata() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        for stem in ["meeting_A", "meeting_B"] {
            let url = root.appendingPathComponent(stem + ".m4a")
            let metadata = root.appendingPathComponent(stem + ".processing.json")
            var saved = RecordingEntry(recording: url, date: Date(), title: "Saved " + stem, phase: .completed)
            saved.duration = 456
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(saved)
            let precise = Data("{\"precise\":123456789012345678901234567890.123456789}".utf8)
            let bytes = try TranscriptResultStorage.mergeUnknownFields(from: precise, into: data)
            try bytes.write(to: metadata)
            try Data(("Saved " + stem).utf8).write(to: url.deletingPathExtension().appendingPathExtension("sources.transcript.txt"))
            let entry = RecordingEntry.load(recording: url)
            #expect(entry.title == "Saved " + stem && entry.duration == 456)
            #expect(entry.metadata == metadata)
            #expect(!entry.capabilities.canReview && !entry.capabilities.canRetry && !entry.capabilities.canPreviewAudio)
            #expect(throws: Error.self) { try TranscriptResultStorage(recordingURL: url).currentDocument() }
            #expect(try TranscriptReviewSession.open(recordingURL: url) == nil)
            let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
            #expect(state.isReadOnly && state.session == nil)
            let model = try await TranscriptReviewWindowModel(state: state)
            #expect(model.legacyText == "Saved " + stem)
            #expect(!model.canExport && !model.playbackEnabled)
            let repo = RecordingHistoryRepository()
            repo.put(entry, persist: false)
            #expect(throws: Error.self) { try repo.putThrowing(saved) }
            #expect(throws: Error.self) { try repo.updateThrowing(url) { $0.title = "Changed" } }
            #expect(repo.updateStatus(url) { $0.title = "Changed" }.persistenceWarning != nil)
            #expect(repo.update(url) { $0.title = "Changed" }.persistenceWarning != nil)
            #expect(repo.put(saved).persistenceWarning != nil)
            #expect(repo.entry(url)?.title == "Saved " + stem)
            #expect(try Data(contentsOf: metadata) == bytes)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("raw/" + stem + ".processing.json").path))
            model.close(); state.close()
        }
    }

    @Test func flatMetadataReadPathDoesNotChangeWhenRawAppears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting_B.m4a")
        let entry = RecordingEntry(recording: url, date: Date(), title: "Saved B", phase: .completed)
        let metadata = root.appendingPathComponent("meeting_B.processing.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try TranscriptResultStorage.mergeUnknownFields(
            from: Data("{\"precise\":123456789012345678901234567890.123456789}".utf8), into: encoder.encode(entry))
        try bytes.write(to: metadata)
        #expect(RecordingEntry.load(recording: url).title == "Saved B")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw/transcripts"), withIntermediateDirectories: true)
        #expect(RecordingEntry.load(recording: url).title == "Saved B")
        #expect(RecordingEntry.load(recording: url).metadata == metadata)
        #expect(throws: Error.self) { try RecordingHistoryRepository().putThrowing(entry) }
        #expect(try Data(contentsOf: metadata) == bytes)
    }

    @Test func flatWithoutTXTDoesNotOpenNeighbourResult() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("other.m4a")
        let entry = RecordingEntry.load(recording: url)
        #expect(!entry.capabilities.canReview && !entry.capabilities.canRetry && !entry.capabilities.hasSavedText)
        await #expect(throws: TranscriptWindowError.self) { try await TranscriptWindowCoordinator().openWindow(for: url) }
    }

    @Test func standardOwnerWithoutOriginalsKeepsEditorAndPlaybackAndIsolatesNeighbour() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        try Data([1]).write(to: root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/mix.m4a"))
        try Data([2]).write(to: root.appendingPathComponent("meeting.m4a"))
        let owner = root.appendingPathComponent("meeting.m4a")
        let neighbour = root.appendingPathComponent("other.m4a")
        let entry = RecordingEntry.load(recording: owner)
        #expect(entry.capabilities.canReview && entry.capabilities.canPreviewAudio)
        #expect(!entry.capabilities.canRetry)
        let repo = RecordingHistoryRepository()
        try repo.putThrowing(entry)
        #expect(throws: Error.self) { try repo.updateThrowing(neighbour) { $0.title = "Foreign" } }
        let coordinator = TranscriptWindowCoordinator()
        let state = try await coordinator.openWindow(for: owner).state
        #expect(!state.isReadOnly && state.session != nil)
        let session = try #require(state.session)
        #expect(session.activeResultID == "res_valid_parakeet_off")
        await #expect(throws: TranscriptWindowError.self) { try await coordinator.openWindow(for: neighbour) }
        #expect(try TranscriptResultStorage(recordingURL: owner).currentDocument()?.resultID == "res_valid_parakeet_off")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("other.processing.json").path))
        state.close()
    }

    @Test(arguments: ["recording", "preparing", "checking"]) func constructorReattachesToAuthoritativeServices(activity: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let repo = RecordingHistoryRepository()
        let session = RecordingSessionService(historyRepo: repo)
        let processing = ProcessingService(transcriptionRunner: Runner(), audioExporter: Exporter(), historyRepository: repo)
        let output = root.appendingPathComponent("meeting.m4a")
        let task: Task<Void, Never>?
        if activity != "recording" {
            task = Task { _ = try? await processing.checkOrPrepareDependencies(prepare: activity == "preparing", parakeet: false) }
            while await processing.currentPreparationState == .idle { await Task.yield() }
        } else {
            task = nil
            _ = try await session.start(controller: Capture(output: output), outputURL: output, meetingID: "meeting", meetingSummary: "Meeting")
        }
        let model = isolatedRecorderModel(sessionService: session, processingService: processing,
            historyRepository: repo, defaults: defaults, startBackgroundServices: false)
        for _ in 0..<100 { await Task.yield() }
        #expect(model.preventsTermination)
        #expect(!model.canResetCache)
        if activity != "recording" { #expect(model.diagnosticRunning) }
        else { #expect(model.isRecording); #expect(model.lastFileURL == output); #expect(model.recordingMeetingID == "meeting") }
        if activity != "recording" { await processing.cancelPreparation(); await task?.value }
        else { _ = try await session.stop(expectedSessionID: (await session.currentSnapshot).sessionID) }
        for _ in 0..<1000 { if !model.preventsTermination { break }; await Task.yield() }
        #expect(!model.preventsTermination)
        #expect(model.canResetCache)
    }
    @Test func chronologicalReadingEditingCopyAndReopen() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/chronological.json")
        let result = root.appendingPathComponent("raw/transcripts/res_chronological")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let resultURL = result.appendingPathComponent("result.json")
        let original = try Data(contentsOf: fixture)
        try original.write(to: resultURL)
        let manager = TranscriptReviewWindowManager()
        defer { manager.closeCurrent() }
        let recording = root.appendingPathComponent("meeting.m4a")
        var editor = try await manager.open(recordingURL: recording, title: "Synthetic interruption")
        #expect(editor.rows.map(\.text) == ["Обсудим…", "Да", "…релиз"])
        #expect(try Data(contentsOf: resultURL) == original)
        editor.openTextEditing(for: "t0")
        #expect(editor.activeTextDraft?.text == "Обсудим")
        editor.cancelTextDraft()
        #expect(editor.rows.first?.text == "Обсудим…")
        editor.openTextEditing(for: "t0")
        editor.saveTextEditing()
        #expect(editor.rows.first?.text == "Обсудим…")
        let repository = try #require(editor.state.session?.editsRepository)
        #expect(try repository.loadEdits(resultID: "res_chronological").overrides["t0"]?.text == nil)
        #expect(!repository.canUndo(resultID: "res_chronological"))
        editor.openTextEditing(for: "t0")
        let exact = "  Ручная правка\nбез маркера  "
        editor.updateDraftText(exact)
        editor.saveTextEditing()
        #expect(editor.error == nil && editor.rows.first?.text == exact)
        var copied = ""
        editor.copySavedText { copied = $0; return true }
        #expect(copied.contains(exact + "\n\n"))
        #expect(copied.contains("…релиз"))
        _ = try repository.undo(resultID: "res_chronological")
        manager.closeCurrent()
        editor = try await manager.open(recordingURL: recording, title: "Synthetic interruption")
        #expect(editor.rows.first?.text == "Обсудим…")
        editor.openTextEditing(for: "t0")
        #expect(editor.activeTextDraft?.text == "Обсудим")
        editor.updateDraftText(exact); editor.saveTextEditing()
        manager.closeCurrent()
        let reopened = try await manager.open(recordingURL: recording, title: "Synthetic interruption")
        #expect(reopened.rows.first?.text == exact)
        reopened.openTextEditing(for: "t0")
        #expect(reopened.activeTextDraft?.text == exact)
        reopened.cancelTextDraft()
        #expect(try Data(contentsOf: resultURL) == original)
    }

    @Test func chronologicalPlaybackFocusAndUserFollowing() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/chronological.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        json["playback"] = ["status": "ready", "mixPath": "raw/transcripts/res_chronological/mix.m4a"]
        json["warnings"] = []
        let result = root.appendingPathComponent("raw/transcripts/res_chronological")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json)
        let resultURL = result.appendingPathComponent("result.json")
        try data.write(to: resultURL)
        try Data([0]).write(to: result.appendingPathComponent("mix.m4a"))
        let transport = BufferingPresentationTransport()
        transport.duration = 100
        let state = try await TranscriptWindowCoordinator().openWindow(for: root.appendingPathComponent("meeting.m4a")).state
        let editor = try await TranscriptReviewWindowModel(state: state, transportFactory: { transport })
        defer { editor.close(); state.close() }
        for _ in 0..<500 where editor.playbackState != .ready { try await Task.sleep(for: .milliseconds(1)) }
        #expect(editor.playbackState == .ready)
        editor.togglePlayback(); transport.releaseBuffer()
        for (time, expected) in [(10.5, ["t0"]), (11.0, ["t1"]), (11.5, []), (12.2, ["t2"])] {
            transport.onEvent?(.position(time))
            #expect(editor.activeTurnIDs == expected)
            if let id = expected.first { #expect(editor.follow.targetID == id) }
        }
        editor.userScrollPhaseChanged(.interacting)
        #expect(!editor.follow.isFollowing)
        transport.onEvent?(.position(11))
        #expect(editor.activeTurnIDs == ["t1"])
        editor.returnToPlayback()
        #expect(editor.follow.isFollowing && editor.follow.targetID == "t1")
        editor.openTextEditing(for: "t1")
        #expect(!editor.follow.isFollowing)
        editor.cancelTextDraft()
        await editor.seekPlayback(to: 10.5)
        #expect(editor.activeTurnIDs == ["t0"])
        await editor.seekPlayback(to: 11.6)
        #expect(editor.activeTurnIDs.isEmpty)
        #expect(try Data(contentsOf: resultURL) == data)
    }

    @Test func oldOverlappingDocumentOpensWithoutRegroupingOrWritingEdits() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/chronological.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var turns = json["turns"] as! [[String: Any]]
        turns[0]["wordIDs"] = ["a1", "a2"]; turns[0]["end"] = 13.0
        turns.removeLast(); json["turns"] = turns
        json["playback"] = ["status": "ready", "mixPath": "raw/transcripts/res_chronological/mix.m4a"]
        json["warnings"] = []
        let result = root.appendingPathComponent("raw/transcripts/res_chronological")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let documentBytes = try JSONSerialization.data(withJSONObject: json)
        let editBytes = try JSONEncoder().encode(TranscriptEdits(resultID: "res_chronological", revision: 3,
            overrides: ["t0": .init(text: "  Старая правка  ")]))
        try documentBytes.write(to: result.appendingPathComponent("result.json"))
        try editBytes.write(to: result.appendingPathComponent("edits.json"))
        try Data([0]).write(to: result.appendingPathComponent("mix.m4a"))
        let transport = BufferingPresentationTransport(); transport.duration = 100
        let manager = TranscriptReviewWindowManager(transportFactory: { transport })
        defer { manager.closeCurrent() }
        let editor = try await manager.open(recordingURL: root.appendingPathComponent("meeting.m4a"), title: "Old")
        #expect(editor.rows.map(\.id) == ["t0", "t1"])
        #expect(editor.rows.map(\.text) == ["  Старая правка  ", "Да"])
        for _ in 0..<500 where editor.playbackState != .ready { try await Task.sleep(for: .milliseconds(1)) }
        #expect(editor.playbackState == .ready)
        await editor.seekPlayback(to: 11)
        #expect(editor.activeTurnIDs == ["t1"])
        await editor.seekPlayback(to: 11.6)
        #expect(editor.activeTurnIDs.isEmpty)
        await editor.seekPlayback(to: 10.5)
        #expect(editor.activeTurnIDs == ["t0"])
        #expect(try Data(contentsOf: result.appendingPathComponent("result.json")) == documentBytes)
        #expect(try Data(contentsOf: result.appendingPathComponent("edits.json")) == editBytes)
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
        return root
    }

    private func published(_ id: String, in root: URL) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/transcript-document/valid_parakeet_off.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        json["resultID"] = id
        if var playback = json["playback"] as? [String: Any] {
            playback["mixPath"] = "raw/transcripts/" + id + "/mix.m4a"
            json["playback"] = playback
        }
        let directory = root.appendingPathComponent("raw/transcripts/" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("result.json"))
        _ = try TranscriptDocument.load(from: directory.appendingPathComponent("result.json"), recordingDirectory: root)
    }

    @Test(arguments: ["saved-text", "unsupported", "flat"])
    func owner23OldSavedTextRetryEligibility(kind: String) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stem = kind == "flat" ? "old-flat" : "meeting"
        let recording = root.appendingPathComponent(stem + ".m4a")
        // Empty file placeholders test admission only; no PCM/audio is generated or decoded.
        for source in ["host", "remote"] {
            try Data().write(to: root.appendingPathComponent("raw/" + stem + "." + source + "_record.wav"))
        }
        let entry = RecordingEntry(recording: recording, date: Date(timeIntervalSince1970: 1), title: "Old saved meeting", phase: .completed)
        try Data("old saved text".utf8).write(to: entry.transcript)
        try Data("{\"recordingFormatVersion\":0,\"producer\":\"old\"}".utf8).write(to: entry.metadata)
        if kind == "unsupported" {
            let result = root.appendingPathComponent("raw/transcripts/future")
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
            try Data("{\"schemaVersion\":99}".utf8).write(to: result.appendingPathComponent("result.json"))
        }
        let original = try Data(contentsOf: entry.transcript)
        let loaded = await Task.detached { RecordingEntry.load(recording: recording) }.value
        #expect(loaded.capabilities.hasSavedText)
        #expect(!loaded.capabilities.canReview)
        #expect(loaded.capabilities.canRetry == (kind != "flat"))
        #expect(loaded.capabilities.reason != nil)
        #expect(try Data(contentsOf: entry.transcript) == original)
    }

    private func sources(in root: URL, stem: String = "meeting", flat: Bool = false) throws {
        for source in ["host", "remote"] {
            // Existence/readability is retry eligibility; the existing worker validates audio decoding.
            try Data([0, 0]).write(to: (flat ? root : root.appendingPathComponent("raw"))
                .appendingPathComponent(stem + "." + source + "_record.wav"))
        }
    }

    @Test(arguments: [false, true]) func supportedUnmarkedJSONKeepsCapabilitiesWithoutTXT(flat: Bool) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try sources(in: root, flat: flat)
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("meeting.m4a")
        let bytes = try Data(contentsOf: root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/result.json"))
        let entry = await Task.detached { RecordingEntry.load(recording: url) }.value
        #expect(entry.capabilities.canReview)
        #expect(entry.capabilities.canRetry == !flat)
        #expect(!entry.capabilities.hasSavedText)
        let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(!state.isReadOnly)
        #expect(state.activeResultID == "res_valid_parakeet_off")
        #expect(try Data(contentsOf: root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/result.json")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: entry.metadata.path))
    }

    @Test(arguments: [false, true], [false, true]) func corruptOrMissingCurrentResultRemainsRetryable(missing: Bool, flat: Bool) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.m4a")
        try sources(in: root, flat: flat)
        if !missing {
            let result = root.appendingPathComponent("raw/transcripts/broken")
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
            try Data("{broken".utf8).write(to: result.appendingPathComponent("result.json"))
        }
        let entry = RecordingEntry(recording: url, date: Date(), title: "Current", phase: .failed)
        try RecordingHistoryRepository().putThrowing(entry)
        try Data("saved recognized text".utf8).write(to: entry.transcript)
        let loaded = await Task.detached { RecordingEntry.load(recording: url) }.value
        #expect(loaded.capabilities.canRetry == !flat)
        #expect(!loaded.capabilities.canReview)
        #expect(loaded.isLegacy == flat)
        let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(state.isReadOnly)
        if !missing, case .legacyReadOnly = state.mode { Issue.record("Corrupt current result was masked as a clean standalone TXT") }
        let model = try await TranscriptReviewWindowModel(state: state)
        #expect(model.legacyText == "saved recognized text")
        #expect(!model.canExport)
        #expect(!model.playbackEnabled)
        #expect(model.explanation != nil)
    }

    @Test(arguments: ["{}", "{\"selectedResultID\":\"res_valid_parakeet_off\"}",
        "{\"recordingFormatVersion\":999}", "{\"recordingFormatVersion\":\"future\"}",
        "{\"recordingFormatVersion\":1,\"recordingFormatVersion\":999}",
        "{\"recordingFormatVersion\":999,\"recordingFormatVersion\":1}"])
    func minimalMetadataRespectsArtifactAndFormatContracts(metadata: String) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.m4a")
        try sources(in: root)
        try published("res_valid_parakeet_off", in: root)
        let metadataURL = root.appendingPathComponent("raw/meeting.processing.json")
        let bytes = Data(metadata.utf8)
        try bytes.write(to: metadataURL)
        try Data("saved text".utf8).write(to: root.appendingPathComponent("meeting.sources.transcript.txt"))
        let entry = await Task.detached { RecordingEntry.load(recording: url) }.value
        #expect(entry.capabilities.canReview)
        #expect(entry.capabilities.canRetry)
        let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(!state.isReadOnly)
        #expect(try Data(contentsOf: metadataURL) == bytes)
    }



    @Test func historyMutationRunsOffMainActorAndIsAwaited() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = RecordingEntry(recording: root.appendingPathComponent("meeting.m4a"), date: Date(), title: "Before", phase: .completed)
        let history = RecordingHistory()
        await history.put(entry)
        let (started, continuation) = AsyncStream<Bool>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        let mutation = Task {
            await history.update(entry.id) {
                continuation.yield(Thread.isMainThread)
                _ = gate.wait(timeout: .now() + 2)
                $0.title = "After"
            }
        }
        for await mainThread in started {
            #expect(!mainThread)
            #expect(history.entry(entry.id)?.title == "Before")
            gate.signal()
            break
        }
        await mutation.value
        #expect(history.entry(entry.id)?.title == "After")
        #expect(RecordingEntry.load(recording: entry.id).title == "After")
    }

    @Test func constructorReattachesQueueAndContinuesEventsWithoutDoubleCount() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let repo = RecordingHistoryRepository()
        let processing = ProcessingService(transcriptionRunner: Runner(), audioExporter: Exporter(), historyRepository: repo)
        var jobs: [ProcessingJob] = []
        for name in ["first", "second"] {
            let owned = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: owned.appendingPathComponent("raw"), withIntermediateDirectories: true)
            try sources(in: owned, stem: name)
            let url = owned.appendingPathComponent(name + ".m4a")
            try repo.putThrowing(RecordingEntry(recording: url, date: Date(), title: name, phase: .failed))
            jobs.append(await processing.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false)))
        }
        let model = isolatedRecorderModel(sessionService: RecordingSessionService(historyRepo: repo), processingService: processing,
            historyRepository: repo, defaults: defaults, startBackgroundServices: false)
        #expect(model.preventsTermination)
        for _ in 0..<1000 { if model.transcriptionJobs == 2 { break }; await Task.yield() }
        #expect(model.transcriptionJobs == 2)
        #expect(model.lastFileURL == jobs[0].recordingURL)
        #expect(!model.canResetCache)
        await processing.cancel(jobID: jobs[1].id)
        for _ in 0..<1000 { if model.transcriptionJobs == 1 { break }; await Task.yield() }
        #expect(model.transcriptionJobs == 1)
        await processing.cancel(jobID: jobs[0].id)
        for _ in 0..<1000 { if model.transcriptionJobs == 0 { break }; await Task.yield() }
        #expect(model.transcriptionJobs == 0)
        #expect(model.canResetCache)
        #expect(!model.preventsTermination)
    }

    @Test func lifecycleReloadIgnoresAndPreservesObsoleteMetadata() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try sources(in: root)
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("meeting.m4a")
        let metadata = root.appendingPathComponent("raw/meeting.processing.json")
        let precise = "123456789012345678901234567890.1234567890123456789"
        let bytes = Data(("{\"selectedResultID\":\"gone\",\"recordingFormatVersion\":1,\"recordingFormatVersion\":999,\"precise\":" + precise + "}").utf8)
        try bytes.write(to: metadata)
        let repo = RecordingHistoryRepository()
        let service = RecordingSessionService(historyRepo: repo)
        _ = try await service.start(controller: Capture(output: url), outputURL: url)
        _ = try await service.stop(expectedSessionID: (await service.currentSnapshot).sessionID)
        for _ in 0..<3 { _ = repo.updateStatus(url) { $0.phase = .completed } }
        let disk = await Task.detached { RecordingEntry.load(recording: url) }.value
        #expect(disk.capabilities.canReview && disk.capabilities.canRetry)
        let text = try String(contentsOf: metadata, encoding: .utf8)
        #expect(text.contains(precise))
        #expect(text.components(separatedBy: "\"recordingFormatVersion\"").count - 1 == 2)
        #expect(text.contains("gone"))
        let window = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(!window.isReadOnly)
        #expect(window.activeResultID == "res_valid_parakeet_off")
    }

    @Test(arguments: ["unsupported", "corrupt", "missing"])
    func newestDirectoryCannotFallBackToOldSelectedResult(kind: String) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        try sources(in: root)
        let a = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: a.path)
        let b = root.appendingPathComponent("raw/transcripts/newest")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        if kind == "unsupported" { try Data("{\"schemaVersion\":2}".utf8).write(to: b.appendingPathComponent("result.json")) }
        if kind == "corrupt" { try Data("{broken".utf8).write(to: b.appendingPathComponent("result.json")) }
        let metadata = root.appendingPathComponent("raw/meeting.processing.json")
        let oldSelection = Data("{\"selectedResultID\":\"res_valid_parakeet_off\"}".utf8)
        try oldSelection.write(to: metadata)
        try Data("explicitly saved old text".utf8).write(to: root.appendingPathComponent("meeting.sources.transcript.txt"))
        let url = root.appendingPathComponent("meeting.m4a")
        let entry = await Task.detached { RecordingEntry.load(recording: url) }.value
        #expect(!entry.capabilities.canReview)
        #expect(entry.capabilities.canRetry)
        let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(state.isReadOnly && state.session == nil)
        #expect(try Data(contentsOf: metadata) == oldSelection)
    }

    @Test(arguments: ["save", "discard", "cancel"])
    func guiRetryResolvesDraftBeforeAdmission(choice: String) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try sources(in: root)
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("meeting.m4a")
        let repo = RecordingHistoryRepository()
        repo.put(RecordingEntry.load(recording: url), persist: false)
        let coordinator = TranscriptWindowCoordinator()
        let state = try await coordinator.openWindow(for: url).state
        let editor = try await TranscriptReviewWindowModel(state: state)
        let turn = try #require(editor.rows.first?.id)
        editor.openTextEditing(for: turn)
        editor.updateDraftText("Manual correction")
        let service = ProcessingService(transcriptionRunner: Runner(), audioExporter: Exporter(), historyRepository: repo,
            retryAdmission: { _ in await editor.resolveForRetry() })
        let blocked = await service.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false))
        #expect(await service.totalJobCount == 0)
        #expect(!state.isClosed && editor.hasUnsavedChanges)
        if choice == "save" { editor.saveTextEditing() }
        if choice == "discard" { editor.cancelTextDraft() }
        let job = choice == "cancel" ? blocked : await service.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false))
        let editsURL = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/edits.json")
        if choice == "cancel" {
            #expect(!state.isClosed)
            #expect(editor.hasUnsavedChanges)
            #expect(await service.totalJobCount == 0)
            #expect(!FileManager.default.fileExists(atPath: editsURL.path))
        } else {
            #expect(state.isClosed && state.session == nil)
            #expect(await service.isProcessing(recordingURL: url))
            let manager = TranscriptReviewWindowManager(isProcessing: { await service.isProcessing(recordingURL: $0) })
            await #expect(throws: TranscriptWindowError.self) { try await manager.open(recordingURL: url, title: "Blocked") }
            if choice == "save" {
                let edits = try TranscriptEditsRepository(recordingDirectory: root).loadEdits(resultID: "res_valid_parakeet_off")
                #expect(edits.overrides[turn]?.text == "Manual correction")
            } else { #expect(!FileManager.default.fileExists(atPath: editsURL.path)) }
            await service.cancel(jobID: job.id)
            #expect(!(await service.isProcessing(recordingURL: url)))
            // Terminal reopen re-resolves disk, with no old draft or old edits mapped to B.
            try published("replacement", in: root)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off").path)
            let next = try await coordinator.openWindow(for: url).state
            let reopened = try await TranscriptReviewWindowModel(state: next)
            #expect(reopened.currentResultID == "replacement")
            #expect(!reopened.hasUnsavedChanges)
            #expect(!reopened.rows.contains { $0.text == "Manual correction" })
        }
        editor.close()
        coordinator.closeAll()
    }

    @Test func retryRejectsInputWithoutDeferredAction() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let state = try await TranscriptWindowCoordinator().openWindow(for: root.appendingPathComponent("meeting.m4a")).state
        let editor = try await TranscriptReviewWindowModel(state: state)
        editor.openTextEditing(for: try #require(editor.rows.first?.id))
        editor.updateDraftText("First")
        #expect(await editor.resolveForRetry() == false)
        editor.updateDraftText("New draft")
        #expect(editor.activeTextDraft?.text == "New draft")
        #expect(!state.isClosed)
        editor.cancelTextDraft()
        #expect(await editor.resolveForRetry())
        #expect(state.isClosed)
    }

    @Test func committedStructuredCurrentDoesNotReadRootExportCache() async throws {
        let root = try fixtureRoot()
        let outside = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try published("res_valid_parakeet_off", in: root)
        let saved = outside.appendingPathComponent("saved.txt")
        try Data("Stale unrelated export".utf8).write(to: saved)
        let url = root.appendingPathComponent("meeting.m4a")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("meeting.sources.transcript.txt"), withDestinationURL: saved)
        let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(!state.isReadOnly)
        #expect(state.activeResultID == "res_valid_parakeet_off")
        let editor = try await TranscriptReviewWindowModel(state: state)
        #expect(editor.legacyText == nil)
        #expect(!editor.rows.isEmpty)
        editor.close(); state.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func defaultVoiceMatchPolicyAndProductionDelegateConfiguration() async throws {
        #expect(RecorderViewModel.defaultVoiceMatchPolicy == VoiceMatchPolicy(
            threshold: 0.60, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0,
            mixedClusterRescue: VoiceMixedClusterRescuePolicy(threshold: 0.65, margin: 0.20)
        ))

        let parent = try fixtureRoot()
        let root = parent.appendingPathComponent("meeting_retry")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
        let appData = root.appendingPathComponent("appData")
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }
        try sources(in: root, stem: "meeting_retry")
        let catalogueRepo = VoiceProfileCatalogueRepository(applicationDataDirectory: appData)
        let learning = VoiceLearningCoordinator(catalogue: catalogueRepo)
        let alice = VoiceProfilePerson(displayName: "Алиса")
        let bob = VoiceProfilePerson(displayName: "Боб")
        _ = try catalogueRepo.update(catalogueRepo.load()) { value in
            let vAlice: [Float] = [1] + Array(repeating: 0, count: 255)
            let vBob: [Float] = [0, 1] + Array(repeating: 0, count: 254)
            value.people = [alice, bob]
            value.samples = zip([alice, bob], [vAlice, vBob]).map { person, vector in
                .init(personID: person.id, embeddingSpaceID: VoiceEmbeddingProtocol.embeddingSpaceID, embedding: vector,
                      recordingLocator: "/synthetic/seed", resultID: "seed", turnID: "seed",
                      sourceID: .host, start: 0, end: 5, pcmFingerprint: person.id.uuidString,
                      assignment: .init(personID: person.id, origin: "manual"), policyID: "test")
            }
            value.aggregates = value.samples.map {
                .init(personID: $0.personID, embeddingSpaceID: $0.embeddingSpaceID, centroid: $0.embedding,
                      activeSampleIDs: [$0.id], policyID: "test")
            }
        }
        learning.reconcileLibrary(recordings: [], scanComplete: true, id: learning.beginLibraryReconciliation())

        let url = root.appendingPathComponent("meeting_retry.m4a")
        let repo = RecordingHistoryRepository(voiceLearning: learning)
        try publishedVoiceFixture("res_before_retry", in: root)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 100)],
                                              ofItemAtPath: root.appendingPathComponent("raw/transcripts/res_before_retry").path)
        try repo.putThrowing(RecordingEntry.load(recording: url))

        let (asrEntered, signalASR) = AsyncStream<Void>.makeStream()
        let (asrGate, openASRGate) = AsyncStream<Void>.makeStream()
        let (voiceEntered, signalEntered) = AsyncStream<Void>.makeStream()
        let (voiceGate, openVoiceGate) = AsyncStream<Void>.makeStream()
        defer { signalASR.finish(); openASRGate.finish(); signalEntered.finish(); openVoiceGate.finish() }

        let asr = CompositionVoiceASRRunner {
            signalASR.yield(())
            for await _ in asrGate {}
            try self.publishedVoiceFixture("res_comp_voice", in: root)
            return root.appendingPathComponent("raw/transcripts/res_comp_voice/transcript.txt")
        }
        let voiceRunner = CompositionVoiceRunner { request in
            signalEntered.yield(())
            for await _ in voiceGate {}
            let vAlice: [Float] = [1] + Array(repeating: 0, count: 255)
            return .init(requestID: request.id, features: request.windows.map {
                .init(windowID: $0.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: vAlice)
            })
        }

        let suite = "comp-voice-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.deletingLastPathComponent().path, forKey: "recordingsDirectory")
        defaults.set(true, forKey: "localVoiceIdentityEnabled")

        let service = ProcessingService(
            transcriptionRunner: asr,
            audioExporter: Exporter(),
            historyRepository: repo,
            voiceLearning: learning,
            voiceRunner: voiceRunner
        )
        let model = RecorderViewModel(
            sessionService: RecordingSessionService(historyRepo: repo),
            processingService: service,
            historyRepository: repo,
            voiceLearning: learning,
            voiceMatchPolicy: RecorderViewModel.defaultVoiceMatchPolicy,
            defaults: defaults,
            appDataDirectory: appData,
            startBackgroundServices: false,
            microphoneProvider: { [] },
            accessProvider: { [] },
            calendarCatalogProvider: { [] }
        )
        for _ in 0..<1000 { if model.isAttached { break }; try await Task.sleep(for: .milliseconds(1)) }
        try #require(model.isAttached)
        #expect(model.automaticVoiceNamesAvailable)
        #expect(model.voiceIdentityEnabled)
        await model.history.synchronize()

        model.retryRecording(url)
        var asrEvents = asrEntered.makeAsyncIterator()
        _ = await asrEvents.next()
        await model.history.refresh(root: root.deletingLastPathComponent(), manual: true)
        #expect(learning.failure(for: root) == nil)
        try #require(learning.canMatchVoices)
        openASRGate.finish()
        var it = voiceEntered.makeAsyncIterator()
        _ = await it.next()
        for _ in 0..<1000 {
            if model.capsuleProgress?.current == .voices { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.capsuleProgress?.route.last == .voices)
        #expect(model.capsuleProgress?.current == .voices)
        #expect(model.transcriptionJobs == 1)
        let pendingEntry = try #require(model.history.entry(url))
        #expect(pendingEntry.phase == .processing)
        let historyView = RecordingHistoryView(model: model, history: model.history, workspace: model.workspace, showSettings: {})
        #expect(historyView.processingDetails(for: pendingEntry) != nil)

        openVoiceGate.finish()
        for _ in 0..<1000 {
            if model.transcriptionJobs == 0, model.history.entry(url)?.phase == .completed { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.transcriptionJobs == 0)
        #expect(model.history.entry(url)?.phase == .completed)
        #expect(model.capsuleProgress?.terminal == true)
        #expect(model.capsuleProgress?.states[.voices] == .completed)
        #expect(model.capsuleProgress?.failure == nil)

        let opened = try #require(model.showTranscript(url))
        #expect(await model.loadWorkspace(opened))
        let rows = try #require(model.workspace.current?.rows)
        #expect(rows.first?.name == alice.displayName)
        #expect(rows.first?.nameOriginLabel == "Автоимя")
        model.workspace.closeCurrent()
    }

    @Test(.timeLimit(.minutes(1)))
    func voiceModelPreparationDoesNotOverwriteASRDiagnostics() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let (entered, signalEntered) = AsyncStream<Void>.makeStream()
        let (gate, openGate) = AsyncStream<Void>.makeStream()
        defer { signalEntered.finish(); openGate.finish() }
        let worker = CompositionVoiceRunner(prepareModel: {
            signalEntered.yield(())
            for await _ in gate {}
        }) { _ in throw TranscriptEditsError.notImplemented }
        let service = ProcessingService(
            transcriptionRunner: CompositionVoiceASRRunner { throw TranscriptEditsError.notImplemented },
            audioExporter: Exporter(), voiceRunner: worker
        )
        let suite = "voice-prepare-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let model = isolatedRecorderModel(processingService: service, defaults: defaults)
        for _ in 0..<1000 { if model.isAttached { break }; try await Task.sleep(for: .milliseconds(1)) }
        try #require(model.isAttached)
        model.diagnosticReport = "Предыдущая проверка"
        model.checkVoiceModel(prepare: true)
        try #require(model.voiceModelStatus == .preparing)
        var events = entered.makeAsyncIterator()
        _ = await events.next()
        #expect(!model.canChangeTranscriptionModels)
        await model.checkTranscription(prepare: true)
        #expect(model.diagnosticReport == "Предыдущая проверка")
        openGate.finish()
        for _ in 0..<1000 {
            if model.voiceModelStatus == .ready { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.voiceModelStatus == .ready)
        #expect(model.canChangeTranscriptionModels)
    }

    private nonisolated func publishedVoiceFixture(_ id: String, in root: URL) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/transcript-document/valid_empty_voices.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        json["resultID"] = id
        if var playback = json["playback"] as? [String: Any] {
            playback["mixPath"] = "raw/transcripts/" + id + "/mix.m4a"
            json["playback"] = playback
        }
        for key in ["words", "baselineWords", "turns"] {
            var items = try #require(json[key] as? [[String: Any]])
            items[0]["end"] = 5.0
            json[key] = items
        }
        let dir = root.appendingPathComponent("raw/transcripts/" + id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let resultFile = dir.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject: json).write(to: resultFile)
        try Data("00:00 [Собеседник 1] Монолог\n".utf8).write(to: dir.appendingPathComponent("transcript.txt"))
        let doc = try TranscriptDocument.load(from: resultFile, recordingDirectory: root)
        let host = try #require(doc.sources.first { $0.id == .host })
        let remote = try #require(doc.sources.first { $0.id == .remote })
        let quality = VoiceAudioQuality(resultID: id, producer: "test", sources: [
            .init(id: .host, recognitionAudioPath: host.recognitionAudioPath,
                  fingerprint: String(repeating: "a", count: 64), duration: 5,
                  speech: [.init(start: 0, end: 5)], overlap: []),
            .init(id: .remote, recognitionAudioPath: remote.recognitionAudioPath,
                  fingerprint: String(repeating: "b", count: 64), duration: 5,
                  speech: nil, overlap: [])
        ], recordingFingerprint: String(repeating: "c", count: 64))
        try quality.encoded(for: doc).write(to: dir.appendingPathComponent(VoiceAudioQuality.filename))
    }

}

private struct CompositionVoiceASRRunner: TranscriptionRunnerProtocol {
    let publish: @Sendable () async throws -> URL
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("ok", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        onProgress?(.init(stage: .diarization, channel: "host", completed: 0, total: 0, state: .completed))
        onProgress?(.init(stage: .diarization, channel: "remote", completed: 0, total: 0, state: .completed))
        onProgress?(.init(stage: .gigaam, channel: "host", completed: 1, total: 1, state: .completed))
        onProgress?(.init(stage: .gigaam, channel: "remote", completed: 1, total: 1, state: .completed))
        onProgress?(.init(stage: .publication, completed: 1, total: 1, state: .completed))
        return try await publish()
    }
}

private struct CompositionVoiceRunner: VoiceEmbeddingRunnerProtocol {
    var prepareModel: @Sendable () async -> Void = {}
    let runExtract: @Sendable (VoiceEmbeddingProtocol.Request) async throws -> VoiceEmbeddingProtocol.Response
    func checkOrPrepareVoiceModel(prepare: Bool) async throws {
        if prepare { await prepareModel() }
    }
    func extractVoiceEmbeddings(_ request: VoiceEmbeddingProtocol.Request, recordingDirectory: URL) async throws -> VoiceEmbeddingProtocol.Response {
        try await runExtract(request)
    }
}
