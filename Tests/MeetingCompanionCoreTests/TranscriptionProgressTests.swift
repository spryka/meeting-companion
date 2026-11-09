import Foundation
import Testing
@testable import MeetingCompanionCore

struct TranscriptionProgressTests {
    @Test func processingWireLifecycleValidation() throws {
        for stage in ["audio", "mix", "publication", "gigaam"] {
            let line = "MEETING_PROGRESS {\"stage\":\"\(stage)\",\"completed\":0,\"total\":0,\"state\":\"started\"}"
            let value = try #require(TranscriptionProgress(line: Data(line.utf8)))
            #expect(value.state == .started && value.stageFraction == nil)
        }
        let invalid = "MEETING_PROGRESS {\"stage\":\"vad\",\"completed\":0,\"total\":0,\"state\":\"invented\"}"
        #expect(TranscriptionProgress(line: Data(invalid.utf8)) == nil)
    }

    @Test func capsule24NativeEchoFramesArePercentageNotSeconds() throws {
        for (done, total, text) in [(47_840_160, 58_547_450, "81%"), (0, 1, "0%"), (1, 1, "100%")] {
            let line = "MEETING_PROGRESS {\"stage\":\"echo\",\"channel\":\"host\",\"completed\":\(done),\"total\":\(total)}"
            let progress = try #require(TranscriptionProgress(line: Data(line.utf8)))
            #expect(progress.text == "Подавление эха · микрофон · \(text)…")
            #expect(progress.step == nil && progress.steps == nil)
        }
        let unknown = try #require(TranscriptionProgress(line: Data("MEETING_PROGRESS {\"stage\":\"echo\",\"completed\":0,\"total\":0}".utf8)))
        #expect(unknown.stageFraction == nil && unknown.text == "Подавление эха…")
    }

    @Test func capsule24NativeUnknownWarningAndValidationStayHonest() throws {
        let warning = try #require(TranscriptionProgress(line: Data("MEETING_PROGRESS {\"stage\":\"warning\",\"completed\":0,\"total\":0,\"warning\":\"Synthetic warning\",\"channel\":\"remote\"}".utf8)))
        #expect(warning.stageFraction == nil && warning.text == "Synthetic warning · системный звук…")
        for json in ["{\"stage\":\"echo\",\"completed\":2,\"total\":1}", "{\"stage\":\"warning\",\"completed\":0,\"total\":0}", "{\"stage\":\"gigaam\",\"completed\":1,\"total\":3,\"step\":1}"] {
            #expect(TranscriptionProgress(line: Data(("MEETING_PROGRESS " + json).utf8)) == nil)
        }
    }
}
