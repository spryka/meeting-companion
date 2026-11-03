import Foundation
import CryptoKit

enum Nemotron3DiarizationError: LocalizedError {
    case missingArtifact(String)
    case invalidConfiguration(String)
    case incompatibleWeights(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .missingArtifact(let path):
            return "Nemotron 3 local artifact is missing: \(path)"
        case .invalidConfiguration(let reason):
            return "Invalid Nemotron 3 artifact configuration: \(reason)"
        case .incompatibleWeights(let reason):
            return "Incompatible Nemotron 3 weights: \(reason)"
        case .runtime(let reason):
            return "Nemotron 3 inference failed: \(reason)"
        }
    }
}

struct Nemotron3ArtifactConfiguration: Decodable, Sendable {
    struct Quantization: Decodable, Sendable {
        let groupSize: Int?
        let bits: Int?
        let mode: String?
    }

    let modelType: String
    let sourceModel: String
    let sourceRevision: String
    let dtype: String
    let sampleRate: Int
    let nMels: Int
    let dModel: Int
    let tfModel: Int
    let numLayers: Int
    let numHeads: Int
    let numSpeakers: Int
    let subsamplingFactor: Int
    let upsampleFactor: Int
    let spkcacheLen: Int
    let fifoLen: Int
    let chunkLen: Int
    let rightContext: Int
    let spkcacheUpdatePeriod: Int
    let quantization: Quantization

    static func load(from directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Nemotron3DiarizationError.missingArtifact(url.path)
        }
        let data = try Data(contentsOf: url)
        if (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["model_type"] as? String == "nemotron_diarization" {
            // Disposable probe: accept only the exact baseline config, including all DSP/cache settings.
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                == "f215091252bc54f8dcc7d682962a659e03a6bcb26d1c86e4728b8c6730130eb4" else {
                throw Nemotron3DiarizationError.invalidConfiguration("unsupported BF16 baseline configuration")
            }
            return Self(modelType: "nemotron_diarization", sourceModel: "nvidia/Nemotron-3-Diarization",
                sourceRevision: "723e19c601d99b7e58fba6a14e32153e0afe48d9", dtype: "bfloat16",
                sampleRate: 16000, nMels: 128, dModel: 512, tfModel: 192, numLayers: 31,
                numHeads: 8, numSpeakers: 8, subsamplingFactor: 8, upsampleFactor: 8,
                spkcacheLen: 264, fifoLen: 40, chunkLen: 340, rightContext: 40,
                spkcacheUpdatePeriod: 300, quantization: Quantization(groupSize: nil, bits: nil, mode: nil))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(Self.self, from: Data(contentsOf: url))
        try configuration.validate()
        return configuration
    }

    private func validate() throws {
        guard modelType == "nemotron3_diarization",
              sourceModel == "nvidia/Nemotron-3-Diarization",
              sourceRevision == "a435e9867d79e789e90053f9b6d6834053af564a" else {
            throw Nemotron3DiarizationError.invalidConfiguration(
                "bundle must use the pinned final Nemotron 3 checkpoint")
        }
        guard dtype == "int8" else {
            throw Nemotron3DiarizationError.invalidConfiguration(
                "only the INT8 export is supported")
        }
        guard sampleRate == 16_000, nMels == 128, dModel == 512,
              tfModel == 192, numLayers == 31, numHeads == 8,
              numSpeakers == 8, subsamplingFactor == 8,
              upsampleFactor == 8, spkcacheLen == 264, fifoLen == 40,
              chunkLen == 340, rightContext == 40,
              spkcacheUpdatePeriod == 300 else {
            throw Nemotron3DiarizationError.invalidConfiguration(
                "artifact geometry does not match the supported offline graph")
        }
    }
}

struct Nemotron3HeadOutput {
    let probabilities10ms: [Float]
    let probabilities80ms: [Float]
}

protocol Nemotron3InferenceBackend: AnyObject {
    var learnedSilenceEmbedding: [Float] { get }
    func preencode(chunk: [Float]) throws -> [Float]
    func predictHead(packedEmbeddings: [Float], validLength: Int) throws
        -> Nemotron3HeadOutput
}

/// Eight-speaker diarization using the final Nemotron 3 Core ML or MLX export.
/// The model predicts 10 ms speaker activity while keeping cache state at 80 ms.
public final class Nemotron3Diarizer {
    private let backend: Nemotron3InferenceBackend
    private let melExtractor: ([Float]) -> ([Float], Int)
    let config: SortformerConfig
    private var state: SortformerStreamingState
    private let updater: SortformerStateUpdater

    init(backend: Nemotron3InferenceBackend, extract: (([Float]) -> ([Float], Int))? = nil) {
        self.backend = backend
        self.config = .nemotron3Offline
        self.melExtractor = extract ?? SortformerMelExtractor(config: config).extract
        self.state = SortformerStreamingState(config: config)
        self.updater = SortformerStateUpdater(
            config: config,
            learnedSilenceEmbedding: backend.learnedSilenceEmbedding
        )
    }

    public func resetState() {
        state.reset()
    }

