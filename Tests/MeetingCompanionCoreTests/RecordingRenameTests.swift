import Foundation
import Testing
@testable import MeetingCompanionCore
@testable import MeetingCompanionApplication

struct RecordingRenameTests {
    @Test func workspaceRenamePersistsAndPreservesUnknownPrecision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("meeting_test")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("meeting_test.m4a")
        let repo = RecordingHistoryRepository()
        let original = try repo.putThrowing(RecordingEntry(recording: url, date: Date(), title: "Original", phase: .completed))
        var bytes = try String(contentsOf: original.metadata, encoding: .utf8)
        bytes = String(bytes.dropLast()) + ",\"exact\":900719925474099312345,\"future\":{\"n\":1.2300000000000000001}}"
        try Data(bytes.utf8).write(to: original.metadata)
        _ = try repo.rename(url, displayTitle: "  Локальное имя  ")
        let data = try Data(contentsOf: original.metadata)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["displayTitle"] as? String == "Локальное имя")
        #expect(String(decoding: data, as: UTF8.self).contains("900719925474099312345"))
        #expect(String(decoding: data, as: UTF8.self).contains("1.2300000000000000001"))
        #expect(RecordingEntry.load(recording: url).effectiveTitle == "Локальное имя")
        _ = try repo.rename(url, displayTitle: "Локальное имя")
        #expect(try Data(contentsOf: original.metadata) == data)
        _ = try repo.putThrowing(original)
        #expect(RecordingEntry.load(recording: url).effectiveTitle == "Локальное имя")
        #expect(String(decoding: try Data(contentsOf: original.metadata), as: UTF8.self).components(separatedBy: "\"displayTitle\"").count == 2)
        let beforeError = try Data(contentsOf: original.metadata)
        try FileManager.default.removeItem(at: original.metadata)
        try FileManager.default.createDirectory(at: original.metadata, withIntermediateDirectories: true)
        #expect(throws: Error.self) { try repo.rename(url, displayTitle: "Failed title") }
        #expect(repo.entry(url)?.effectiveTitle == "Локальное имя")
        try FileManager.default.removeItem(at: original.metadata)
        try beforeError.write(to: original.metadata)
        let flat = root.appendingPathComponent("flat.m4a")
        #expect(throws: Error.self) { try repo.rename(flat, displayTitle: "Never write") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("flat.processing.json").path))
        #expect(throws: Error.self) { try repo.rename(url, displayTitle: "  ") }
        #expect(throws: Error.self) { try repo.rename(url, displayTitle: String(repeating: "a", count: 121)) }
        #expect(throws: Error.self) { try repo.rename(url, displayTitle: "bad\nname") }
        _ = repo.updateStatus(url) { $0.phase = .processing }
        #expect(throws: Error.self) { try repo.rename(url, displayTitle: "Busy") }
    }
}
