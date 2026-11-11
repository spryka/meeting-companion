import Foundation
import Testing
import MLX
import MLXNN
import PipelineSilero
@testable import MeetingTranscriptionPipeline

@Suite(.serialized) struct BoundedVADTests {
    private enum ProbeError: Error { case cancelled, read }

    private func model() throws -> SileroVAD {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let metallib = root.appendingPathComponent(".build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        if FileManager.default.fileExists(atPath: metallib.path) { GPU.metallib = metallib }
        let model = SileroVAD(SileroVADConfig(), include8k: false)
        // Synthetic deterministic weights; no private audio or downloaded models in tests.
        let weights = model.parameters().flattened().map { name, value in
            (name, MLXArray((0..<value.size).map { Float(sin(Double($0 + name.count))) * 0.03 }, value.shape))
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model.parameters())
        return model
    }

    @Test func exactProbabilitiesAcrossFeedsDrainsAndChannels() throws {
        let model = try model()
        let input = (0..<164_353).map { Float(sin(Double($0) * 0.071)) * 0.8 }
        for count in [0, 1, 511, 512, 513, 163_839, 163_840, 164_353] {
            let samples = Array(input.prefix(count))
            var referenceRead = false
            let reference = try referenceBoundedVAD(model) {
                defer { referenceRead = true }
                return referenceRead ? nil : samples
            }
            for block in [733, 160_000] {
                var offset = 0
                let (actual, frames) = try boundedVAD(model) {
                    guard offset < samples.count else { return nil }
                    let end = min(offset + block, samples.count)
                    defer { offset = end }
                    return Array(samples[offset..<end])
                }
                #expect(actual.map(\.bitPattern) == reference.0.map(\.bitPattern))
                #expect(actual.count == (count + 511) / 512)
                #expect(actual.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                #expect(frames.samples == count && frames.finished && frames.tail.isEmpty)
            }
        }
    }

    @Test func cancellationAndReadErrorsPropagate() throws {
        let model = try model()
        var checks = 0
        #expect(throws: ProbeError.cancelled) {
            _ = try boundedVAD(model, checkCancel: {
                checks += 1
                if checks == 323 { throw ProbeError.cancelled }
            }, next: { Array(repeating: 0, count: 164_353) })
        }
        #expect(checks == 323)
        #expect(throws: ProbeError.read) {
            _ = try boundedVAD(model, next: { throw ProbeError.read })
        }
        var supplied = false
        let (fresh, _) = try boundedVAD(model) {
            defer { supplied = true }
            return supplied ? nil : [Float(0)]
        }
        var referenceSupplied = false
        let (expected, _) = try referenceBoundedVAD(model) {
            defer { referenceSupplied = true }
            return referenceSupplied ? nil : [Float(0)]
        }
        #expect(fresh.map(\.bitPattern) == expected.map(\.bitPattern))
    }
}
