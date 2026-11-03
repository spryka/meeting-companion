import Foundation
@preconcurrency import MLX
@preconcurrency import MLXNN

public struct GigaAMProTranscription: Sendable {
    public let tokenIds: [Int]
    public let text: String
    public let encodedLength: Int
    /// Words with start/end times derived from RNNT emission frame indices
    /// (resolution = one encoder frame, see `GigaAMProModel.encoderFrameDuration`).
    public let words: [GigaAMProWord]
}

/// A word with timestamps derived from the greedy decoder's emission trace:
/// start = first token's encoder frame, end = last token's frame + 1.
public struct GigaAMProWord: Sendable, Codable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct GigaAMProTranscriptionTiming: Sendable {
    public let arraySec: TimeInterval
    public let encoderSec: TimeInterval
    public let rnntGreedySec: TimeInterval
    public let rnntDecoderSec: TimeInterval
    public let rnntJointSec: TimeInterval
    public let rnntReadbackSec: TimeInterval
    public let rnntStepCount: Int
    public let tokenizerSec: TimeInterval
    public let totalSec: TimeInterval
}

public struct GigaAMProTimedTranscription: Sendable {
    public let transcription: GigaAMProTranscription
    public let timing: GigaAMProTranscriptionTiming
}

public final class GigaAMProModel: @unchecked Sendable {
    public let bundle: ModelBundle
    private let melProcessor: MelSpectrogramProcessor

    private let store: GigaAMTensorStore
    private let encoder: GigaAMEncoder
    private let head: GigaAMRNNTHead
    private let greedyDecoder: RNNTGreedyDecoder
    private let tokenizer: SentencePieceTokenizer

    public init(bundle: ModelBundle) throws {
        self.bundle = bundle

        guard let assetsDirectory = bundle.directory ?? bundle.tokenizerURL?.deletingLastPathComponent() else {
            throw GigaAMError.modelDirectoryNotFound("Cannot resolve model assets directory")
        }

        self.melProcessor = try MelSpectrogramProcessor(
            config: MelSpectrogramConfig(sampleRate: bundle.manifest.sampleRate),
            assetsDirectory: assetsDirectory
        )

        guard let weightsURL = bundle.weightsURL else {
            throw GigaAMError.weightsNotFound("weights file is not attached")
        }

        guard let tokenizerURL = bundle.tokenizerURL else {
            throw GigaAMError.fileNotFound("tokenizer.model is not attached")
        }

        self.store = try GigaAMTensorStore(weightsURL: weightsURL)
        self.encoder = try GigaAMEncoder(store: store)
        self.head = try GigaAMRNNTHead(store: store, blankId: 1024)
        self.greedyDecoder = RNNTGreedyDecoder(
            config: RNNTGreedyDecoderConfig(
                blankId: 1024,
                maxSymbolsPerFrame: 10
            )
        )
        self.tokenizer = try SentencePieceTokenizer(modelURL: tokenizerURL)
    }

    public func transcribe(
        features: [Float],
        shape: [Int],
        length: Int
    ) throws -> GigaAMProTranscription {
        try transcribeTimed(
            features: features,
            shape: shape,
            length: length
        ).transcription
    }

