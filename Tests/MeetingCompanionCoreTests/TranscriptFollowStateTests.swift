import Testing
@testable import MeetingCompanionCore

@Suite struct TranscriptFollowStateTests {
    @Test func firstDisplayOverlapAndDiscreteTicks() {
        var s = TranscriptFollowState()
        s.update(activeIDs: ["display-first", "earlier-time"], playing: true)
        #expect(s.targetID == "display-first" && s.request == 1 && s.isFollowing)
        s.update(activeIDs: ["display-first", "earlier-time"], playing: true)
        #expect(s.request == 1)
    }
    @Test func gapsAndPauseDoNotJump() {
        var s = TranscriptFollowState()
        s.update(activeIDs: ["a"], playing: true)
        s.update(activeIDs: [], playing: true)
        #expect(s.request == 1)
        s.update(activeIDs: ["b"], playing: false)
        #expect(s.request == 1)
        s.update(activeIDs: ["b"], playing: true)
        #expect(s.targetID == "b" && s.request == 2)
    }
    @Test func manualScrollSurvivesSeekPausePlayVersion() {
        var s = TranscriptFollowState()
        s.manualScroll()
        s.update(activeIDs: ["a"], playing: false)
        s.update(activeIDs: ["b"], playing: true)
        s.versionChanged()
        s.update(activeIDs: ["v2"], playing: true)
        #expect(!s.isFollowing && s.request == 0 && s.targetID == nil)
        s.returnToPlayback()
        #expect(s.isFollowing && s.targetID == "v2" && s.request == 1)
    }
    @Test func editingHookRequiresExplicitReturn() {
        var s = TranscriptFollowState()
        s.beginEditing(); s.update(activeIDs: ["a"], playing: true)
        #expect(!s.isFollowing && s.request == 0)
        s.returnToPlayback(); #expect(s.targetID == "a" && s.request == 1)
    }
    @Test func returnInGapWaitsNextActive() {
        var s = TranscriptFollowState()
        s.manualScroll(); s.update(activeIDs: [], playing: true); s.returnToPlayback()
        #expect(s.isFollowing && s.request == 0)
        s.update(activeIDs: ["next"], playing: true)
        #expect(s.targetID == "next" && s.request == 1)
    }
    @Test func explicitReturnWhilePausedTargetsCurrent() {
        var s = TranscriptFollowState()
        s.manualScroll(); s.update(activeIDs: ["paused"], playing: false); s.returnToPlayback()
        #expect(s.targetID == "paused" && s.request == 1)
    }
    @Test func closeRejectsUpdatesAndReturn() {
        var s = TranscriptFollowState()
        s.close(); s.update(activeIDs: ["a"], playing: true); s.returnToPlayback(); s.versionChanged()
        #expect(s.isClosed && !s.isFollowing && s.targetID == nil && s.request == 0)
    }
    @Test func sameIDReappearsAfterGapRequestsAgain() {
        var s = TranscriptFollowState()
        s.update(activeIDs: ["a"], playing: true); s.update(activeIDs: [], playing: true)
        s.update(activeIDs: ["a"], playing: true)
        #expect(s.request == 2 && s.targetID == "a")
    }
}
