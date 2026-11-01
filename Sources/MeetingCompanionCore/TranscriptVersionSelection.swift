import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Information about a published transcript recognition version.
public struct TranscriptVersionInfo: Equatable, Sendable {
    public let resultID: String
    public let createdAt: String
    public let date: Date

    public init(resultID: String, createdAt: String, date: Date) {
        self.resultID = resultID
        self.createdAt = createdAt
        self.date = date
    }
}

/// Errors occurring during transcript version selection.
public enum TranscriptVersionSelectionError: LocalizedError, Sendable, Equatable {
    case malformedMetadata(String)
    case pathEscapesRecording(String)
    case selectedVersionUnavailable(String)
    case metadataNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .malformedMetadata(let detail):
            return "Некорректный файл истории: \(detail)"
        case .pathEscapesRecording(let detail):
            return "Путь выходит за пределы каталога записи: \(detail)"
        case .selectedVersionUnavailable(let resultID):
            return "Выбранная версия недоступна: \(resultID)"
        case .metadataNotFound(let detail):
            return "Файл истории не найден: \(detail)"
        }
    }
}

/// Selector and resolver for transcript recognition versions based on persisted recording history.
public struct TranscriptVersionSelector: Sendable {
    public let recordingDirectory: URL
    public let recordingURL: URL?
    public var onPersistSelection: (@Sendable (_ resultID: String) throws -> Void)?

    public init(
        recordingDirectory: URL,
        recordingURL: URL? = nil,
        onPersistSelection: (@Sendable (_ resultID: String) throws -> Void)? = nil
    ) {
        self.recordingDirectory = recordingDirectory
        self.recordingURL = recordingURL
        self.onPersistSelection = onPersistSelection
    }

