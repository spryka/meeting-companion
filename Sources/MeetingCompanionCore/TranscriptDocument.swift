import Foundation

/// An immutable recognition snapshot; loading never runs models or prepares audio.
/// JSON v1 encoding keeps required nullable fields present.
public struct TranscriptDocument: Codable, Sendable {
    public enum SourceID: String, Codable, Sendable { case host, remote }
    public enum ProcessingStatus: String, Codable, Sendable { case completed, disabled, failed }
    public enum AECOutcome: String, Codable, Sendable { case disabled, applied, bypassed, failed }
    public enum PlaybackStatus: String, Codable, Sendable { case ready, unavailable }
    public struct Source: Codable, Sendable {
        public let id: SourceID
        public let originalAudioPath: String
        public let recognitionAudioPath: String
        public let diarizationStatus: ProcessingStatus
        public let detectedVoiceCount: Int?
        public let correctionStatus: ProcessingStatus

        public init(
            id: SourceID,
            originalAudioPath: String,
            recognitionAudioPath: String,
            diarizationStatus: ProcessingStatus,
            detectedVoiceCount: Int?,
            correctionStatus: ProcessingStatus
        ) {
            self.id = id
            self.originalAudioPath = originalAudioPath
            self.recognitionAudioPath = recognitionAudioPath
            self.diarizationStatus = diarizationStatus
            self.detectedVoiceCount = detectedVoiceCount
            self.correctionStatus = correctionStatus
        }

        private enum CodingKeys: String, CodingKey {
            case id, originalAudioPath, recognitionAudioPath, diarizationStatus, detectedVoiceCount, correctionStatus
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(originalAudioPath, forKey: .originalAudioPath)
            try c.encode(recognitionAudioPath, forKey: .recognitionAudioPath)
            try c.encode(diarizationStatus, forKey: .diarizationStatus)
            try c.encode(detectedVoiceCount, forKey: .detectedVoiceCount)
            try c.encode(correctionStatus, forKey: .correctionStatus)
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(SourceID.self, forKey: .id)
            originalAudioPath = try c.decode(String.self, forKey: .originalAudioPath)
            recognitionAudioPath = try c.decode(String.self, forKey: .recognitionAudioPath)
            diarizationStatus = try c.decode(ProcessingStatus.self, forKey: .diarizationStatus)
            detectedVoiceCount = try c.decode(Int?.self, forKey: .detectedVoiceCount)
            correctionStatus = try c.decode(ProcessingStatus.self, forKey: .correctionStatus)
        }
    }
    public struct Speaker: Codable, Sendable {
        public let id: String
        public let sourceID: SourceID
        public let localID: Int
        public let displayNumber: Int

        public init(id: String, sourceID: SourceID, localID: Int, displayNumber: Int) {
            self.id = id
            self.sourceID = sourceID
            self.localID = localID
            self.displayNumber = displayNumber
        }
    }
    public struct Word: Codable, Sendable {
        public let id: String
        public let speakerID: String
        public let start: Double
        public let end: Double
        public let text: String

        public init(id: String, speakerID: String, start: Double, end: Double, text: String) {
            self.id = id
            self.speakerID = speakerID
            self.start = start
            self.end = end
            self.text = text
        }
    }
    public struct Turn: Codable, Sendable {
        public let id: String
        public let speakerID: String
        public let start: Double
        public let end: Double
        public let wordIDs: [String]

        public init(id: String, speakerID: String, start: Double, end: Double, wordIDs: [String]) {
            self.id = id
            self.speakerID = speakerID
            self.start = start
            self.end = end
            self.wordIDs = wordIDs
        }
    }
    public struct AEC: Codable, Sendable {
        public let requested: Bool
        public let outcome: AECOutcome

        public init(requested: Bool, outcome: AECOutcome) {
            self.requested = requested
            self.outcome = outcome
        }
    }
    public struct Playback: Codable, Sendable {
        public let status: PlaybackStatus
        public let mixPath: String?

