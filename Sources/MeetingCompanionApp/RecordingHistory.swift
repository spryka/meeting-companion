import Combine
import Foundation
#if canImport(MeetingCompanionCore)
import MeetingCompanionCore
#endif

struct SavedMeeting: Codable, Equatable, Sendable {
    let summary: String
    let start: Date
    let end: Date
    let agenda: String
    let attendees: [String]
    let links: [String]
}

struct RecordingProblem: Codable, Equatable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable {
        case capture, saving, transcription, context, recovery
        var title: String {
            switch self {
            case .capture: return "Захват звука"
            case .saving: return "Сохранение"
            case .transcription: return "Распознавание"
            case .context: return "Календарный контекст"
            case .recovery: return "Восстановление микрофона"
            }
        }
    }
    var id: String { stage.rawValue + message }
    let stage: Stage
    let message: String
    let isError: Bool
    var advice: String {
        switch stage {
        case .capture, .recovery: return "Проверьте исходное аудио. Повторное распознавание не восстановит отсутствующую речь."
        case .saving: return "Исходники остаются в raw/. Повторите обработку для сборки общего аудио."
        case .transcription: return "Проверьте модели и журнал обработки, затем повторите обработку."
        case .context: return "Календарный контекст недоступен. Аудио и текст можно использовать отдельно."
        }
    }
}

