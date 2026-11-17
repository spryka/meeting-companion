import Foundation
import Testing
import MeetingCompanionCore
import MeetingCompanionPlatform
@testable import MeetingCompanionApp

@Suite(.serialized) @MainActor
struct SpeakerReviewTests {
    @Test func listRequestCannotHideDirtyDetailsAfterWideToCompactTransition() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openVoiceReview()
        for _ in 0..<6 { model.skipVoice() }
        #expect(model.voiceReviewComplete)
        model.selectVoice(try #require(model.selectedVoiceID))
        #expect(model.requestVoiceList() && model.voiceListVisible) // Wide: list and details visible.
        model.updateVoiceName("Новое имя")
        #expect(!model.voiceListVisible) // Compact must retain the details, Save and Cancel.
        #expect(model.isVoiceDraftDirty && model.canConfirmVoice)
        #expect(!model.requestVoiceList())
        #expect(model.voiceDraft?.inputName == "Новое имя")
        model.cancelVoiceInput()
        #expect(model.requestVoiceList() && model.voiceListVisible)
    }
    @Test func dirtyInputKeepsVoiceDetailsAndCancelReachable() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openVoiceReview(); model.updateVoiceName("Новое имя")
        #expect(!model.requestVoiceList())
        #expect(model.voiceReviewVisible && model.voiceDraft?.inputName == "Новое имя")
        #expect(model.error != nil)
        model.cancelVoiceInput()
        #expect(model.requestVoiceList())
    }

    @Test func unnamedQuickEditorAndTransferStartWithoutInput() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openSpeakerAssignment(for: "t6")
        #expect(model.activeDraft?.inputName == "")
        model.selectDraftScope(.allVoiceGroup)
        #expect(model.activeDraft?.pendingConfirmation == nil)
        model.openDraftVoiceReview()
        #expect(model.voiceDraft?.inputName == "" && !model.isVoiceDraftDirty)
        model.returnToTranscript()
        #expect(!model.voiceReviewVisible)
        model.openSpeakerAssignment(for: "t0")
        #expect(model.activeDraft?.inputName == "Мария")
    }

    @Test func queuedFragmentCannotStartBehindExternalModal() async throws {
        let fake = SpeakerReviewPlaybackFake()
        let fixture = try SpeakerReviewFixture(transportFactory: { fake })
        defer { fixture.close() }
        let model = try await fixture.open()
        for _ in 0..<100 where !model.playbackEnabled { try await Task.sleep(for: .milliseconds(5)) }
        model.openVoiceReview()
        let queued = Task { await model.playVoiceTurn("t8") }
        fixture.manager.externalModal = true
        await queued.value
        #expect(fake.plays == 0 && model.fragmentTurnID == nil)
    }

    @Test func identicalIntervalsDoNotAdmitOldFragmentCompletion() async throws {
        let fake = SpeakerReviewPlaybackFake()
        let fixture = try SpeakerReviewFixture(transportFactory: { fake })
        defer { fixture.close() }
        let file = fixture.result.appendingPathComponent("result.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        for key in ["turns", "words", "baselineWords"] {
            var array = json[key] as! [[String: Any]]
            array[8]["start"] = 0.0; array[8]["end"] = 1.0
            json[key] = array
        }
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let model = try await fixture.open()
        for _ in 0..<100 where !model.playbackEnabled { try await Task.sleep(for: .milliseconds(5)) }
        model.openVoiceReview()
        fake.deferSeek = true
        let first = Task { await model.playVoiceTurn("t1") }
        for _ in 0..<100 where fake.pendingSeeks.count < 1 { await Task.yield() }
        let second = Task { await model.playVoiceTurn("t8") }
        for _ in 0..<100 where fake.pendingSeeks.count < 2 { await Task.yield() }
        try #require(fake.pendingSeeks.count == 2)
        fake.pendingSeeks.removeLast().resume(returning: true)
        await second.value
        #expect(model.fragmentTurnID == "t8")
        fake.pendingSeeks.removeLast().resume(returning: true)
        await first.value
        #expect(model.fragmentTurnID == "t8" && fake.plays == 1)
    }

    @Test func returnToContextDoesNotLeaveAnUnexecutedSeek() async throws {
        let fake = SpeakerReviewPlaybackFake()
        let fixture = try SpeakerReviewFixture(transportFactory: { fake })
        defer { fixture.close() }
        let model = try await fixture.open()
        for _ in 0..<100 where !model.playbackEnabled { try await Task.sleep(for: .milliseconds(5)) }
        model.openVoiceReview()
        await model.playVoiceTurn("t8")
        model.returnToTranscript(turnID: "t1")
        #expect(model.highlightedTurnID == "t1")
        #expect(model.playbackSeekPosition == model.playbackPosition)
    }
    @Test func fragmentUsesCurrentPlayerAndStopsOnVoiceOrScreenChange() async throws {
        let fake = SpeakerReviewPlaybackFake()
        let fixture = try SpeakerReviewFixture(transportFactory: { fake })
        defer { fixture.close() }
        let model = try await fixture.open()
        for _ in 0..<100 where !model.playbackEnabled { try await Task.sleep(for: .milliseconds(5)) }
        model.openVoiceReview()
        await model.playVoiceTurn("t8")
        #expect(model.fragmentTurnID == "t8" && model.playbackState == .playing)
        #expect(fake.seeks == [10] && fake.plays == 1)
        await model.playVoiceTurn("t8")
        #expect(model.playbackState == .ready)
        await model.playVoiceTurn("t8")
        #expect(fake.plays == 2 && fake.seeks == [10])
        fake.onEvent?(.position(11))
        #expect(model.fragmentTurnID == nil && model.playbackState == .ready)
        await model.playVoiceTurn("t8")
        model.selectVoice(model.voiceGroups[6].id)
        #expect(model.fragmentTurnID == nil && model.playbackState == .ready)
        await model.playVoiceTurn("t6")
        model.returnToTranscript(turnID: "t6")
        #expect(model.fragmentTurnID == nil && model.playbackState == .ready)
        #expect(model.highlightedTurnID == "t6")
    }
    @Test func groupSavePreservesManualTextAndAdvancesOnlyAfterCommit() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        let original = try Data(contentsOf: fixture.result.appendingPathComponent("result.json"))
        model.openVoiceReview()
        #expect(model.selectedVoice?.originalName == "Speaker 2")
        #expect(model.reviewedVoiceCount == 1)
        model.updateVoiceName("Анна")
        #expect(model.voiceChangesCount == 2)
        let confirmation = try #require(model.voiceDraft)
        model.confirmVoiceAssignment(confirmation)
        #expect(model.rows.first { $0.id == "t1" }?.name == "Алексей")
        #expect(model.rows.first { $0.id == "t1" }?.editText == "Правка текста")
        #expect(model.rows.first { $0.id == "t8" }?.name == "Анна")
        #expect(model.rows.first { $0.id == "t15" }?.name == "Анна")
        #expect(model.voiceGroups[1].mixedNames)
        #expect(model.selectedVoice?.originalName == "Speaker 3")
        let saved = try Data(contentsOf: fixture.result.appendingPathComponent("edits.json"))
        model.confirmVoiceAssignment(confirmation) // Late/double confirm cannot touch next group.
        #expect(try Data(contentsOf: fixture.result.appendingPathComponent("edits.json")) == saved)
        model.selectVoice(model.voiceGroups[1].id)
        model.updateVoiceName("Мария")
        model.setVoiceReplaceManual(true)
        #expect(model.voiceChangesCount == 3)
        model.confirmVoiceAssignment(try #require(model.voiceDraft))
        #expect(model.voiceGroups[1].title == "Мария") // Same person, two independent voices.
        #expect(model.voiceGroups.count == 7)
        #expect(model.voiceGroups[0].title == "Мария")
        #expect(try Data(contentsOf: fixture.result.appendingPathComponent("result.json")) == original)
        var exported = ""
        model.copySavedText { exported = $0; return true }
        #expect(exported.contains("Правка текста") && exported.contains("Мария"))
        model.close(); model.state.close()
        let reopened = try await fixture.open()
        #expect(reopened.voiceGroups[1].title == "Мария")
        #expect(reopened.rows.first { $0.id == "t1" }?.editText == "Правка текста")
        #expect(reopened.skippedVoices.isEmpty)
    }

    @Test func skipWrapCompletionAndNoOpDoNotWrite() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        let saved = try Data(contentsOf: fixture.result.appendingPathComponent("edits.json"))
        model.openVoiceReview()
        for _ in 0..<6 { model.skipVoice() }
        #expect(model.voiceReviewComplete && model.reviewedVoiceCount == 7)
        #expect(model.skippedVoices.count == 6)
        model.selectVoice(model.voiceGroups[0].id)
        model.confirmVoiceAssignment(try #require(model.voiceDraft)) // All names protected, zero targets.
        #expect(try Data(contentsOf: fixture.result.appendingPathComponent("edits.json")) == saved)
        model.returnToTranscript()
        model.openVoiceReview()
        #expect(model.selectedVoiceID == model.voiceGroups[0].id)
    }

    @Test func transferredDraftBlocksExternalNavigationUntilExplicitCancel() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openSpeakerAssignment(for: "t6")
        model.updateDraftName("Поздний")
        let saved = try Data(contentsOf: fixture.result.appendingPathComponent("edits.json"))
        model.openDraftVoiceReview()
        #expect(model.activeDraft == nil && model.voiceReviewVisible)
        #expect(model.selectedVoice?.originalName == "Speaker 7")
        #expect(model.voiceDraft?.inputName == "Поздний")
        #expect(model.voiceDraft?.preview?.totalTurnsInGroup == 3)
        #expect(!(await fixture.manager.prepareForRetry(fixture.recording)))
        model.selectVoice(model.voiceGroups[0].id)
        model.returnToTranscript()
        var closed = false
        model.requestWindowClose { closed = true }
        #expect(!closed && model.voiceReviewVisible && model.voiceDraft?.inputName == "Поздний")
        #expect(try Data(contentsOf: fixture.result.appendingPathComponent("edits.json")) == saved)
        model.cancelVoiceInput()
        model.returnToTranscript(turnID: "t6")
        #expect(!model.voiceReviewVisible && model.highlightedTurnID == "t6")
    }

    @Test(arguments: ["disk", "revision", "result", "draft", "foreign"])
    func saveErrorsAndStaleConfirmRetainInputAndProgress(kind: String) async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let repo = kind == "disk" ? TranscriptEditsRepository(recordingDirectory: fixture.root, atomicReplaceHook: { _, _ in
            throw CocoaError(.fileWriteUnknown)
        }) : nil
        let model = try await fixture.open(repository: repo)
        model.openVoiceReview()
        model.updateVoiceName("Анна")
        let confirmation = try #require(model.voiceDraft)
        let file = fixture.result.appendingPathComponent("edits.json")
        var saved = try Data(contentsOf: file)
        var other: SpeakerReviewFixture?
        defer { other?.close() }
        if kind == "revision" {
            saved.append(0x20); try saved.write(to: file)
        } else if kind == "result" {
            let next = fixture.result.deletingLastPathComponent().appendingPathComponent("v2")
            try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.result.appendingPathComponent("result.json"))) as! [String: Any]
            json["resultID"] = "v2"
            json["playback"] = ["status": "ready", "mixPath": "raw/transcripts/v2/mix.m4a"]
            try JSONSerialization.data(withJSONObject: json).write(to: next.appendingPathComponent("result.json"))
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: next.path)
        } else if kind == "draft" {
            model.updateVoiceName("Другое")
        } else if kind == "foreign" {
            let foreign = try SpeakerReviewFixture(); other = foreign
            let foreignModel = try await foreign.open()
            foreignModel.openVoiceReview(); foreignModel.updateVoiceName("Анна")
            model.confirmVoiceAssignment(try #require(foreignModel.voiceDraft))
        }
        if kind != "foreign" { model.confirmVoiceAssignment(confirmation) }
        #expect(model.error != nil)
        #expect(model.selectedVoice?.originalName == "Speaker 2")
        #expect(model.voiceDraft?.inputName == (kind == "draft" ? "Другое" : "Анна"))
        #expect(model.reviewedVoiceCount == 1)
        #expect(try Data(contentsOf: file) == saved)
    }

    @Test func quickRemainingRetainsEarlierNamesAndTextOverrides() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openSpeakerAssignment(for: "t8")
        model.updateDraftName("Мария")
        model.selectDraftScope(.allVoiceGroup)
        #expect(model.activeDraft?.pendingConfirmation?.affectedTurnsCount == 2)
        model.confirmGroupAssignment()
        #expect(model.rows.first { $0.id == "t1" }?.name == "Алексей")
        #expect(model.rows.first { $0.id == "t1" }?.editText == "Правка текста")
        #expect(model.rows.first { $0.id == "t8" }?.name == "Мария")
        #expect(model.rows.first { $0.id == "t15" }?.name == "Мария")
        #expect(model.rows.first { $0.id == "t0" }?.name == "Мария")
    }
    @Test func projectionPreservesVoiceIdentityOrderAndPartialManualNames() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        let groups = model.voiceGroups
        #expect(groups.count == 7)
        #expect(groups.map(\.id) == (1...7).map { TranscriptVoiceKey(sourceID: $0 == 1 ? .host : .remote, localID: $0 == 1 ? 1 : $0 - 1) })
        #expect(groups.first?.rows.map(\.id) == ["t0", "t7", "t14"])
        #expect(groups.first?.title == "Мария")
        #expect(groups.first?.fullyNamed == true)
        #expect(groups.dropFirst().first?.title == "Speaker 2")
        #expect(groups.dropFirst().first?.fullyNamed == false)
        #expect(groups.dropFirst().first?.mixedNames == false)
        #expect(groups.last?.rows.first?.start == 4324)
        #expect(groups.last?.rows.map(\.id) == ["t6", "t13", "t20"])
    }

    @Test func suggestionsUseAllManualNamesUnicodeAndRecomputeAfterRename() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        #expect(model.availableCalendarNames == ["Анна", "Éva"])
        #expect(model.contextAttendees == [" МАРИЯ ", "Алексей", "Анна", "анна", "Éva", "E\u{301}VA"])
        model.openSpeakerAssignment(for: "t1")
        #expect(model.activeDraft?.calendarAttendees == model.availableCalendarNames)
        model.updateDraftName("Анна")
        model.confirmGroupAssignment()
        #expect(model.rows.first { $0.id == "t1" }?.name == "Анна")
        #expect(model.availableCalendarNames == ["Алексей", "Éva"])
        model.openSpeakerAssignment(for: "t8")
        model.updateDraftName("Мария") // Repeated manual input remains legal.
        model.confirmGroupAssignment()
        #expect(model.rows.first { $0.id == "t8" }?.name == "Мария")
    }
}

