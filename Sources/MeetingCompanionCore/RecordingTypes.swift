import Foundation

public enum OutputKind: Sendable {
    case m4a
    case mp4

    public var fileExtension: String {
        switch self {
        case .m4a:
            return "m4a"
        case .mp4:
            return "mp4"
        }
    }
}

public struct RecordingResult: Sendable {
    public let outputURL: URL
    public let duration: TimeInterval
    public let fileSize: Int
    public let warnings: [String]

    public init(outputURL: URL, duration: TimeInterval, fileSize: Int, warnings: [String]) {
        self.outputURL = outputURL
        self.duration = duration
        self.fileSize = fileSize
        self.warnings = warnings
    }
}

public protocol StoppedCaptureProtocol: Sendable {
    var outputURL: URL { get }
    var duration: Double { get }
    func finish() async -> RecordingResult
}

public struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@available(macOS 15.0, *)
public enum MicrophoneRecordingState: Sendable, Equatable {
    case receiving, silent, missing, reconnecting
}

public func formatDuration(_ seconds: TimeInterval) -> String {
    let rounded = Int(seconds.rounded())
    let hours = rounded / 3600
    let minutes = (rounded % 3600) / 60
    let seconds = rounded % 60

    if hours > 0 {
        return "\(hours)h \(String(format: "%02d", minutes))m \(String(format: "%02d", seconds))s"
    }

    return "\(minutes)m \(String(format: "%02d", seconds))s"
}

public func formatClock(_ seconds: TimeInterval) -> String {
    let rounded = Int(seconds.rounded())
    let hours = rounded / 3600
    let minutes = (rounded % 3600) / 60
    let seconds = rounded % 60

    if hours > 0 {
        return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
    }

    return "\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
}

public func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

public func fileSize(at url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.size] as? Int ?? 0
}

public let permissionHint = """

If this is the first run, grant permissions in System Settings:
  Privacy & Security -> Screen & System Audio Recording
  Privacy & Security -> Microphone

When running from Terminal, the permission is usually granted to Terminal.app.
After changing permissions, quit and reopen Terminal before retrying.
"""
