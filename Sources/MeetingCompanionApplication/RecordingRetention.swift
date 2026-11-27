import Darwin
import Foundation
import MeetingCompanionCore

public struct RecordingRetention: Codable, Equatable, Sendable {
    public var sourceDays: Int
    public var meetingMonths: Int
    public init(sourceDays: Int = 0, meetingMonths: Int = 0) {
        self.sourceDays = sourceDays
        self.meetingMonths = meetingMonths
    }
    public enum Action: Sendable { case sources, meeting }
    public func action(start: Date?, now: Date, calendar: Calendar = .current) -> Action? {
        guard let start, start > .distantPast, start <= now else { return nil }
        if meetingMonths > 0, let end = calendar.date(byAdding: .month, value: meetingMonths, to: start), end <= now { return .meeting }
        if sourceDays > 0, let end = calendar.date(byAdding: .day, value: sourceDays, to: start), end <= now { return .sources }
        return nil
    }

    public static func preferenceKey(for root: URL) -> String? {
        let directory = root.standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return "recordingRetention.\(directory.path).\(info.st_dev).\(info.st_ino).\(info.st_birthtimespec.tv_sec).\(info.st_birthtimespec.tv_nsec)"
    }

}
