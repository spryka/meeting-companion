import Foundation

public struct GigaAMConfiguration: Sendable {
    public enum ModelVariant: String, Sendable, Codable {
        case pro
    }

    public enum ComputeMode: String, Sendable, Codable {
        case automatic
        case cpu
        case gpu
    }

    public var variant: ModelVariant
    public var computeMode: ComputeMode
    public var modelDirectory: URL?
    public var sampleRate: Int
    public var chunkDuration: TimeInterval

    public static let pro = GigaAMConfiguration()

    public init(
        variant: ModelVariant = .pro,
        computeMode: ComputeMode = .automatic,
        modelDirectory: URL? = nil,
        sampleRate: Int = 16_000,
        chunkDuration: TimeInterval = 20.0
    ) {
        self.variant = variant
        self.computeMode = computeMode
        self.modelDirectory = modelDirectory
        self.sampleRate = sampleRate
        self.chunkDuration = chunkDuration
    }
}
