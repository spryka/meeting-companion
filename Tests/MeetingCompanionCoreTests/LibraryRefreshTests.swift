import Foundation
import Testing
import MeetingCompanionCore
@testable import MeetingCompanionApplication

struct LibraryRefreshTests {
    @Test func partialEnumerationReportsErrorAndKeepsReadableEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recording = root.appendingPathComponent("meeting_readable/meeting_readable.m4a")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: recording)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = RecordingHistoryRepository()
        let enumerate = repository.historyEnumerator
        repository.historyEnumerator = { directory, handler in
            _ = handler(directory.appendingPathComponent("unreadable"), CocoaError(.fileReadNoPermission))
            return enumerate(directory, handler)
        }
        let result = await repository.refresh(root: root)
        #expect(result.error != nil)
        #expect(result.entries.map(\.id) == [RecordingEntry.canonicalURL(recording)])
    }

    @Test func missingEnumeratorReportsFailureAndKeepsPreviousEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = RecordingHistoryRepository()
        repository.historyEnumerator = { _, _ in nil }
        let recording = root.appendingPathComponent("meeting_saved/meeting_saved.m4a")
        _ = try repository.putThrowing(RecordingEntry(recording: recording, date: Date(), title: "Saved", phase: .completed), persist: false)
        let result = await repository.refresh(root: root)
        #expect(result.error != nil)
        #expect(result.entries.map(\.id) == [recording])
    }

    @Test func missingRootReportsFailure() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = await RecordingHistoryRepository().refresh(root: root)
        #expect(result.error != nil)
    }

    @Test func fileInsteadOfRootReportsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let repository = RecordingHistoryRepository()
        let result = await repository.refresh(root: root)
        #expect(result.error != nil)
        #expect(result.entries.isEmpty)
    }
    @Test func staleScanCannotOverwriteNewerRequestOrMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("meeting_test/meeting_test.m4a")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
        try Data().write(to: recording)
        let repository = RecordingHistoryRepository()
        _ = await repository.refresh(root: root)
        let stale = repository.beginRefresh()
        let current = repository.beginRefresh()
        _ = await repository.refresh(root: root, request: current)
        _ = try repository.updateThrowing(recording, { $0.phase = .processing })
        _ = await repository.refresh(root: root, request: stale)
        #expect(repository.entry(recording)?.phase == .processing)
        let beforeUpdate = repository.beginRefresh()
        _ = try repository.updateThrowing(recording, { $0.phase = .recording })
        _ = await repository.refresh(root: root, request: beforeUpdate)
        #expect(repository.entry(recording)?.phase == .recording)
    }

    @Test func restoredFolderIsRediscoveredExactlyOnceWithoutChangingSavedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("meeting_restore")
        let recording = folder.appendingPathComponent("meeting_restore.m4a")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: recording)
        let repository = RecordingHistoryRepository()
        var entry = RecordingEntry(recording: recording, date: Date(), title: "Restored", phase: .completed)
        entry.displayTitle = "Saved display title"
        _ = try repository.putThrowing(entry)
        let metadata = try Data(contentsOf: entry.metadata)
        let target = try repository.prepareTrash(recording, root: root)
        let reservation = try repository.reserveTrash(target)
        let oldRequest = repository.beginRefresh()
        let trash = root.appendingPathComponent(".test-trash")
        #expect(try repository.trash(target, reservation: reservation, operation: { try FileManager.default.moveItem(at: $0, to: trash) }) == .moved)
        _ = await repository.refresh(root: root, request: oldRequest)
        #expect(repository.entry(recording) == nil)
        try FileManager.default.moveItem(at: trash, to: folder)
        _ = await repository.refresh(root: root)
        _ = await repository.refresh(root: root)
        #expect(repository.allEntries().count == 1)
        #expect(repository.entry(recording)?.displayTitle == "Saved display title")
        #expect(try Data(contentsOf: entry.metadata) == metadata)
        #expect(try Data(contentsOf: recording) == Data([1, 2, 3]))
    }
}
