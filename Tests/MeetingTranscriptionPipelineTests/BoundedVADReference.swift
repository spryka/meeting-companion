// Frozen pre-compile runner from 35d00b8; keep independent of production implementation.
import Foundation
import MLX
import PipelineSilero
import MeetingTranscriptionPipeline

// Keep upstream async eval every 16 feeds; drain one bounded 10.24s graph to CPU.
func referenceBoundedVAD(
    _ model: SileroVAD,
    checkCancel: () throws -> Void = {},
    next: () throws -> [Float]?
) throws -> ([Float], FeedFrames) {
    let gain = Float(pow(10.0, 6.0 / 20.0))
    var state: MLXArray? = nil
    var probabilities: [Float] = []
    var samples: [Float] = []
    var context = Array(repeating: Float(0), count: 64)
    var frames = FeedFrames()

    func flush() throws {
        guard !samples.isEmpty else { return }
        let a = MLXArray(context + samples, [1, 64 + samples.count])
        var pending: [MLXArray] = []
        for pos in stride(from: 0, to: samples.count, by: 512) {
            let (p, s) = try model(a[0..., pos..<pos + 576], state: state, sampleRate: 16000)
            pending.append(p)
            state = s
            if pending.count % 16 == 0 { asyncEval([p, s]) }
        }
        let p = concatenated(pending, axis: 1)[0]
        eval(p, state!)
        probabilities += p.asArray(Float.self)
        context = Array(samples.suffix(64))
        samples.removeAll(keepingCapacity: true)
    }

    func feed(_ frame: [Float]) throws {
        try checkCancel()
        samples += frame
        if samples.count == 512 * 320 { try flush() }
    }

    while let pcm = try next() {
        try checkCancel()
        try frames.append(pcm.map { min(1, max(-1, $0 * gain)) }, emit: feed)
    }
    try frames.finish(emit: feed)
    try flush()
    return (probabilities, frames)
}
