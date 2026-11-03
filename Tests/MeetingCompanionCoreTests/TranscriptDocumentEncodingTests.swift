import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite struct TranscriptDocumentEncodingTests {
    @Test(arguments: ["parakeet_off", "parakeet_on", "partial_failure",
                      "overlaps_identities", "empty_voices", "unknown_voices"])
    func nativeEncodingPreservesJSONv1(_ name: String) throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("transcription/fixtures/transcript-document")
        let input = try Data(contentsOf: fixtures.appendingPathComponent("valid_" + name + ".json"))
        let document = try JSONDecoder().decode(TranscriptDocument.self, from: input)
        let output = try JSONEncoder().encode(document)
        let original = try #require(JSONSerialization.jsonObject(with: input) as? NSDictionary)
        let encoded = try #require(JSONSerialization.jsonObject(with: output) as? NSDictionary)
        #expect(encoded == original, "Encoding must preserve every known field, explicit null, ID and timestamp")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("result.json")
        try output.write(to: file)
        let reopened = try TranscriptDocument.load(from: file, recordingDirectory: root)
        #expect(reopened.schemaVersion == 1)
        #expect(reopened.resultID == document.resultID)
        #expect(reopened.words.map(\.id) == document.words.map(\.id))
        #expect(reopened.turns.map(\.wordIDs) == document.turns.map(\.wordIDs))
    }
}
