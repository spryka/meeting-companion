import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum TranscriptStorageError: LocalizedError, Sendable, Equatable {
    case malformedMetadata(String)
    case pathEscapesRecording(String)
    case currentResultUnavailable(String)
    case metadataNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .malformedMetadata(let detail):
            return "Некорректный файл истории: \(detail)"
        case .pathEscapesRecording(let detail):
            return "Путь выходит за пределы каталога записи: \(detail)"
        case .currentResultUnavailable(let resultID):
            return "Текущий результат недоступен: \(resultID)"
        case .metadataNotFound(let detail):
            return "Файл истории не найден: \(detail)"
        }
    }
}

/// Contained current-result resolution and lossless recording metadata storage.
public struct TranscriptResultStorage: Sendable {
    public let recordingDirectory: URL
    public let recordingURL: URL?

    public init(recordingDirectory: URL, recordingURL: URL? = nil) {
        self.recordingDirectory = recordingDirectory
        self.recordingURL = recordingURL
    }
    public init(recordingURL: URL) {
        self.recordingDirectory = recordingURL.deletingLastPathComponent()
        self.recordingURL = recordingURL
    }

    private func isContained(fileURL: URL, within parentURL: URL) -> Bool {
        let parentComponents = parentURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count >= parentComponents.count else { return false }
        for i in 0..<parentComponents.count {
            if fileComponents[i] != parentComponents[i] {
                return false
            }
        }
        return true
    }

    private func verifyContainedPath(
        components: [String],
        allowFinalAbsence: Bool,
        allowIntermediateAbsence: Bool = false
    ) throws -> (url: URL, exists: Bool) {
        let realRecordingURL = recordingDirectory.resolvingSymlinksInPath().standardizedFileURL
        var current = realRecordingURL

        for (index, component) in components.enumerated() {
            let isFinal = (index == components.count - 1)
            let next = current.appendingPathComponent(component)

            #if canImport(Darwin)
            var st = stat()
            let res = lstat(next.path, &st)
            if res != 0 {
                let err = errno
                if err == ENOENT {
                    if (isFinal && allowFinalAbsence) || allowIntermediateAbsence {
                        return (next, false)
                    }
                    throw TranscriptStorageError.pathEscapesRecording("Path component missing: \(component)")
                }
                throw TranscriptStorageError.pathEscapesRecording("lstat failed with errno \(err) for \(component)")
            }

            if (st.st_mode & S_IFMT) == S_IFLNK {
                let resolved = next.resolvingSymlinksInPath().standardizedFileURL
                guard isContained(fileURL: resolved, within: realRecordingURL) else {
                    throw TranscriptStorageError.pathEscapesRecording("Symlink escapes recording directory at \(component)")
                }
                guard FileManager.default.fileExists(atPath: resolved.path) else {
                    throw TranscriptStorageError.pathEscapesRecording("Dangling symlink at \(component)")
                }
                current = resolved
            } else {
                current = next.standardizedFileURL
                guard isContained(fileURL: current, within: realRecordingURL) else {
                    throw TranscriptStorageError.pathEscapesRecording("Path escapes recording directory at \(component)")
                }
            }
            #else
            guard isContained(fileURL: next, within: realRecordingURL) else {
                throw TranscriptStorageError.pathEscapesRecording(component)
            }
            current = next
            #endif
        }

        return (current, true)
    }

    private func resolveMetadataPath() throws -> (folderComponents: [String], filename: String) {
        let baseName: String
        if let rec = recordingURL {
            baseName = rec.deletingPathExtension().lastPathComponent
        } else {
            baseName = recordingDirectory.lastPathComponent
        }

        let recording = recordingURL ?? recordingDirectory.appendingPathComponent(baseName + ".m4a")
        if RecordingPaths.isStandardLayout(recording) {
            return (["raw"], "\(baseName).processing.json")
        } else {
            return ([], "\(baseName).processing.json")
        }
    }

