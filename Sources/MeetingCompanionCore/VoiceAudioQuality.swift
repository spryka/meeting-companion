import Darwin
import Foundation
import CryptoKit

public struct VoiceAudioInterval: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var isValid: Bool { start.isFinite && start >= 0 && end.isFinite && end > start }
}

public struct VoiceAudioQuality: Codable, Equatable, Sendable {
    public static let filename = "voice-quality.v1.json"
    private static let maxBytes = 4 * 1_024 * 1_024
    public let schemaVersion: Int
    public let resultID: String
    public let producer: String
    public let sources: [Source]
    public let recordingFingerprint: String?

    public struct Source: Codable, Equatable, Sendable {
        public let id: TranscriptDocument.SourceID
        public let recognitionAudioPath: String
        public let fingerprint: String
        public let duration: Double
        public let speech: [VoiceAudioInterval]?
        public let overlap: [VoiceAudioInterval]

        public init(
            id: TranscriptDocument.SourceID, recognitionAudioPath: String, fingerprint: String, duration: Double,
            speech: [VoiceAudioInterval]?, overlap: [VoiceAudioInterval]
        ) {
            self.id = id
            self.recognitionAudioPath = recognitionAudioPath
            self.fingerprint = fingerprint
            self.duration = duration
            self.speech = speech
            self.overlap = overlap
        }
    }

    public init(resultID: String, producer: String, sources: [Source], recordingFingerprint: String? = nil) {
        schemaVersion = 1
        self.resultID = resultID
        self.producer = producer
        self.sources = sources
        self.recordingFingerprint = recordingFingerprint
    }

    public static func recordingFingerprint(originalFingerprints: [TranscriptDocument.SourceID: String]) -> String {
        let evidence = originalFingerprints.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(evidence.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public enum Invalid: LocalizedError {
        case artifact
        public var errorDescription: String? { "Некорректные данные о речи в результате транскрибации." }
    }

    public func validate(for document: TranscriptDocument) throws {
        guard schemaVersion == 1, resultID == document.resultID, !producer.isEmpty,
              !sources.isEmpty, Set(sources.map(\.id)).count == sources.count,
              recordingFingerprint.map(Self.isFingerprint) != false else { throw Invalid.artifact }
        for source in sources {
            guard document.sources.contains(where: { $0.id == source.id && $0.recognitionAudioPath == source.recognitionAudioPath }),
                  source.duration.isFinite, source.duration >= 0,
                  Self.isFingerprint(source.fingerprint),
                  ((source.speech ?? []) + source.overlap).allSatisfy({ $0.isValid && $0.end <= source.duration }) else {
                throw Invalid.artifact
            }
        }
    }

    static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public func encoded(for document: TranscriptDocument) throws -> Data {
        try validate(for: document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maxBytes else { throw Invalid.artifact }
        return bytes
    }

    public static func load(in resultDirectory: URL, for document: TranscriptDocument) throws -> Self? {
        guard resultDirectory.lastPathComponent == document.resultID else { throw Invalid.artifact }
        let url = resultDirectory.appendingPathComponent(filename)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Invalid.artifact
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              (1...Int64(maxBytes)).contains(status.st_size) else { throw Invalid.artifact }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let bytes = try file.read(upToCount: Int(status.st_size) + 1), bytes.count == Int(status.st_size) else {
            throw Invalid.artifact
        }
        let quality = try JSONDecoder().decode(Self.self, from: bytes)
        try quality.validate(for: document)
        return quality
    }
}
