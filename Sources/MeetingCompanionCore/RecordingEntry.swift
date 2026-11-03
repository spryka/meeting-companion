import Foundation
import Darwin

public struct SavedMeeting: Codable, Equatable, Sendable {
    public let summary: String
    public let start: Date
    public let end: Date
    public let agenda: String
    public let attendees: [String]
    public let links: [String]

    public init(summary: String, start: Date, end: Date, agenda: String, attendees: [String], links: [String]) {
        self.summary = summary
        self.start = start
        self.end = end
        self.agenda = agenda
        self.attendees = attendees
        self.links = links
    }
}

public struct RecordingProblem: Codable, Equatable, Identifiable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case capture
        case saving
        case transcription
        case context
        case recovery

        public var title: String {
            switch self {
            case .capture: return "Захват звука"
            case .saving: return "Сохранение"
            case .transcription: return "Распознавание"
            case .context: return "Календарный контекст"
            case .recovery: return "Восстановление микрофона"
            }
        }
    }

    public var id: String { stage.rawValue + message }
    public let stage: Stage
    public let message: String
    public let isError: Bool

    public init(stage: Stage, message: String, isError: Bool) {
        self.stage = stage
        self.message = message
        self.isError = isError
    }

    public var advice: String {
        switch stage {
        case .capture, .recovery:
            return "Проверьте исходное аудио. Повторное распознавание не восстановит отсутствующую речь."
        case .saving:
            return "Исходники остаются в raw/. Повторите обработку для сборки общего аудио."
        case .transcription:
            return "Проверьте модели и журнал обработки, затем повторите обработку."
        case .context:
            return "Календарный контекст недоступен. Аудио и текст можно использовать отдельно."
        }
    }
}

public struct RecordingCapabilities: Equatable, Sendable {
    public var canReview = false
    public var canRetry = false
    public var hasSavedText = false
    public var canPreviewAudio = false
    public var reason: String?
    public var isTextOnly: Bool { !canReview && !canRetry }
    public init() {}
}

