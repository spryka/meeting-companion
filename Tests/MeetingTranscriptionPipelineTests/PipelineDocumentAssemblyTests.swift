import Foundation
import Testing
import MeetingCompanionCore
@testable import MeetingTranscriptionPipeline

@Suite("Pipeline document assembly")
struct PipelineDocumentAssemblyTests {
    private func encoded(_ document: TranscriptDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    private func channel(
        _ id: TranscriptDocument.SourceID,
        final: [PipelineWord], baseline: [PipelineWord],
        status: TranscriptDocument.ProcessingStatus = .completed
    ) -> PipelineRunner.ChannelAudio {
        let path = "raw/meeting.\(id.rawValue)_record.wav"
        let unusedURL = URL(fileURLWithPath: "/unused/" + path)
        return PipelineRunner.ChannelAudio(
            id: id, originalURL: unusedURL, recognitionURL: unusedURL,
            originalRelPath: path, recognitionRelPath: path,
            sha256: "unused", frameCount: 0, duration: 0,
            gigaamWords: baseline, finalWords: final, correctionStatus: status
        )
    }

    private func assemble(_ channels: [PipelineRunner.ChannelAudio]) throws -> TranscriptDocument {
        try PipelineRunner.assembleDocument(
            channels: channels, resultID: "res_assembly",
            aec: .init(requested: false, outcome: .disabled),
            playback: .init(status: .unavailable, mixPath: nil),
            additionalWarnings: [.init(code: "playback_mix_failed", sourceID: nil, message: "Synthetic text-only publication")]
        )
    }

    @Test func insertionSplitsHostBeforeSortingTurns() throws {
        let host = [
            PipelineWord(start: 10, end: 11, text: "начало", speaker: 1),
            PipelineWord(start: 12, end: 12.5, text: "продолжение", speaker: 1)
        ]
        let remote = [PipelineWord(start: 11.2, end: 11.8, text: "вставка", speaker: 1)]
        let document = try assemble([
            channel(.host, final: host, baseline: host),
            channel(.remote, final: remote, baseline: remote)
        ])
        #expect(document.turns.map(\.wordIDs) == [["w_h_1"], ["w_r_1"], ["w_h_2"]])
        #expect(document.turns.map(\.speakerID) == ["spk_h1", "spk_r1", "spk_h1"])
        #expect(document.words.map(\.text) == (host + remote).map(\.text))
        #expect(document.baselineWords.map(\.text) == (host + remote).map(\.text))
        #expect(Set(document.turns.flatMap(\.wordIDs)) == Set(document.words.map(\.id)))
        #expect(document.turns.flatMap(\.wordIDs).count == document.words.count)
    }

    @Test(arguments: [1.49, 1.5, 2.5])
    func paragraphPauseThreshold(gap: Double) throws {
        let words = [
            PipelineWord(start: 0, end: 1, text: "до", speaker: 1),
            PipelineWord(start: 1 + gap, end: 2 + gap, text: "после", speaker: 1)
        ]
        let document = try assemble([channel(.host, final: words, baseline: words)])
        #expect(document.turns.count == (gap < 1.5 ? 1 : 2))
        #expect(document.words.map(\.start) == words.map(\.start))
        #expect(document.words.map(\.end) == words.map(\.end))
    }

    @Test func equalStartsUseSourceThenOrdinalRegardlessOfChannelOrder() throws {
        let host = [
            PipelineWord(start: 10, end: 10.8, text: "первое", speaker: 2),
            PipelineWord(start: 10, end: 10.5, text: "второе", speaker: 1)
        ]
        let remote = [PipelineWord(start: 10, end: 11, text: "удалённое", speaker: 1)]
        let document = try assemble([
            channel(.remote, final: remote, baseline: remote),
            channel(.host, final: host, baseline: host)
        ])
        #expect(document.turns.map(\.wordIDs) == [["w_h_1"], ["w_h_2"], ["w_r_1"]])
        #expect(document.turns.map(\.speakerID) == ["spk_h2", "spk_h1", "spk_r1"])
    }

    @Test func overlappingWordsKeepFullIntervalsAndChronologicalFragments() throws {
        let host = [
            PipelineWord(start: 10, end: 13, text: "длинное", speaker: 1),
            PipelineWord(start: 12, end: 12.5, text: "короткое", speaker: 1),
            PipelineWord(start: 13, end: 14, text: "продолжение", speaker: 1)
        ]
        let remote = [PipelineWord(start: 12.7, end: 13.5, text: "вставка", speaker: 1)]
        let document = try assemble([
            channel(.host, final: host, baseline: host),
            channel(.remote, final: remote, baseline: remote)
        ])
        #expect(document.turns.map(\.wordIDs) == [["w_h_1", "w_h_2"], ["w_r_1"], ["w_h_3"]])
        #expect(document.turns.map(\.start) == [10, 12.7, 13])
        #expect(document.turns.map(\.end) == [13, 13.5, 14])
        let roundtrip = try JSONDecoder().decode(TranscriptDocument.self, from: encoded(document))
        #expect(roundtrip.words == document.words)
        #expect(roundtrip.baselineWords == document.baselineWords)
    }

    @Test(arguments: ["конец.»", "конец.“", "конец!)", "конец?]", "конец.}"])
    func sentenceEndingInsideClosingQuotesSplitsAfterFifteenSeconds(ending: String) throws {
        let words = [
            PipelineWord(start: 0, end: 14, text: "начало", speaker: 1),
            PipelineWord(start: 14, end: 15, text: ending, speaker: 1),
            PipelineWord(start: 15, end: 16, text: "дальше", speaker: 1)
        ]
        let document = try assemble([channel(.host, final: words, baseline: words)])
        #expect(document.turns.map(\.wordIDs) == [["w_h_1", "w_h_2"], ["w_h_3"]])
    }

    @Test func durationLimitAndIndivisibleWord() throws {
        let words = [
            PipelineWord(start: 0, end: 29, text: "до", speaker: 1),
            PipelineWord(start: 29, end: 30, text: "ровно", speaker: 1),
            PipelineWord(start: 30, end: 31, text: "после", speaker: 1),
            PipelineWord(start: 31, end: 65, text: "неделимое", speaker: 1)
        ]
        let document = try assemble([channel(.host, final: words, baseline: words)])
        #expect(document.turns.map(\.wordIDs) == [["w_h_1", "w_h_2"], ["w_h_3"], ["w_h_4"]])
        #expect(document.turns.map(\.end) == [30, 31, 65])
    }

    @Test func publishedInsertionRetainsExactChronologicalWordOrder() throws {
        let host = [PipelineWord(start: 0, end: 1, text: "начало", speaker: 2),
                    PipelineWord(start: 2, end: 3, text: "продолжение", speaker: 2)]
        let remote = [PipelineWord(start: 1, end: 2, text: "вставка", speaker: 2)]
        let document = try assemble([channel(.host, final: host, baseline: host),
                                     channel(.remote, final: remote, baseline: remote)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try TranscriptPublisher(recordingDirectory: root).publish(document: document, recordingStem: "meeting")
        let loaded = try TranscriptDocument.load(from: result, recordingDirectory: root)
        #expect(loaded.turns.map(\.wordIDs) == [["w_h_1"], ["w_r_1"], ["w_h_2"]])
        let text = try String(contentsOf: result.deletingLastPathComponent().appendingPathComponent("transcript.txt"), encoding: .utf8)
        let a = try #require(text.range(of: "начало"))
        let b = try #require(text.range(of: "вставка"))
        let c = try #require(text.range(of: "продолжение"))
        #expect(a.lowerBound < b.lowerBound && b.lowerBound < c.lowerBound)
    }

    @Test func prolongedOverlapKeepsEverySourceVoiceAndWordInterval() throws {
        let host = (0..<20).map { PipelineWord(start: Double($0), end: Double($0) + 3,
            text: "host\($0)", speaker: $0 % 2 + 1) }
        let remote = (0..<20).map { PipelineWord(start: Double($0) + 0.5, end: Double($0) + 2,
            text: "remote\($0)", speaker: $0 % 2 + 1) }
        let document = try assemble([channel(.host, final: host, baseline: host),
                                     channel(.remote, final: remote, baseline: remote)])
        let expectedIDs = (1...20).flatMap { ["w_h_\($0)", "w_r_\($0)"] }
        #expect(document.turns.flatMap(\.wordIDs) == expectedIDs)
        #expect(document.turns.count == 40)
        #expect(document.words.map(\.text) == (host + remote).map(\.text))
        #expect(document.words.map(\.start) == (host + remote).map(\.start))
        #expect(document.words.map(\.end) == (host + remote).map(\.end))
        #expect(document.baselineWords.map(\.text) == document.words.map(\.text))
        #expect(Set(document.turns.map(\.speakerID)) == ["spk_h1", "spk_h2", "spk_r1", "spk_r2"])
        let byID = Dictionary(uniqueKeysWithValues: document.words.map { ($0.id, $0) })
        #expect(document.turns.allSatisfy { turn in
            turn.wordIDs.allSatisfy { id in
                guard let word = byID[id] else { return false }
                return word.speakerID == turn.speakerID && turn.start <= word.start && turn.end >= word.end
            }
        })
    }

    @Test func baselineOnlyHostAndRemoteSpeakersRoundtripAndPublish() throws {
        let hostBaseline = [
            PipelineWord(start: 0, end: 1, text: "host baseline", speaker: nil),
            PipelineWord(start: 1, end: 2, text: "host seven", speaker: 7)
        ]
        let remoteBaseline = [
            PipelineWord(start: 0, end: 1, text: "remote baseline", speaker: 1),
            PipelineWord(start: 1, end: 2, text: "remote three", speaker: 3)
        ]
        let document = try assemble([
            channel(.host, final: [.init(start: 0, end: 2, text: "host final", speaker: 1)], baseline: hostBaseline),
            channel(.remote, final: [.init(start: 0, end: 2, text: "remote final", speaker: 1)], baseline: remoteBaseline)
        ])
        #expect(document.speakers.map(\.id) == ["spk_h1", "spk_h7", "spk_r1", "spk_r3"])
        #expect(document.speakers.map(\.displayNumber) == [1, 7, 8, 10])
        #expect(document.baselineWords.map(\.speakerID) == ["spk_h1", "spk_h7", "spk_r1", "spk_r3"])
        #expect(document.baselineWords.map(\.text) == (hostBaseline + remoteBaseline).map(\.text))
        #expect(document.baselineWords.map(\.start) == [0, 1, 0, 1])
        #expect(document.baselineWords.map(\.end) == [1, 2, 1, 2])
        let roundtrip = try JSONDecoder().decode(TranscriptDocument.self, from: JSONEncoder().encode(document))
        #expect(try encoded(roundtrip) == encoded(document))

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = scratch.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let published = try TranscriptPublisher(recordingDirectory: root).publish(document: document, recordingStem: "meeting")
        let loaded = try TranscriptDocument.load(from: published, recordingDirectory: root)
        #expect(try encoded(loaded) == encoded(document))
        let text = try String(contentsOf: published.deletingLastPathComponent().appendingPathComponent("transcript.txt"), encoding: .utf8)
        #expect(text.contains("host final"))
        #expect(text.contains("remote final"))
    }

    @Test func baselineOnlyRemoteSpeakerIsRegisteredIndependently() throws {
        let final = [PipelineWord(start: 0, end: 1, text: "final", speaker: 1)]
        let document = try assemble([
            channel(.host, final: final, baseline: final),
            channel(.remote, final: final, baseline: [.init(start: 0, end: 1, text: "remote baseline", speaker: 3)])
        ])
        #expect(document.speakers.map(\.id) == ["spk_h1", "spk_r1", "spk_r3"])
        #expect(document.speakers.map(\.displayNumber) == [1, 2, 4])
        #expect(document.baselineWords.last?.speakerID == "spk_r3")
    }

    @Test(arguments: [TranscriptDocument.ProcessingStatus.disabled, .failed])
    func unsuccessfulCorrectionPreservesFinalBaselineSignatures(status: TranscriptDocument.ProcessingStatus) throws {
        let final = [PipelineWord(start: 0.25, end: 1.5, text: "unchanged", speaker: nil)]
        let unusedBaseline = [PipelineWord(start: 0, end: 2, text: "not serialized", speaker: 7)]
        let document = try assemble([
            channel(.host, final: final, baseline: unusedBaseline, status: status),
            channel(.remote, final: final, baseline: unusedBaseline, status: status)
        ])
        #expect(document.speakers.map(\.id) == ["spk_h1", "spk_r1"])
        #expect(document.speakers.map(\.displayNumber) == [1, 2])
        #expect(document.words.map(\.text) == document.baselineWords.map(\.text))
        #expect(document.words.map(\.start) == document.baselineWords.map(\.start))
        #expect(document.words.map(\.end) == document.baselineWords.map(\.end))
        #expect(document.words.map(\.speakerID) == document.baselineWords.map(\.speakerID))
        let roundtrip = try JSONDecoder().decode(TranscriptDocument.self, from: encoded(document))
        #expect(try encoded(roundtrip) == encoded(document))
    }

    @Test func unknownBaselineSpeakerStillFailsStrictValidation() throws {
        let word = PipelineWord(start: 0, end: 1, text: "baseline", speaker: 1)
        let document = try assemble([channel(.host, final: [word], baseline: [word])])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        var baseline = try #require(json["baselineWords"] as? [[String: Any]])
        baseline[0]["speakerID"] = "missing"
        json["baselineWords"] = baseline
        do {
            _ = try JSONDecoder().decode(TranscriptDocument.self, from: JSONSerialization.data(withJSONObject: json))
            Issue.record("Unknown baseline speaker was accepted")
        } catch TranscriptDocument.LoadError.invalidReference(let detail) {
            #expect(detail == "голос слова bw_h_1")
        }
    }

    @Test(arguments: [0, -1])
    func nonpositiveSourceLocalSpeakerStillFails(speaker: Int) throws {
        let word = PipelineWord(start: 0, end: 1, text: "invalid", speaker: speaker)
        #expect(throws: TranscriptDocument.LoadError.self) {
            try assemble([channel(.host, final: [word], baseline: [word])])
        }
    }
}
