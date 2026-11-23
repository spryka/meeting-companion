import Foundation

public enum VoiceEmbeddingProtocol {
    public static let sampleRate = 16_000
    public static let dimensions = 256
    public static let windowLimit = 64
    public static let requestByteLimit = 64 * 1_024
    public static let responseByteLimit = 512 * 1_024
    public static let weightsSHA256 = "f56204883f2de969f584af7893e5373575556b422190c14c206a5fd94f3d7fe6"
    public static let embeddingSpaceID = "wespeaker-resnet34lm/\(weightsSHA256)/speech-swift-cmn1-mlx-metal/l2-256-v1"

    public enum Invalid: LocalizedError {
        case request, response
        public var errorDescription: String? {
            switch self {
            case .request: "Некорректный запрос признаков голоса."
            case .response: "Некорректный ответ с признаками голоса."
            }
        }
    }

    public struct Window: Codable, Sendable {
        public let id: UUID
        public let sourceID: TranscriptDocument.SourceID
        public let sourceFingerprint: String
        public let startFrame: Int
        public let endFrame: Int

        public init(id: UUID = UUID(), sourceID: TranscriptDocument.SourceID, sourceFingerprint: String,
                    startFrame: Int, endFrame: Int) {
            self.id = id
            self.sourceID = sourceID
            self.sourceFingerprint = sourceFingerprint
            self.startFrame = startFrame
            self.endFrame = endFrame
        }
    }

    public struct Request: Codable, Sendable {
        public let schemaVersion: Int
        public let id: UUID
        public let resultID: String
        public let windows: [Window]

        public init(id: UUID = UUID(), resultID: String, windows: [Window]) {
            schemaVersion = 1
            self.id = id
            self.resultID = resultID
            self.windows = windows
        }
    }

    public struct Feature: Codable, Sendable {
        public let windowID: UUID
        public let pcmFingerprint: String
        public let embedding: [Float]?

        public init(windowID: UUID, pcmFingerprint: String, embedding: [Float]?) {
            self.windowID = windowID
            self.pcmFingerprint = pcmFingerprint
            self.embedding = embedding
        }
    }

    public struct Response: Codable, Sendable {
        public let schemaVersion: Int
        public let requestID: UUID
        public let embeddingSpaceID: String
        public let features: [Feature]

        public init(requestID: UUID, features: [Feature]) {
            schemaVersion = 1
            self.requestID = requestID
            embeddingSpaceID = VoiceEmbeddingProtocol.embeddingSpaceID
            self.features = features
        }
    }

    public static func decodeRequest(_ data: Data) throws -> Request {
        guard data.count <= requestByteLimit, let request = try? JSONDecoder().decode(Request.self, from: data) else {
            throw Invalid.request
        }
        try validateRequest(request)
        return request
    }

    public static func validateRequest(_ request: Request) throws {
        guard request.schemaVersion == 1, (1...128).contains(request.resultID.utf8.count),
              request.resultID != ".", request.resultID != "..",
              !request.resultID.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" }),
              (1...windowLimit).contains(request.windows.count),
              Set(request.windows.map(\.id)).count == request.windows.count,
              request.windows.allSatisfy({ window in
                  window.startFrame >= 0 && window.endFrame > window.startFrame &&
                      (3 * sampleRate...6 * sampleRate).contains(window.endFrame - window.startFrame) &&
                      isFingerprint(window.sourceFingerprint)
              }) else {
            throw Invalid.request
        }
    }

    public static func decodeResponse(_ data: Data, for request: Request) throws -> Response {
        guard data.count <= responseByteLimit, let response = try? JSONDecoder().decode(Response.self, from: data),
              response.schemaVersion == 1, response.requestID == request.id, response.embeddingSpaceID == embeddingSpaceID,
              response.features.map(\.windowID) == request.windows.map(\.id),
              response.features.allSatisfy({ feature in
                  isFingerprint(feature.pcmFingerprint) && feature.embedding.map(isNormalizedEmbedding) != false
              }) else {
            throw Invalid.response
        }
        return response
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isNormalizedEmbedding(_ values: [Float]) -> Bool {
        values.count == dimensions && values.allSatisfy(\.isFinite) &&
            abs(values.reduce(0.0) { $0 + Double($1) * Double($1) } - 1) <= 0.01
    }
}
