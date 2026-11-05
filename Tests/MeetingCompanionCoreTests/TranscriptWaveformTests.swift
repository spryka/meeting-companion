import Testing
@testable import MeetingCompanionCore

@Suite struct TranscriptWaveformTests {
    @Test func placeholderCountAndBounds() {
        let wf = TranscriptWaveform(samples: [])
        #expect(wf.samples.count == TranscriptWaveform.sampleCount)
        for s in wf.samples {
            #expect(s >= 0.0 && s <= 1.0)
        }
    }

    @Test func resampleToTargetCount() {
        let custom: [Float] = [0.1, 0.5, 0.9]
        let wf = TranscriptWaveform(samples: custom)
        #expect(wf.samples.count == TranscriptWaveform.sampleCount)
    }

    @Test func exactCountPreserved() {
        let exact = (0..<TranscriptWaveform.sampleCount).map { Float($0) / Float(TranscriptWaveform.sampleCount) }
        let wf = TranscriptWaveform(samples: exact)
        #expect(wf.samples == exact)
    }
}
