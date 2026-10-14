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
        let access = RecorderDiagnostics.access()
        precondition(access.map(\.name) == ["Микрофон", "Системный звук", "Календарь"])
        for item in access { print(item.name + ": " + item.message) }
        print("Folder write/preservation checks passed")
    }
}
