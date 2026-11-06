import Foundation
import Testing
import MeetingCompanionCore

@Suite struct TranscriptContinuationTests {
    private func document(_ modify: (inout [String: Any]) -> Void = { _ in }) throws -> TranscriptDocument {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/chronological.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        modify(&json)
        return try JSONDecoder().decode(TranscriptDocument.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func text(_ document: TranscriptDocument, overrides: [String: TranscriptTurnOverride] = [:]) throws -> String {
        try TranscriptExportFormatter().format(document: document,
            edits: TranscriptEdits(resultID: document.resultID, revision: 0, overrides: overrides))
    }

    @Test func insertionMarkersAndExactManualOverride() throws {
        let doc = try document()
        let before = try JSONEncoder().encode(doc)
        let exported = try text(doc)
        #expect(exported.contains("Обсудим…"))
        #expect(exported.contains("…релиз"))
        let exact = "  Исправлено\r\nбез маркера  "
        let edited = try text(doc, overrides: ["t0": .init(text: exact)])
        #expect(edited.contains(exact + "\n\n"))
        #expect(!edited.contains("Исправлено…"))
        #expect(edited.contains("…релиз"))
        #expect(try JSONDecoder().decode(TranscriptDocument.self, from: before).words == doc.words)
        #expect(doc.words == doc.baselineWords)
    }

    @Test(arguments: ["Обсудим.", "Обсудим!»", "Обсудим?)", "Обсудим…", "Обсудим..."])
    func existingPunctuationIsNotDuplicated(ending: String) throws {
        let doc = try document { json in
            var words = json["words"] as! [[String: Any]]
            words[0]["text"] = ending
            json["words"] = words; json["baselineWords"] = words
        }
        let exported = try text(doc)
        #expect(exported.contains(ending))
        #expect(!exported.contains(ending + "…"))
        if ending.hasSuffix("…") || ending.hasSuffix("...") {
            #expect(exported.contains("…релиз"))
        } else {
            #expect(!exported.contains("…релиз"))
        }
    }

    @Test func ambiguousOldTurnDoesNotAcquireMarkers() throws {
        let doc = try document { json in
            var turns = json["turns"] as! [[String: Any]]
            turns[0]["wordIDs"] = ["a1", "a2"]
            turns[0]["end"] = 13.0
            turns.removeLast()
            json["turns"] = turns
        }
        let exported = try text(doc)
        #expect(exported.contains("Обсудим релиз"))
        #expect(!exported.contains("…"))
    }

    @Test func outOfOrderOldFragmentsDoNotAcquireMarkersAcrossSameSpeaker() throws {
        let doc = try document { json in
            var words = json["words"] as! [[String: Any]]
            words.append(["id": "a3", "speakerID": "spk_h1", "start": 13.2, "end": 14.0, "text": "потом"])
            json["words"] = words; json["baselineWords"] = words
            var turns = json["turns"] as! [[String: Any]]
            turns.insert(["id": "t3", "speakerID": "spk_h1", "start": 13.2, "end": 14.0, "wordIDs": ["a3"]], at: 2)
            json["turns"] = turns
        }
        #expect(try !text(doc).contains("…"))
    }

    @Test(arguments: [13.5, 41.0])
    func pauseOrDurationBoundaryHasNoContinuation(nextStart: Double) throws {
        let doc = try document { json in
            var words = json["words"] as! [[String: Any]]
            words[2]["start"] = nextStart; words[2]["end"] = nextStart + 1
            var turns = json["turns"] as! [[String: Any]]
            turns[2]["start"] = nextStart; turns[2]["end"] = nextStart + 1
            json["words"] = words; json["baselineWords"] = words; json["turns"] = turns
        }
        #expect(try !text(doc).contains("…"))
    }

    @Test func sameSourceOtherVoiceAlsoInterrupts() throws {
        let doc = try document { json in
            var speakers = json["speakers"] as! [[String: Any]]
            speakers[1]["displayNumber"] = 3
            speakers.append(["id": "spk_h2", "sourceID": "host", "localID": 2, "displayNumber": 2])
            json["speakers"] = speakers
            var words = json["words"] as! [[String: Any]]
            words[1]["speakerID"] = "spk_h2"
            var turns = json["turns"] as! [[String: Any]]
            turns[1]["speakerID"] = "spk_h2"
            json["words"] = words; json["baselineWords"] = words; json["turns"] = turns
        }
        #expect(try text(doc).contains("Обсудим…"))
        #expect(try text(doc).contains("…релиз"))
    }
}