    public func diarize(
        audio: [Float],
        sampleRate: Int,
        config thresholds: DiarizationConfig = .sortformer,
        coreEncoderFrames: Int = 340,
        rightContextEncoderFrames: Int = 40
    ) throws -> DiarizationResult {
        guard (1...340).contains(coreEncoderFrames),
              (0...40).contains(rightContextEncoderFrames),
              coreEncoderFrames + rightContextEncoderFrames <= 380 else {
            throw Nemotron3DiarizationError.invalidConfiguration(
                "chunk geometry exceeds the fixed Core ML/MLX pre-encoder input")
        }
        let samples = DiarizationHelpers.resample(
            audio, from: sampleRate, to: config.sampleRate)
        guard !samples.isEmpty else { return Self.emptyResult }

        resetState()
        let (melSpec, totalMelFrames) = melExtractor(samples)
        guard totalMelFrames > 0 else { return Self.emptyResult }

        let encoderStride = config.subsamplingFactor
        let rightEncoderFrames = rightContextEncoderFrames
        let coreMelFrames = coreEncoderFrames * encoderStride
        // The compiled graph is fixed at 340 core + 40 right-context frames;
        // shorter experimental cadences still pad its input to that shape.
        let fixedChunkMelFrames = 380 * encoderStride
        let fixedChunkEmbeddingFrames = 380
        let packedCapacity = config.spkcacheLen + config.fifoLen
            + fixedChunkEmbeddingFrames
        let dim = config.fcDModel
        let speakers = config.maxSpeakers

        var allHighResolutionProbabilities: [Float] = []
        allHighResolutionProbabilities.reserveCapacity(totalMelFrames * speakers)
        var startFrame = 0

        while startFrame < totalMelFrames {
            let endFrame = min(startFrame + coreMelFrames, totalMelFrames)
            let rightOffset = min(
                rightEncoderFrames * encoderStride,
                totalMelFrames - endFrame)
            let validChunkMelFrames = endFrame + rightOffset - startFrame

            var chunk = [Float](
                repeating: 0,
                count: fixedChunkMelFrames * config.nMels)
            Self.copy(
                source: melSpec,
                sourceOffset: startFrame * config.nMels,
                destination: &chunk,
                destinationOffset: 0,
                count: validChunkMelFrames * config.nMels)

            let allChunkEmbeddings = try autoreleasepool {
                try backend.preencode(chunk: chunk)
            }
            let validChunkEmbeddingFrames = min(
                fixedChunkEmbeddingFrames,
                (validChunkMelFrames + encoderStride - 1) / encoderStride)
            guard allChunkEmbeddings.count == fixedChunkEmbeddingFrames * dim else {
                throw Nemotron3DiarizationError.runtime(
                    "pre-encoder returned \(allChunkEmbeddings.count) values")
            }

            let previousSpkcacheLength = state.spkcacheLength
            let previousFifoLength = state.fifoLength
            var packed = [Float](repeating: 0, count: packedCapacity * dim)
            var packedRows = 0
            Self.copy(
                source: state.spkcache,
                sourceOffset: 0,
                destination: &packed,
                destinationOffset: packedRows * dim,
                count: state.spkcacheLength * dim)
            packedRows += state.spkcacheLength
            Self.copy(
                source: state.fifo,
                sourceOffset: 0,
                destination: &packed,
                destinationOffset: packedRows * dim,
                count: state.fifoLength * dim)
            packedRows += state.fifoLength
            Self.copy(
                source: allChunkEmbeddings,
                sourceOffset: 0,
                destination: &packed,
                destinationOffset: packedRows * dim,
                count: validChunkEmbeddingFrames * dim)
            packedRows += validChunkEmbeddingFrames

            let output = try autoreleasepool {
                try backend.predictHead(
                    packedEmbeddings: packed, validLength: packedRows)
            }
            guard output.probabilities80ms.count == packedCapacity * speakers,
                  output.probabilities10ms.count
                    == packedCapacity * encoderStride * speakers else {
                throw Nemotron3DiarizationError.runtime(
                    "head returned an unexpected output shape")
            }

            let rightContext = (rightOffset + encoderStride - 1) / encoderStride
            let validChunkEmbeddings = Array(
                allChunkEmbeddings.prefix(validChunkEmbeddingFrames * dim))
            _ = updater.update(
                state: &state,
                chunkEmbs: validChunkEmbeddings,
                preds: output.probabilities80ms,
                leftContext: 0,
                rightContext: rightContext)

            // High-resolution predictions are laid out over
            // [spkcache | fifo | chunk] at eight 10 ms rows per cache row.
            let highStartFrame = (previousSpkcacheLength + previousFifoLength)
                * encoderStride
            let emittedFrames = endFrame - startFrame
            let highStart = highStartFrame * speakers
            let highEnd = highStart + emittedFrames * speakers
            guard highEnd <= output.probabilities10ms.count else {
                throw Nemotron3DiarizationError.runtime(
                    "10 ms core slice exceeds the head output")
            }
            allHighResolutionProbabilities.append(
                contentsOf: output.probabilities10ms[highStart..<highEnd])
            startFrame = endFrame
        }

        let audioDuration = Float(samples.count) / Float(config.sampleRate)
        let segments = SortformerDiarizer.binarize(
            probs: allHighResolutionProbabilities,
            frameCount: allHighResolutionProbabilities.count / config.maxSpeakers,
            audioDuration: audioDuration,
            config: config,
            thresholds: thresholds)
        return DiarizationResult(
            segments: segments,
            numSpeakers: Set(segments.map(\.speakerId)).count,
            speakerEmbeddings: [])
    }

    private static let emptyResult = DiarizationResult(
        segments: [], numSpeakers: 0, speakerEmbeddings: [])

    fileprivate static func copy(
        source: [Float],
        sourceOffset: Int,
        destination: inout [Float],
        destinationOffset: Int,
        count: Int
    ) {
        guard count > 0 else { return }
        precondition(sourceOffset >= 0 && sourceOffset + count <= source.count)
        precondition(destinationOffset >= 0 && destinationOffset + count <= destination.count)
        destination.withUnsafeMutableBufferPointer { target in
            source.withUnsafeBufferPointer { input in
                target.baseAddress!.advanced(by: destinationOffset).update(
                    from: input.baseAddress!.advanced(by: sourceOffset),
                    count: count)
            }
        }
    }
}

