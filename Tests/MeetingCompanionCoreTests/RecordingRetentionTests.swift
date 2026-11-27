import Foundation
import Testing
@testable import MeetingCompanionApplication
import MeetingCompanionCore

struct RecordingRetentionTests {
    @Test func stagesOperateOnOnlyTheirOwnedFiles() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        let recording = try RecordingPaths.makeOutputURL(outputDirectory: root)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        var entry = RecordingEntry(recording: recording, date: started, title: "Встреча", phase: .completed)
        entry.duration = 20
        let version = entry.folder.appendingPathComponent("raw/transcripts/res_valid_parakeet_off")

        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_parakeet_off.json")
        let older = version.deletingLastPathComponent().appendingPathComponent("older")
        try manager.createDirectory(at: older, withIntermediateDirectories: true)
        let olderJSON = try String(contentsOf: fixture, encoding: .utf8).replacingOccurrences(of: "res_valid_parakeet_off", with: "older")
        try Data(olderJSON.utf8).write(to: older.appendingPathComponent("result.json"))
        try manager.createDirectory(at: version, withIntermediateDirectories: true)
        try manager.copyItem(at: fixture, to: version.appendingPathComponent("result.json"))
        let oldMix = older.appendingPathComponent("mix.m4a"), oldAEC = older.appendingPathComponent("host_aec.wav")
        let notes = entry.folder.appendingPathComponent("мои заметки.txt")
        for file in [oldMix, oldAEC, notes] { try Data([2]).write(to: file) }
        let mix = version.appendingPathComponent("mix.m4a")
        let text = version.appendingPathComponent("transcript.txt")
        let external = root.appendingPathComponent("export.txt")
        let source = entry.rawBase.appendingPathExtension("host_record.wav")
        for url in [mix, text, external, recording, source] { try Data([1]).write(to: url) }
        let repo = RecordingHistoryRepository()
        _ = try repo.putThrowing(entry)
        let policy = RecordingRetention(sourceDays: 14, meetingMonths: 6)
        let first = started.addingTimeInterval(15 * 86400)
        let last = started.addingTimeInterval(200 * 86400)
        let verify: RecordingHistoryRepository.VerifyMix = { url, duration in url.path == mix.path && duration == 20 }
        #expect(try repo.retentionCandidates(root: root, policy: policy, now: first, verifyMix: { _,_ in false }).isEmpty)
        _ = try repo.updateThrowing(recording) { $0.addProblem(.capture, "Нужно сохранить оригиналы") }
        #expect(try repo.retentionCandidates(root: root, policy: policy, now: first, verifyMix: verify).isEmpty)
        _ = try repo.updateThrowing(recording) { $0.problems = []; $0.phase = .failed }
        #expect(try repo.retentionCandidates(root: root, policy: policy, now: first, verifyMix: verify).isEmpty)
        _ = try repo.updateThrowing(recording) { $0.phase = .completed }
        let recoveryCAF = entry.rawBase.appendingPathExtension("host.capture.caf")
        try Data().write(to: recoveryCAF)
        #expect(try repo.retentionCandidates(root: root, policy: policy, now: first, verifyMix: verify).isEmpty)
        try manager.removeItem(at: recoveryCAF)