    /// Choose the directory BEFORE validating its result; never fall back to older content.
    public func currentResultDirectory() throws -> URL? {
        let recording = recordingURL ?? recordingDirectory.appendingPathComponent(recordingDirectory.lastPathComponent + ".m4a")
        try RecordingPaths.requireStandardLayout(recording)
        guard RecordingEntry.canonicalURL(recording).deletingLastPathComponent() == recordingDirectory.resolvingSymlinksInPath().standardizedFileURL else {
            throw TranscriptStorageError.pathEscapesRecording(recording.path)
        }
        let (directory, exists) = try verifyContainedPath(components: ["raw", "transcripts"], allowFinalAbsence: true, allowIntermediateAbsence: true)
        guard exists else { return nil }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var candidates: [(URL, Date)] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard !name.hasPrefix("staging"), !name.hasPrefix("."), !name.contains(".tmp") else { continue }
            let (contained, _) = try verifyContainedPath(components: ["raw", "transcripts", name], allowFinalAbsence: false)
            let values = try contained.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard values.isDirectory == true else { continue }
            guard let created = values.creationDate else {
                throw TranscriptStorageError.currentResultUnavailable("Нет даты создания каталога " + name)
            }
            candidates.append((entry, created))
        }
        return candidates.sorted {
            $0.1 == $1.1 ? $0.0.lastPathComponent > $1.0.lastPathComponent : $0.1 > $1.1
        }.first?.0
    }

    public func currentDocument() throws -> TranscriptDocument? {
        guard let directory = try currentResultDirectory() else { return nil }
        let id = directory.lastPathComponent
        let (url, exists) = try verifyContainedPath(components: ["raw", "transcripts", id, "result.json"], allowFinalAbsence: true)
        guard exists else { throw TranscriptStorageError.currentResultUnavailable(id + ": result.json отсутствует") }
        let document = try TranscriptDocument.load(from: url, recordingDirectory: recordingDirectory)
        guard document.resultID == id else { throw TranscriptStorageError.currentResultUnavailable(id) }
        return document
    }

    /// Only a newly committed result's mandatory text can acknowledge processing success.
    public func committedText(after previousResultID: String?) throws -> URL? {
        guard let document = try currentDocument(), document.resultID != previousResultID else { return nil }
        let (url, exists) = try verifyContainedPath(components: ["raw", "transcripts", document.resultID, "transcript.txt"], allowFinalAbsence: true)
        guard exists, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw TranscriptStorageError.currentResultUnavailable(document.resultID + ": transcript.txt отсутствует")
        }
        return url
    }

    public func metadataData() throws -> Data? {
        let (components, filename) = try resolveMetadataPath()
        let (url, exists) = try verifyContainedPath(components: components + [filename], allowFinalAbsence: true)
        guard exists else { return nil }
        let data = try Data(contentsOf: url)
        _ = try Self.parseTopLevelFields(data: data)
        return data
    }

    private struct TopLevelField {
        let key: String
        let keyRange: Range<Int>
        let valueRange: Range<Int>
    }

    private static func parseTopLevelFields(data: Data) throws -> [TopLevelField] {
        guard (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil else {
            throw TranscriptStorageError.malformedMetadata("Not a JSON object")
        }

        let n = data.count
        var i = 0

        func skipWhitespace() {
            while i < n {
                let b = data[i]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { i += 1 } else { break }
            }
        }

        func scanString() -> Range<Int>? {
            guard i < n, data[i] == 0x22 else { return nil }
            let start = i
            i += 1
            while i < n {
                let b = data[i]
                if b == 0x22 {
                    i += 1
                    return start..<i
                }
                if b == 0x5C {
                    i += 2
                    continue
                }
                i += 1
            }
            return nil
        }

        func skipValue() -> Range<Int>? {
            skipWhitespace()
            guard i < n else { return nil }
            let start = i
            let b = data[i]
            if b == 0x22 {
                return scanString()
            } else if b == 0x7B {
                i += 1
                var depth = 1
                while i < n && depth > 0 {
                    if data[i] == 0x22 {
                        _ = scanString()
                    } else {
                        if data[i] == 0x7B { depth += 1 }
                        else if data[i] == 0x7D { depth -= 1 }
                        i += 1
                    }
                }
                return start..<i
            } else if b == 0x5B {
                i += 1
                var depth = 1
                while i < n && depth > 0 {
                    if data[i] == 0x22 {
                        _ = scanString()
                    } else {
                        if data[i] == 0x5B { depth += 1 }
                        else if data[i] == 0x5D { depth -= 1 }
                        i += 1
                    }
                }
                return start..<i
            } else {
                while i < n && data[i] != 0x2C && data[i] != 0x7D && data[i] != 0x5D && data[i] > 0x20 {
                    i += 1
                }
                return start..<i
            }
        }

        skipWhitespace()
        guard i < n, data[i] == 0x7B else {
            throw TranscriptStorageError.malformedMetadata("Expected opening brace")
        }
        i += 1

        var fields: [TopLevelField] = []
        while i < n {
            skipWhitespace()
            if i < n && data[i] == 0x7D { break }
            guard let keyRange = scanString() else {
                throw TranscriptStorageError.malformedMetadata("Expected string key")
            }
            guard let decodedKey = try? JSONDecoder().decode(String.self, from: data[keyRange]) else {
                throw TranscriptStorageError.malformedMetadata("Invalid string key")
            }
            skipWhitespace()
            guard i < n, data[i] == 0x3A else {
                throw TranscriptStorageError.malformedMetadata("Expected colon")
            }
            i += 1
            skipWhitespace()

            guard let valRange = skipValue() else {
                throw TranscriptStorageError.malformedMetadata("Expected value")
            }

            fields.append(TopLevelField(key: decodedKey, keyRange: keyRange, valueRange: valRange))

            skipWhitespace()
            if i < n && data[i] == 0x2C { i += 1 }
            else if i < n && data[i] == 0x7D { break }
        }
        return fields
    }

    /// Merges unknown top-level fields from `existingData` into `encodedData` without numeric loss.
    public static func mergeUnknownFields(from existingData: Data, into encodedData: Data) throws -> Data {
        let knownKeys: Set<String> = [
            "recording", "date", "title", "duration", "phase", "problems", "meeting", "log"
        ]
        let existingFields = try parseTopLevelFields(data: existingData)
        _ = try parseTopLevelFields(data: encodedData)
        let unknownFields = existingFields.filter { !knownKeys.contains($0.key) }
        guard !unknownFields.isEmpty else { return encodedData }

        let targetString = String(decoding: encodedData, as: UTF8.self)
        guard let lastBrace = targetString.lastIndex(of: "}"),
              let firstBrace = targetString.firstIndex(of: "{") else {
            throw TranscriptStorageError.malformedMetadata("Missing braces in encoded history")
        }

        var prefix = String(targetString[..<lastBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.hasSuffix(",") { prefix.removeLast() }

        for field in unknownFields {
            let keyBytes = existingData[field.keyRange]
            let valBytes = existingData[field.valueRange]
            let keyStr = String(decoding: keyBytes, as: UTF8.self)
            let valStr = String(decoding: valBytes, as: UTF8.self)
            let needsComma = !prefix[prefix.index(after: firstBrace)...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            prefix += (needsComma ? ",\n  " : "\n  ") + keyStr + ": " + valStr
        }
        prefix += "\n}"
        let result = Data(prefix.utf8)
        guard (try? JSONSerialization.jsonObject(with: result)) != nil else {
            throw TranscriptStorageError.malformedMetadata("Merged history is invalid")
        }
        return result
    }

}
