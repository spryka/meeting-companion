import AVFoundation
import CoreGraphics
import EventKit
import Foundation

struct RecorderDiagnostics {
    static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MeetingCompanion")
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

    static func access(coreAudioTap: Bool = false, captureCheck: Access? = nil) -> [Access] {
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
            captureCheck ?? Access(name: "Системный звук", message: coreAudioTap ? "Не проверен" : systemAllowed ? "доступ разрешён" : "нет доступа", state: coreAudioTap ? .pending : systemAllowed ? .granted : .denied),
            Access(name: "Календарь", message: calendarText, state: calendar == .fullAccess ? .granted :
                calendar == .notDetermined ? .pending : .denied)]
    }

    static func cacheDirectories(in directory: URL, recordings: URL) throws -> [URL] {
        if FileManager.default.fileExists(atPath: directory.path),
           try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw NSError(domain: "CacheReset", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Сброс отменён: папка данных приложения заменена ссылкой."])
        }
        let targets = ["models", "runtime"].map { directory.appendingPathComponent($0) }
        let recordingPath = recordings.resolvingSymlinksInPath().standardizedFileURL.path
        for target in targets {
            let path = target.resolvingSymlinksInPath().standardizedFileURL.path
            guard recordingPath != path, !recordingPath.hasPrefix(path + "/"),
                  !path.hasPrefix(recordingPath + "/") else {
                throw NSError(domain: "CacheReset", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Папка записей пересекается с кэшем. Сначала выберите другую папку записей."])
            }
            if FileManager.default.fileExists(atPath: target.path) {
                let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else {
                    throw NSError(domain: "CacheReset", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        "Сброс отменён: папка кэша заменена ссылкой или файлом."])
                }
            }
        }
        return targets
    }

    static func resetCache(in directory: URL, recordings: URL) throws {
        for target in try cacheDirectories(in: directory, recordings: recordings) {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        }
    }

    static func checkFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let probe = folder.appendingPathComponent(".recorder-check-" + UUID().uuidString)
        try Data("check".utf8).write(to: probe, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probe)
    }
}
