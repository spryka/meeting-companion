import Foundation
import Testing
@testable import MeetingCompanionCore
@testable import MeetingCompanionApplication

private struct TrashFixture {
    let root: URL
    let recording: URL
    let repository = RecordingHistoryRepository()
    var folder: URL { recording.deletingLastPathComponent() }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("trash-test-" + UUID().uuidString).resolvingSymlinksInPath()
        recording = root.appendingPathComponent("2026-11/09/meeting_test/meeting_test.m4a")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: recording)
        _ = try repository.putThrowing(RecordingEntry(recording: recording, date: Date(), title: "Test", phase: .completed))
    }
    func target() throws -> RecordingTrashTarget { try repository.prepareTrash(recording, root: root) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct RecordingTrashTests {
    @Test func historicalAECIsOwnedAndPreserved() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let artifact = f.folder.appendingPathComponent("raw/meeting_test.host_record.aec.wav")
        try Data("historical AEC".utf8).write(to: artifact)
        let target = try f.target(), token = try f.repository.reserveTrash(target)
        let destination = f.root.appendingPathComponent("synthetic-trash")
        _ = try f.repository.trash(target, reservation: token) { try FileManager.default.moveItem(at: $0, to: destination) }
        #expect(try String(contentsOf: destination.appendingPathComponent("raw/meeting_test.host_record.aec.wav"), encoding: .utf8) == "historical AEC")
    }

    @Test func symlinkDoesNotSkipFollowingOwnershipChecks() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let link = f.folder.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root.appendingPathComponent("absent"))
        try Data().write(to: f.folder.appendingPathComponent("raw/other.host_record.wav"))
        #expect(throws: Error.self) { try f.target() }
    }

    @Test(arguments: [".hidden/second", "raw/second", "experiments/second", "second"], ["m4a", "mp4"])
    func ownershipIncludesHiddenRawExperimentsAndNonMeetingNames(path: String, ext: String) throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let nested = f.folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("second." + ext))
        #expect(throws: Error.self) { try f.target() }
    }

    @Test(arguments: ["raw/other.host_record.wav", ".hidden/second/raw/second.processing.json"])
    func ownershipDetectsOtherOriginalsAndMetadataWithoutMixedAudio(path: String) throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let artifact = f.folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: artifact)
        #expect(throws: Error.self) { try f.target() }
    }

    @Test func overlappingReservationCannotBeAdmittedDuringNativeOperation() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let target = try f.target(), token = try f.repository.reserveTrash(target)
        let destination = f.root.appendingPathComponent("synthetic-trash")
        _ = try f.repository.trash(target, reservation: token) { folder in
            let nested = folder.appendingPathComponent(".hidden/second")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let url = nested.appendingPathComponent("second.m4a")
            try Data().write(to: url)
            #expect(throws: Error.self) {
                let child = try f.repository.prepareTrash(url, root: f.root)
                let childToken = try f.repository.reserveTrash(child)
                f.repository.releaseTrash(child, id: childToken)
            }
            #expect(f.repository.snapshot().entries.map(\.id) == [target.recording])
            try FileManager.default.moveItem(at: folder, to: destination)
        }
        #expect(f.repository.snapshot().entries.isEmpty)
        #expect(f.repository.entry(f.folder.appendingPathComponent(".hidden/second/second.m4a")) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.folder.path))
    }

    @Test func finalIdentityCheckFollowsOwnershipTraversal() throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
        }
        let f = try TrashFixture(); defer { f.cleanup() }
        let target = try f.target(), token = try f.repository.reserveTrash(target), counter = Counter()
        f.repository.trashValidationDidScan = {
            if counter.next() == 2 {
                try FileManager.default.moveItem(at: f.folder, to: f.root.appendingPathComponent("original"))
                try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
            }
        }
        #expect(throws: Error.self) {
            try f.repository.trash(target, reservation: token) { _ in Issue.record("Replacement must never reach native operation") }
        }
    }

    @Test func duplicateExecutionCannotReleaseRunningReservation() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let target = try f.target(), token = try f.repository.reserveTrash(target)
        let destination = f.root.appendingPathComponent("synthetic-trash")
        _ = try f.repository.trash(target, reservation: token) { folder in
            #expect(throws: Error.self) {
                try f.repository.trash(target, reservation: token) { _ in Issue.record("Duplicate disk operation") }
            }
            f.repository.releaseTrash(target, id: token)
            let work = UUID()
            #expect(!f.repository.reserveWork(f.recording, id: work))
            f.repository.releaseWork(f.recording, id: work)
            try FileManager.default.moveItem(at: folder, to: destination)
        }
    }

    @Test func commitRevalidatesAfterReservationAndRejectsOtherWriter() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let target = try f.target(), token = try f.repository.reserveTrash(target)
        let otherWriter = TranscriptEditsRepository(recordingDirectory: f.folder)
        try otherWriter.acquireWriteLock()
        #expect(throws: Error.self) {
            try f.repository.trash(target, reservation: token) { _ in Issue.record("Must not trash while another writer is open") }
        }
        otherWriter.releaseWriteLock()
        let next = try f.repository.reserveTrash(target)
        let original = f.root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: f.folder, to: original)
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        #expect(throws: Error.self) {
            try f.repository.trash(target, reservation: next) { _ in Issue.record("Must reject replaced folder after awaited teardown") }
        }
    }

    @Test func ownedFolderMovesAsOneUnitAndRestoredFolderCanBeScanned() async throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let extra = f.folder.appendingPathComponent("notes.txt")
        try Data("user notes".utf8).write(to: extra)
        for source in ["host", "remote"] {
            try Data("synthetic source".utf8).write(to: f.folder.appendingPathComponent("raw/meeting_test." + source + "_record.wav"))
        }
        try Data("synthetic historical AEC".utf8).write(to: f.folder.appendingPathComponent("raw/meeting_test.host_record.aec.wav"))
        let external = f.root.appendingPathComponent("external.txt")
        try Data("outside".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: f.folder.appendingPathComponent("external-link"), withDestinationURL: external)
        let target = try f.target(), token = try f.repository.reserveTrash(target)
        let destination = f.root.appendingPathComponent("synthetic-trash")
        let revision = f.repository.snapshot().revision
        let result = try f.repository.trash(target, reservation: token) { folder in
            #expect(folder == f.folder)
            try FileManager.default.moveItem(at: folder, to: destination)
        }
        #expect(result == .moved)
        #expect(f.repository.entry(f.recording) == nil)
        #expect(f.repository.snapshot().revision > revision)
        #expect(try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8) == "user notes")
        #expect(try String(contentsOf: external, encoding: .utf8) == "outside")
        try FileManager.default.moveItem(at: destination, to: f.folder)
        _ = await f.repository.refresh(root: f.root)
        #expect(f.repository.entry(f.recording) != nil)
    }

    @Test func unsupportedSharedRootDayAndOutsideAreRejected() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        for root in [f.folder, f.folder.appendingPathComponent("raw"), f.root.appendingPathComponent("elsewhere")] {
            #expect(throws: Error.self) { try f.repository.prepareTrash(f.recording, root: root) }
        }
        let flat = f.root.appendingPathComponent("2026-11/09/meeting_flat.m4a")
        try Data().write(to: flat)
        _ = f.repository.put(RecordingEntry.load(recording: flat), persist: false)
        #expect(throws: Error.self) { try f.repository.prepareTrash(flat, root: f.root) }
        let second = f.folder.appendingPathComponent("meeting_other.m4a")
        try Data().write(to: second)
        #expect(throws: Error.self) { try f.target() }
    }

    @Test func busyAndReservationRejectTrashEvenBeforePhaseChanges() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let target = try f.target(), work = UUID()
        f.repository.reserveWork(f.recording, id: work)
        #expect(throws: Error.self) { try f.repository.reserveTrash(target) }
        f.repository.releaseWork(f.recording, id: work)
        for phase: RecordingEntry.Phase in [.recording, .saving, .queued, .processing] {
            _ = try f.repository.updateThrowing(f.recording) { $0.phase = phase }
            #expect(throws: Error.self) { try f.target() }
            #expect(throws: Error.self) { try f.repository.reserveTrash(target) }
        }
    }

    @Test func replacementAndSymlinkAfterConfirmationAreRejected() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let target = try f.target()
        let original = f.root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: f.folder, to: original)
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        #expect(throws: Error.self) { try f.repository.reserveTrash(target) }
        try FileManager.default.removeItem(at: f.folder)
        try FileManager.default.createSymbolicLink(at: f.folder, withDestinationURL: original)
        #expect(throws: Error.self) { try f.repository.reserveTrash(target) }
        #expect(throws: Error.self) { try f.repository.prepareTrash(f.recording, root: f.root) }
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func trashReservationBlocksMetadataRenameAndDuplicateTrash() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let target = try f.target(), token = try f.repository.reserveTrash(target)
        defer { f.repository.releaseTrash(target, id: token) }
        let entry = try #require(f.repository.entry(f.recording))
        let before = try Data(contentsOf: entry.metadata)
        #expect(throws: Error.self) { try f.repository.reserveTrash(target) }
        #expect(throws: Error.self) { try f.repository.rename(f.recording, displayTitle: "Blocked") }
        #expect(throws: Error.self) { try f.repository.putThrowing(entry) }
        #expect(throws: Error.self) { try f.repository.updateThrowing(f.recording) { $0.title = "Blocked" } }
        _ = f.repository.put(entry)
        _ = f.repository.updateStatus(f.recording) { $0.phase = .queued }
        #expect(try Data(contentsOf: entry.metadata) == before)
        #expect(f.repository.entry(f.recording)?.phase == .completed)
    }

    @Test func knownFailurePreservesHistoryAndAllowsExplicitRetry() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let target = try f.target(), token = try f.repository.reserveTrash(target)
        do {
            _ = try f.repository.trash(target, reservation: token) { _ in throw CocoaError(.fileWriteNoPermission) }
            Issue.record("Expected failure")
        } catch let error as RecordingTrashFailure { #expect(error.retryAllowed) }
        #expect(f.repository.entry(f.recording) != nil)
        let retry = try f.repository.reserveTrash(target)
        f.repository.releaseTrash(target, id: retry)
    }

    @Test func uncertainMissingSourceNeverReportsSuccessOrAutomaticallyRetries() throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let target = try f.target(), token = try f.repository.reserveTrash(target)
        let destination = f.root.appendingPathComponent("synthetic-trash")
        let outcome = try f.repository.trash(target, reservation: token) { folder in
            try FileManager.default.moveItem(at: folder, to: destination)
            throw CocoaError(.fileWriteUnknown)
        }
        guard case .unconfirmed = outcome else { Issue.record("Must reconcile without declaring success"); return }
        #expect(f.repository.entry(f.recording) == nil)
        #expect(throws: Error.self) { try f.repository.reserveTrash(target) }
    }

    @Test func staleWritesCannotResurrectRemovedRecording() async throws {
        let f = try TrashFixture(); defer { f.cleanup() }
        let entry = try #require(f.repository.entry(f.recording))
        let target = try f.target(), token = try f.repository.reserveTrash(target)
        let destination = f.root.appendingPathComponent("synthetic-trash")
        _ = try f.repository.trash(target, reservation: token) { try FileManager.default.moveItem(at: $0, to: destination) }
        _ = f.repository.put(entry)
        _ = f.repository.put(entry, persist: false)
        _ = f.repository.updateStatus(f.recording) { $0.phase = .completed }
        _ = await f.repository.refresh(root: f.folder.deletingLastPathComponent())
        #expect(f.repository.entry(f.recording) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.folder.path))
    }
}