struct RecordingEntry: Codable, Identifiable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case recording, queued, saving, processing, completed, failed, interrupted
        var text: String {
            switch self {
            case .recording: return "Идёт запись"
            case .queued: return "В очереди"
            case .saving: return "Сборка аудио"
            case .processing: return "Распознавание"
            case .completed: return "Текст готов"
            case .failed: return "Ошибка обработки"
            case .interrupted: return "Обработка не завершена"
            }
        }
        var isWorking: Bool { [.recording, .queued, .saving, .processing].contains(self) }
    }
    static func canonicalURL(_ url: URL) -> URL {
        // The final M4A may not exist yet, but its parent directory already does.
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }
    var id: URL { recording }
    let recording: URL
    var date: Date
    var title: String
    var duration: Double?
    var phase: Phase
    var problems: [RecordingProblem] = []
    var meeting: SavedMeeting?
    var log: URL?
    init(recording: URL, date: Date, title: String, phase: Phase) {
        self.recording = Self.canonicalURL(recording)
        self.date = date
        self.title = title
        self.phase = phase
    }
    var folder: URL { recording.deletingLastPathComponent() }
    var base: URL { recording.deletingPathExtension() }
    var rawBase: URL {
        let raw = folder.appendingPathComponent("raw")
        return FileManager.default.fileExists(atPath: raw.path) ? raw.appendingPathComponent(base.lastPathComponent) : base
    }
    var transcript: URL { base.appendingPathExtension("sources.transcript.txt") }
    var metadata: URL { rawBase.appendingPathExtension("processing.json") }
    var captureReport: URL { rawBase.appendingPathExtension("capture-report.json") }
    var context: URL { base.appendingPathExtension("context.json") }
    var status: String {
        phase == .completed && !problems.isEmpty ? "Текст готов с предупреждениями" : phase.text
    }

    static func shareableTranscript(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            for prefix in ["Host audio: ", "Remote audio: ", "Audio: "] where line.hasPrefix(prefix) {
                let path = String(line.dropFirst(prefix.count))
                guard path.hasPrefix("/") else { return line }
                let url = URL(fileURLWithPath: path)
                let directory = prefix != "Audio: " && url.deletingLastPathComponent().lastPathComponent == "raw" ? "raw/" : ""
                return prefix + directory + url.lastPathComponent
            }
            if line.hasPrefix("Warning:") {
                return line.replacingOccurrences(of: #"/(Users|home)/[^/\s]+"#, with: "~", options: .regularExpression)
            }
            return line
        }.joined(separator: "\n")
    }

    mutating func addProblem(_ stage: RecordingProblem.Stage, _ message: String, error: Bool = false) {
        let problem = RecordingProblem(stage: stage, message: message, isError: error)
        if !problems.contains(where: { $0.id == problem.id }) { problems.append(problem) }
    }

    func clearExportFailure() throws {
        guard FileManager.default.fileExists(atPath: captureReport.path) else { return }
        guard var report = try JSONSerialization.jsonObject(with: Data(contentsOf: captureReport)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        report.removeValue(forKey: "exportFailure")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: captureReport, options: .atomic)
    }

    mutating func readArtifacts() {
        let manager = FileManager.default
        let logs = (try? manager.contentsOfDirectory(at: rawBase.deletingLastPathComponent(),
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        log = logs.filter { $0.lastPathComponent.hasPrefix(rawBase.lastPathComponent + ".transcription") && $0.pathExtension == "log" }
            .max { left, right in
                let a = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if manager.fileExists(atPath: context.path) {
            do {
                meeting = try decoder.decode(SavedMeeting.self, from: Data(contentsOf: context))
                if let meeting { title = meeting.summary }
            } catch { addProblem(.context, "Не удалось прочитать контекст: " + error.localizedDescription) }
        }
        if manager.fileExists(atPath: captureReport.path) {
            do {
                let report = try JSONDecoder().decode(HistoryCaptureReport.self, from: Data(contentsOf: captureReport))
                if let count = report.droppedBuffers, count > 0 {
                    addProblem(.capture, "Пропущено аудиобуферов: \(count); \(String(format: "%.3f", report.droppedSourceSeconds ?? 0)) с суммарно по дорожкам.")
                }
                if let failure = report.failure { addProblem(.capture, failure) }
                if let failure = report.exportFailure { addProblem(.saving, failure) }
                if report.microphoneMissing == true { addProblem(.capture, "Во время записи переставали поступать данные микрофона; часть речи могла не сохраниться.") }
                if let count = report.microphoneRecoveries, count > 0 {
                    addProblem(.recovery, "Попыток восстановления микрофона: \(count). Возможны пропуски речи.")
                }
                for event in report.microphoneRecoveryEvents ?? [] {
                    guard event.timestamp.isFinite, event.timestamp >= 0, event.timestamp < Double(Int.max) else {
                        addProblem(.capture, "В журнале захвата некорректное время восстановления микрофона.")
                        continue
                    }
                    let seconds = max(0, Int(event.timestamp))
                    addProblem(.recovery, String(format: "[%02d:%02d] ", seconds / 60, seconds % 60) + event.reason)
                }
            } catch { addProblem(.capture, "Не удалось прочитать журнал захвата: " + error.localizedDescription) }
        }
        if manager.fileExists(atPath: transcript.path) {
            do {
                let file = try FileHandle(forReadingFrom: transcript)
                defer { try? file.close() }
                let header = String(decoding: try file.read(upToCount: 32768) ?? Data(), as: UTF8.self)
                for line in header.components(separatedBy: .newlines) {
                    if line.hasPrefix("[") { break }
                    if line.hasPrefix("Warning: ") {
                        let message = String(line.dropFirst(9))
                        let captureWarning = ["Попыток восстановления", "При захвате", "Сбой захвата", "Во время записи переставали", "Общая запись не собрана"]
                            .contains { message.hasPrefix($0) }
                        if !captureWarning || !manager.fileExists(atPath: captureReport.path) { addProblem(.transcription, message) }
                    }
                }
            } catch { addProblem(.transcription, "Не удалось прочитать транскрипт: " + error.localizedDescription, error: true) }
        }
    }

    static func load(recording: URL) -> Self {
        var entry = Self(recording: recording, date: .distantPast, title: recording.deletingPathExtension().lastPathComponent, phase: .interrupted)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let hasMetadata = FileManager.default.fileExists(atPath: entry.metadata.path)
        if hasMetadata {
            do {
                let saved = try decoder.decode(Self.self, from: Data(contentsOf: entry.metadata))
                guard Self.canonicalURL(saved.recording) == entry.recording else { throw CocoaError(.fileReadCorruptFile) }
                entry = saved
                if entry.phase.isWorking {
                    entry.phase = .interrupted
                    entry.addProblem(.transcription, "Приложение завершилось до окончания обработки. Проверьте файлы и повторите обработку.")
                }
            } catch { entry.addProblem(.saving, "Не удалось прочитать состояние обработки: " + error.localizedDescription, error: true) }
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "'meeting_'yyyy-MM-dd_HH-mm-ss"
            entry.date = formatter.date(from: entry.base.lastPathComponent) ?? .distantPast
        }
        entry.readArtifacts()
        let hasTranscript = FileManager.default.fileExists(atPath: entry.transcript.path)
        if hasTranscript && !hasMetadata { entry.phase = .completed }
        if !hasTranscript, !hasMetadata, let log = entry.log, let detail = Transcription.failureDetail(log: log) {
            entry.phase = .failed
            entry.addProblem(.transcription, detail, error: true)
        }
        if entry.phase == .completed && !hasTranscript {
            entry.phase = .interrupted
            entry.addProblem(.transcription, "Результат обработки отсутствует на диске. Проверьте папку записи.", error: true)
        }
        if entry.phase == .interrupted && entry.problems.isEmpty {
            entry.addProblem(.transcription, "Общий транскрипт не найден. Если сохранились исходные WAV, можно повторить обработку; готовые тексты дорожек доступны отдельно.")
        }
        return entry
    }
}

private struct HistoryCaptureReport: Decodable {
    struct Recovery: Decodable { let timestamp: Double; let reason: String }
    let droppedBuffers: Int?
    let droppedSourceSeconds: Double?
    let failure: String?
    let exportFailure: String?
    let microphoneRecoveries: Int?
    let microphoneRecoveryEvents: [Recovery]?
    let microphoneMissing: Bool?
}

@MainActor
final class RecordingHistory: ObservableObject {
    @Published private(set) var entries: [RecordingEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var initialLoadComplete = false
    @Published private(set) var error: String?
    @Published var progress: [URL: TranscriptionProgress] = [:]
    private var generation = 0
    private var revisions: [URL: Int] = [:]

    func reportError(_ message: String) { error = message }

    func entry(_ url: URL) -> RecordingEntry? {
        let canonical = RecordingEntry.canonicalURL(url)
        return entries.first { $0.id == canonical }
    }

    func put(_ entry: RecordingEntry, persist: Bool = true) {
        revisions[entry.id, default: 0] += 1
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        else { entries.append(entry); entries.sort { $0.date > $1.date } }
        guard persist else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entry).write(to: entry.metadata, options: .atomic)
        } catch { self.error = "Не удалось сохранить историю. Аудио не удалено: " + error.localizedDescription }
    }

    func update(_ url: URL, _ change: (inout RecordingEntry) -> Void) {
        guard var entry = entry(url) else { return }
        change(&entry)
        put(entry)
    }

    func cancelShortRecording(_ url: URL, duration: Double,
                              trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> Bool {
        guard duration.isFinite, duration >= 0, duration < 10 else { return false }
        guard let entry = entry(url), entry.phase == .recording,
              entry.folder.lastPathComponent.hasPrefix("meeting_"),
              entry.folder.lastPathComponent == entry.base.lastPathComponent else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        // Trash only the dedicated directory of this active recording, never a legacy day folder.
        try trash(entry.folder)
        revisions[entry.id, default: 0] += 1
        entries.removeAll { $0.id == entry.id }
        progress.removeValue(forKey: entry.id)
        return true
    }

    func refresh(root: URL) async {
        generation += 1
        let request = generation
        let before = revisions
        loading = true
        let result = await Task.detached(priority: .utility) { () -> (entries: [RecordingEntry], error: String?) in
            var files = Set<URL>()
            var failure: String?
            let manager = FileManager.default
            guard manager.fileExists(atPath: root.path) else { return ([], nil) }
            let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { _, error in
                failure = error.localizedDescription
                return true
            })
            while let url = enumerator?.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if url.lastPathComponent == "raw" || url.lastPathComponent == "experiments" { enumerator?.skipDescendants(); continue }
                    if url.lastPathComponent.hasPrefix("meeting_") {
                        files.insert(url.appendingPathComponent(url.lastPathComponent + ".m4a"))
                    }
                } else {
                    let name = url.lastPathComponent
                    guard name.hasPrefix("meeting_") else { continue }
                    for suffix in [".m4a", ".sources.transcript.txt", ".context.json", ".host_record.wav"] where name.hasSuffix(suffix) {
                        files.insert(url.deletingLastPathComponent().appendingPathComponent(String(name.dropLast(suffix.count)) + ".m4a"))
                        break
                    }
                }
            }
            return (files.map(RecordingEntry.load), failure)
        }.value
        guard request == generation else { return }
        // Publish one sorted snapshot; incremental inserts make the visible list jump during first load.
        var refreshed = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        // A scan must never overwrite a recording or a job updated while it was reading disk.
        for entry in result.entries where revisions[entry.id] == before[entry.id] {
            if refreshed[entry.id]?.phase.isWorking == true { continue }
            revisions[entry.id, default: 0] += 1
            refreshed[entry.id] = entry
        }
        entries = refreshed.values.sorted { $0.date > $1.date }
        error = result.error.map { "Не удалось прочитать часть истории: " + $0 }
        loading = false
        initialLoadComplete = true
    }
}