        let sources = try #require(try repo.retentionCandidates(root: root, policy: policy, now: first, verifyMix: verify).first)
        do {
            let cli = try RecordingDirectoryLock(folder: entry.folder, exclusive: false)
            defer { withExtendedLifetime(cli) {} }
            #expect(throws: Error.self) { try repo.applyRetention(sources, policy: policy, now: first, verifyMix: verify, authorized: { true }) }
        }
        let editor = TranscriptEditsRepository(recordingDirectory: entry.folder)
        try editor.acquireWriteLock()
        #expect(throws: Error.self) { try repo.applyRetention(sources, policy: policy, now: first, verifyMix: verify, authorized: { true }) }
        editor.releaseWriteLock()
        let link = entry.rawBase.appendingPathExtension("remote_record.wav")
        try manager.createSymbolicLink(at: link, withDestinationURL: external)
        #expect(throws: Error.self) { try repo.applyRetention(sources, policy: policy, now: first, verifyMix: verify, authorized: { true }) }
        #expect(manager.fileExists(atPath: source.path))
        try manager.removeItem(at: link)
        try repo.applyRetention(sources, policy: policy, now: first, verifyMix: verify, authorized: { false })
        #expect(manager.fileExists(atPath: source.path))
        try repo.applyRetention(sources, policy: policy, now: first, verifyMix: verify, authorized: { FileManager.default.fileExists(atPath: source.path) })
        #expect(RecordingEntry.load(recording: recording).sourceRetention == .removing)
        #expect(manager.fileExists(atPath: recording.path))
        try repo.applyRetention(sources, policy: policy, now: first, verifyMix: verify, authorized: { true })
        #expect(RecordingEntry.load(recording: recording).capabilities.reason == "Исходники удалены по сроку хранения")
        #expect(!manager.fileExists(atPath: oldMix.path) && !manager.fileExists(atPath: oldAEC.path))
        #expect(manager.fileExists(atPath: notes.path))
        #expect(!manager.fileExists(atPath: source.path))
        #expect(!manager.fileExists(atPath: recording.path))
        #expect(try Data(contentsOf: mix) == Data([1]))
        #expect(RecordingEntry.load(recording: recording).capabilities.canReview)
        #expect(try String(contentsOf: text, encoding: .utf8) == "\u{1}")
        #expect(try repo.retentionCandidates(root: root, policy: policy, now: first, verifyMix: verify).isEmpty)
        let restarted = RecordingHistoryRepository()
        let meeting = try #require(try restarted.retentionCandidates(root: root, policy: policy, now: last, verifyMix: verify).first)
        #expect(restarted.allEntries().isEmpty)
        let job = UUID()
        #expect(repo.reserveWork(recording, id: job))
        #expect(throws: Error.self) { try repo.applyRetention(meeting, policy: policy, now: last, verifyMix: verify, authorized: { true }) }
        repo.releaseWork(recording, id: job)
        try restarted.applyRetention(meeting, policy: policy, now: last, verifyMix: verify, authorized: { true })
        #expect(!manager.fileExists(atPath: entry.folder.path))
        #expect(restarted.allEntries().isEmpty)
        #expect(manager.fileExists(atPath: external.path))
    }

    @Test func previewDiscoversMP4WithoutAlteringHistoryAndSkipsFlatFiles() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        let old = Date(timeIntervalSince1970: 1700000000)
        let mp4 = try RecordingPaths.makeOutputURL(outputDirectory: root, outputKind: .mp4, date: old)
        try manager.createDirectory(at: mp4.deletingLastPathComponent().appendingPathComponent("raw"), withIntermediateDirectories: true)
        _ = try RecordingHistoryRepository().putThrowing(RecordingEntry(recording: mp4, date: old, title: "MP4", phase: .failed))
        let flat = root.appendingPathComponent("meeting_2023-11-01_09-00-00.m4a")
        try Data().write(to: flat)
        let repo = RecordingHistoryRepository()
        let targets = try repo.retentionCandidates(root: root, policy: RecordingRetention(meetingMonths: 1), now: Date(),
                                                   verifyMix: { _, _ in false })
        #expect(targets.map(\.target.recording) == [mp4])
        #expect(repo.allEntries().isEmpty)
        // A moved directory stays intact even if an old descriptor still refers to it.
        let target = try #require(targets.first?.target)
        let pinned = try RecordingDirectoryLock(folder: target.folder, exclusive: true)
        let moved = root.appendingPathComponent("moved")
        try manager.moveItem(at: target.folder, to: moved)
        #expect(throws: Error.self) { try pinned.withVerifiedParent(of: target) { _ in Issue.record("Unexpected operation") } }
        #expect(manager.fileExists(atPath: moved.path))
        #expect(manager.fileExists(atPath: flat.path))
    }

    @Test func independentCalendarDeadlines() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(cal.date(from: DateComponents(year: 2024, month: 8, day: 31, hour: 12)))
        let end = try #require(cal.date(from: DateComponents(year: 2025, month: 2, day: 28, hour: 12)))
        let day14 = start.addingTimeInterval(14 * 86400)
        let both = RecordingRetention(sourceDays: 14, meetingMonths: 6)
        #expect(both.action(start: start, now: day14.addingTimeInterval(-1), calendar: cal) == nil)
        #expect(both.action(start: start, now: day14, calendar: cal) == .sources)
        #expect(both.action(start: start, now: end.addingTimeInterval(-1), calendar: cal) == .sources)
        #expect(both.action(start: start, now: end, calendar: cal) == .meeting)
        #expect(RecordingRetention(meetingMonths: 6).action(start: start, now: day14, calendar: cal) == nil)
        #expect(RecordingRetention(sourceDays: 14).action(start: start, now: end, calendar: cal) == .sources)
        #expect(RecordingRetention().action(start: start, now: end, calendar: cal) == nil)
        #expect(both.action(start: nil, now: end) == nil)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        let unknown = try decoder.decode(Date.self, from: encoder.encode(Date.distantPast))
        #expect(both.action(start: unknown, now: end) == nil)
    }
}
