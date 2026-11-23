import CryptoKit
import Foundation
import MeetingCompanionCore
import MLX
import MLXNN

public enum VoiceEmbeddingWorker {
    private static let modelDirectory = "voice"
    private static let weightsFilename = "model.safetensors"

    public static func checkLocalWeights(
        modelRoot: URL, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> URL {
        let weights = modelRoot.appendingPathComponent(modelDirectory).appendingPathComponent(weightsFilename)
        let actual = try ModelAssets.computeSHA256(at: weights, isCancelled: isCancelled)
        guard actual == VoiceEmbeddingProtocol.weightsSHA256 else {
            throw PipelineError("Контрольная сумма модели голосов не совпала.")
        }
        return weights
    }

    public static func extract(
        _ request: VoiceEmbeddingProtocol.Request, recordingDirectory: URL, modelRoot: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> VoiceEmbeddingProtocol.Response {
        func checkCancellation() throws {
            if isCancelled() { throw PipelineError("cancelled") }
        }
        try checkCancellation()
        try VoiceEmbeddingProtocol.validateRequest(request)
        let root = recordingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let result = root.appendingPathComponent("raw/transcripts").appendingPathComponent(request.resultID)
            .appendingPathComponent("result.json").resolvingSymlinksInPath()
        guard result.pathComponents.starts(with: root.pathComponents), result.deletingLastPathComponent().lastPathComponent == request.resultID else {
            throw VoiceEmbeddingProtocol.Invalid.request
        }
        let document = try TranscriptDocument.load(from: result, recordingDirectory: root)
        guard document.resultID == request.resultID else { throw VoiceEmbeddingProtocol.Invalid.request }
        var audio: [TranscriptDocument.SourceID: (url: URL, fingerprint: String, frames: Int)] = [:]
        for window in request.windows {
            try checkCancellation()
            if audio[window.sourceID] == nil {
                guard let source = document.sources.first(where: { $0.id == window.sourceID }) else {
                    throw VoiceEmbeddingProtocol.Invalid.request
                }
                let url = root.appendingPathComponent(source.recognitionAudioPath).resolvingSymlinksInPath()
                guard url.pathComponents.starts(with: root.pathComponents),
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw VoiceEmbeddingProtocol.Invalid.request
                }
                let fingerprint = try ModelAssets.computeSHA256(at: url, isCancelled: isCancelled)
                let reader = try PCMReader(url, block: 1)
                audio[window.sourceID] = (url, fingerprint, reader.count)
            }
            guard let source = audio[window.sourceID], window.sourceFingerprint == source.fingerprint,
                  window.endFrame <= source.frames else {
                throw PipelineError("Изменился источник звука для определения голоса.")
            }
        }

        let weights = try checkLocalWeights(modelRoot: modelRoot, isCancelled: isCancelled)
        try checkCancellation()
        let model = WeSpeakerNetwork()
        try model.update(parameters: ModuleParameters.unflattened(try MLX.loadArrays(url: weights)), verify: .all)
        model.train(false)
        eval(model.parameters())
        let melExtractor = MelFeatureExtractor()
        let features = try request.windows.map { window in
            try checkCancellation()
            guard let source = audio[window.sourceID] else { throw VoiceEmbeddingProtocol.Invalid.request }
            let count = window.endFrame - window.startFrame
            let reader = try PCMReader(source.url, block: count, limit: count)
            reader.file.framePosition = Int64(window.startFrame)
            guard let samples = try reader.next(), samples.allSatisfy(\.isFinite) else {
                throw VoiceEmbeddingProtocol.Invalid.request
            }
            let pcmFingerprint = samples.withUnsafeBytes { bytes in
                SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
            }
            guard samples.contains(where: { $0 != 0 }) else {
                return VoiceEmbeddingProtocol.Feature(windowID: window.id, pcmFingerprint: pcmFingerprint, embedding: nil)
            }
            let mel = melExtractor.extract(samples)
            let vector = model(mel.reshaped(1, mel.dim(0), 80, 1))
            eval(vector)
            let raw = vector[0].asArray(Float.self)
            let norm = raw.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard raw.count == VoiceEmbeddingProtocol.dimensions, norm.isFinite, norm > 0 else {
                throw VoiceEmbeddingProtocol.Invalid.response
            }
            return VoiceEmbeddingProtocol.Feature(windowID: window.id, pcmFingerprint: pcmFingerprint,
                                                   embedding: raw.map { Float(Double($0) / norm) })
        }
        for source in audio.values {
            guard try ModelAssets.computeSHA256(at: source.url, isCancelled: isCancelled) == source.fingerprint else {
                throw PipelineError("Источник звука изменился во время вычисления признаков голоса.")
            }
        }
        try checkCancellation()
        return .init(requestID: request.id, features: features)
    }
}
