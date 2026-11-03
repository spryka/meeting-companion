import Foundation

public struct GigaAMManifest: Codable, Sendable {
    public let name: String
    public let bundleId: String
    public let sourceModel: String
    public let sourceRevision: String
    public let architecture: String
    public let precision: String
    public let runtime: String
    public let sampleRate: Int
    public let channels: Int
    public let weightsFile: String
    public let tokenizerFile: String?
    public let targetPlatforms: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case bundleId = "bundle_id"
        case sourceModel = "source_model"
        case sourceRevision = "source_revision"
        case architecture
        case precision
        case runtime
        case sampleRate = "sample_rate"
        case channels
        case weightsFile = "weights_file"
        case tokenizerFile = "tokenizer_file"
        case targetPlatforms = "target_platforms"
    }
}
