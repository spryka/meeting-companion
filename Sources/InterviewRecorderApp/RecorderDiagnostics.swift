import AVFoundation
import CoreGraphics
import EventKit
import Foundation

struct RecorderDiagnostics {
    static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/InterviewRecorder")
    }

    struct PreparationProgress: Sendable, Equatable {
        var bytes: Int64 = 0
        var lastModified: Date?
    }

    static func preparationProgress(in directory: URL) -> PreparationProgress {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let properties = Set(keys)
        var result = PreparationProgress()
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return result }
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: properties),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            result.bytes += Int64(values.fileSize ?? 0)
            if let date = values.contentModificationDate, date > (result.lastModified ?? .distantPast) {
                result.lastModified = date
            }
        }
        return result
    }

    struct Access: Identifiable, Equatable {
        enum State { case granted, pending, denied }
        let name: String
        let message: String
        let state: State
        var id: String { name }
    }

    static func access() -> [Access] {
        let microphone: String
        let microphoneState: Access.State
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "доступ разрешён"; microphoneState = .granted
        case .notDetermined: microphone = "доступ ещё не запрошен"; microphoneState = .pending
        case .denied: microphone = "доступ запрещён"; microphoneState = .denied
        case .restricted: microphone = "доступ ограничен macOS"; microphoneState = .denied
        @unknown default: microphone = "статус неизвестен"; microphoneState = .pending
        }
        let calendar = EKEventStore.authorizationStatus(for: .event)
        let calendarText = calendar == .fullAccess ? "доступ разрешён" :
            calendar == .notDetermined ? "доступ ещё не запрошен" : "нет доступа к чтению"
        let systemAllowed = CGPreflightScreenCaptureAccess()
        return [Access(name: "Микрофон", message: microphone, state: microphoneState),
            Access(name: "Системный звук", message: systemAllowed ? "доступ разрешён" : "нет доступа", state: systemAllowed ? .granted : .denied),
            Access(name: "Календарь", message: calendarText, state: calendar == .fullAccess ? .granted :
                calendar == .notDetermined ? .pending : .denied)]
    }

    static func checkFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let probe = folder.appendingPathComponent(".recorder-check-" + UUID().uuidString)
        try Data("check".utf8).write(to: probe, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probe)
    }
}
