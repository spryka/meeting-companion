import Foundation
import Testing
@testable import MeetingTranscriptionPipeline

@Suite("Cascade exact parity")
struct CascadeParityTests {
    private func check(_ source: [PipelineWord], _ donor: [PipelineWord]) {
        let expected = CascadeReference.cascade(source, donor)
        let actual = PipelineLogic.cascade(source, donor)
        #expect(actual.0 == expected.0)
        #expect(actual.1 == expected.1) // Includes order, scores, all rejected rows and reasons.
    }

    @Test func boundariesAndNonmonotonicEnds() {
        let g = [
            PipelineWord(start: 10, end: 12, text: "alpha", speaker: nil),
            PipelineWord(start: 10, end: 10.1, text: "beta", speaker: 1),
            PipelineWord(start: 12, end: 14, text: "gamma", speaker: 1)
        ]
        let p = [
            PipelineWord(start: 0, end: 20, text: "alpha"),
            PipelineWord(start: 1, end: 2, text: "beta"),
            PipelineWord(start: 2, end: 3, text: "gamma"),
            PipelineWord(start: 3, end: 13, text: "alpha"),
            PipelineWord(start: 9, end: 10, text: "alpha"),
            PipelineWord(start: 9, end: 10.05, text: "alpha"),
            PipelineWord(start: 9, end: (10.05).nextUp, text: "alpha"),
            PipelineWord(start: 12, end: 14, text: "gamma")
        ]
        check(g, p)
        #expect(CascadeReference.cascade([g[0]], p).1.contains { $0.donor_indices == [0, 1] })
        check([], p)
        check(g, [])
        check([], [])
        check(Array(g.reversed()), Array(p.reversed()))
        // The qualifying end belongs to the fourth word, whose start is before the source.
        let fourthEnd = (0..<4).map { index -> PipelineWord in
            let end = index == 3 ? 13.0 : Double(index + 1)
            return PipelineWord(start: Double(index), end: end, text: index == 3 ? "alpha" : "")
        }
        #expect(CascadeReference.cascade([g[0]], fourthEnd).1.contains { $0.donor_indices == [0, 4] })
        check([g[0]], fourthEnd)
    }

    @Test func exactOverlapAndCrossingAlignment() {
        let source = [PipelineWord(start: 0, end: 1, text: "alpha", speaker: 1),
                      PipelineWord(start: 0, end: 1, text: "beta", speaker: 2)]
        let donor = [PipelineWord(start: 0, end: 1, text: "beta"),
                     PipelineWord(start: 0, end: 1, text: "alpha")]
        #expect(CascadeReference.cascade(source, donor).1.contains { $0.reason == "crossing_alignment" })
        check(source, donor)
        for end in [(0.05).nextDown, 0.05, (0.05).nextUp] {
            let p = [PipelineWord(start: 0, end: end, text: "alpha")]
            let result = CascadeReference.cascade([source[0]], p)
            #expect(result.1.isEmpty == (end <= 0.05))
            check([source[0]], p)
        }
    }

    @Test func normalizationProtectionAndConflicts() {
        let texts = ["и", "Ёлка,", "café", "API-2", "42", "!!!", "alpha beta", "альфа", "alpha"]
        let g = texts.enumerated().map { PipelineWord(start: Double($0.offset) * 0.1, end: 2, text: $0.element, speaker: $0.offset < 4 ? nil : 1) }
        let p = texts.reversed().enumerated().map { PipelineWord(start: Double($0.offset) * 0.1, end: 2, text: $0.element) }
        check(g, p)
        check(g.map { $0.with(speaker: 1) }, p)
    }

    @Test func unroundedSimilarityOrdersEqualScores() {
        let g = [PipelineWord(start: 0, end: 1, text: String(repeating: "a", count: 61))]
        let p = [PipelineWord(start: 0, end: 1, text: String(repeating: "a", count: 62)),
                 PipelineWord(start: 0, end: 1, text: String(repeating: "a", count: 60))]
        // 61/62 and 60/61 both round to 0.984; raw similarity must beat donor index.
        let reference = CascadeReference.cascade(g, p)
        #expect(reference.1.filter(\.applied).map(\.donor_indices) == [[0, 1]])
        check(g, p)
    }

    @Test func seededFiniteIntervals() {
        var state: UInt64 = 0xCA5CADE
        func next(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1
            return Int(state >> 32) % count
        }
        let texts = ["альфа", "alpha", "бета", "beta", "и", "42", " café ", "!!!", "a b", "ё", "api", "тест", "ΟΣ", "İ", "e\u{301}"]
        for _ in 0..<100 {
            func words() -> [PipelineWord] {
                (0..<next(12)).map { _ in
                    let start = Double(next(30)) * 0.05
                    return PipelineWord(start: start, end: start + Double(next(50)) * 0.05,
                                        text: texts[next(texts.count)], speaker: [nil, 1, 2][next(3)])
                }
            }
            check(words(), words())
        }
    }
}
