import Foundation
@preconcurrency import MLX

public struct MelSpectrogramConfig: Sendable, Codable, Hashable {
    public let sampleRate: Int
    public let nMels: Int
    public let nFFT: Int
    public let hopLength: Int
    public let winLength: Int
    public let center: Bool

    public init(
        sampleRate: Int = 16_000,
        nMels: Int = 64,
        nFFT: Int = 320,
        hopLength: Int = 160,
        winLength: Int = 320,
        center: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.nMels = nMels
        self.nFFT = nFFT
        self.hopLength = hopLength
        self.winLength = winLength
        self.center = center
    }
}

public final class MelSpectrogramProcessor: @unchecked Sendable {
    public let config: MelSpectrogramConfig
    public let nFreqs: Int

    private let window: MLXArray
    private let filterbank: MLXArray

    public init(
        config: MelSpectrogramConfig = MelSpectrogramConfig(),
        assetsDirectory: URL
    ) throws {
        guard !config.center else {
            throw GigaAMError.notImplemented("MelSpectrogram.center=true is not implemented")
        }

        guard config.nFFT == config.winLength else {
            throw GigaAMError.notImplemented("nFFT != winLength is not implemented")
        }

        self.config = config
        self.nFreqs = config.nFFT / 2 + 1

        let windowURL = assetsDirectory.appendingPathComponent("hann_window.f32.bin")
        let filterbankURL = assetsDirectory.appendingPathComponent("mel_filterbank_mel_freq.f32.bin")

        let window = try Self.readFloat32Binary(windowURL)
        let filterbank = try Self.readFloat32Binary(filterbankURL)

        guard window.count == config.winLength else {
            throw GigaAMError.invalidArguments(
                "Invalid hann window size: \(window.count), expected \(config.winLength)"
            )
        }

        guard filterbank.count == config.nMels * nFreqs else {
            throw GigaAMError.invalidArguments(
                "Invalid mel filterbank size: \(filterbank.count), expected \(config.nMels * nFreqs)"
            )
        }

        self.window = MLXArray(window)
        self.filterbank = MLXArray(filterbank, [config.nMels, nFreqs]).transposed()
        eval(self.window, self.filterbank)
    }

    public func compute(samples: [Float]) throws -> [[Float]] {
        let flat = try computeFlat(samples: samples)
        return (0..<config.nMels).map { mel in
            Array(flat.features[(mel * flat.length)..<((mel + 1) * flat.length)])
        }
    }

    public func computeFlat(samples: [Float]) throws -> (features: [Float], shape: [Int], length: Int) {
        guard samples.count >= config.winLength else {
            throw GigaAMError.invalidArguments(
                "Audio is shorter than winLength: samples=\(samples.count), winLength=\(config.winLength)"
            )
        }
        let frameCount = Self.outputLength(sampleCount: samples.count, config: config)
        let positions = MLXArray(Int32(0)..<Int32(frameCount)).reshaped(-1, 1) * config.hopLength
            + MLXArray(Int32(0)..<Int32(config.winLength)).reshaped(1, -1)
        let frames = MLXArray(samples)[positions] * window
        let power = pow(abs(MLXFFT.rfft(frames)), 2)
        let features = log(clip(matmul(power, filterbank), min: 1e-9, max: 1e9)).transposed()
        return (features.reshaped(-1).asArray(Float.self), [1, config.nMels, frameCount], frameCount)
    }

    private static func outputLength(sampleCount: Int, config: MelSpectrogramConfig) -> Int {
        if config.center {
            return sampleCount / config.hopLength + 1
        }

        return ((sampleCount - config.winLength) / config.hopLength) + 1
    }

    private static func readFloat32Binary(_ url: URL) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GigaAMError.fileNotFound(url.path)
        }

        let data = try Data(contentsOf: url)

        guard data.count % MemoryLayout<Float>.size == 0 else {
            throw GigaAMError.invalidArguments(
                "Float32 binary size is not divisible by 4: \(url.path)"
            )
        }

        var values = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)

        _ = values.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }

        return values
    }
}

public enum MelSpectrogram {
    public static func compute(
        samples: [Float],
        config: MelSpectrogramConfig = MelSpectrogramConfig(),
        assetsDirectory: URL
    ) throws -> [[Float]] {
        let processor = try MelSpectrogramProcessor(
            config: config,
            assetsDirectory: assetsDirectory
        )

        return try processor.compute(samples: samples)
    }

    public static func outputLength(sampleCount: Int, config: MelSpectrogramConfig = MelSpectrogramConfig()) -> Int {
        if config.center {
            return sampleCount / config.hopLength + 1
        }

        return ((sampleCount - config.winLength) / config.hopLength) + 1
    }
}
