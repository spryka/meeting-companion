import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite final class TranscriptDocumentTests {
    private var cleanup: [URL] = []
    deinit { for url in cleanup { try? FileManager.default.removeItem(at: url) } }
    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/transcript-document")

    private func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name + ".json") }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptDocumentTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        return directory
    }
    private func object(_ name: String = "valid_parakeet_off") throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture(name))) as? [String: Any])
    }
    private func write(_ object: [String: Any], in root: URL) throws -> URL {
        let url = root.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        return url
    }
    // Dot-separated paths include array indices; nil removes a field.
    private func changing(_ object: [String: Any], _ path: String, _ value: Any?) -> [String: Any] {
        func change(_ current: Any, _ components: ArraySlice<String>) -> Any {
            guard let key = components.first else { return value ?? NSNull() }
            if var array = current as? [Any], let index = Int(key) {
                array[index] = change(array[index], components.dropFirst())
                return array
            }
            var dictionary = current as! [String: Any]
            if components.count == 1 { dictionary[key] = value }
            else { dictionary[key] = change(dictionary[key]!, components.dropFirst()) }
            return dictionary
        }
        return change(object, ArraySlice(path.split(separator: ".").map(String.init))) as! [String: Any]
    }
    private func assertRejected(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let root = try temporaryDirectory()
        let url = try write(object, in: root)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try TranscriptDocument.load(from: url, recordingDirectory: root), file: file, line: line) {
            guard let error = $0 as? TranscriptDocument.LoadError else {
                return XCTFail("Expected readable document error: \($0)", file: file, line: line)
            }
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("not implemented"), file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: url), before, file: file, line: line)
    }
    @Test func testSixSharedValidFixturesWithoutAudio() throws {
        let root = try temporaryDirectory()
        for name in ["parakeet_off", "parakeet_on", "partial_failure", "overlaps_identities", "empty_voices", "unknown_voices"] {
            let document = try TranscriptDocument.load(from: fixture("valid_" + name), recordingDirectory: root)
            XCTAssertEqual(document.schemaVersion, 1)
            XCTAssertEqual(document.resultID, "res_valid_" + name)
            XCTAssertFalse(document.words.isEmpty)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    @Test func testFiveSharedInvalidFixturesHaveSpecificErrors() throws {
        let root = try temporaryDirectory()
        for (name, category) in [("schema_version", "version"), ("duplicate_ids", "reference"), ("broken_references", "reference"), ("intervals", "malformed"), ("path_traversal", "path")] {
            XCTAssertThrowsError(try TranscriptDocument.load(from: fixture("invalid_" + name), recordingDirectory: root)) {
                switch ($0, category) {
                case (TranscriptDocument.LoadError.unsupportedVersion(2), "version"),
                     (TranscriptDocument.LoadError.invalidReference, "reference"),
                     (TranscriptDocument.LoadError.malformed, "malformed"),
                     (TranscriptDocument.LoadError.invalidPath, "path"): break
                default: XCTFail("Wrong error for \(name): \($0)")
                }
            }
        }
    }
    @Test func testRequiredFieldsAndNulls() throws {
        let original = try object()
        let required = ["schemaVersion", "resultID", "createdAt", "sources", "speakers", "words", "turns", "baselineWords", "aec", "playback", "warnings", "context",
                        "sources.0.id", "sources.0.originalAudioPath", "sources.0.recognitionAudioPath", "sources.0.diarizationStatus", "sources.0.detectedVoiceCount", "sources.0.correctionStatus",
                        "speakers.0.id", "speakers.0.sourceID", "speakers.0.localID", "speakers.0.displayNumber",
                        "words.0.id", "words.0.speakerID", "words.0.start", "words.0.end", "words.0.text",
                        "baselineWords.0.id", "baselineWords.0.speakerID", "baselineWords.0.start", "baselineWords.0.end", "baselineWords.0.text",
                        "turns.0.id", "turns.0.speakerID", "turns.0.start", "turns.0.end", "turns.0.wordIDs", "aec.requested", "aec.outcome", "playback.status", "playback.mixPath"]
        for path in required {
            try assertRejected(changing(original, path, nil))
            if !["context", "sources.0.detectedVoiceCount", "playback.mixPath"].contains(path) {
                try assertRejected(changing(original, path, NSNull()))
            }
        }
        for path in ["warnings.0.code", "warnings.0.sourceID", "warnings.0.message"] {
            try assertRejected(changing(try object("valid_partial_failure"), path, nil))
        }
    }
    @Test func testUnknownKeysAndExplicitNullsAreAccepted() throws {
        let root = try temporaryDirectory()
        var data = try object("valid_unknown_voices")
        for path in ["future", "sources.0.future", "speakers.0.future", "words.0.future", "baselineWords.0.future", "turns.0.future", "aec.future", "playback.future", "warnings.0.future"] {
            data = changing(data, path, ["unknown": true])
        }
        let document = try TranscriptDocument.load(from: write(data, in: root), recordingDirectory: root)
        XCTAssertNil(document.context)
        XCTAssertNil(document.sources[0].detectedVoiceCount)
        XCTAssertEqual(document.words[0].text, "Микрофон")
        let empty = try TranscriptDocument.load(from: fixture("valid_empty_voices"), recordingDirectory: root)
        XCTAssertEqual(empty.sources[1].detectedVoiceCount, 0)
        XCTAssertEqual(empty.sources[1].diarizationStatus, .completed)
    }
    @Test func testInvalidIDsReferencesAndOwnership() throws {
        let data = try object()
        let cases: [(String, Any)] = [("resultID", ""), ("sources.1.id", "host"), ("sources.0.id", "other"), ("speakers.1.id", "spk_h1"), ("speakers.0.id", ""), ("speakers.0.sourceID", "other"), ("speakers.0.localID", 0), ("speakers.0.displayNumber", 0), ("speakers.1.displayNumber", 1), ("speakers.1.displayNumber", 3), ("words.0.speakerID", "missing"), ("baselineWords.0.speakerID", "missing"), ("baselineWords.1.id", "bw_1"), ("turns.1.id", "turn_1"), ("turns.0.speakerID", "missing"), ("turns.0.speakerID", "spk_r1"), ("turns.0.wordIDs", ["w_1", "w_1", "w_2"]), ("turns.1.wordIDs", ["w_1", "w_3"]), ("turns.0.wordIDs", ["w_1"]), ("turns.0.start", 0.6), ("turns.0.end", 1.5)]
        for (path, value) in cases { try assertRejected(changing(data, path, value)) }
        try assertRejected(changing(try object("valid_overlaps_identities"), "speakers.1.localID", 1))
        try assertRejected(changing(data, "sources", []))
    }
    @Test func testSeparateIDNamespacesAndOpaqueSpeakerIDs() throws {
        let root = try temporaryDirectory()
        var data = changing(try object(), "baselineWords.0.id", "w_1")
        data = changing(data, "turns.0.id", "w_1")
        for path in ["speakers.0.id", "words.0.speakerID", "words.1.speakerID", "baselineWords.0.speakerID", "baselineWords.1.speakerID", "turns.0.speakerID"] {
            data = changing(data, path, "opaque-remote-in-host-name")
        }
        XCTAssertEqual(try TranscriptDocument.load(from: write(data, in: root), recordingDirectory: root).words.count, 3)
    }
    @Test func testIntervalsCountsStatusesAndDates() throws {
        let data = try object()
        for collection in ["words", "baselineWords", "turns"] {
            for (field, value) in [("start", -1.0), ("start", 3.0), ("end", -1.0)] {
                try assertRejected(changing(data, "\(collection).0.\(field)", value))
            }
        }
        let cases: [(String, Any)] = [("schemaVersion", true), ("schemaVersion", 1.5), ("schemaVersion", -1), ("createdAt", "2026-10-29T12:00:00"), ("createdAt", "nonsense"), ("context.startAt", "nonsense"), ("sources.0.detectedVoiceCount", -1), ("sources.0.detectedVoiceCount", 9), ("sources.0.detectedVoiceCount", 1.5), ("sources.0.detectedVoiceCount", NSNull()), ("sources.0.diarizationStatus", "other"), ("sources.0.correctionStatus", "other"), ("aec.outcome", "other"), ("playback.status", "other"), ("sources.0.diarizationStatus", "disabled")]
        for (path, value) in cases { try assertRejected(changing(data, path, value)) }
        try assertRejected(changing(try object("valid_unknown_voices"), "sources.0.detectedVoiceCount", 0))
        let root = try temporaryDirectory()
        let url = try write(data, in: root)
        let json = String(data: try Data(contentsOf: url), encoding: .utf8)!.replacingOccurrences(of: "\"start\":0.5", with: "\"start\":1e999")
        XCTAssertTrue(json.contains("1e999"))
        try Data(json.utf8).write(to: url)
        XCTAssertThrowsError(try TranscriptDocument.load(from: url, recordingDirectory: root))
    }
    @Test func testPlaybackAndAECConsistency() throws {
        let data = try object()
        let cases: [(String, Any)] = [("playback.mixPath", NSNull()), ("playback.mixPath", ""), ("playback.status", "unavailable"), ("aec.requested", true), ("aec.outcome", "applied"), ("aec.outcome", "bypassed"), ("aec.outcome", "failed"), ("sources.0.recognitionAudioPath", "raw/different.wav"), ("sources.1.recognitionAudioPath", "raw/different.wav")]
        for (path, value) in cases { try assertRejected(changing(data, path, value)) }
        try assertRejected(changing(try object("valid_partial_failure"), "warnings", []))
        let root = try temporaryDirectory()
        for outcome in ["applied", "bypassed", "failed"] {
            var valid = changing(data, "aec.requested", true)
            valid = changing(valid, "aec.outcome", outcome)
            valid = changing(valid, "warnings", [["code": "aec_failed", "sourceID": "host", "message": "AEC unavailable"]])
            if outcome == "applied" { valid = changing(valid, "sources.0.recognitionAudioPath", "raw/transcripts/res_valid_parakeet_off/microphone.wav") }
            XCTAssertEqual(try TranscriptDocument.load(from: write(valid, in: root), recordingDirectory: root).aec.outcome.rawValue, outcome)
        }
    }
    @Test func testAppliedAECRequiresVersionCopyAndFailedAECWarning() throws {
        var data = changing(try object(), "aec.requested", true)
        data = changing(data, "aec.outcome", "applied")
        try assertRejected(data)
        try assertRejected(changing(data, "sources.0.recognitionAudioPath", "raw/working-aec.wav"))
        try assertRejected(changing(data, "sources.0.recognitionAudioPath", "raw/transcripts/other/microphone.wav"))
        try assertRejected(changing(data, "aec.outcome", "failed"))
    }
    @Test func testEmptyDocumentAndSparseContext() throws {
        let root = try temporaryDirectory()
        var data = try object()
        for collection in ["speakers", "words", "baselineWords", "turns"] { data[collection] = [Any]() }
        data["context"] = ["future": "ignored"]
        let document = try TranscriptDocument.load(from: write(data, in: root), recordingDirectory: root)
        XCTAssertTrue(document.words.isEmpty)
        XCTAssertNil(document.context?.title)
    }
    @Test func testAudioPathsRejectAbsoluteEscapeAndSymlinkSibling() throws {
        let root = try temporaryDirectory()
        let sibling = URL(fileURLWithPath: root.path + "-sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        cleanup.append(sibling)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: sibling)
        for field in ["sources.0.originalAudioPath", "sources.0.recognitionAudioPath", "sources.1.originalAudioPath", "sources.1.recognitionAudioPath", "playback.mixPath"] {
            for value in ["/private/missing.wav", "../escape.wav", "outside/nonexistent.wav", ""] {
                let url = try write(changing(try object(), field, value), in: root)
                XCTAssertThrowsError(try TranscriptDocument.load(from: url, recordingDirectory: root)) {
                    guard case TranscriptDocument.LoadError.invalidPath = $0 else { return XCTFail("Expected path error: \($0)") }
                }
            }
        }
    }
    @Test func testInternalSymlinksAndMissingAudioAreAllowed() throws {
        let root = try temporaryDirectory()
        let version = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inside"), withDestinationURL: version)
        let data = changing(try object(), "playback.mixPath", "inside/missing.m4a")
        XCTAssertEqual(try TranscriptDocument.load(from: write(data, in: root), recordingDirectory: root).playback.status, .ready)
    }
    @Test func testReadyMixMustBelongToExactVersion() throws {
        let data = try object()
        for path in ["raw/transcripts/other/mix.m4a", "raw/mix.m4a",
                     "raw/transcripts/res_valid_parakeet_off-sibling/mix.m4a"] {
            try assertRejected(changing(data, "playback.mixPath", path))
        }
        let root = try temporaryDirectory()
        let other = root.appendingPathComponent("raw/transcripts/other")
        let own = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: own.appendingPathComponent("alias"), withDestinationURL: other)
        let url = try write(changing(data, "playback.mixPath", "raw/transcripts/res_valid_parakeet_off/alias/missing.m4a"), in: root)
        XCTAssertThrowsError(try TranscriptDocument.load(from: url, recordingDirectory: root))
    }
    @Test func testResultIDIsOneOpaqueDirectorySegment() throws {
        let original = try object()
        for id in ["../other", "nested/other", ".", "..", "/other", "bad\0id"] {
            var data = changing(original, "resultID", id)
            data = changing(data, "playback.mixPath", "raw/transcripts/\(id)/mix.m4a")
            try assertRejected(data)
        }
        let root = try temporaryDirectory()
        var data = changing(original, "resultID", "opaque version-Ж")
        data = changing(data, "playback.mixPath", "raw/transcripts/opaque version-Ж/missing.m4a")
        XCTAssertEqual(try TranscriptDocument.load(from: write(data, in: root), recordingDirectory: root).resultID, "opaque version-Ж")
    }
    @Test func testUncorrectedBaselineMustMatchTextAndTimesPerSource() throws {
        for name in ["valid_parakeet_off", "valid_partial_failure"] {
            let data = try object(name)
            let index = name == "valid_partial_failure" ? 1 : 0
            for (field, value): (String, Any) in [("text", "changed"), ("start", 0.1), ("end", 3.2)] {
                try assertRejected(changing(data, "baselineWords.\(index).\(field)", value))
            }
        }
        let root = try temporaryDirectory()
        var data = try object("valid_overlaps_identities")
        // Baseline identity and ordering are not an alignment contract.
        data = changing(data, "baselineWords.0.speakerID", "spk_h2")
        data["baselineWords"] = (data["baselineWords"] as! [Any]).reversed().map { $0 }
        XCTAssertEqual(try TranscriptDocument.load(from: write(data, in: root), recordingDirectory: root).baselineWords.count, 5)
    }
    @Test func testMalformedReadNeverWrites() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("result.json")
        let edits = root.appendingPathComponent("edits.json")
        let audio = root.appendingPathComponent("audio.wav")
        for file in [edits, audio] { try Data("sentinel".utf8).write(to: file) }
        let malformed = Data("{\"schemaVersion\":1,".utf8)
        try malformed.write(to: url)
        XCTAssertThrowsError(try TranscriptDocument.load(from: url, recordingDirectory: root)) {
            guard case TranscriptDocument.LoadError.malformed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), malformed)
        for file in [edits, audio] { XCTAssertEqual(try Data(contentsOf: file), Data("sentinel".utf8)) }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["result.json", "edits.json", "audio.wav"])
    }
}

// Small assertion helpers keep table-driven failures at the caller's source location.
private func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T,
                                        file: StaticString = #filePath, line: UInt = #line) {
    do {
        let value = try actual()
        #expect(value == expected, sourceLocation: SourceLocation(fileID: String(describing: file), filePath: String(describing: file), line: Int(line), column: 1))
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
private func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    #expect(!value, sourceLocation: SourceLocation(fileID: String(describing: file), filePath: String(describing: file), line: Int(line), column: 1))
}
private func XCTAssertTrue(_ value: Bool) { #expect(value) }
private func XCTAssertNil<T>(_ value: T?) { #expect(value == nil) }
private func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    Issue.record(Comment(rawValue: message), sourceLocation: SourceLocation(fileID: String(describing: file), filePath: String(describing: file), line: Int(line), column: 1))
}
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                                     file: StaticString = #filePath, line: UInt = #line,
                                     _ handler: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch { handler(error) }
}