    public init(
        recordingURL: URL,
        onPersistSelection: (@Sendable (_ resultID: String) throws -> Void)? = nil
    ) {
        self.recordingDirectory = recordingURL.deletingLastPathComponent()
        self.recordingURL = recordingURL
        self.onPersistSelection = onPersistSelection
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
                    throw TranscriptVersionSelectionError.pathEscapesRecording("Path component missing: \(component)")
                }
                throw TranscriptVersionSelectionError.pathEscapesRecording("lstat failed with errno \(err) for \(component)")
            }

            if (st.st_mode & S_IFMT) == S_IFLNK {
                let resolved = next.resolvingSymlinksInPath().standardizedFileURL
                guard isContained(fileURL: resolved, within: realRecordingURL) else {
                    throw TranscriptVersionSelectionError.pathEscapesRecording("Symlink escapes recording directory at \(component)")
                }
                guard FileManager.default.fileExists(atPath: resolved.path) else {
                    throw TranscriptVersionSelectionError.pathEscapesRecording("Dangling symlink at \(component)")
                }
                current = resolved
            } else {
                current = next.standardizedFileURL
                guard isContained(fileURL: current, within: realRecordingURL) else {
                    throw TranscriptVersionSelectionError.pathEscapesRecording("Path escapes recording directory at \(component)")
                }
            }
            #else
            guard isContained(fileURL: next, within: realRecordingURL) else {
                throw TranscriptVersionSelectionError.pathEscapesRecording(component)
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

        let (_, rawExists) = try verifyContainedPath(components: ["raw"], allowFinalAbsence: true)
        if rawExists {
            return (["raw"], "\(baseName).processing.json")
        } else {
            return ([], "\(baseName).processing.json")
        }
    }

    /// Discovers all valid, published (non-staging) versions, sorted descending by creation date (latest first).
    public func availableVersions() throws -> [TranscriptVersionInfo] {
        let realRecordingURL = recordingDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(fileURL: recordingDirectory, within: realRecordingURL) else {
            throw TranscriptVersionSelectionError.pathEscapesRecording("recordingDirectory escapes")
        }

        let (transcriptsDir, exists) = try verifyContainedPath(
            components: ["raw", "transcripts"],
            allowFinalAbsence: true,
            allowIntermediateAbsence: true
        )
        guard exists else { return [] }

        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: transcriptsDir, includingPropertiesForKeys: nil)
        var results: [TranscriptVersionInfo] = []

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        for entry in entries {
            let name = entry.lastPathComponent
            guard !name.hasPrefix("staging"),
                  !name.hasPrefix("."),
                  !name.contains(".tmp") else {
                continue
            }

            // Verify full containment chain including result.json before any read
            guard let (resultURL, rExists) = try? verifyContainedPath(
                components: ["raw", "transcripts", name, "result.json"],
                allowFinalAbsence: false
            ), rExists else {
                continue
            }

            guard let doc = try? TranscriptDocument.load(from: resultURL, recordingDirectory: recordingDirectory) else {
                continue
            }
            guard doc.resultID == name else { continue }

            let date = formatter.date(from: doc.createdAt) ?? fallbackFormatter.date(from: doc.createdAt) ?? .distantPast
            results.append(TranscriptVersionInfo(resultID: doc.resultID, createdAt: doc.createdAt, date: date))
        }

        results.sort {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.resultID > $1.resultID
        }
        return results
    }

    private struct TopLevelField {
        let key: String
        let keyRange: Range<Int>
        let valueRange: Range<Int>
        let isString: Bool
        let isNull: Bool
        let stringValue: String?
    }

    private static func parseTopLevelFields(data: Data) throws -> [TopLevelField] {
        guard (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil else {
            throw TranscriptVersionSelectionError.malformedMetadata("Not a JSON object")
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
            throw TranscriptVersionSelectionError.malformedMetadata("Expected opening brace")
        }
        i += 1

        var fields: [TopLevelField] = []
        while i < n {
            skipWhitespace()
            if i < n && data[i] == 0x7D { break }
            guard let keyRange = scanString() else {
                throw TranscriptVersionSelectionError.malformedMetadata("Expected string key")
            }
            guard let decodedKey = try? JSONDecoder().decode(String.self, from: data[keyRange]) else {
                throw TranscriptVersionSelectionError.malformedMetadata("Invalid string key")
            }
            skipWhitespace()
            guard i < n, data[i] == 0x3A else {
                throw TranscriptVersionSelectionError.malformedMetadata("Expected colon")
            }
            i += 1
            skipWhitespace()

            let isStr = (i < n && data[i] == 0x22)
            let isNul = (i + 4 <= n && String(decoding: data[i..<(i+4)], as: UTF8.self) == "null")
            guard let valRange = skipValue() else {
                throw TranscriptVersionSelectionError.malformedMetadata("Expected value")
            }

            var strVal: String? = nil
            if isStr {
                strVal = try? JSONDecoder().decode(String.self, from: data[valRange])
            }
            fields.append(TopLevelField(key: decodedKey, keyRange: keyRange, valueRange: valRange, isString: isStr, isNull: isNul, stringValue: strVal))

            skipWhitespace()
            if i < n && data[i] == 0x2C { i += 1 }
            else if i < n && data[i] == 0x7D { break }
        }
        return fields
    }

    /// Reads the persisted `selectedResultID` from the recording history metadata (`processing.json`), if present.
    public func persistedSelectedResultID() throws -> String? {
        let (folderComponents, filename) = try resolveMetadataPath()
        let (verifiedURL, exists) = try verifyContainedPath(
            components: folderComponents + [filename],
            allowFinalAbsence: true
        )
        guard exists else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: verifiedURL)
        } catch {
            throw TranscriptVersionSelectionError.malformedMetadata("Cannot read metadata: \(error.localizedDescription)")
        }

        let fields = try Self.parseTopLevelFields(data: data)
        return try Self.selectedResultID(in: fields)
    }

    private static func selectedResultID(in fields: [TopLevelField]) throws -> String? {
        let matching = fields.filter { $0.key == "selectedResultID" }
        if matching.count > 1 {
            throw TranscriptVersionSelectionError.malformedMetadata("Duplicate selectedResultID key")
        }
        guard let field = matching.first else {
            return nil
        }
        if field.isNull { return nil }
        guard field.isString, let value = field.stringValue else {
            throw TranscriptVersionSelectionError.malformedMetadata("selectedResultID must be a string or null")
        }
        return value
    }

    private static func patchSelectedResultIDNonLossy(data: Data, newResultID: String) throws -> Data {
        let fields = try parseTopLevelFields(data: data)
        _ = try selectedResultID(in: fields)
        let matching = fields.filter { $0.key == "selectedResultID" }
        if matching.count > 1 {
            throw TranscriptVersionSelectionError.malformedMetadata("Duplicate selectedResultID key")
        }

        let encodedValue = try String(decoding: JSONEncoder().encode(newResultID), as: UTF8.self)

        if let existingField = matching.first {
            // Replace existing value in place
            var patched = Data()
            patched.append(data[0..<existingField.valueRange.lowerBound])
            patched.append(Data(encodedValue.utf8))
            patched.append(data[existingField.valueRange.upperBound..<data.count])
            guard (try? JSONSerialization.jsonObject(with: patched)) as? [String: Any] != nil else {
                throw TranscriptVersionSelectionError.malformedMetadata("Patched JSON is invalid")
            }
            return patched
        }

        // Insert before last }
        let string = String(decoding: data, as: UTF8.self)
        guard let lastBrace = string.lastIndex(of: "}"),
              let firstBrace = string.firstIndex(of: "{") else {
            throw TranscriptVersionSelectionError.malformedMetadata("Missing braces")
        }

        let inside = string[string.index(after: firstBrace)..<lastBrace].trimmingCharacters(in: .whitespacesAndNewlines)
        let patchedString: String
        if inside.isEmpty {
            patchedString = "{\n  \"selectedResultID\": \(encodedValue)\n}"
        } else {
            var prefix = String(string[..<lastBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.hasSuffix(",") { prefix.removeLast() }
            patchedString = prefix + ",\n  \"selectedResultID\": \(encodedValue)\n}"
        }

        let patchedData = Data(patchedString.utf8)
        guard (try? JSONSerialization.jsonObject(with: patchedData)) as? [String: Any] != nil else {
            throw TranscriptVersionSelectionError.malformedMetadata("Patched JSON is invalid")
        }
        return patchedData
    }

    /// Merges unknown top-level fields from `existingData` into `encodedData` without numeric loss.
    public static func mergeUnknownFields(from existingData: Data, into encodedData: Data) throws -> Data {
        let knownKeys: Set<String> = [
            "recording", "date", "title", "duration", "phase", "problems", "meeting", "log", "selectedResultID"
        ]
        let existingFields = try parseTopLevelFields(data: existingData)
        _ = try selectedResultID(in: existingFields)
        _ = try parseTopLevelFields(data: encodedData)
        let unknownFields = existingFields.filter { !knownKeys.contains($0.key) }
        guard !unknownFields.isEmpty else { return encodedData }

        let targetString = String(decoding: encodedData, as: UTF8.self)
        guard let lastBrace = targetString.lastIndex(of: "}"),
              let firstBrace = targetString.firstIndex(of: "{") else {
            throw TranscriptVersionSelectionError.malformedMetadata("Missing braces in encoded history")
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
            throw TranscriptVersionSelectionError.malformedMetadata("Merged history is invalid")
        }
        return result
    }

    /// Persists the selected resultID into the recording history metadata (`processing.json`),
    /// preserving all existing metadata fields without numeric loss.
    public func persistSelectedResultID(_ resultID: String) throws {
        if let handler = onPersistSelection {
            try handler(resultID)
            return
        }

        let available = try availableVersions()
        guard available.contains(where: { $0.resultID == resultID }) else {
            throw TranscriptVersionSelectionError.selectedVersionUnavailable(resultID)
        }

        let (folderComponents, filename) = try resolveMetadataPath()
        let (verifiedURL, exists) = try verifyContainedPath(
            components: folderComponents + [filename],
            allowFinalAbsence: true
        )
        guard exists else {
            throw TranscriptVersionSelectionError.metadataNotFound(filename)
        }

        let existingData: Data
        do {
            existingData = try Data(contentsOf: verifiedURL)
        } catch {
            throw TranscriptVersionSelectionError.malformedMetadata("Cannot read metadata: \(error.localizedDescription)")
        }

        let patchedData = try Self.patchSelectedResultIDNonLossy(data: existingData, newResultID: resultID)

        let tempURL = verifiedURL.deletingLastPathComponent().appendingPathComponent("metadata.tmp.\(UUID().uuidString)")
        try patchedData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        #if canImport(Darwin)
        guard rename(tempURL.path, verifiedURL.path) == 0 else {
            throw TranscriptVersionSelectionError.malformedMetadata("rename failed with errno \(errno)")
        }
        #else
        _ = try FileManager.default.replaceItemAt(verifiedURL, withItemAt: tempURL)
        #endif
    }

    /// Resolves the effective resultID to open: returns explicit persisted selection if valid,
    /// or falls back to the latest successfully published non-staging version.
    public func resolveSelectedResultID() throws -> String? {
        let persisted = try persistedSelectedResultID()
        let available = try availableVersions()

        if let explicit = persisted {
            guard available.contains(where: { $0.resultID == explicit }) else {
                throw TranscriptVersionSelectionError.selectedVersionUnavailable(explicit)
            }
            return explicit
        }
        return available.first?.resultID
    }

    /// Opens a `TranscriptEditsRepository` for the resolved version resultID.
    public func selectAndOpenRepository() throws -> (resultID: String, repository: TranscriptEditsRepository)? {
        guard let selectedID = try resolveSelectedResultID() else { return nil }
        let repo = TranscriptEditsRepository(recordingDirectory: recordingDirectory)
        return (selectedID, repo)
    }
}
