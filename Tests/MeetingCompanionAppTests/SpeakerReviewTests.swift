import AppKit
import Foundation
import Testing
import MeetingCompanionApplication
import MeetingCompanionCore
import MeetingCompanionPlatform
@testable import MeetingCompanionApp

@Suite(.serialized) @MainActor
struct SpeakerReviewTests {
    @Test func emptyUnrecognizedFilterCanReturnToSavedGroup() async throws {
        let fixture = try SpeakerReviewFixture(voiceCount: 1)
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openVoiceReview()
        let anchor = model.voiceDraft?.anchorTurnID
        model.setUnrecognizedVoiceFilter(true)
        #expect(model.voiceReviewComplete && model.voiceDraft == nil)
        model.setUnrecognizedVoiceFilter(false)
        #expect(!model.voiceReviewComplete && model.voiceDraft?.anchorTurnID == anchor)
        #expect(model.voiceDraft?.inputName == "Мария")
    }

    @Test func unifiedEditorPreservesDraftAcrossTurnFilterAndTranscript() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        let saved = try Data(contentsOf: fixture.result.appendingPathComponent("edits.json"))
        model.openVoiceReview(anchorTurnID: "t8")
        #expect(model.voiceDraft?.scope == .single && model.voiceDraft?.inputName == "")
        model.updateVoiceName("Анна")
        model.setVoiceScope(.remaining)
        model.selectVoice(model.voiceGroups[0].id)
        #expect(model.voiceDraft?.anchorTurnID == "t0")
        model.setUnrecognizedVoiceFilter(true)
        #expect(model.showOnlyUnrecognizedVoices)
        #expect(model.voiceDraft?.anchorTurnID != "t0")
        model.returnToTranscript(turnID: "t8")
        #expect(!model.voiceReviewVisible && model.highlightedTurnID == "t8")
        #expect(!(await fixture.manager.prepareForRetry(fixture.recording)))
        model.openVoiceReview(anchorTurnID: "t8")
        #expect(model.voiceDraft?.inputName == "Анна" && model.voiceDraft?.scope == .remaining)
        model.cancelVoiceInput()
        #expect(!model.hasUnsavedChanges)
        #expect(try Data(contentsOf: fixture.result.appendingPathComponent("edits.json")) == saved)
    }

    @Test func untouchedDraftUsesEntryScopeAndExplicitScopeSurvivesReturn() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openVoiceReview()
        let anchor = try #require(model.voiceDraft?.anchorTurnID)
        model.returnToTranscript()
        model.openVoiceReview(anchorTurnID: anchor)
        #expect(model.voiceDraft?.scope == .single)
        model.setVoiceScope(.remaining)
        model.returnToTranscript()
        model.openVoiceReview()
        #expect(model.voiceDraft?.anchorTurnID == anchor && model.voiceDraft?.scope == .remaining)
    }

    @Test func headerReopensHiddenDirtyDraftAfterReturningFromAnotherVoice() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openVoiceReview(anchorTurnID: "t0")
        model.updateVoiceName("Исправленное имя")
        model.setUnrecognizedVoiceFilter(true)
        model.returnToTranscript()
        #expect(model.hasUnsavedChanges && !model.voiceReviewVisible)

        model.openVoiceReview()
        #expect(model.voiceDraft?.anchorTurnID == "t0")
        #expect(model.voiceDraft?.inputName == "Исправленное имя")
        #expect(!model.showOnlyUnrecognizedVoices)
        model.cancelVoiceInput()
        #expect(!model.hasUnsavedChanges && fixture.manager.admitNavigation())
    }

    @Test(arguments: [false, true])
    func unicodeOnlyNameCorrectionIsAVisibleAndSavableDraft(useStaleConfirmation: Bool) async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let writer = TranscriptEditsRepository(recordingDirectory: fixture.root)
        let personID = UUID()
        _ = try writer.saveEdits(resultID: "v1", overrides: [
            "t0": .init(displayName: "Алёна", assignment: .init(personID: personID, origin: "automaticVoiceMatch"))
        ])
        let model = try await fixture.open(repository: writer)
        model.openVoiceReview(anchorTurnID: "t0")
        model.updateVoiceName("АЛЁНА")
        let stale = try #require(model.voiceDraft)
        if useStaleConfirmation {
            model.updateVoiceName("АЛЕ\u{308}НА")
            model.confirmVoiceAssignment(stale)
            #expect(model.error?.contains("устарело") == true)
            let before = try #require(writer.readEditsSnapshot(resultID: "v1").edits.overrides["t0"])
            #expect(before.displayName == "Алёна")
            return
        }
        let name = "Але\u{308}на"
        model.updateVoiceName(name)
        #expect(model.isVoiceDraftDirty && model.canConfirmVoice)
        model.confirmVoiceAssignment(try #require(model.voiceDraft))
        let saved = try #require(writer.readEditsSnapshot(resultID: "v1").edits.overrides["t0"])
        #expect(saved.displayName?.utf8.elementsEqual(name.utf8) == true)
        #expect(saved.assignment?.personID == personID && saved.assignment?.isMachineAssigned == true)
    }

    @Test(arguments: [0, 1, 2]) func applyingTypedNameResolvesPersonOnlyOnSave(matches: Int) async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: fixture.root.appendingPathComponent("test-data"))
        let coordinator = VoiceLearningCoordinator(catalogue: catalogue)
        coordinator.setEnabled(true)
        let name = "Новое имя"
        let enteredName = " \(name) "
        let people = (0..<matches).map { _ in VoiceProfilePerson(displayName: name) }
        _ = try catalogue.update(catalogue.load()) { $0.people = people }
        let writer = TranscriptEditsRepository(recordingDirectory: fixture.root, learningCommitObserver: coordinator.observe)
        let model = try await fixture.open(repository: writer)
        model.voiceIdentityActions = .init(
            people: { (try? catalogue.load().catalogue.people) ?? [] }, selectPerson: { _, _ in .asEntered },
            confirmCalendarBinding: { _, _, _ in }, isEnabled: { true }, learningFailure: coordinator.failure,
            resolveTypedPerson: coordinator.personForManuallyEnteredName
        )
        model.openVoiceReview(anchorTurnID: "t8")
        let before = try catalogue.load().catalogue
        model.updateVoiceName(enteredName)
        #expect(try catalogue.load().catalogue == before)
        model.confirmVoiceAssignment(try #require(model.voiceDraft))
        let edits = try writer.loadEdits(resultID: "v1")
        if matches == 2 {
            #expect(model.error?.contains("несколько людей") == true)
            #expect(model.isVoiceDraftDirty && edits.overrides["t8"] == nil)
            #expect(try catalogue.load().catalogue == before)
        } else {
            let person = try #require(catalogue.load().catalogue.people.first)
            #expect(person.displayName == name)
            if let existing = people.first { #expect(person.id == existing.id) }
            #expect(edits.overrides["t8"]?.displayName == enteredName)
            #expect(edits.overrides["t8"]?.assignment?.personID == person.id)
            #expect(edits.pendingLearningEvents?.last?.allowsLearning == true)
        }
    }

    @Test(arguments: [0, 1, 2])
    func confirmingSavedNameEnrollsOnlyTheSelectedTurn(profileCount: Int) async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: fixture.root.appendingPathComponent("test-data"))
        let coordinator = VoiceLearningCoordinator(catalogue: catalogue)
        coordinator.setEnabled(true)
        let existing = (0..<profileCount).map { _ in VoiceProfilePerson(displayName: "Мария") }
        if !existing.isEmpty { _ = try catalogue.update(catalogue.load()) { $0.people = existing } }
        let writer = TranscriptEditsRepository(recordingDirectory: fixture.root, learningCommitObserver: coordinator.observe)
        _ = try writer.saveTurnOverride(resultID: "v1", turnID: "t0", text: nil, displayName: " Мария ")
        let model = try await fixture.open(repository: writer)
        model.voiceIdentityActions = .init(
            people: { (try? catalogue.load().catalogue.people) ?? [] }, selectPerson: { _, _ in .asEntered },
            confirmCalendarBinding: { _, _, _ in }, isEnabled: { coordinator.isEnabled }, learningFailure: coordinator.failure,
            resolveTypedPerson: coordinator.personForManuallyEnteredName
        )
        model.openVoiceReview(anchorTurnID: "t0")
        model.setVoiceScope(.group)
        let draft = try #require(model.voiceDraft)
        #expect(draft.anchorTurnID == "t0" && draft.scope == .group)
        #expect(model.canConfirmSavedVoiceName)
        let before = try writer.loadEdits(resultID: "v1")
        model.confirmVoiceAssignment(draft, confirmSavedName: true)

        let edits = try writer.loadEdits(resultID: "v1")
        if profileCount == 2 {
            #expect(edits == before && model.voiceDraft?.scope == .single)
            #expect(model.error?.contains("несколько людей") == true)
            #expect(model.matchingVoicePeople == existing)
            return
        }
        let person = try #require(catalogue.load().catalogue.people.first)
        #expect(person.displayName == "Мария")
        if let prior = existing.first { #expect(person.id == prior.id) }
        #expect(edits.overrides["t0"]?.displayName == before.overrides["t0"]?.displayName)
        #expect(edits.overrides["t0"]?.assignment?.personID == person.id)
        #expect(edits.overrides["t7"] == before.overrides["t7"])
        #expect(edits.overrides["t14"] == before.overrides["t14"])
        #expect(edits.pendingLearningEvents?.filter(\.allowsLearning).map(\.turnID) == ["t0"])
        #expect(model.selectedVoice?.mixedNames == false)
        #expect(model.selectedVoice?.title.trimmingCharacters(in: .whitespacesAndNewlines) == "Мария")
        #expect(model.voiceDraft?.anchorTurnID == "t0" && !model.canConfirmVoice)
        #expect(model.voiceLearningConfirmedTurnID == "t0")
        #expect(!model.canConfirmSavedVoiceName)
        model.confirmVoiceAssignment(draft, confirmSavedName: true)
        #expect(try writer.loadEdits(resultID: "v1") == edits)
    }

    @Test func sameNameWithTwoKnownProfilesIsStillMixed() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let writer = TranscriptEditsRepository(recordingDirectory: fixture.root)
        _ = try writer.saveEdits(resultID: "v1", overrides: [
            "t0": .init(displayName: "Мария", assignment: .init(personID: UUID(), origin: "manual")),
            "t7": .init(displayName: "Мария", assignment: .init(personID: UUID(), origin: "manual")),
            "t14": .init(displayName: "Мария")
        ])
        let model = try await fixture.open(repository: writer)
        #expect(model.voiceGroups[0].mixedNames && model.voiceGroups[0].title == "Speaker 1")
    }

    @Test func parkedDraftCanBeCancelledAfterNewCurrentAppears() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openVoiceReview(anchorTurnID: "t8")
        model.updateVoiceName("Проверка")
        model.returnToTranscript()
        let next = fixture.result.deletingLastPathComponent().appendingPathComponent("v2")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.result.appendingPathComponent("result.json"))) as? [String: Any])
        json["resultID"] = "v2"
        json["playback"] = ["status": "ready", "mixPath": "raw/transcripts/v2/mix.m4a"]
        try JSONSerialization.data(withJSONObject: json).write(to: next.appendingPathComponent("result.json"))
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(60)], ofItemAtPath: next.path)

        model.openVoiceReview(anchorTurnID: "t8")
        #expect(model.voiceReviewVisible && model.voiceRequiresReopen)
        #expect(model.voiceDraft?.inputName == "Проверка" && !model.canConfirmVoice)
        model.cancelVoiceInput()
        #expect(!model.hasUnsavedChanges && model.state.isClosed)
        #expect(fixture.manager.current == nil)
        let reopened = try await fixture.open()
        #expect(reopened !== model && !reopened.state.isClosed)
    }
    @Test func listRequestCannotHideDirtyDetailsAfterWideToCompactTransition() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openVoiceReview()
        #expect(model.requestVoiceList() && model.voiceListVisible) // Wide: list and details visible.
        model.updateVoiceName("Новое имя")
        #expect(!model.voiceListVisible) // Compact must retain the details, Save and Cancel.
        #expect(model.isVoiceDraftDirty && model.canConfirmVoice)
        #expect(model.requestVoiceList())
        #expect(model.voiceDraft?.inputName == "Новое имя")
        model.cancelVoiceInput()
        #expect(model.requestVoiceList() && model.voiceListVisible)
    }
    @Test func dirtyInputKeepsVoiceDetailsAndCancelReachable() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openVoiceReview(); model.updateVoiceName("Новое имя")
        #expect(model.requestVoiceList())
        #expect(model.voiceReviewVisible && model.voiceDraft?.inputName == "Новое имя")
        #expect(model.error == nil)
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
    @Test func groupSavePreservesManualTextAndNextIsSeparate() async throws {
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
        #expect(model.selectedVoice?.originalName == "Speaker 2")
        let saved = try Data(contentsOf: fixture.result.appendingPathComponent("edits.json"))
        model.nextVoice()
        #expect(model.selectedVoice?.originalName == "Speaker 3")
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
    }

    @Test func nextVoiceWrapsAndNoOpDoesNotWrite() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        let saved = try Data(contentsOf: fixture.result.appendingPathComponent("edits.json"))
        model.openVoiceReview()
        let originalGroup = model.selectedVoiceID
        for _ in 0..<7 { model.nextVoice() }
        #expect(model.selectedVoiceID == originalGroup && model.reviewedVoiceCount == 1)
        model.selectVoice(model.voiceGroups[0].id)
        #expect(!model.canConfirmVoice)
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
        #expect(model.voiceDraft?.preview?.totalTurnsInGroup == 1)
        #expect(!(await fixture.manager.prepareForRetry(fixture.recording)))
        model.selectVoice(model.voiceGroups[0].id)
        model.returnToTranscript()
        var closed = false
        model.requestWindowClose { closed = true }
        #expect(!closed && !model.voiceReviewVisible)
        model.openVoiceReview(anchorTurnID: "t6")
        #expect(model.voiceDraft?.inputName == "Поздний")
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
        #expect(model.savedMeetingNames == ["Мария", "Алексей"])
        #expect(model.contextAttendees == [" МАРИЯ ", "Алексей", "Анна", "анна", "Éva", "E\u{301}VA"])
        model.openSpeakerAssignment(for: "t1")
        #expect(model.activeDraft?.calendarAttendees == model.availableCalendarNames)
        model.updateDraftName("Анна")
        model.confirmGroupAssignment()
        #expect(model.rows.first { $0.id == "t1" }?.name == "Анна")
        #expect(model.availableCalendarNames == ["Алексей", "Éva"])
        #expect(model.savedMeetingNames == ["Мария", "Анна"])
        model.openSpeakerAssignment(for: "t8")
        model.updateDraftName("Мария") // Repeated manual input remains legal.
        model.confirmGroupAssignment()
        #expect(model.rows.first { $0.id == "t8" }?.name == "Мария")
    }

    @Test func suggestionSectionsDeduplicateParticipantsPreserveHomonymsAndVerifyIcons() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: fixture.root.appendingPathComponent("voice-data"))
        let alexey = VoiceProfilePerson(displayName: "Алексей")
        let maria = VoiceProfilePerson(displayName: "Мария")
        let roman1 = VoiceProfilePerson(displayName: "Роман", calendarBindings: ["roman1@example.com"])
        let roman2 = VoiceProfilePerson(displayName: "Роман")
        let vadim = VoiceProfilePerson(displayName: "Вадим", calendarBindings: ["vadim@example.com"])
        let centroid: [Float] = [1] + Array(repeating: 0, count: 255)
        let allPeople = [vadim, roman1, maria, alexey, roman2]
        _ = try catalogue.update(catalogue.load()) { value in
            value.people = allPeople
            // Mark maria and vadim ready; alexey stays collecting (not ready).
            for person in [maria, vadim] {
                let sample = VoiceProfileSample(
                    personID: person.id, embeddingSpaceID: VoiceEmbeddingProtocol.embeddingSpaceID,
                    embedding: centroid, recordingLocator: "/seed", resultID: "seed", turnID: "seed",
                    sourceID: .host, start: 0, end: 5, pcmFingerprint: "fp-\(person.id.uuidString)",
                    assignment: .init(personID: person.id, origin: "manual"), policyID: "test"
                )
                value.samples.append(sample)
                value.aggregates.append(.init(
                    personID: person.id, embeddingSpaceID: VoiceEmbeddingProtocol.embeddingSpaceID,
                    centroid: centroid, activeSampleIDs: [sample.id], policyID: "test"
                ))
            }
        }
        let writer = TranscriptEditsRepository(recordingDirectory: fixture.root)
        _ = try writer.saveEdits(resultID: "v1", overrides: [
            "t2": .init(displayName: "АвтоГость", assignment: .init(personID: UUID(), origin: "automaticVoiceMatch")),
            "t3": .init(displayName: "Дмитрий")
        ])
        writer.releaseWriteLock()

        let coordinator = VoiceLearningCoordinator(catalogue: catalogue)
        let model = try await fixture.open(repository: writer)
        model.voiceIdentityActions = .init(
            people: { (try? catalogue.load().catalogue.people) ?? [] },
            selectPerson: { id, name in
                try coordinator.personSelection(id.map(VoiceLearningCoordinator.PersonChoice.existing) ?? .new(UUID()), displayName: name)
            },
            confirmCalendarBinding: { _, _, _ in },
            isEnabled: { true },
            learningFailure: { _ in nil },
            readyPersonIDs: {
                let agg = (try? catalogue.load().catalogue.availableAggregates) ?? []
                return Set(agg.filter { $0.embeddingSpaceID == VoiceEmbeddingProtocol.embeddingSpaceID }.map(\.personID))
            }
        )
        model.openVoiceReview(anchorTurnID: "t8")

        let sections = model.voiceNameSuggestionSections(query: "")
        #expect(sections.map(\.title) == ["Участники встречи", "Сохранённые голоса"])

        let meetingItems = sections[0].items
        // Calendar has: " МАРИЯ " (-> maria), "Алексей" (-> alexey), "Анна", "анна", "Éva", "ÉVA"; plus manual-only "Дмитрий".
        #expect(meetingItems.map(\.displayName) == ["Мария", "Алексей", "Анна", "Éva", "Дмитрий"])
        let mariaItem = try #require(meetingItems.first { $0.displayName == "Мария" })
        #expect(mariaItem.selection == .existingPerson(maria))
        #expect(mariaItem.hasSavedProfile && mariaItem.isVoiceReady && mariaItem.isCalendarAttendee)
        #expect(mariaItem.subtitle == nil)

        let alexeyItem = try #require(meetingItems.first { $0.displayName == "Алексей" })
        #expect(alexeyItem.selection == .existingPerson(alexey))
        #expect(alexeyItem.hasSavedProfile && !alexeyItem.isVoiceReady)
        #expect(alexeyItem.subtitle == nil)

        let annaItem = try #require(meetingItems.first { $0.displayName == "Анна" })
        #expect(annaItem.selection == .plainName("Анна") && !annaItem.hasSavedProfile && annaItem.isCalendarAttendee)
        let dmitryItem = try #require(meetingItems.first { $0.displayName == "Дмитрий" })
        #expect(dmitryItem.selection == .plainName("Дмитрий") && !dmitryItem.hasSavedProfile && !dmitryItem.isCalendarAttendee)
        #expect(!meetingItems.contains { $0.displayName == "АвтоГость" })

        let savedItems = sections[1].items
        #expect(savedItems.count == 3) // Vadim + 2 Roman homonyms (Maria and Alexey are not duplicated!)
        let vadimItem = try #require(savedItems.first { $0.displayName == "Вадим" })
        #expect(vadimItem.selection == .existingPerson(vadim) && vadimItem.isVoiceReady && vadimItem.subtitle == "vadim@example.com")
        let romans = savedItems.filter { $0.displayName == "Роман" }
        #expect(romans.count == 2)
        #expect(romans.map(\.subtitle) == ["roman1@example.com", "Профиль 2"])
        for item in meetingItems + savedItems {
            if let sub = item.subtitle {
                #expect(!sub.contains(String(maria.id.uuidString.suffix(4))))
                #expect(!sub.contains(String(roman2.id.uuidString.suffix(4))))
            }
        }

        // Live Unicode/email search across both sections.
        let emailFilter = model.voiceNameSuggestionSections(query: "vadim@")
        #expect(emailFilter.flatMap(\.items).map(\.displayName) == ["Вадим"])
        let evaFilter = model.voiceNameSuggestionSections(query: "e\u{301}va")
        #expect(evaFilter.flatMap(\.items).map(\.displayName) == ["Éva"])

        // Selection paths.
        model.selectVoiceSuggestion(mariaItem)
        #expect(model.voiceDraft?.inputName == "Мария")
        if case .confirmed(let intent) = model.voiceDraft?.person {
            #expect(intent.personID == maria.id)
        } else {
            Issue.record("Expected confirmed person selection for existing saved profile")
        }
        model.selectVoiceSuggestion(annaItem)
        #expect(model.voiceDraft?.inputName == "Анна")
        #expect(model.voiceDraft?.person == .asEntered)

        for symbol in ["waveform", "person.crop.circle", "calendar", "xmark.circle.fill", "chevron.down", "chevron.up", "plus.circle"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        }
    }

    @Test func homonymCalendarAndManualResolutionDoesNotPullAllHomonymsIntoMeetingParticipants() async throws {
        // Case A: Calendar attendee "Роман" WITHOUT confirmed email + 2 homonyms -> stays plainName in meeting, both Romans in savedVoices.
        do {
            let fixture = try SpeakerReviewFixture()
            defer { fixture.close() }
            let resultURL = fixture.result.appendingPathComponent("result.json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
            json["context"] = ["title": "Встреча", "attendees": ["Роман"]]
            try JSONSerialization.data(withJSONObject: json).write(to: resultURL)

            let catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: fixture.root.appendingPathComponent("voice-a"))
            let roman1 = VoiceProfilePerson(displayName: "Роман", calendarBindings: ["roman1@example.com"])
            let roman2 = VoiceProfilePerson(displayName: "Роман")
            _ = try catalogue.update(catalogue.load()) { $0.people = [roman1, roman2] }
            let coordinator = VoiceLearningCoordinator(catalogue: catalogue)
            let model = try await fixture.open()
            model.voiceIdentityActions = .init(
                people: { (try? catalogue.load().catalogue.people) ?? [] },
                selectPerson: { id, name in try coordinator.personSelection(id.map(VoiceLearningCoordinator.PersonChoice.existing) ?? .new(UUID()), displayName: name) },
                confirmCalendarBinding: { _, _, _ in }, isEnabled: { true }, learningFailure: { _ in nil }
            )
            model.openVoiceReview(anchorTurnID: "t8")
            let sections = model.voiceNameSuggestionSections(query: "")
            let meeting = sections.first { $0.id == "meeting" }?.items ?? []
            let saved = sections.first { $0.id == "saved" }?.items ?? []
            #expect(meeting.map(\.displayName) == ["Роман", "Мария", "Алексей"])
            let romanMeeting = try #require(meeting.first { $0.displayName == "Роман" })
            #expect(romanMeeting.selection == .plainName("Роман"))
            #expect(!romanMeeting.hasSavedProfile && romanMeeting.isCalendarAttendee)
            #expect(saved.count == 2)
            #expect(Set(saved.compactMap {
                if case .existingPerson(let p) = $0.selection { return p.id }
                return nil
            }) == [roman1.id, roman2.id])
            #expect(saved.allSatisfy { !$0.isCalendarAttendee })
        }

        // A confirmed invite, an unbound invite and a manually identified homonym are independent.
        for moreInvites in [false, true] {
            let fixture = try SpeakerReviewFixture()
            defer { fixture.close() }
            let resultURL = fixture.result.appendingPathComponent("result.json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
            var attendees = ["Роман"]
            var contacts = [["displayName": "Роман", "address": "roman1@example.com"]]
            if moreInvites {
                attendees.append("mailto:denis@example.com")
                contacts.append(["displayName": "Роман", "address": "guest@example.com"])
                contacts.append(["displayName": "Роман", "address": "other@example.com"])
                contacts.append(["displayName": "denis@example.com", "address": "denis@example.com"])
            }
            json["context"] = [
                "title": "Встреча",
                "attendees": attendees,
                "calendarParticipants": contacts
            ]
            try JSONSerialization.data(withJSONObject: json).write(to: resultURL)

            let catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: fixture.root.appendingPathComponent("voice-b"))
            let roman1 = VoiceProfilePerson(displayName: "Роман", calendarBindings: ["roman1@example.com"])
            let roman2 = VoiceProfilePerson(displayName: "Роман")
            let denis = VoiceProfilePerson(displayName: "Денис", calendarBindings: ["denis@example.com"])
            _ = try catalogue.update(catalogue.load()) { $0.people = moreInvites ? [roman1, roman2, denis] : [roman1, roman2] }
            let writer = TranscriptEditsRepository(recordingDirectory: fixture.root)
            var overrides: [String: TranscriptTurnOverride] = [
                "t3": .init(displayName: "Роман", assignment: .init(personID: roman2.id, origin: "manual"))
            ]
            if moreInvites { overrides["t5"] = .init(displayName: "Роман") }
            _ = try writer.saveEdits(resultID: "v1", overrides: overrides)
            writer.releaseWriteLock()
            let coordinator = VoiceLearningCoordinator(catalogue: catalogue)
            let model = try await fixture.open(repository: writer)
            model.voiceIdentityActions = .init(
                people: { (try? catalogue.load().catalogue.people) ?? [] },
                selectPerson: { id, name in try coordinator.personSelection(id.map(VoiceLearningCoordinator.PersonChoice.existing) ?? .new(UUID()), displayName: name) },
                confirmCalendarBinding: { _, _, _ in }, isEnabled: { true }, learningFailure: { _ in nil }
            )
            model.openVoiceReview(anchorTurnID: "t8")
            let sections = model.voiceNameSuggestionSections(query: "")
            let meeting = sections.first { $0.id == "meeting" }?.items ?? []
            let saved = sections.first { $0.id == "saved" }?.items ?? []
            #expect(meeting.first?.selection == .existingPerson(roman1))
            #expect(meeting.first?.isCalendarAttendee == true)
            let manual = try #require(meeting.first { $0.selection == .existingPerson(roman2) })
            #expect(!manual.isCalendarAttendee)
            #expect(saved.isEmpty)
            let invited = meeting.filter { $0.displayName == "Роман" && $0.isCalendarAttendee }
            #expect(invited.count == (moreInvites ? 3 : 1))
            #expect(Set(invited.map(\.id)).count == invited.count)
            if moreInvites {
                let guest = model.voiceNameSuggestionSections(query: "guest@example.com").flatMap(\.items)
                #expect(guest.map(\.selection) == [.plainName("Роман")])
                #expect(guest.first?.isCalendarAttendee == true)
                let denisItems = model.voiceNameSuggestionSections(query: "denis@example.com").flatMap(\.items)
                #expect(denisItems.map(\.selection) == [.existingPerson(denis)])
                let legacy = meeting.filter { !$0.isCalendarAttendee && $0.selection == .plainName("Роман") }
                #expect(legacy.count == 1)
            }
        }

        // An unbound invite and a manually identified homonym remain separate suggestions.
        do {
            let fixture = try SpeakerReviewFixture()
            defer { fixture.close() }
            let resultURL = fixture.result.appendingPathComponent("result.json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
            json["context"] = [
                "title": "Встреча",
                "attendees": ["Роман"],
                "calendarParticipants": [["displayName": "Роман", "address": "guest@example.com"]]
            ]
            try JSONSerialization.data(withJSONObject: json).write(to: resultURL)

            let catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: fixture.root.appendingPathComponent("voice-c"))
            let roman1 = VoiceProfilePerson(displayName: "Роман", calendarBindings: ["roman1@example.com"])
            let roman2 = VoiceProfilePerson(displayName: "Роман")
            _ = try catalogue.update(catalogue.load()) { $0.people = [roman1, roman2] }
            let writer = TranscriptEditsRepository(recordingDirectory: fixture.root)
            _ = try writer.saveEdits(resultID: "v1", overrides: [
                "t3": .init(displayName: "Роман", assignment: .init(personID: roman2.id, origin: "manual"))
            ])
            writer.releaseWriteLock()

            let coordinator = VoiceLearningCoordinator(catalogue: catalogue)
            let model = try await fixture.open(repository: writer)
            model.voiceIdentityActions = .init(
                people: { (try? catalogue.load().catalogue.people) ?? [] },
                selectPerson: { id, name in try coordinator.personSelection(id.map(VoiceLearningCoordinator.PersonChoice.existing) ?? .new(UUID()), displayName: name) },
                confirmCalendarBinding: { _, _, _ in }, isEnabled: { true }, learningFailure: { _ in nil }
            )
            model.openVoiceReview(anchorTurnID: "t8")
            let sections = model.voiceNameSuggestionSections(query: "")
            let meeting = sections.first { $0.id == "meeting" }?.items ?? []
            let saved = sections.first { $0.id == "saved" }?.items ?? []
            #expect(meeting.first?.selection == .plainName("Роман"))
            #expect(meeting.first?.isCalendarAttendee == true)
            let manual = try #require(meeting.first { $0.selection == .existingPerson(roman2) })
            #expect(!manual.isCalendarAttendee)
            #expect(!meeting.contains { $0.selection == .existingPerson(roman1) })
            #expect(saved.map(\.selection) == [.existingPerson(roman1)])
            #expect(saved.first?.isCalendarAttendee == false)
        }
    }

    @Test(arguments: [false, true])
    func calendarSuggestionsPreservePositionSearchAliasesAndExplicitHomonymSelection(fromDraft: Bool) async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let resultURL = fixture.result.appendingPathComponent("result.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
        let contacts = [
            ("denis@example.com", "other@example.com"),
            ("denis@example.com", "denis@example.com"),
            ("Роман", "guest@example.com"),
            ("Александр", "alex1@example.com"),
            ("Александр", "alex2@example.com"),
            ("Иван", "ivan@example.com"),
            ("Денис из календаря", "alias@example.com"),
            ("Софья", "sofia@example.com")
        ]
        json["context"] = [
            "title": "Встреча",
            "attendees": ["denis@example.com", "Мария", "mailto:denis@example.com", "Роман",
                          "Александр", "Александр", "Иван", "Иван", "Денис из календаря"],
            "calendarParticipants": contacts.map { ["displayName": $0.0, "address": $0.1] }
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: resultURL)

        let catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: fixture.root.appendingPathComponent("ordered-voices"))
        let denis = VoiceProfilePerson(displayName: "Денис", calendarBindings: ["denis@example.com", "alias@example.com"])
        let roman = VoiceProfilePerson(displayName: "Роман")
        _ = try catalogue.update(catalogue.load()) { $0.people = [denis, roman] }
        let coordinator = VoiceLearningCoordinator(catalogue: catalogue)
        coordinator.setEnabled(true)
        let writer = TranscriptEditsRepository(recordingDirectory: fixture.root, learningCommitObserver: coordinator.observe)
        _ = try writer.saveTurnOverride(resultID: "v1", turnID: "t5", text: nil, displayName: "Денис")
        let model = try await fixture.open(repository: writer)
        model.voiceIdentityActions = .init(
            people: { (try? catalogue.load().catalogue.people) ?? [] },
            selectPerson: { id, name in
                try coordinator.personSelection(id.map(VoiceLearningCoordinator.PersonChoice.existing) ?? .new(UUID()), displayName: name)
            }, confirmCalendarBinding: { _, _, _ in }, isEnabled: { coordinator.isEnabled },
            learningFailure: coordinator.failure, resolveTypedPerson: coordinator.personForManuallyEnteredName
        )
        if fromDraft {
            model.openSpeakerAssignment(for: "t8")
            model.openDraftVoiceReview()
        } else {
            model.openVoiceReview(anchorTurnID: "t8")
        }
        func suggestions(_ query: String = "") -> [TranscriptReviewWindowModel.VoiceNameSuggestion] {
            model.voiceNameSuggestionSections(query: query).flatMap(\.items)
        }
        let invited = suggestions().filter(\.isCalendarAttendee)
        #expect(invited.map(\.id) == [
            "calendar-other@example.com", "name-мария", "person-\(denis.id.uuidString)", "person-\(roman.id.uuidString)",
            "calendar-alex1@example.com", "calendar-alex2@example.com", "calendar-ivan@example.com", "name-иван",
            "calendar-sofia@example.com"
        ])
        for query in ["alias@", "Денис из календаря"] {
            #expect(suggestions(query).map(\.selection) == [.existingPerson(denis)])
        }
        #expect(suggestions("guest@").map(\.selection) == [.existingPerson(roman)])
        #expect(suggestions("guest@").first?.subtitle == "guest@example.com")
        #expect(suggestions("denis@example.com").contains { $0.selection == .existingPerson(denis) })

        let namesake = try #require(suggestions().first { !$0.isCalendarAttendee && $0.selection == .plainName("Денис") })
        model.selectVoiceSuggestion(namesake)
        let draft = try #require(model.voiceDraft)
        model.confirmVoiceAssignment(draft)
        #expect(model.error?.contains("Создать человека") == true)
        #expect(try writer.loadEdits(resultID: "v1").overrides["t8"] == nil)
        model.selectVoicePerson(nil)
        model.confirmVoiceAssignment(try #require(model.voiceDraft))
        let saved = try #require(writer.loadEdits(resultID: "v1").overrides["t8"])
        let newID = try #require(saved.assignment?.personID)
        #expect(newID != denis.id && saved.displayName == "Денис")
        #expect(try catalogue.load().catalogue.people.contains { $0.id == newID && $0.displayName == "Денис" })
    }

    @Test(arguments: ["legacy", "mixed", "mixedWithManual", "namesake", "namesakeWithProfile"])
    func calendarSuggestionsRequireExplicitIdentityBeforeSaving(scenario: String) async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let resultURL = fixture.result.appendingPathComponent("result.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
        let hasManualNamesake = scenario == "namesake" || scenario == "namesakeWithProfile"
        let contact = hasManualNamesake
            ? ["displayName": "Роман", "address": "guest@example.com"]
            : ["displayName": "Мария", "address": "maria@example.com"]
        json["context"] = [
            "title": "Встреча", "attendees": ["Роман", "Мария"],
            "calendarParticipants": scenario == "legacy" ? [] : [contact]
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: resultURL)

        let catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: fixture.root.appendingPathComponent("explicit-voices"))
        let profile = VoiceProfilePerson(displayName: "Роман",
                                         calendarBindings: hasManualNamesake ? [] : ["other@example.com"])
        let knownPeople = scenario == "namesake" ? [] : [profile]
        _ = try catalogue.update(catalogue.load()) { $0.people = knownPeople }
        let coordinator = VoiceLearningCoordinator(catalogue: catalogue)
        coordinator.setEnabled(true)
        let writer = TranscriptEditsRepository(recordingDirectory: fixture.root, learningCommitObserver: coordinator.observe)
        if hasManualNamesake || scenario == "mixedWithManual" {
            _ = try writer.saveTurnOverride(resultID: "v1", turnID: "t5", text: nil, displayName: "Роман")
        }
        let model = try await fixture.open(repository: writer)
        model.voiceIdentityActions = .init(
            people: { (try? catalogue.load().catalogue.people) ?? [] },
            selectPerson: { id, name in
                try coordinator.personSelection(id.map(VoiceLearningCoordinator.PersonChoice.existing) ?? .new(UUID()), displayName: name)
            }, confirmCalendarBinding: { _, _, _ in }, isEnabled: { coordinator.isEnabled },
            learningFailure: coordinator.failure, resolveTypedPerson: coordinator.personForManuallyEnteredName
        )
        model.openVoiceReview(anchorTurnID: "t8")
        let suggestions = model.voiceNameSuggestionSections(query: "роман").flatMap(\.items)
        let invite = try #require(suggestions.first { $0.isCalendarAttendee })
        if scenario == "legacy" {
            #expect(invite.selection == .existingPerson(profile))
            model.selectVoiceSuggestion(invite)
            model.confirmVoiceAssignment(try #require(model.voiceDraft))
            #expect(try writer.loadEdits(resultID: "v1").overrides["t8"]?.assignment?.personID == profile.id)
            return
        }
        #expect(invite.selection == .plainName("Роман"))
        if scenario == "mixed" || scenario == "mixedWithManual" {
            #expect(suggestions.first { $0.selection == .existingPerson(profile) }?.kind == .savedVoice)
        }
        let candidates = hasManualNamesake
            ? [invite, try #require(suggestions.first { !$0.isCalendarAttendee && $0.selection == .plainName("Роман") })]
            : [invite]
        let before = try writer.loadEdits(resultID: "v1")
        for candidate in candidates {
            model.selectVoiceSuggestion(candidate)
            model.confirmVoiceAssignment(try #require(model.voiceDraft))
            #expect(model.error?.contains("Создать человека") == true)
            #expect(try writer.loadEdits(resultID: "v1") == before)
            #expect(try catalogue.load().catalogue.people == knownPeople)
        }
        model.selectVoicePerson(knownPeople.first)
        model.confirmVoiceAssignment(try #require(model.voiceDraft))
        let saved = try writer.loadEdits(resultID: "v1")
        let savedID = try #require(saved.overrides["t8"]?.assignment?.personID)
        if let existing = knownPeople.first {
            #expect(savedID == existing.id)
        } else {
            #expect(try catalogue.load().catalogue.people.map(\.id) == [savedID])
        }
    }

    @Test func suggestionKeyboardNavigationIncludesCreateOptionAndRepeatedSelectVoiceBumpsRevision() async throws {
        // Navigation cycles forward/backward across suggestions AND createPersonOptionID.
        let ids = ["item-1", "item-2", SpeakerReviewView.createPersonOptionID]
        #expect(SpeakerReviewView.nextHighlightedSuggestionID(current: nil, in: ids, step: 1) == "item-1")
        #expect(SpeakerReviewView.nextHighlightedSuggestionID(current: "item-1", in: ids, step: 1) == "item-2")
        #expect(SpeakerReviewView.nextHighlightedSuggestionID(current: "item-2", in: ids, step: 1) == SpeakerReviewView.createPersonOptionID)
        #expect(SpeakerReviewView.nextHighlightedSuggestionID(current: SpeakerReviewView.createPersonOptionID, in: ids, step: 1) == "item-1")
        #expect(SpeakerReviewView.nextHighlightedSuggestionID(current: nil, in: ids, step: -1) == SpeakerReviewView.createPersonOptionID)
        #expect(SpeakerReviewView.nextHighlightedSuggestionID(current: "item-1", in: ids, step: -1) == SpeakerReviewView.createPersonOptionID)
        #expect(SpeakerReviewView.nextHighlightedSuggestionID(current: "item-1", in: [], step: 1) == nil)

        // Repeated selectVoice on same voice and anchor increments voiceSelectionRevision while keeping dirty draft.
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let model = try await fixture.open()
        model.openVoiceReview(anchorTurnID: "t8")
        model.updateVoiceName("Черновик")
        let selectedVoice = try #require(model.selectedVoiceID)
        let revisionBefore = model.voiceSelectionRevision
        model.selectVoice(selectedVoice, anchorTurnID: "t8")
        #expect(model.voiceSelectionRevision == revisionBefore + 1)
        #expect(model.voiceDraft?.inputName == "Черновик")

        model.selectVoice(TranscriptVoiceKey(sourceID: .remote, localID: 999))
        #expect(model.voiceSelectionRevision == revisionBefore + 1)
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
