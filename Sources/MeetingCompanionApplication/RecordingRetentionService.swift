import Darwin
import Foundation
import MeetingCompanionCore

public struct RetentionCandidate: Sendable {
    public let target: RecordingTrashTarget
    public let action: RecordingRetention.Action
}

extension RecordingHistoryRepository {
    public typealias VerifyMix = @Sendable (URL, Double) throws -> Bool

    public func retentionCandidates(root: URL, policy: RecordingRetention, now: Date,
                                    verifyMix: VerifyMix) throws -> [RetentionCandidate] {
        guard policy != RecordingRetention() else { return [] }
        let scan = scanRecordings(in: root)
        guard scan.complete else {
            throw RecordingTrashFailure(message: scan.error ?? "Не удалось прочитать папку записей.", retryAllowed: true)
        }
        var result: [RetentionCandidate] = []
        for entry in scan.entries {
            try Task.checkCancellation()
            guard let action = retentionAction(entry, policy: policy, now: now),
                  let target = try? retentionTarget(entry.recording, root: root) else { continue }
            if action == .sources, (try? expiringAudio(entry, verifyMix: verifyMix)) == nil { continue }
            result.append(RetentionCandidate(target: target, action: action))
        }
        return result
    }

    private func retentionAction(_ entry: RecordingEntry, policy: RecordingRetention, now: Date) -> RecordingRetention.Action? {
        guard RecordingPaths.isStandardLayout(entry.recording) else { return nil }
        let storage = TranscriptResultStorage(recordingURL: entry.recording)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            if let data = try storage.metadataData() {
                let saved = try decoder.decode(RecordingEntry.self, from: data)
                guard saved.folder.path == entry.folder.path, saved.base.lastPathComponent == entry.base.lastPathComponent,
                      ["m4a", "mp4"].contains(saved.recording.pathExtension) else { return nil }
                return policy.action(start: saved.date, now: now)
            }
        } catch { return nil }
        // Older captures may only have a generated recording name and their original audio.
        let stem = entry.base.lastPathComponent
        guard let match = stem.wholeMatch(of: /^meeting_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})(?:_\d+)?$/),
              entry.containedReadableFile(entry.rawBase.appendingPathExtension("host_record.wav")),
              entry.containedReadableFile(entry.rawBase.appendingPathExtension("remote_record.wav")) else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        guard let date = format.date(from: String(match.1)), format.string(from: date) == match.1 else { return nil }
        return policy.action(start: date, now: now)
    }

    private func expiringAudio(_ entry: RecordingEntry, verifyMix: VerifyMix) throws -> [URL]? {
        guard entry.phase == .completed, let duration = entry.duration, duration.isFinite, duration > 0,
              !entry.problems.contains(where: { [.capture, .saving, .recovery].contains($0.stage) }) else { return nil }
        let storage = TranscriptResultStorage(recordingURL: entry.recording)
        guard let doc = try storage.currentDocument(), doc.playback.status == .ready,
              let relative = doc.playback.mixPath, relative == "raw/transcripts/\(doc.resultID)/mix.m4a",
              try storage.committedText(after: nil) != nil else { return nil }
        let mix = entry.folder.appendingPathComponent(relative)
        // The recorder keeps CAF only when capture or export needs recovery.
        for suffix in ["host.capture.caf", "remote.capture.caf"] {
            if try ownedRegularFile(entry.rawBase.appendingPathExtension(suffix), in: entry.folder) { return nil }
        }
        if try ownedRegularFile(entry.captureReport, in: entry.folder), !entry.containedReadableFile(entry.captureReport) { return nil }
        var files = ["host_record.wav", "remote_record.wav", "host_record.aec.wav"]
            .map { entry.rawBase.appendingPathExtension($0) }
        files += ["m4a", "mp4"].map { entry.base.appendingPathExtension($0) }
        let transcripts = entry.folder.appendingPathComponent("raw/transcripts")
        for published in try storage.publishedResultDirectories() {
            let dir = transcripts.appendingPathComponent(published.lastPathComponent, isDirectory: true)
            if dir.lastPathComponent != doc.resultID {
                let json = dir.appendingPathComponent("result.json")
                guard let old = try? TranscriptDocument.load(from: json, recordingDirectory: entry.folder),
                      old.resultID == dir.lastPathComponent else { continue }
                if old.playback.mixPath == "raw/transcripts/\(old.resultID)/mix.m4a" {
                    files.append(dir.appendingPathComponent("mix.m4a"))
                }
            }
            files.append(dir.appendingPathComponent("host_aec.wav"))
        }
        let existing = try files.filter { try ownedRegularFile($0, in: entry.folder) }
        guard !existing.isEmpty || entry.sourceRetention == .removing,
              try ownedRegularFile(mix, in: entry.folder), try verifyMix(mix, duration) else { return nil }
        return existing
    }

    private func ownedRegularFile(_ url: URL, in folder: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG, url.path.hasPrefix(folder.path + "/"),
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: url.path])
        }
        return true
    }

    public func applyRetention(_ candidate: RetentionCandidate, policy: RecordingRetention, now: Date,
                               verifyMix: VerifyMix, authorized: @Sendable () -> Bool) throws {
        let target = candidate.target
        guard authorized() else { return }
        let reservation = try reserveTrash(target)
        defer { releaseTrash(target, id: reservation) }
        let directoryLock = try RecordingDirectoryLock(folder: target.folder, exclusive: true)
        defer { withExtendedLifetime(directoryLock) {} }
        try validateRetention(target, reservation: reservation, lock: directoryLock)
        let fresh = RecordingEntry.load(recording: target.recording)
        guard retentionAction(fresh, policy: policy, now: now) == candidate.action, authorized() else { return }
        switch candidate.action {
        case .meeting:
            let outcome = try trash(target, reservation: reservation) { _ in
                guard authorized() else { throw CancellationError() }
                try directoryLock.removeMeeting(target)
            }
            if case .unconfirmed(let message) = outcome {
                throw RecordingTrashFailure(message: message, retryAllowed: false)
            }
        case .sources:
            let writer = TranscriptEditsRepository(recordingDirectory: target.folder)
            try writer.acquireWriteLock()
            defer { writer.releaseWriteLock() }
            guard let files = try expiringAudio(fresh, verifyMix: verifyMix), authorized() else { return }
            try validateRetention(target, reservation: reservation, lock: directoryLock)
            if fresh.sourceRetention != .removing { try recordSourceExpiry(.removing, target: target, reservation: reservation) }
            for file in files {
                guard authorized() else { return }
                try directoryLock.withVerifiedParent(of: target) { _ in
                    if try ownedRegularFile(file, in: target.folder) {
                        try directoryLock.removeFile(file, from: target.folder)
                    }
                }
            }
            if authorized(), try files.allSatisfy({ try !ownedRegularFile($0, in: target.folder) }) {
                try recordSourceExpiry(.removed, target: target, reservation: reservation)
            }
        }
    }
}
