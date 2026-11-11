import Testing
import MeetingCompanionCore
@testable import MeetingTranscriptionPipeline

@Suite("Nemotron speech gate")
struct NemotronGateTests {
    @Test func shortSpeechAndStrictWindowBoundaries() {
        let samples = 50 * 16000
        // The 24–25 second overlap belongs to both windows; no sample rounding.
        for (start, end, expected) in [
            (1.0, 1.02, [true, false, false]),
            (24.0, 24.01, [true, true, false]),
            (25.0, 25.01, [false, true, false]),
            (23.9, 24.0, [true, false, false]),
            (49.99, 50.0, [false, false, true]),
            (50.0, 50.1, [false, false, false]),
            (25.0, 25.0, [false, false, false]),
            (25.0 - 0.000001, 25.0, [true, true, false])
        ] {
            #expect(PipelineLogic.speechMask(samples, [.init(start: start, end: end, speaker: 7)], status: .completed) == expected)
        }
    }

    @Test func failureEmptyAndSourceIsolation() {
        let samples = 50 * 16000
        let host = [DiarizationInterval(start: 1, end: 1.1, speaker: 0)]
        let remote = [DiarizationInterval(start: 49, end: 49.2, speaker: 3)]
        for status: TranscriptDocument.ProcessingStatus in [.failed, .disabled] {
            #expect(PipelineLogic.speechMask(samples, host, status: status) == [true, true, true])
        }
        #expect(PipelineLogic.speechMask(samples, [], status: .completed) == [true, true, true])
        #expect(PipelineLogic.speechMask(0, host, status: .completed).isEmpty)
        #expect(PipelineLogic.speechMask(1, host, status: .failed) == [true])
        #expect(PipelineLogic.speechMask(samples, host + remote, status: .completed) == [true, false, true])
        #expect(PipelineLogic.speechMask(samples, remote, status: .completed) == [false, false, true])
        #expect(PipelineLogic.speechMask(samples, host, status: .completed) == [true, false, false])
    }
}
