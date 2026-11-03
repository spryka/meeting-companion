import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite final class TranscriptEditsReadingTests {
    private var cleanup: [URL] = []

    deinit {
        for url in cleanup {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/transcript-document")

    private func fixture(_ name: String) -> URL {
        fixtures.appendingPathComponent(name + ".json")
    }

    private func temporaryDirectory(_ prefix: String = "TranscriptEditsReadingTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            prefix + "-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        return directory
    }

    private func createSyntheticRecording(
        in root: URL,
        resultID: String = "res_valid_parakeet_off"
    ) throws -> (resultURL: URL, versionDir: URL) {
        let versionDir = root
            .appendingPathComponent("raw")
            .appendingPathComponent("transcripts")
            .appendingPathComponent(resultID)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let resultURL = versionDir.appendingPathComponent("result.json")
        let fixtureData = try Data(contentsOf: fixture("valid_parakeet_off"))
        try fixtureData.write(to: resultURL)

        let rawDir = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

        let hostAudio = rawDir.appendingPathComponent("meeting.host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("meeting.remote_record.wav")
        let mixAudio = versionDir.appendingPathComponent("mix.m4a")

        try Data("SYNTHETIC_PCM_AUDIO_HOST_16KHZ".utf8).write(to: hostAudio)
        try Data("SYNTHETIC_PCM_AUDIO_REMOTE_16KHZ".utf8).write(to: remoteAudio)
        try Data("SYNTHETIC_M4A_MIX_AUDIO_PAYLOAD".utf8).write(to: mixAudio)

        // Validate baseline document with production reader
        _ = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        return (resultURL, versionDir)
    }

    @Test func testInitialAbsenceReturnsRevisionZeroWithoutWritingToDisk() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        _ = try createSyntheticRecording(in: root, resultID: resultID)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let editsFile = repo.editsURL(for: resultID)
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))

        let loaded = try repo.loadEdits(resultID: resultID)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.resultID == resultID)
        #expect(loaded.revision == 0)
        #expect(loaded.overrides.isEmpty)

        // Reading absent edits must never create a file on disk
        #expect(!FileManager.default.fileExists(atPath: editsFile.path))
    }

    @Test func testValidEditsLoadsAllFieldsIncludingEmptyTextAndOptionalDisplayName() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let editsFile = versionDir.appendingPathComponent("edits.json")
        // valid JSON with empty text, optional displayName omitted, and unknown fields ignored
        let jsonString = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 2,
            "unknownRootKey": 12345,
            "overrides": {
                "turn_1": {
                    "text": "",
                    "displayName": "Алиса",
                    "unknownField": true
                },
                "turn_2": {
                    "text": "Текст без имени"
                }
            }
        }
        """
        try Data(jsonString.utf8).write(to: editsFile)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        let loaded = try repo.loadEdits(resultID: resultID)

        #expect(loaded.schemaVersion == 1)
        #expect(loaded.resultID == resultID)
        #expect(loaded.revision == 2)
        #expect(loaded.overrides["turn_1"]?.text == "")
        #expect(loaded.overrides["turn_1"]?.displayName == "Алиса")
        #expect(loaded.overrides["turn_2"]?.text == "Текст без имени")
        #expect(loaded.overrides["turn_2"]?.displayName == nil)
    }

    @Test func testUnsupportedVersionThrowsSpecificError() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let editsFile = versionDir.appendingPathComponent("edits.json")
        let jsonString = """
        {
            "schemaVersion": 2,
            "resultID": "\(resultID)",
            "revision": 1,
            "overrides": {}
        }
        """
        try Data(jsonString.utf8).write(to: editsFile)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .unsupportedVersion(2) = error as? TranscriptEditsError else {
                return false
            }
            return true
        }
    }

    @Test func testResultIDMismatchThrowsMalformed() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let editsFile = versionDir.appendingPathComponent("edits.json")
        let jsonString = """
        {
            "schemaVersion": 1,
            "resultID": "mismatched_result_id",
            "revision": 1,
            "overrides": {}
        }
        """
        try Data(jsonString.utf8).write(to: editsFile)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else {
                return false
            }
            return true
        }
    }

    @Test func testNegativeFractionalOrBooleanRevisionThrowsMalformed() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)
        let editsFile = versionDir.appendingPathComponent("edits.json")
        let repo = TranscriptEditsRepository(recordingDirectory: root)

        let invalidRevisions = ["-1", "1.5", "true", "\"1\"", "9007199254740992.1"]
        for rev in invalidRevisions {
            let jsonString = """
            {
                "schemaVersion": 1,
                "resultID": "\(resultID)",
                "revision": \(rev),
                "overrides": {}
            }
            """
            try Data(jsonString.utf8).write(to: editsFile)

            #expect {
                try repo.loadEdits(resultID: resultID)
            } throws: { error in
                guard case .malformed = error as? TranscriptEditsError else {
                    return false
                }
                return true
            }
        }
    }

    @Test func testNullOrEmptyDisplayNameThrowsMalformed() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)
        let editsFile = versionDir.appendingPathComponent("edits.json")
        let repo = TranscriptEditsRepository(recordingDirectory: root)

        // 1. empty string displayName
        let emptyNameJson = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 1,
            "overrides": {
                "turn_1": { "displayName": "" }
            }
        }
        """
        try Data(emptyNameJson.utf8).write(to: editsFile)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else { return false }
            return true
        }

        // 2. explicit null displayName
        let nullNameJson = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 1,
            "overrides": {
                "turn_1": { "displayName": null }
            }
        }
        """
        try Data(nullNameJson.utf8).write(to: editsFile)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else { return false }
            return true
        }

        // 3. explicit null text
        let nullTextJson = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 1,
            "overrides": {
                "turn_1": { "text": null }
            }
        }
        """
        try Data(nullTextJson.utf8).write(to: editsFile)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else { return false }
            return true
        }

        // 4. explicit null overrides
        let nullOverridesJson = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 1,
            "overrides": null
        }
        """
        try Data(nullOverridesJson.utf8).write(to: editsFile)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test func testOverrideForUnknownTurnIDThrowsInvalidReference() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let editsFile = versionDir.appendingPathComponent("edits.json")
        let jsonString = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 1,
            "overrides": {
                "nonexistent_turn_999": {
                    "text": "Неизвестная реплика"
                }
            }
        }
        """
        try Data(jsonString.utf8).write(to: editsFile)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .invalidReference = error as? TranscriptEditsError else {
                return false
            }
            return true
        }
    }

    @Test func testMissingResultJSONThrowsResultNotFound() throws {
        let root = try temporaryDirectory()
        let repo = TranscriptEditsRepository(recordingDirectory: root)

        #expect {
            try repo.loadEdits(resultID: "nonexistent_result_dir")
        } throws: { error in
            guard case .resultNotFound = error as? TranscriptEditsError else {
                return false
            }
            return true
        }
    }

    @Test func testPathTraversalOrEscapingSymlinkThrowsResultNotFoundOrMalformed() throws {
        let root = try temporaryDirectory()
        let repo = TranscriptEditsRepository(recordingDirectory: root)

        // Traversal path in resultID
        #expect {
            try repo.loadEdits(resultID: "../outside")
        } throws: { error in
            guard case .resultNotFound = error as? TranscriptEditsError else {
                guard case .malformed = error as? TranscriptEditsError else { return false }
                return true
            }
            return true
        }

        // Nested traversal
        #expect {
            try repo.loadEdits(resultID: "sub/dir")
        } throws: { error in
            guard case .resultNotFound = error as? TranscriptEditsError else {
                guard case .malformed = error as? TranscriptEditsError else { return false }
                return true
            }
            return true
        }
    }

    @Test func testMismatchedRecognitionResultIDThrowsResultNotFound() throws {
        let root = try temporaryDirectory()
        let requestedResultID = "res_valid_parakeet_off"
        let (resultURL, _) = try createSyntheticRecording(in: root, resultID: requestedResultID)

        // Modify result.json so its internal resultID is different
        let fixtureData = try Data(contentsOf: fixture("valid_parakeet_off"))
        var docJson = try #require(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        docJson["resultID"] = "different_result_id"
        let modifiedData = try JSONSerialization.data(withJSONObject: docJson, options: [.sortedKeys])
        try modifiedData.write(to: resultURL)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.loadEdits(resultID: requestedResultID)
        } throws: { error in
            guard case .resultNotFound = error as? TranscriptEditsError else {
                return false
            }
            return true
        }
    }

    @Test func testValidIntegerRevisions10And100AreAccepted() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)
        let editsFile = versionDir.appendingPathComponent("edits.json")
        let repo = TranscriptEditsRepository(recordingDirectory: root)

        for validRev in [10, 100, 9223372036854775807] {
            let jsonString = """
            {
                "schemaVersion": 1,
                "resultID": "\(resultID)",
                "revision": \(validRev),
                "overrides": {}
            }
            """
            try Data(jsonString.utf8).write(to: editsFile)
            let loaded = try repo.loadEdits(resultID: resultID)
            #expect(loaded.revision == validRev)
        }
    }

    @Test func testPrecisionBoundaryFractionAndOverflowRevisionsThrowMalformed() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)
        let editsFile = versionDir.appendingPathComponent("edits.json")
        let repo = TranscriptEditsRepository(recordingDirectory: root)

        // 1. Extreme precision fraction: 1.000...0001 (beyond Decimal 38-digit precision)
        let extremeFractionJson = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 1.00000000000000000000000000000000000000001,
            "overrides": {}
        }
        """
        try Data(extremeFractionJson.utf8).write(to: editsFile)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else { return false }
            return true
        }

        // 2. Integer overflow: Int.max + 1 (9223372036854775808)
        let overflowJson = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 9223372036854775808,
            "overrides": {}
        }
        """
        try Data(overflowJson.utf8).write(to: editsFile)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test func testLexicalScannerHandlesEscapedKeysNestedNumbersAndDuplicateKeys() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)
        let editsFile = versionDir.appendingPathComponent("edits.json")
        let repo = TranscriptEditsRepository(recordingDirectory: root)

        // 1. Escaped field names and nested misleading revision in overrides
        let escapedAndNestedJson = """
        {
            "\\u0073chemaVersion": 1,
            "resultID": "\(resultID)",
            "\\u0072evision": 10,
            "overrides": {
                "turn_1": {
                    "revision": 1.5,
                    "text": "Valid text"
                }
            }
        }
        """
        try Data(escapedAndNestedJson.utf8).write(to: editsFile)
        let loaded = try repo.loadEdits(resultID: resultID)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.revision == 10)
        #expect(loaded.overrides["turn_1"]?.text == "Valid text")

        // 2. Duplicate top-level required key is rejected as malformed
        let duplicateKeyJson = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 1,
            "revision": 2,
            "overrides": {}
        }
        """
        try Data(duplicateKeyJson.utf8).write(to: editsFile)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else { return false }
            return true
        }
    }

    @Test(arguments: [#"schema\bVersion"#, #"schema\fVersion"#, #"revi\bsion"#, #"revi\fsion"#])
    func testControlEscapedUnknownKeysDoNotCollide(escapedKey: String) throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)
        let data = Data("""
        {"schemaVersion":1,"resultID":"\(resultID)","revision":10,"overrides":{},"\(escapedKey)":99}
        """.utf8)
        // Establish that the fixture contains a distinct, valid unknown key.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.count == 5)
        try data.write(to: versionDir.appendingPathComponent("edits.json"))
        let loaded = try TranscriptEditsRepository(recordingDirectory: root).loadEdits(resultID: resultID)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.revision == 10)
    }

    @Test(arguments: [#"schema\bVersion"#, #"schema\fVersion"#, #"revi\bsion"#, #"revi\fsion"#])
    func testControlEscapedCounterfeitKeysCannotSupplyMandatoryFields(escapedKey: String) throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)
        let missingKey = escapedKey.hasPrefix("schema") ? "schemaVersion" : "revision"
        let fields = missingKey == "schemaVersion"
            ? "\"\(escapedKey)\":1,\"revision\":10"
            : "\"schemaVersion\":1,\"\(escapedKey)\":10"
        let data = Data("""
        {\(fields),"resultID":"\(resultID)","overrides":{}}
        """.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object[missingKey] == nil)
        try data.write(to: versionDir.appendingPathComponent("edits.json"))
        #expect {
            try TranscriptEditsRepository(recordingDirectory: root).loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed(let detail) = error as? TranscriptEditsError else { return false }
            return detail == (missingKey == "schemaVersion"
                ? "schemaVersion must be an integer"
                : "revision must be a nonnegative integer")
        }
    }

    @Test func testAllStandardStringEscapesRemainValid() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (_, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)
        let data = Data(#"""
        {"\u0073chemaVersion":1,"resultID":"res_valid_parakeet_off","\u0072evision":10,
         "unknown\/\"\\\b\f\n\r\t\uD83D\uDE00":99,
         "overrides":{"turn_1":{"text":"slash\/quote\"backslash\\backspace\bformfeed\fnewline\nreturn\rtab\tunicode\uD83D\uDE00"}}}
        """#.utf8)
        try data.write(to: versionDir.appendingPathComponent("edits.json"))
        let loaded = try TranscriptEditsRepository(recordingDirectory: root).loadEdits(resultID: resultID)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.revision == 10)
        #expect(loaded.overrides["turn_1"]?.text == "slash/quote\"backslash\\backspace\u{8}formfeed\u{C}newline\nreturn\rtab\tunicode😀")
    }

    @Test func testAncestorDirectorySymlinkEscapesAreRejected() throws {
        let parentDir = try temporaryDirectory("parent")
        let root = parentDir.appendingPathComponent("recording")
        let outsideDir = try temporaryDirectory("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let resultID = "res_valid_parakeet_off"
        let rawDir = root.appendingPathComponent("raw")
        let transcriptsDir = rawDir.appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)

        // Make raw/transcripts/res_valid_parakeet_off a symlink pointing to an outside directory
        let versionDirSymlink = transcriptsDir.appendingPathComponent(resultID)
        let outsideVersionDir = outsideDir.appendingPathComponent("fake_version")
        try FileManager.default.createDirectory(at: outsideVersionDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: versionDirSymlink, withDestinationURL: outsideVersionDir)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else {
                guard case .resultNotFound = error as? TranscriptEditsError else { return false }
                return true
            }
            return true
        }
    }

    @Test func testRealSymlinksEscapingRecordingDirectoryAreRejected() throws {
        let root = try temporaryDirectory("recording")
        let outsideDir = try temporaryDirectory("outside")
        let resultID = "res_valid_parakeet_off"
        let (resultURL, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        // 1. edits.json is a symlink pointing outside recording directory
        let outsideEdits = outsideDir.appendingPathComponent("outside_edits.json")
        let validEdits = """
        {
            "schemaVersion": 1,
            "resultID": "\(resultID)",
            "revision": 1,
            "overrides": {}
        }
        """
        try Data(validEdits.utf8).write(to: outsideEdits)
        let editsFile = versionDir.appendingPathComponent("edits.json")
        try FileManager.default.createSymbolicLink(at: editsFile, withDestinationURL: outsideEdits)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else {
                guard case .resultNotFound = error as? TranscriptEditsError else { return false }
                return true
            }
            return true
        }

        // 2. Dangling edits symlink must NOT be treated as initial absence (revision 0)
        try FileManager.default.removeItem(at: editsFile)
        let nonexistentTarget = outsideDir.appendingPathComponent("nonexistent.json")
        try FileManager.default.createSymbolicLink(at: editsFile, withDestinationURL: nonexistentTarget)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else {
                guard case .resultNotFound = error as? TranscriptEditsError else { return false }
                return true
            }
            return true
        }

        // 3. result.json is a symlink pointing outside recording directory
        try FileManager.default.removeItem(at: resultURL)
        let outsideResult = outsideDir.appendingPathComponent("outside_result.json")
        try Data(contentsOf: fixture("valid_parakeet_off")).write(to: outsideResult)
        try FileManager.default.createSymbolicLink(at: resultURL, withDestinationURL: outsideResult)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .resultNotFound = error as? TranscriptEditsError else {
                guard case .malformed = error as? TranscriptEditsError else { return false }
                return true
            }
            return true
        }
    }

    @Test func testSiblingPrefixRecordingEscapeIsRejected() throws {
        // Parent folder contains two directories: "recording" and "recording-sibling"
        let parentDir = try temporaryDirectory("parent")
        let root = parentDir.appendingPathComponent("recording")
        let siblingRoot = parentDir.appendingPathComponent("recording-sibling")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingRoot, withIntermediateDirectories: true)

        let resultID = "res_valid_parakeet_off"
        let (_, siblingVersionDir) = try createSyntheticRecording(in: siblingRoot, resultID: resultID)

        // Inside root, create raw/transcripts/res_valid_parakeet_off as a symlink pointing to siblingRoot's version dir
        let rootTranscripts = root.appendingPathComponent("raw").appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: rootTranscripts, withIntermediateDirectories: true)
        let linkURL = rootTranscripts.appendingPathComponent(resultID)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: siblingVersionDir)

        // Repository pointing to root must NOT access siblingRoot despite matching string prefix
        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else {
                guard case .resultNotFound = error as? TranscriptEditsError else { return false }
                return true
            }
            return true
        }
    }

    @Test func testMalformedEditsNeverWritesOrMutatesDisk() throws {
        let root = try temporaryDirectory()
        let resultID = "res_valid_parakeet_off"
        let (resultURL, versionDir) = try createSyntheticRecording(in: root, resultID: resultID)

        let editsFile = versionDir.appendingPathComponent("edits.json")
        let corruptData = Data("NOT_A_VALID_JSON{:::".utf8)
        try corruptData.write(to: editsFile)

        let initialResultData = try Data(contentsOf: resultURL)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.loadEdits(resultID: resultID)
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else {
                return false
            }
            return true
        }

        // edits.json must not be overwritten or modified on read error
        #expect(try Data(contentsOf: editsFile) == corruptData)
        // result.json must remain identical
        #expect(try Data(contentsOf: resultURL) == initialResultData)
    }
}