        public init(status: PlaybackStatus, mixPath: String?) {
            self.status = status
            self.mixPath = mixPath
        }

        private enum CodingKeys: String, CodingKey { case status, mixPath }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(status, forKey: .status)
            try c.encode(mixPath, forKey: .mixPath)
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decode(PlaybackStatus.self, forKey: .status)
            mixPath = try c.decode(String?.self, forKey: .mixPath)
        }
    }
    public struct Warning: Codable, Sendable, Equatable {
        public let code: String
        public let sourceID: SourceID?
        public let message: String
        private enum CodingKeys: String, CodingKey { case code, sourceID, message }

        public init(code: String, sourceID: SourceID? = nil, message: String) {
            self.code = code
            self.sourceID = sourceID
            self.message = message
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(code, forKey: .code)
            try c.encode(sourceID, forKey: .sourceID)
            try c.encode(message, forKey: .message)
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(String.self, forKey: .code)
            sourceID = try c.decode(SourceID?.self, forKey: .sourceID)
            message = try c.decode(String.self, forKey: .message)
        }
    }
    public struct Context: Codable, Sendable {
        public let title: String?
        public let startAt: String?
        public let timeZone: String?
        public let agenda: String?
        public let attendees: [String]?

        public init(
            title: String? = nil,
            startAt: String? = nil,
            timeZone: String? = nil,
            agenda: String? = nil,
            attendees: [String]? = nil
        ) {
            self.title = title
            self.startAt = startAt
            self.timeZone = timeZone
            self.agenda = agenda
            self.attendees = attendees
        }
    }
    public let schemaVersion: Int
    public let resultID: String
    public let createdAt: String
    public let sources: [Source]
    public let speakers: [Speaker]
    public let words: [Word]
    public let turns: [Turn]
    public let baselineWords: [Word]
    public let aec: AEC
    public let playback: Playback
    public let warnings: [Warning]
    public let context: Context?

    public init(
        schemaVersion: Int = 1,
        resultID: String,
        createdAt: String,
        sources: [Source],
        speakers: [Speaker],
        words: [Word],
        turns: [Turn],
        baselineWords: [Word],
        aec: AEC,
        playback: Playback,
        warnings: [Warning] = [],
        context: Context? = nil
    ) throws {
        self.schemaVersion = schemaVersion
        self.resultID = resultID
        self.createdAt = createdAt
        self.sources = sources
        self.speakers = speakers
        self.words = words
        self.turns = turns
        self.baselineWords = baselineWords
        self.aec = aec
        self.playback = playback
        self.warnings = warnings
        self.context = context
        try validate()
    }

    public enum LoadError: LocalizedError, Sendable {
        case unsupportedVersion(Int)
        case malformed(String)
        case invalidReference(String)
        case invalidPath(String)
        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): "Версия документа \(version) не поддерживается."
            case .malformed(let detail): "Некорректный документ расшифровки: \(detail)"
            case .invalidReference(let detail): "Некорректная ссылка в расшифровке: \(detail)"
            case .invalidPath(let detail): "Некорректный аудиопть или выход из папки записи: \(detail)"
            }
        }
    }
    public static func localizedSourceLabel(for sourceID: SourceID) -> String {
        switch sourceID {
        case .host: "Микрофон"
        case .remote: "Системный звук"
        }
    }

    /// Derives source-specific diarization warning information for presentation.
    /// Preserves existing warnings and detects if detectedVoiceCount >= 8.
    /// Does not mutate document or persist JSON changes.
    public func diarizationWarning(for sourceID: SourceID) -> String? {
        for warning in warnings where warning.sourceID == sourceID {
            if warning.code == "diarization_voice_limit" {
                return warning.message
            }
        }
        guard let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        guard source.diarizationStatus == .completed, let count = source.detectedVoiceCount, count >= 8 else {
            return nil
        }
        let label = Self.localizedSourceLabel(for: sourceID)
        return "Достигнут предел распознавания 8 голосов для дорожки «\(label)»."
    }

    /// All active presentation warnings including derived per-source diarization warnings.
    public var presentationWarnings: [Warning] {
        var result = warnings
        for source in sources {
            guard source.diarizationStatus == .completed, let count = source.detectedVoiceCount, count >= 8 else {
                continue
            }
            let alreadyHas = warnings.contains { w in
                w.sourceID == source.id && w.code == "diarization_voice_limit"
            }
            if !alreadyHas {
                let label = Self.localizedSourceLabel(for: source.id)
                result.append(Warning(
                    code: "diarization_voice_limit",
                    sourceID: source.id,
                    message: "Достигнут предел распознавания 8 голосов для дорожки «\(label)»."
                ))
            }
        }
        return result
    }

    public static func load(from url: URL, recordingDirectory: URL) throws -> TranscriptDocument {
        do {
            let document = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            for source in document.sources {
                try validatePath(source.originalAudioPath, in: recordingDirectory)
                try validatePath(source.recognitionAudioPath, in: recordingDirectory)
            }
            if let path = document.playback.mixPath { try validatePath(path, in: recordingDirectory) }
            try document.validateAudioConsistency(in: recordingDirectory)
            return try document.includingSavedContext(in: recordingDirectory)
        } catch let error as LoadError {
            throw error
        } catch let error as DecodingError {
            let detail: String
            switch error {
            case .keyNotFound(let key, let context):
                detail = "отсутствует поле \((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))"
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                detail = "неверное значение \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            @unknown default: detail = "не удалось декодировать JSON"
            }
            throw LoadError.malformed(detail)
        } catch {
            throw LoadError.malformed("не удалось прочитать JSON: \(error.localizedDescription)")
        }
    }

    private struct SavedContext: Decodable {
        let summary: String
        let start: String?
        let timezone: String?
        let agenda: String?
        let attendees: [String]?
    }

    /// Older results omitted the saved meeting; enrich in memory without changing recognition files.
    public func includingSavedContext(in recordingDirectory: URL) throws -> Self {
        guard context == nil else { return self }
        let root = recordingDirectory.resolvingSymlinksInPath().standardizedFileURL
        let name = root.lastPathComponent + ".context.json"
        var savedContext: Context?
        var savedWarnings = warnings
        do {
            try Self.validatePath(name, in: root)
            let saved = try JSONDecoder().decode(SavedContext.self, from: Data(contentsOf: root.appendingPathComponent(name)))
            if let start = saved.start { try Self.validateDate(start) }
            savedContext = Context(title: saved.summary, startAt: saved.start, timeZone: saved.timezone,
                                   agenda: saved.agenda, attendees: saved.attendees)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return self
        } catch {
            let warning = Warning(code: "context_warning",
                message: "Не удалось прочитать сохранённый контекст встречи: " + error.localizedDescription)
            if !savedWarnings.contains(warning) { savedWarnings.append(warning) }
        }
        return try Self(schemaVersion: schemaVersion, resultID: resultID, createdAt: createdAt,
            sources: sources, speakers: speakers, words: words, turns: turns, baselineWords: baselineWords,
            aec: aec, playback: playback, warnings: savedWarnings, context: savedContext)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, resultID, createdAt, sources, speakers, words, turns, baselineWords, aec, playback, warnings, context
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(resultID, forKey: .resultID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(sources, forKey: .sources)
        try c.encode(speakers, forKey: .speakers)
        try c.encode(words, forKey: .words)
        try c.encode(turns, forKey: .turns)
        try c.encode(baselineWords, forKey: .baselineWords)
        try c.encode(aec, forKey: .aec)
        try c.encode(playback, forKey: .playback)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(context, forKey: .context)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw LoadError.unsupportedVersion(schemaVersion) }
        resultID = try c.decode(String.self, forKey: .resultID)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        sources = try c.decode([Source].self, forKey: .sources)
        speakers = try c.decode([Speaker].self, forKey: .speakers)
        words = try c.decode([Word].self, forKey: .words)
        turns = try c.decode([Turn].self, forKey: .turns)
        baselineWords = try c.decode([Word].self, forKey: .baselineWords)
        aec = try c.decode(AEC.self, forKey: .aec)
        playback = try c.decode(Playback.self, forKey: .playback)
        warnings = try c.decode([Warning].self, forKey: .warnings)
        context = try c.decode(Context?.self, forKey: .context)
        try validate()
    }

    private static func validateDate(_ value: String) throws {
        // Require an explicit timezone; ISO8601DateFormatter also accepts fractional seconds.
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: value)
        formatter.formatOptions = [.withInternetDateTime]
        guard value.range(of: pattern, options: .regularExpression) != nil,
              fractional != nil || formatter.date(from: value) != nil else {
            throw LoadError.malformed("дата должна быть RFC 3339 с часовым поясом")
        }
    }

    private static func unique(_ ids: [String], _ collection: String) throws {
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw LoadError.invalidReference("пустые или повторяющиеся ID: \(collection)")
        }
    }

    private static func interval(_ start: Double, _ end: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, start <= end else {
            throw LoadError.malformed("временной интервал должен быть конечным и 0 ≤ start ≤ end")
        }
    }

    private func validate() throws {
        guard !resultID.isEmpty, resultID != ".", resultID != "..",
              !resultID.contains("/"), !resultID.contains("\0") else {
            throw LoadError.malformed("resultID должен быть одним непустым именем каталога версии")
        }
        try Self.validateDate(createdAt)
        if let start = context?.startAt { try Self.validateDate(start) }
        try Self.unique(sources.map { $0.id.rawValue }, "sources")
        try Self.unique(speakers.map(\.id), "speakers")
        try Self.unique(words.map(\.id), "words")
        try Self.unique(baselineWords.map(\.id), "baselineWords")
        try Self.unique(turns.map(\.id), "turns")
        let sourceIDs = Set(sources.map(\.id))
        for source in sources {
            if source.diarizationStatus == .completed {
                guard let count = source.detectedVoiceCount, (0...8).contains(count) else {
                    throw LoadError.malformed("completed требует detectedVoiceCount от 0 до 8")
                }
            } else if source.detectedVoiceCount != nil {
                throw LoadError.malformed("неизвестное число голосов должно быть null")
            }
        }
        let hostMaximum = max(1, speakers.filter { $0.sourceID == .host }.map(\.localID).max() ?? 1)
        var pairs: [SourceID: Set<Int>] = [:]
        var displayNumbers = Set<Int>()
        for speaker in speakers {
            guard sourceIDs.contains(speaker.sourceID) else { throw LoadError.invalidReference("источник голоса \(speaker.id)") }
            guard speaker.localID > 0, speaker.displayNumber > 0,
                  pairs[speaker.sourceID, default: []].insert(speaker.localID).inserted,
                  displayNumbers.insert(speaker.displayNumber).inserted else {
                throw LoadError.invalidReference("повтор или неверный номер голоса \(speaker.id)")
            }
            let offset = speaker.sourceID == .host ? 0 : hostMaximum
            let (expected, overflow) = speaker.localID.addingReportingOverflow(offset)
            guard !overflow, speaker.displayNumber == expected else {
                throw LoadError.invalidReference("displayNumber не соответствует источнику и localID")
            }
        }
        let speakerIDs = Set(speakers.map(\.id))
        for word in words + baselineWords {
            try Self.interval(word.start, word.end)
            guard speakerIDs.contains(word.speakerID) else { throw LoadError.invalidReference("голос слова \(word.id)") }
        }
        let speakerSources = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.sourceID) })
        for source in sources where source.correctionStatus != .completed {
            func signatures(_ collection: [Word]) -> [RecognitionWord: Int] {
                var counts: [RecognitionWord: Int] = [:]
                for word in collection where speakerSources[word.speakerID] == source.id {
                    counts[RecognitionWord(text: word.text, start: word.start, end: word.end), default: 0] += 1
                }
                return counts
            }
            guard signatures(words) == signatures(baselineWords) else {
                throw LoadError.malformed("без успешной коррекции baseline и итоговые текст/интервалы должны совпадать: \(source.id.rawValue)")
            }
        }
        let indexedWords = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
        var owned = Set<String>()
        for turn in turns {
            try Self.interval(turn.start, turn.end)
            guard speakerIDs.contains(turn.speakerID) else { throw LoadError.invalidReference("голос реплики \(turn.id)") }
            for id in turn.wordIDs {
                guard let word = indexedWords[id], word.speakerID == turn.speakerID,
                      owned.insert(id).inserted else { throw LoadError.invalidReference("слово реплики \(turn.id): \(id)") }
                guard turn.start <= word.start, turn.end >= word.end else {
                    throw LoadError.malformed("интервал реплики не охватывает слово \(id)")
                }
            }
        }
        guard owned.count == words.count else { throw LoadError.invalidReference("не все слова входят в реплики") }
        for warning in warnings {
            if let source = warning.sourceID, !sourceIDs.contains(source) {
                throw LoadError.invalidReference("источник предупреждения")
            }
        }
        guard aec.requested == (aec.outcome != .disabled) else {
            throw LoadError.malformed("AEC requested не соответствует outcome")
        }
        if aec.outcome == .failed && !warnings.contains(where: { $0.sourceID == .host || $0.sourceID == nil }) {
            throw LoadError.malformed("сбой AEC требует предупреждение")
        }
        switch playback.status {
        case .ready:
            guard playback.mixPath != nil else { throw LoadError.malformed("ready требует mixPath") }
        case .unavailable:
            guard playback.mixPath == nil, !warnings.isEmpty else {
                throw LoadError.malformed("unavailable требует null mixPath и предупреждение")
            }
        }
    }

    private struct RecognitionWord: Hashable {
        let text: String
        let start: Double
        let end: Double
    }

    private func validateAudioConsistency(in directory: URL) throws {
        let version = Self.resolvedPath("raw/transcripts", in: directory).appendingPathComponent(resultID)
        func isVersionChild(_ url: URL) -> Bool {
            url.pathComponents.count > version.pathComponents.count && url.pathComponents.starts(with: version.pathComponents)
        }
        if let mix = playback.mixPath, !isVersionChild(Self.resolvedPath(mix, in: directory)) {
            throw LoadError.invalidPath("mixPath должен находиться внутри каталога своей версии")
        }
        for source in sources {
            let original = Self.resolvedPath(source.originalAudioPath, in: directory)
            let recognition = Self.resolvedPath(source.recognitionAudioPath, in: directory)
            if source.id == .host && aec.outcome == .applied {
                guard recognition != original, isVersionChild(recognition) else {
                    throw LoadError.malformed("applied AEC требует отдельную копию микрофона внутри версии")
                }
            } else if recognition != original {
                throw LoadError.malformed("recognitionAudioPath должен указывать исходный источник")
            }
        }
    }

    private static func validatePath(_ path: String, in directory: URL) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { throw LoadError.invalidPath(path) }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = resolvedPath(path, in: root)
        let rootComponents = root.pathComponents
        guard candidate.pathComponents.count > rootComponents.count,
              candidate.pathComponents.starts(with: rootComponents) else { throw LoadError.invalidPath(path) }
    }

    private static func resolvedPath(_ path: String, in directory: URL) -> URL {
        // Resolve each existing prefix, even when the final audio file is missing.
        // Resolving only the full URL can leave a symlink parent unresolved on macOS.
        var candidate = directory.resolvingSymlinksInPath().standardizedFileURL
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            candidate = candidate.appendingPathComponent(String(component)).resolvingSymlinksInPath().standardizedFileURL
        }
        return candidate
    }
}
