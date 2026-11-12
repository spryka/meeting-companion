import Foundation

public struct RecordingPaths {
    public static let unsupportedLayoutMessage = "Нестандартное размещение записи. Поддерживается отдельная папка с именем записи; доступен только сохранённый TXT для чтения."

    public static func isStandardLayout(_ recording: URL) -> Bool {
        let url = RecordingEntry.canonicalURL(recording)
        return url.deletingLastPathComponent().lastPathComponent == url.deletingPathExtension().lastPathComponent
    }

    public static func requireStandardLayout(_ recording: URL) throws {
        guard isStandardLayout(recording) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: unsupportedLayoutMessage])
        }
    }

    public static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent("Meetings")
    }

    public static func makeOutputURL(outputDirectory: URL, outputKind: OutputKind = .m4a, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM/dd"
        let directory = outputDirectory.appendingPathComponent(formatter.string(from: date))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let baseName = "meeting_\(formatter.string(from: date))"
        var name = baseName
        var meetingDirectory = directory.appendingPathComponent(name)
        var suffix = 1
        while FileManager.default.fileExists(atPath: meetingDirectory.path) {
            name = "\(baseName)_\(suffix)"
            meetingDirectory = directory.appendingPathComponent(name)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: false)
        return meetingDirectory.appendingPathComponent(name).appendingPathExtension(outputKind.fileExtension)
    }
}
