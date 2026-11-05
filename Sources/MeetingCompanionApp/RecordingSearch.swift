import Foundation
import Darwin
import Combine
import MeetingCompanionCore

@MainActor final class RecordingSearch: ObservableObject {
    struct Result: Sendable {
        let matches: [RecordingEntry]
        let failures: [String]
    }
    @Published private(set) var result = Result(matches: [], failures: [])
    @Published private(set) var loading = false
    private var generation = 0
    private let scan: @Sendable (String, [RecordingEntry]) async -> Result
    init(scan: @escaping @Sendable (String, [RecordingEntry]) async -> Result = { RecordingSearch.scan(query: $0, entries: $1) }) { self.scan = scan }
    func update(query: String, entries: [RecordingEntry]) async {
        generation += 1
        let expected = generation
        loading = true
        let scan = scan
        let next = await Task.detached { await scan(query, entries) }.value
        guard expected == generation, !Task.isCancelled else { return }
        result = next; loading = false
    }
    nonisolated static func scan(query: String, entries: [RecordingEntry]) -> Result {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Result(matches: entries, failures: []) }
        var matches: [RecordingEntry] = []
        var failures: [String] = []
        for entry in entries {
            if Task.isCancelled { break }
            var text = entry.effectiveTitle
            var loadedDocument = false
            do {
                if RecordingPaths.isStandardLayout(entry.recording), let document = try TranscriptResultStorage(recordingURL: entry.recording).currentDocument() {
                    loadedDocument = true
                    let repository = TranscriptEditsRepository(recordingDirectory: entry.folder)
                    let edits = try repository.loadEdits(resultID: document.resultID)
                    text += "\n" + (try TranscriptExportFormatter().format(document: document, edits: edits, recordingDirectory: entry.folder))
                } else { text += try savedTXT(entry) }
            } catch {
                failures.append(entry.effectiveTitle + ": " + error.localizedDescription)
                if !loadedDocument { text += (try? savedTXT(entry)) ?? "" }
            }
            if text.localizedCaseInsensitiveContains(query) { matches.append(entry) }
        }
        return Result(matches: matches, failures: failures)
    }
    nonisolated private static func savedTXT(_ entry: RecordingEntry) throws -> String {
        var status = stat()
        guard lstat(entry.transcript.path, &status) == 0 else {
            let failure = errno
            if failure == ENOENT { return "" }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        let resolved = entry.transcript.resolvingSymlinksInPath().standardizedFileURL
        let parent = entry.folder.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(parent.path + "/"),
              try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw TranscriptWindowError.pathEscapesRecording(entry.transcript.path)
        }
        return "\n" + (try String(contentsOf: resolved, encoding: .utf8))
    }

}
