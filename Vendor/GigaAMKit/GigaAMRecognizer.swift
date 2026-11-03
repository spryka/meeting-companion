import Foundation

public final class GigaAMRecognizer: @unchecked Sendable {
    public let configuration: GigaAMConfiguration
    public let bundle: ModelBundle
    private let model: GigaAMProModel

    public init(configuration: GigaAMConfiguration = .pro) throws {
        self.configuration = configuration
        self.bundle = try ModelBundle.load(configuration: configuration)
        self.model = try GigaAMProModel(bundle: bundle)
    }

    public func info() -> String {
        var weightsInfo = "not attached yet"

        if let weightsURL = bundle.weightsURL {
            do {
                let index = try SafetensorsIndex.loadHeader(url: weightsURL)
                let params = index.totalParameterCount
                weightsInfo = """
                \(weightsURL.path)
                tensors: \(index.tensorCount)
                params: \(params)
                """
            } catch {
                weightsInfo = "\(weightsURL.path)\nfailed to read safetensors header: \(error.localizedDescription)"
            }
        }

        return """
        \(bundle.manifest.name)
        source: \(bundle.manifest.sourceModel) @ \(bundle.manifest.sourceRevision)
        architecture: \(bundle.manifest.architecture)
        precision: \(bundle.manifest.precision)
        runtime: \(bundle.manifest.runtime)
        sample_rate: \(bundle.manifest.sampleRate)
        mlx: \(MLXEnvironment.description)
        weights: \(weightsInfo)
        tokenizer: \(bundle.tokenizerURL?.path ?? "not attached yet")
        """
    }

    public func transcribe(url: URL) async throws -> GigaAMResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GigaAMError.fileNotFound(url.path)
        }

        let audio = try AudioLoader.loadMonoFloat32(
            url: url,
            targetSampleRate: bundle.manifest.sampleRate
        )

        let transcription = try model.transcribe(
            samples: audio.samples,
            sampleRate: audio.sampleRate
        )

        let duration = TimeInterval(audio.samples.count) / TimeInterval(audio.sampleRate)

        return GigaAMResult(
            text: transcription.text,
            segments: [],
            words: transcription.words,
            duration: duration
        )
    }



    public func transcribeTimed(
        features: [Float],
        shape: [Int],
        length: Int
    ) throws -> GigaAMProTimedTranscription {
        try model.transcribeTimed(
            features: features,
            shape: shape,
            length: length
        )
    }

    public func transcribe(
        features: [Float],
        shape: [Int],
        length: Int
    ) throws -> GigaAMProTranscription {
        try model.transcribe(
            features: features,
            shape: shape,
            length: length
        )
    }

    public func transcribe(samples: [Float], sampleRate: Int) async throws -> GigaAMResult {
        let transcription = try model.transcribe(
            samples: samples,
            sampleRate: sampleRate
        )

        let duration = TimeInterval(samples.count) / TimeInterval(sampleRate)

        return GigaAMResult(
            text: transcription.text,
            segments: [],
            words: transcription.words,
            duration: duration
        )
    }
}
