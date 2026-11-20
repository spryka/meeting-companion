import Darwin
import Foundation
import Testing
@testable import MeetingCompanionApplication
@testable import MeetingCompanionCore

struct AudioRetentionTests {
    @Test func expiresAtTheBoundaryAndPreservesLibraryAndText() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        fixture.removeExpiredAudio(before: fixture.end.addingTimeInterval(-1))
        #expect(fixture.audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        fixture.removeExpiredAudio(before: fixture.end)
        fixture.removeExpiredAudio(before: fixture.end)
        #expect(fixture.audio.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        for (url, data) in fixture.preserved {
            #expect(try Data(contentsOf: url) == data)
        }
        let entry = try #require(fixture.repository.scanRecordings(in: fixture.root).entries.first)
        #expect(entry.id == fixture.recording)
        #expect(entry.capabilities.canReview)
        #expect(!entry.capabilities.canRetry)
        #expect(!entry.capabilities.canPreviewAudio)
    }

    @Test func skipsAudioLinksAndUsesTheSharedRecordingLock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let target = fixture.root.appendingPathComponent("outside.m4a")
        try Data([42]).write(to: target)
        try FileManager.default.removeItem(at: fixture.recording)
        try FileManager.default.createSymbolicLink(at: fixture.recording, withDestinationURL: target)

        do {
            let lease = try RecordingDirectoryLease(fixture.recording.deletingLastPathComponent())
            defer { withExtendedLifetime(lease) {} }
            fixture.removeExpiredAudio(before: fixture.end)
            #expect(fixture.audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }

        fixture.removeExpiredAudio(before: fixture.end)
        #expect(try Data(contentsOf: target) == Data([42]))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.recording.path) == target.path)
        #expect(fixture.audio.dropFirst().allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func canRetryAPartialRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        #expect(chflags(fixture.recording.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(fixture.recording.path, 0) }
        fixture.removeExpiredAudio(before: fixture.end)
        #expect(FileManager.default.fileExists(atPath: fixture.recording.path))
        #expect(fixture.audio.dropFirst().allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        #expect(chflags(fixture.recording.path, 0) == 0)
        fixture.removeExpiredAudio(before: fixture.end)
        #expect(fixture.audio.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func runningWorkerProtectsAudioUntilItReleasesTheLock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = fixture.recording.deletingLastPathComponent()

        do {
            let lease = try RecordingDirectoryLease(directory)
            let lock = try RecordingTranscriptionLock(lease: lease)
            defer { withExtendedLifetime(lock) {} }
            #expect(throws: (any Error).self) { _ = try RecordingTranscriptionLock(lease: lease) }
            fixture.removeExpiredAudio(before: fixture.end)
            #expect(fixture.audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }

        fixture.removeExpiredAudio(before: fixture.end)
        #expect(fixture.audio.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func workerKeepsAReplacementAndCannotWriteOutsideTheApprovedFolder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = fixture.recording.deletingLastPathComponent()
        let name = fixture.recording.lastPathComponent
        let directory = try RecordingAudioDirectory(folder)
        let parent = try #require(realpath(folder.path, nil))
        defer { free(parent) }
        let scope = String(cString: parent)
        let lease = try RecordingDirectoryLease(folder, exclusive: true)
        let staleFile = try #require(directory.audioFiles(in: folder) { $0 == name }.first)

        try FileManager.default.setAttributes([.modificationDate: fixture.end.addingTimeInterval(60)],
                                             ofItemAtPath: fixture.recording.path)
        try RecordingAudioRemoval(folder: folder, files: [staleFile]).run(worker: fixture.worker, lease: lease, scope: scope)
        #expect(try Data(contentsOf: fixture.recording) == Data([1]))

        let previous = folder.appendingPathComponent("saved-original.m4a")
        try FileManager.default.moveItem(at: fixture.recording, to: previous)
        try Data([42]).write(to: fixture.recording)
        try RecordingAudioRemoval(folder: folder, files: [staleFile]).run(worker: fixture.worker, lease: lease, scope: scope)
        #expect(try Data(contentsOf: fixture.recording) == Data([42]))

        let file = try #require(directory.audioFiles(in: folder) { $0 == name }.first)
        let moved = fixture.root.appendingPathComponent("moved-recording")
        try FileManager.default.moveItem(at: folder, to: moved)
        #expect(throws: (any Error).self) {
            try RecordingAudioRemoval(folder: moved, files: [file]).run(worker: fixture.worker, lease: lease, scope: scope)
        }
        #expect(try Data(contentsOf: moved.appendingPathComponent(name)) == Data([42]))
        #expect(try Data(contentsOf: moved.appendingPathComponent(previous.lastPathComponent)) == Data([1]))
    }

    @Test func recoversInterruptedRemovalAndFindsNestedInputs() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = fixture.recording.deletingLastPathComponent()
        let nested = folder.appendingPathComponent("raw/transcripts/res_older/host_aec.wav")
        #expect(RecordingPaths.managedDirectory(containing: nested)?.path == folder.path)
        #expect(RecordingPaths.managedDirectory(containing: fixture.recording)?.path == folder.path)
        #expect(RecordingPaths.managedDirectory(containing: fixture.root.appendingPathComponent("external/raw/host.wav")) == nil)

        let directory = try RecordingAudioDirectory(folder)
        let name = fixture.recording.lastPathComponent
        let identity = try #require(directory.fileIdentity(name))
        let interrupted = folder.appendingPathComponent(RecordingAudioDirectory.quarantineName(for: name, identity: identity))
        try FileManager.default.moveItem(at: fixture.recording, to: interrupted)

        fixture.removeExpiredAudio(before: fixture.end)

        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
        #expect(fixture.audio.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func readsTheLeasedAudioEvenIfTheRecordingFolderIsReplaced() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let folder = fixture.recording.deletingLastPathComponent()
        let backup = fixture.root.appendingPathComponent("backup")
        let retired = fixture.root.appendingPathComponent("retired")
        let host = "raw/meeting_test.host_record.wav"
        let remote = "raw/meeting_test.remote_record.wav"
        try FileManager.default.copyItem(at: folder, to: backup)
        for result in ["res_older", "res_bad"] {
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                ofItemAtPath: backup.appendingPathComponent("raw/transcripts/" + result).path)
        }
        try Data([42]).write(to: backup.appendingPathComponent(host))
        try Data([42]).write(to: backup.appendingPathComponent(remote))
        let lease = try RecordingDirectoryLease(folder)
        defer { withExtendedLifetime(lease) {} }

        let workspacePath: URL
        do {
            let workspace = try TranscriptionWorkspace(temporaryDirectory: fixture.root)
            defer { withExtendedLifetime(workspace) {} }
            workspacePath = workspace.directory
            let pinnedHost = try workspace.snapshot(folder.appendingPathComponent(host), named: "host", lease: lease)

            try FileManager.default.moveItem(at: folder, to: retired)
            try FileManager.default.moveItem(at: backup, to: folder)
            let lock = try RecordingTranscriptionLock(lease: lease)
            defer { withExtendedLifetime(lock) {} }
            let retiredLease = try RecordingDirectoryLease(retired)
            #expect(throws: (any Error).self) { _ = try RecordingTranscriptionLock(lease: retiredLease) }
            _ = try RecordingTranscriptionLock(lease: RecordingDirectoryLease(folder))

            let pinnedRemote = try workspace.snapshot(folder.appendingPathComponent(remote), named: "remote", lease: lease)
            #expect(try Data(contentsOf: folder.appendingPathComponent(host)) == Data([42]))
            fixture.removeExpiredAudio(before: fixture.end)
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(host).path))
            #expect(try Data(contentsOf: pinnedHost) == Data([1]))
            #expect(try Data(contentsOf: pinnedRemote) == Data([1]))
            #expect(throws: (any Error).self) { try lease.validateLocation() }
        }
        #expect(!FileManager.default.fileExists(atPath: workspacePath.path))
    }

    @Test func skipsReservedRecordings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let token = UUID()
        #expect(fixture.repository.reserveWork(fixture.recording, id: token))
        fixture.removeExpiredAudio(before: fixture.end)
        fixture.repository.releaseWork(fixture.recording, id: token)
        #expect(FileManager.default.fileExists(atPath: fixture.recording.path))
    }

    @Test func expiresOldAudioAfterFailedProcessingWithoutStopTimeOrStructuredTranscript() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = fixture.recording.deletingLastPathComponent()
        let versions = folder.appendingPathComponent("raw/transcripts")
        try FileManager.default.removeItem(at: versions)
        _ = try fixture.repository.updateThrowing(fixture.recording) {
            $0.phase = .failed
            $0.addProblem(.capture, "Synthetic microphone interruption", error: true)
        }
        let metadata = folder.appendingPathComponent("raw/meeting_test.processing.json")
        let saved = try Data(contentsOf: metadata)

        fixture.removeExpiredAudio(before: fixture.end)
        #expect(fixture.audio.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        for (url, data) in fixture.preserved where !url.path.hasPrefix(versions.path + "/") && url.pathExtension != "json" {
            #expect(try Data(contentsOf: url) == data)
        }
        #expect(try Data(contentsOf: metadata) == saved)
        let entry = try #require(fixture.repository.scanRecordings(in: fixture.root).entries.first)
        #expect(entry.phase == .failed)
    }

    @Test func newestOwnedAudioDeterminesExpiry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let newest = try #require(fixture.audio.first { $0.lastPathComponent.hasSuffix(".host_record.wav") })
        let modified = fixture.end.addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: newest.path)

        fixture.removeExpiredAudio(before: fixture.end)
        #expect(fixture.audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        fixture.removeExpiredAudio(before: modified)
        #expect(fixture.audio.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func expiresCanonicalLegacyAudioWithoutARawDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = fixture.recording.deletingLastPathComponent()
        let raw = folder.appendingPathComponent("raw")
        let text = folder.appendingPathComponent("meeting_test.sources.transcript.txt")
        let originalText = try Data(contentsOf: text)
        try FileManager.default.removeItem(at: raw)

        let reloaded = RecordingHistoryRepository()
        _ = await reloaded.refresh(root: fixture.root)
        reloaded.removeExpiredAudio(root: fixture.root, before: fixture.end, worker: fixture.worker)

        #expect(!FileManager.default.fileExists(atPath: fixture.recording.path))
        #expect(!FileManager.default.fileExists(atPath: raw.path))
        #expect(try Data(contentsOf: text) == originalText)
        #expect(reloaded.snapshot().entries.contains { $0.id == fixture.recording })
    }

    @Test func expiredAbandonedProcessingRemainsInLibraryAndFlatAudioIsPreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.repository.updateThrowing(fixture.recording) { $0.phase = .processing }
        let flatAudio = fixture.root.appendingPathComponent("meeting_flat.m4a")
        try Data([42]).write(to: flatAudio)
        try FileManager.default.setAttributes([.modificationDate: fixture.end], ofItemAtPath: flatAudio.path)

        fixture.removeExpiredAudio(before: fixture.end)
        #expect(fixture.audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let reloaded = RecordingHistoryRepository()
        _ = await reloaded.refresh(root: fixture.root)
        reloaded.removeExpiredAudio(root: fixture.root, before: fixture.end, worker: fixture.worker)
        #expect(fixture.audio.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(reloaded.snapshot().entries.first { $0.id == fixture.recording }?.phase == .interrupted)
        #expect(try Data(contentsOf: flatAudio) == Data([42]))
    }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let repository = RecordingHistoryRepository()
    let end = Date(timeIntervalSince1970: 1_800_000_000)
    let recording: URL
    let worker: URL
    let audio: [URL]
    let preserved: [URL: Data]

    init() throws {
        worker = try transcriptLockHelperBinary()
        let folder = root.appendingPathComponent("meeting_test")
        recording = folder.appendingPathComponent("meeting_test.m4a")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_parakeet_off.json")
        let version = "res_valid_parakeet_off"
        let olderVersion = "res_older"
        let result = try Data(contentsOf: fixtures)
        let audioPaths = [
            "meeting_test.m4a", "raw/meeting_test.host_record.wav", "raw/meeting_test.remote_record.wav",
            "raw/meeting_test.host.capture.caf", "raw/transcripts/\(version)/mix.m4a",
            "raw/transcripts/\(olderVersion)/mix.m4a", "raw/transcripts/\(olderVersion)/host_aec.wav",
            "raw/transcripts/.staging-\(version)/mix.m4a", "raw/transcripts/.staging-res_3180c32a/mix.m4a",
            "raw/transcripts/.staging-custom-job/host_aec.wav", ".\(UUID().uuidString).m4a"
        ]
        audio = audioPaths.map { folder.appendingPathComponent($0) }
        var expected: [URL: Data] = [:]
        for relative in ["summary.md", "meeting_test.sources.transcript.txt", "raw/transcripts/\(version)/edits.json",
                         "raw/transcripts/\(version)/transcript.txt", "raw/custom.wav",
                         "raw/transcripts/res_bad/result.json", "raw/transcripts/res_bad/mix.m4a",
                         "raw/transcripts/.staging-custom/mix.m4a", "raw/transcripts/.staging-custom-job/.meeting-companion-staging"] {
            expected[folder.appendingPathComponent(relative)] = Data("synthetic".utf8)
        }
        expected[folder.appendingPathComponent("raw/transcripts/\(version)/result.json")] = result
        var olderResult = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
        olderResult["resultID"] = olderVersion
        olderResult["playback"] = ["status": "ready", "mixPath": "raw/transcripts/\(olderVersion)/mix.m4a"]
        olderResult["aec"] = ["requested": true, "outcome": "applied"]
        var sources = try #require(olderResult["sources"] as? [[String: Any]])
        sources[0]["recognitionAudioPath"] = "raw/transcripts/\(olderVersion)/host_aec.wav"
        olderResult["sources"] = sources
        expected[folder.appendingPathComponent("raw/transcripts/\(olderVersion)/result.json")] =
            try JSONSerialization.data(withJSONObject: olderResult)
        expected[folder.appendingPathComponent("raw/transcripts/\(version)/edits.json")] =
            try JSONEncoder().encode(TranscriptEdits.initial(resultID: version))
        for (url, data) in expected.merging(Dictionary(uniqueKeysWithValues: audio.map { ($0, Data([1])) }), uniquingKeysWith: { a, _ in a }) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        for url in audio {
            try FileManager.default.setAttributes([.modificationDate: end], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: folder.appendingPathComponent("raw/transcripts/\(olderVersion)").path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_001)],
            ofItemAtPath: folder.appendingPathComponent("raw/transcripts/res_bad").path)
        let entry = RecordingEntry(recording: recording, date: end.addingTimeInterval(-300), title: "Test", phase: .completed)
        _ = try repository.putThrowing(entry)
        expected[entry.metadata] = try Data(contentsOf: entry.metadata)
        preserved = expected
    }

    func removeExpiredAudio(before cutoff: Date) {
        repository.removeExpiredAudio(root: root, before: cutoff, worker: worker)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