@MainActor private final class SpeakerReviewPlaybackFake: TranscriptPlaybackTransport {
    var onEvent: (@MainActor @Sendable (TranscriptPlaybackEvent) -> Void)?
    var seeks: [Double] = []
    var plays = 0
    var deferSeek = false
    var pendingSeeks: [CheckedContinuation<Bool, Never>] = []
    func prepare(url: URL) async throws -> Double { 5000 }
    func play() { plays += 1; onEvent?(.playing(true)) }
    func pause() { onEvent?(.playing(false)) }
    func stop() {}
    func seek(to seconds: Double) async -> Bool {
        seeks.append(seconds)
        let success = deferSeek ? await withCheckedContinuation { pendingSeeks.append($0) } : true
        if success { onEvent?(.position(seconds)) }
        return success
    }
    func setRate(_ rate: Float) {}
}

@MainActor
final class SpeakerReviewFixture {
    let root: URL
    let result: URL
    let recording: URL
    let manager: TranscriptReviewWindowManager
    var model: TranscriptReviewWindowModel?

    init(voiceCount: Int = 7, turnsPerVoice: Int = 3,
         transportFactory: @escaping @MainActor () -> any TranscriptPlaybackTransport = { TranscriptAVPlayerTransport() }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerReview-" + UUID().uuidString).appendingPathComponent("meeting")
        result = root.appendingPathComponent("raw/transcripts/v1")
        recording = root.appendingPathComponent("meeting.m4a")
        manager = TranscriptReviewWindowManager(transportFactory: transportFactory)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_parakeet_off.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        json["resultID"] = "v1"
        json["context"] = ["title": "Длинная встреча", "attendees": [" МАРИЯ ", "Алексей", "Анна", "анна", "Éva", "E\u{301}VA"]]
        let hostCount = voiceCount > 8 ? 8 : 1
        json["speakers"] = (1...voiceCount).map { n in
            ["id": "s\(n)", "sourceID": n <= hostCount ? "host" : "remote", "localID": n <= hostCount ? n : n - hostCount, "displayNumber": n] as [String: Any]
        }
        // Repeated starts deliberately exercise document order, not a UI time sort.
        let turnCount = voiceCount * turnsPerVoice
        let starts: [Double] = (0..<turnCount).map { i in
            let offset = Double(i / voiceCount) * 10.0
            return voiceCount > 1 && i % voiceCount == voiceCount - 1 ? 4324.0 + offset : offset
        }
        json["words"] = (0..<turnCount).map { i in
            ["id": "w\(i)", "speakerID": "s\(i % voiceCount + 1)", "start": starts[i], "end": starts[i] + 1, "text": "Реплика \(i)"] as [String: Any]
        }
        json["baselineWords"] = json["words"]
        json["turns"] = (0..<turnCount).map { i in
            ["id": "t\(i)", "speakerID": "s\(i % voiceCount + 1)", "start": starts[i], "end": starts[i] + 1, "wordIDs": ["w\(i)"]] as [String: Any]
        }
        json["playback"] = ["status": "ready", "mixPath": "raw/transcripts/v1/mix.m4a"]
        try JSONSerialization.data(withJSONObject: json).write(to: result.appendingPathComponent("result.json"))
        try Data("synthetic".utf8).write(to: result.appendingPathComponent("mix.m4a"))
        try Data("synthetic".utf8).write(to: recording)
        let repo = TranscriptEditsRepository(recordingDirectory: root)
        for id in (0..<min(3, turnsPerVoice)).map({ "t\($0 * voiceCount)" }) {
            _ = try repo.saveTurnOverride(resultID: "v1", turnID: id, text: nil, displayName: "Мария")
        }
        if voiceCount > 1 { _ = try repo.saveTurnOverride(resultID: "v1", turnID: "t1", text: "Правка текста", displayName: "Алексей") }
        repo.releaseWriteLock()
    }

    func open(repository: TranscriptEditsRepository? = nil) async throws -> TranscriptReviewWindowModel {
        let opened: TranscriptReviewWindowModel
        if let repository {
            let session = TranscriptReviewSession(recordingDirectory: root, recordingURL: recording, activeResultID: "v1", editsRepository: repository)
            let state = TranscriptWindowState(id: recording, recordingDirectory: root, recordingURL: recording, mode: .review(activeResultID: "v1"), session: session)
            opened = try await TranscriptReviewWindowModel(state: state)
        } else {
            opened = try await manager.open(recordingURL: recording, title: "Длинная встреча")
        }
        model = opened
        return opened
    }

    func close() {
        model?.close()
        model?.state.close()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}