    public func transcribeTimed(
        features: [Float],
        shape: [Int],
        length: Int
    ) throws -> GigaAMProTimedTranscription {
        guard shape.count == 3 else {
            throw GigaAMError.invalidArguments("Expected features shape [B, 64, T], got \(shape)")
        }

        guard shape[0] == 1 else {
            throw GigaAMError.invalidArguments("Only batch size 1 is supported now, got \(shape[0])")
        }

        guard shape[1] == 64 else {
            throw GigaAMError.invalidArguments("Expected 64 mel features, got \(shape[1])")
        }

        guard features.count == shape.reduce(1, *) else {
            throw GigaAMError.invalidArguments(
                "Feature count mismatch: got \(features.count), expected \(shape.reduce(1, *))"
            )
        }

        let totalStart = Self.now()

        let arrayStart = Self.now()
        let featureArray = MLXArray(features, shape)
        let arraySec = Self.now() - arrayStart

        let encoderStart = Self.now()
        let encoderOutput = encoder.forward(features: featureArray, length: length)
        let encoderSec = Self.now() - encoderStart

        let rnntStart = Self.now()
        let greedyTimed = try greedyDecoder.decodeTimed(
            head: head,
            encoded: encoderOutput.encoded,
            encodedLength: encoderOutput.length
        )
        let greedy = greedyTimed.result
        let rnntTiming = greedyTimed.timing
        let rnntGreedySec = Self.now() - rnntStart

        let tokenizerStart = Self.now()
        let text = try tokenizer.decode(tokenIds: greedy.tokens)
        let words = Self.buildWords(
            steps: greedy.steps,
            piece: tokenizer.piece(forTokenId:),
            frameDuration: encoderFrameDuration
        )
        let tokenizerSec = Self.now() - tokenizerStart

        let totalSec = Self.now() - totalStart

        return GigaAMProTimedTranscription(
            transcription: GigaAMProTranscription(
                tokenIds: greedy.tokens,
                text: text,
                encodedLength: encoderOutput.length,
                words: words
            ),
            timing: GigaAMProTranscriptionTiming(
                arraySec: arraySec,
                encoderSec: encoderSec,
                rnntGreedySec: rnntGreedySec,
                rnntDecoderSec: rnntTiming.decoderSec,
                rnntJointSec: rnntTiming.jointSec,
                rnntReadbackSec: rnntTiming.readbackSec,
                rnntStepCount: rnntTiming.stepCount,
                tokenizerSec: tokenizerSec,
                totalSec: totalSec
            )
        )
    }


    public func transcribe(
        samples: [Float],
        sampleRate: Int
    ) throws -> GigaAMProTranscription {
        guard sampleRate == bundle.manifest.sampleRate else {
            throw GigaAMError.invalidArguments(
                "Expected sampleRate \(bundle.manifest.sampleRate), got \(sampleRate)"
            )
        }

        let featureInput = try melProcessor.computeFlat(samples: samples)

        return try transcribe(
            features: featureInput.features,
            shape: featureInput.shape,
            length: featureInput.length
        )
    }

    /// Seconds per encoder output frame: mel hop (160 samples @ 16 kHz = 10 ms)
    /// × 4 subsampling (two stride-2 convs in `GigaAMPreEncoder`).
    public var encoderFrameDuration: TimeInterval {
        Double(melProcessor.config.hopLength) / Double(bundle.manifest.sampleRate) * 4.0
    }

    /// Group the greedy decoder's non-blank emissions into words at sentencepiece
    /// "▁" boundaries. Word start = first token's frame, end = last token's frame + 1.
    ///
    /// - `piece` maps a token id to its sentencepiece piece; `nil` means a control
    ///   token (bos/eos/pad or out of range) and the step is skipped.
    /// - `<unk>` becomes a standalone `⁇` word, matching how
    ///   `SentencePieceTokenizer.decode` renders it space-separated in the text.
    /// - Punctuation pieces (no `▁` prefix) attach to the preceding word, so the
    ///   e2e models' punctuated output stays word-aligned.
    static func buildWords(
        steps: [RNNTGreedyStepTrace],
        piece: (Int) -> String?,
        frameDuration: TimeInterval
    ) -> [GigaAMProWord] {
        var words = [GigaAMProWord]()
        var currentText = ""
        var startFrame = 0
        var endFrame = 0

        func flush() {
            let trimmed = currentText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                words.append(GigaAMProWord(
                    text: trimmed,
                    start: TimeInterval(startFrame) * frameDuration,
                    end: TimeInterval(endFrame + 1) * frameDuration
                ))
            }
            currentText = ""
        }

        for step in steps where !step.isBlank {
            guard let text = piece(step.token) else { continue }

            if text == "<unk>" {
                flush()
                currentText = "⁇"
                startFrame = step.timeIndex
                endFrame = step.timeIndex
                flush()
                continue
            }

            if text.hasPrefix("▁") {
                flush()
                currentText = String(text.dropFirst())
                startFrame = step.timeIndex
            } else if currentText.isEmpty {
                currentText = text
                startFrame = step.timeIndex
            } else {
                currentText += text
            }
            endFrame = step.timeIndex
        }
        flush()

        return words
    }

    private static func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public func transcribe(features: [[Float]]) throws -> [Int] {
        guard let first = features.first else {
            throw GigaAMError.invalidArguments("Empty features")
        }

        let flat = features.flatMap { $0 }
        let result = try transcribe(
            features: flat,
            shape: [1, features.count, first.count],
            length: first.count
        )

        return result.tokenIds
    }
}
