import Foundation
@main struct Check {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try RecorderDiagnostics.checkFolder(folder)
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(entries.isEmpty)
        let existing = folder.appendingPathComponent("existing.wav")
        try Data("keep".utf8).write(to: existing)
        try RecorderDiagnostics.checkFolder(folder)
        let preserved = try Data(contentsOf: existing)
        precondition(preserved == Data("keep".utf8))
        let first = RecorderDiagnostics.preparationProgress(in: folder)
        precondition(first.bytes == 4 && first.lastModified != nil)
        let alias = folder.appendingPathComponent("alias.wav")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: existing)
        precondition(RecorderDiagnostics.preparationProgress(in: folder).bytes == 4)
        try Data("longer file".utf8).write(to: existing)
        precondition(RecorderDiagnostics.preparationProgress(in: folder).bytes == 11)
        do { try RecorderDiagnostics.checkFolder(existing); preconditionFailure("File accepted as folder") } catch {}
        let cache = folder.appendingPathComponent("app")
        let recordings = folder.appendingPathComponent("recordings")
        for name in ["models", "runtime", "settings"] {
            let path = cache.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: path.appendingPathComponent("data"))
        }
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let recording = recordings.appendingPathComponent("meeting.wav")
        try Data("recording".utf8).write(to: recording)
        do {
            try RecorderDiagnostics.resetCache(in: cache, recordings: cache.appendingPathComponent("models/recordings"))
            preconditionFailure("Nested recordings accepted")
        } catch {}
        do {
            try RecorderDiagnostics.resetCache(in: cache, recordings: folder)
            preconditionFailure("Parent recordings accepted")
        } catch {}
        let linked = folder.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("models"), withDestinationURL: cache.appendingPathComponent("models"))
        do {
            try RecorderDiagnostics.resetCache(in: linked, recordings: recordings)
            preconditionFailure("Linked cache accepted")
        } catch {}
        precondition(FileManager.default.fileExists(atPath: cache.appendingPathComponent("models/data").path))
        try RecorderDiagnostics.resetCache(in: cache, recordings: recordings)
        try RecorderDiagnostics.resetCache(in: cache, recordings: recordings)
        precondition(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("models").path))
        precondition(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("runtime").path))
        precondition(FileManager.default.fileExists(atPath: cache.appendingPathComponent("settings/data").path))
        let savedRecording = try Data(contentsOf: recording)
        precondition(savedRecording == Data("recording".utf8))
        let access = RecorderDiagnostics.access()
        precondition(access.map(\.name) == ["Микрофон", "Системный звук", "Календарь"])
        let tapAccess = RecorderDiagnostics.access(coreAudioTap: true)
        precondition(tapAccess[1].state == .pending)
        precondition(tapAccess[1].message.contains("Проверить звук"))
        for state in [RecorderDiagnostics.Access.State.granted, .denied] {
            let result = RecorderDiagnostics.Access(name: "Системный звук", message: "checked", state: state)
            for tap in [false, true] {
                precondition(RecorderDiagnostics.access(coreAudioTap: tap, captureCheck: result)[1] == result)
            }
        }
        precondition(RecorderDiagnostics.access(coreAudioTap: true)[1].state == .pending)
        for item in access { print(item.name + ": " + item.message) }
        print("Folder write/preservation checks passed")
    }
}
