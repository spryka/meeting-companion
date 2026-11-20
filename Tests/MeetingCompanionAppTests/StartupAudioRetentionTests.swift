import Foundation
import Testing
import MeetingCompanionPlatform
@testable import MeetingCompanionApplication
@testable import MeetingCompanionApp

@MainActor
struct StartupAudioRetentionTests {
    enum RefreshOrder: CaseIterable {
        case single, supersededFirst, currentFirst
    }

    @Test(arguments: [(nil, 14), (7, 7), (366, 14)] as [(Int?, Int)])
    func loadsAudioRetentionPeriod(storedPeriod: Int?, expectedPeriod: Int) throws {
        let suite = "audio-retention-period-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(directory.path, forKey: "recordingsDirectory")
        if let storedPeriod { defaults.set(storedPeriod, forKey: "audioRetentionPeriod") }
        let model = RecorderViewModel(defaults: defaults, appDataDirectory: directory, startBackgroundServices: false)
        #expect(model.audioRetentionDays == expectedPeriod)
    }

    @Test(arguments: [true, false], RefreshOrder.allCases)
    func startupRefreshRespectsAudioRetention(optedIn: Bool, order: RefreshOrder) async throws {
        let fixture = try StartupRetentionFixture(optedIn: optedIn)
        defer { fixture.cleanup() }
        let model = fixture.model
        let gate = fixture.delayFirstTwoScans()
        defer { gate.first.signal(); gate.second.signal() }

        if order == .single {
            gate.first.signal()
            await model.loadInitialLibrary()
        } else {
            let startup = Task { await model.loadInitialLibrary() }
            try await gate.awaitScan(1)
            let window = Task { await model.history.refresh(root: fixture.root) }
            try await gate.awaitScan(2)

            if order == .supersededFirst {
                gate.first.signal()
                await startup.value
                await waitForRetention(model)
                #expect(model.history.entries.isEmpty)
                try fixture.recording.expectAudio(present: true)
                gate.second.signal()
                await window.value
            } else {
                gate.second.signal()
                await window.value
                await waitForRetention(model)
                try fixture.recording.expectAudio(present: !optedIn)
                gate.first.signal()
                await startup.value
            }
        }
        await waitForRetention(model)
        #expect(model.history.entries.map(\.id) == [fixture.recording.audio[0]])
        try fixture.recording.expectAudio(present: !optedIn)
    }

    @Test func retryAfterFailedStartupRefreshRunsCleanup() async throws {
        let fixture = try StartupRetentionFixture(optedIn: true)
        defer { fixture.cleanup() }
        let model = fixture.model
        let enumerate = fixture.repository.historyEnumerator
        fixture.repository.historyEnumerator = { _, _ in nil }

        await model.loadInitialLibrary()
        await waitForRetention(model)
        #expect(model.history.entries.isEmpty)
        #expect(model.history.error != nil)
        try fixture.recording.expectAudio(present: true)

        fixture.repository.historyEnumerator = enumerate
        await model.history.refresh(root: fixture.root, manual: true)
        await waitForRetention(model)
        #expect(model.history.refreshCompletion != nil)
        try fixture.recording.expectAudio(present: false)
    }

    @Test func changingFolderDuringStartupRequiresOptInForNewFolder() async throws {
        let fixture = try StartupRetentionFixture(optedIn: true)
        defer { fixture.cleanup() }
        let otherRoot = fixture.container.appendingPathComponent("other", isDirectory: true)
        let other = try StartupRetentionRecording(root: otherRoot)
        let model = fixture.model
        let gate = fixture.delayFirstTwoScans()
        defer { gate.first.signal(); gate.second.signal() }

        let startup = Task { await model.loadInitialLibrary() }
        try await gate.awaitScan(1)
        model.outputDirectory = otherRoot
        try await gate.awaitScan(2)
        gate.first.signal()
        await startup.value
        gate.second.signal()
        for _ in 0..<400 where model.history.loading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.history.loading)
        await waitForRetention(model)

        #expect(model.history.entries.map(\.id) == [other.audio[0]])
        #expect(!model.audioRetentionEnabled)
        try fixture.recording.expectAudio(present: true)
        try other.expectAudio(present: true)

        model.audioRetentionEnabled = true
        await waitForRetention(model)
        try fixture.recording.expectAudio(present: true)
        try other.expectAudio(present: false)
    }

    private func waitForRetention(_ model: RecorderViewModel) async {
        for _ in 0..<400 where model.audioRetentionRunning { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.audioRetentionRunning)
    }
}

@MainActor
private struct StartupRetentionFixture {
    let container: URL
    let root: URL
    let recording: StartupRetentionRecording
    let repository = RecordingHistoryRepository()
    let model: RecorderViewModel
    private let suite = "startup-audio-retention-" + UUID().uuidString

    init(optedIn: Bool) throws {
        _ = try #require(Transcription.locateWorkerExecutable(), "The test needs the built transcription worker")
        container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        root = container.appendingPathComponent("library")
        recording = try StartupRetentionRecording(root: root)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(root.path, forKey: "recordingsDirectory")
        if optedIn { defaults.set(root.path, forKey: "audioRetentionOptInFolder") }
        model = RecorderViewModel(historyRepository: repository, defaults: defaults,
                                  appDataDirectory: container, startBackgroundServices: false)
    }

    func delayFirstTwoScans() -> StartupScanGate {
        let gate = StartupScanGate()
        let enumerate = repository.historyEnumerator
        repository.historyEnumerator = { directory, onError in
            gate.waitForRelease()
            return enumerate(directory, onError)
        }
        return gate
    }

    func cleanup() {
        model.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: container)
    }
}

private struct StartupRetentionRecording {
    let audio: [URL]
    let transcript: URL
    private let savedText = Data("Synthetic saved transcript".utf8)

    init(root: URL) throws {
        let files = FileManager.default
        let folder = root.appendingPathComponent("meeting_startup")
        let raw = folder.appendingPathComponent("raw")
        try files.createDirectory(at: raw, withIntermediateDirectories: true)
        audio = [
            folder.appendingPathComponent("meeting_startup.m4a"),
            raw.appendingPathComponent("meeting_startup.host_record.wav"),
            raw.appendingPathComponent("meeting_startup.remote_record.wav"),
        ]
        for file in audio {
            try Data([42]).write(to: file)
            try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
        }
        transcript = folder.appendingPathComponent("meeting_startup.sources.transcript.txt")
        try savedText.write(to: transcript)
    }

    func expectAudio(present: Bool) throws {
        for file in audio {
            #expect(FileManager.default.fileExists(atPath: file.path) == present)
        }
        #expect(try Data(contentsOf: transcript) == savedText)
    }
}

private final class StartupScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0
    let first = DispatchSemaphore(value: 0)
    let second = DispatchSemaphore(value: 0)
    private var count: Int { lock.withLock { scans } }

    func awaitScan(_ expected: Int) async throws {
        for _ in 0..<400 where count < expected { try await Task.sleep(for: .milliseconds(5)) }
        try #require(count == expected)
    }

    func waitForRelease() {
        let order = lock.withLock { scans += 1; return scans }
        if order == 1 { _ = first.wait(timeout: .now() + 10) }
        if order == 2 { _ = second.wait(timeout: .now() + 10) }
    }
}
