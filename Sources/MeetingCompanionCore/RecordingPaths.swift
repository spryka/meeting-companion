import Foundation

public struct RecordingPaths {
    public static let audioRetentionMarker = ".audio-retention-applied"
    package static let transcriptionStagingMarker = ".meeting-companion-staging"

    package static func isTemporaryMixedAudio(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".m4a") || name.hasSuffix(".mp4") else { return false }
        return UUID(uuidString: String(name.dropFirst().dropLast(4))) != nil
    }

    package static func managedDirectory(containing audio: URL) -> URL? {
        var folder = audio.deletingLastPathComponent()
        while folder.path != "/" {
            let metadata = folder.appendingPathComponent("raw")
                .appendingPathComponent(folder.lastPathComponent + ".processing.json")
            if (try? metadata.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return folder }
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path else { return nil }
            folder = parent
        }
        return nil
    }

    public static func audioRetentionApplied(in recordingDirectory: URL) -> Bool {
        let marker = recordingDirectory.appendingPathComponent("raw").appendingPathComponent(audioRetentionMarker)
        return (try? marker.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

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