public struct RecordingEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case recording
        case queued
        case saving
        case processing
        case completed
        case failed
        case interrupted

        public var text: String {
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

        public var isWorking: Bool {
            switch self {
            case .recording, .queued, .saving, .processing:
                return true
            case .completed, .failed, .interrupted:
                return false
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case recording
        case date
        case title
        case duration
        case phase
        case problems
        case meeting
        case log
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawRecording = try container.decode(URL.self, forKey: .recording)
        self.recording = Self.canonicalURL(rawRecording)
        self.hasStandardLayout = RecordingPaths.isStandardLayout(recording)
        self.date = try container.decode(Date.self, forKey: .date)
        self.title = try container.decode(String.self, forKey: .title)
        self.duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        self.phase = try container.decode(Phase.self, forKey: .phase)
        self.problems = try container.decodeIfPresent([RecordingProblem].self, forKey: .problems) ?? []
        self.meeting = try container.decodeIfPresent(SavedMeeting.self, forKey: .meeting)
        self.log = try container.decodeIfPresent(URL.self, forKey: .log)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recording, forKey: .recording)
        try container.encode(date, forKey: .date)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encode(phase, forKey: .phase)
        try container.encode(problems, forKey: .problems)
        try container.encodeIfPresent(meeting, forKey: .meeting)
        try container.encodeIfPresent(log, forKey: .log)
    }

    public static func canonicalURL(_ url: URL) -> URL {
        // The final M4A may not exist yet, but its parent directory already does.
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }

    public var id: URL { recording }
    public let recording: URL
    public var date: Date
    public var title: String
    public var duration: Double?
    public var phase: Phase
    public var problems: [RecordingProblem] = []
    public var meeting: SavedMeeting?
    public var log: URL?
    public var capabilities = RecordingCapabilities()
    public var persistenceWarning: String?
    public private(set) var availableFiles: Set<URL> = []
    private var hasStandardLayout = false

    public private(set) var currentResultURL: URL?
    public private(set) var currentTranscriptURL: URL?

    public init(recording: URL, date: Date, title: String, phase: Phase) {
        self.recording = Self.canonicalURL(recording)
        self.hasStandardLayout = RecordingPaths.isStandardLayout(self.recording)
        self.date = date
        self.title = title
        self.phase = phase
    }

    public var folder: URL { recording.deletingLastPathComponent() }
    public var base: URL { recording.deletingPathExtension() }
    public var rawBase: URL {
        let raw = folder.appendingPathComponent("raw")
        return hasStandardLayout ? raw.appendingPathComponent(base.lastPathComponent) : base
    }
    public var transcript: URL { base.appendingPathExtension("sources.transcript.txt") }
    public var metadata: URL { rawBase.appendingPathExtension("processing.json") }
    public var captureReport: URL { rawBase.appendingPathExtension("capture-report.json") }
    public var context: URL { base.appendingPathExtension("context.json") }

    /// Compatibility is cached by off-UI repository work, never inferred from producer identity.
    public var isLegacy: Bool { capabilities.isTextOnly && capabilities.hasSavedText }

    public var status: String {
        if capabilities.isTextOnly, let reason = capabilities.reason { return reason }
        return phase == .completed && (!problems.isEmpty || persistenceWarning != nil) ? "Текст готов с предупреждениями" : phase.text
    }

    public func containedReadableFile(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(folder.path + "/"),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return FileManager.default.isReadableFile(atPath: resolved.path)
    }

    /// Folder ownership is independent of raw existence; the worker validates audio decoding on retry.
    public mutating func assessCapabilities() {
        hasStandardLayout = RecordingPaths.isStandardLayout(recording)
        currentResultURL = nil
        currentTranscriptURL = nil
        capabilities = RecordingCapabilities()
        if !hasStandardLayout {
            availableFiles = Set([transcript, metadata].filter(containedReadableFile))
            capabilities.hasSavedText = availableFiles.contains(transcript)
            capabilities.reason = RecordingPaths.unsupportedLayoutMessage
            return
        }
        let knownFiles = [recording, transcript, context, metadata, captureReport] +
            ["host", "remote"].flatMap { source in
                ["wav", "local.transcript.txt", "local.transcript.gigaam.txt"].map {
                    rawBase.appendingPathExtension(source + "_record." + $0)
                }
            } + (log.map { [$0] } ?? [])
        availableFiles = Set(knownFiles.filter(containedReadableFile))
        capabilities = RecordingCapabilities()
        capabilities.hasSavedText = availableFiles.contains(transcript)
        let rawPair = ["host", "remote"].map { folder.appendingPathComponent("raw").appendingPathComponent(base.lastPathComponent + "." + $0 + "_record.wav") }
        for pair in [rawPair] where pair.allSatisfy(containedReadableFile) {
            if pair[0].resolvingSymlinksInPath() != pair[1].resolvingSymlinksInPath(),
               !pair.contains(where: { $0.resolvingSymlinksInPath() == recording.resolvingSymlinksInPath() }) {
                capabilities.canRetry = true
                break
            }
        }
        let storage = TranscriptResultStorage(recordingURL: recording)
        currentResultURL = nil
        currentTranscriptURL = nil
        do {
            if let directory = try storage.currentResultDirectory() {
                currentResultURL = directory.appendingPathComponent("result.json")
            }
            capabilities.canReview = try storage.currentDocument() != nil
            if capabilities.canReview {
                currentTranscriptURL = try? storage.committedText(after: nil)
            } else {
                capabilities.reason = "Результат обработки ещё не создан. Доступен сохранённый текст; обработку можно повторить при наличии исходных WAV."
            }
        } catch {
            capabilities.reason = "Текущий результат недоступен: " + error.localizedDescription
        }
        capabilities.hasSavedText = capabilities.canReview ? currentTranscriptURL != nil : availableFiles.contains(transcript)
        // Audio preview/export belong to a supported structured record, independently of source retry.
        capabilities.canPreviewAudio = capabilities.canReview && availableFiles.contains(recording)
        if !capabilities.canRetry && !capabilities.canReview {
            capabilities.reason = (capabilities.reason.map { $0 + " " } ?? "") + "Исходные WAV отсутствуют или недоступны."
        }
    }

    public static func shareableTranscript(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            for prefix in ["Host audio: ", "Remote audio: ", "Audio: "] where line.hasPrefix(prefix) {
                let path = String(line.dropFirst(prefix.count))
                guard path.hasPrefix("/") else { return line }
                let url = URL(fileURLWithPath: path)
                let directory = prefix != "Audio: " && url.deletingLastPathComponent().lastPathComponent == "raw" ? "raw/" : ""
                return prefix + directory + url.lastPathComponent
            }
            if line.hasPrefix("Warning:") {
                return line.replacingOccurrences(of: #"/(Users|home)/[^\s]+"#, with: "~", options: .regularExpression)
            }
            return line
        }.joined(separator: "\n")
    }

    public mutating func addProblem(_ stage: RecordingProblem.Stage, _ message: String, error: Bool = false) {
        let problem = RecordingProblem(stage: stage, message: message, isError: error)
        if !problems.contains(where: { $0.id == problem.id }) { problems.append(problem) }
    }

    public func clearExportFailure() throws {
        try RecordingPaths.requireStandardLayout(recording)
        guard FileManager.default.fileExists(atPath: captureReport.path) else { return }
        guard let data = try? Data(contentsOf: captureReport),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json.removeValue(forKey: "exportFailure")
        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try updatedData.write(to: captureReport, options: .atomic)
    }

    public mutating func readArtifacts() {
        defer { assessCapabilities() }
        guard RecordingPaths.isStandardLayout(recording) else { return }
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
        if containedReadableFile(context) {
            do {
                meeting = try decoder.decode(SavedMeeting.self, from: Data(contentsOf: context))
                if let meeting { title = meeting.summary }
            } catch { addProblem(.context, "Не удалось прочитать контекст: " + error.localizedDescription) }
        }
        if containedReadableFile(captureReport) {
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
        if let document = try? TranscriptResultStorage(recordingURL: recording).currentDocument() {
            for warning in document.warnings { addProblem(.transcription, warning.message) }
        } else if containedReadableFile(transcript) {
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

    public static func load(recording: URL) -> Self {
        var entry = Self(recording: recording, date: .distantPast, title: recording.deletingPathExtension().lastPathComponent, phase: .interrupted)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            if let data = try TranscriptResultStorage(recordingURL: entry.recording).metadataData(),
               let saved = try? decoder.decode(Self.self, from: data), saved.recording == entry.recording {
                entry = saved
            }
        } catch {
            entry.addProblem(.saving, "Не удалось прочитать processing.json: " + error.localizedDescription, error: true)
        }
        if entry.date == .distantPast,
           let values = try? entry.recording.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]),
           let date = values.creationDate ?? values.contentModificationDate {
            entry.date = date
        }
        entry.readArtifacts()
        return entry
    }
}

private struct HistoryCaptureReport: Decodable {
    struct Recovery: Decodable {
        let timestamp: Double
        let reason: String
    }
    let droppedBuffers: Int?
    let droppedSourceSeconds: Double?
    let failure: String?
    let exportFailure: String?
    let microphoneRecoveries: Int?
    let microphoneRecoveryEvents: [Recovery]?
    let microphoneMissing: Bool?
}
