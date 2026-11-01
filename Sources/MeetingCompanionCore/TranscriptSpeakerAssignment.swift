import Foundation

/// Voice identifier defined by source and local speaker index.
public struct TranscriptVoiceKey: Hashable, Sendable {
    public let sourceID: TranscriptDocument.SourceID
    public let localID: Int

    public init(sourceID: TranscriptDocument.SourceID, localID: Int) {
        self.sourceID = sourceID
        self.localID = localID
    }
}

/// Information previewing a bulk speaker name assignment across a voice group.
/// Opaque and unforgeable by external clients; issued exclusively by `TranscriptSpeakerAssignmentService`.
public struct TranscriptBulkAssignmentPreview: Equatable, Sendable {
    public let recordingDirectory: URL
    public let resultID: String
    public let sourceID: TranscriptDocument.SourceID
    public let localID: Int
    public let speakerID: String
    public let revision: Int
    public let replaceManuallyAssigned: Bool
    public let totalTurnsInGroup: Int
    public let affectedTurnsCount: Int
    public let replacedManualAssignmentsCount: Int
    public let targetTurnIDs: Set<String>
    public let affectedTurnIDs: Set<String>
    public let replacedTurnIDs: Set<String>
    public let snapshotOverrides: [String: TranscriptTurnOverride]

    internal init(
        recordingDirectory: URL,
        resultID: String,
        sourceID: TranscriptDocument.SourceID,
        localID: Int,
        speakerID: String,
        revision: Int,
        replaceManuallyAssigned: Bool,
        totalTurnsInGroup: Int,
        affectedTurnsCount: Int,
        replacedManualAssignmentsCount: Int,
        targetTurnIDs: Set<String> = [],
        affectedTurnIDs: Set<String> = [],
        replacedTurnIDs: Set<String> = [],
        snapshotOverrides: [String: TranscriptTurnOverride] = [:]
    ) {
        self.recordingDirectory = recordingDirectory
        self.resultID = resultID
        self.sourceID = sourceID
        self.localID = localID
        self.speakerID = speakerID
        self.revision = revision
        self.replaceManuallyAssigned = replaceManuallyAssigned
        self.totalTurnsInGroup = totalTurnsInGroup
        self.affectedTurnsCount = affectedTurnsCount
        self.replacedManualAssignmentsCount = replacedManualAssignmentsCount
        self.targetTurnIDs = targetTurnIDs
        self.affectedTurnIDs = affectedTurnIDs
        self.replacedTurnIDs = replacedTurnIDs
        self.snapshotOverrides = snapshotOverrides
    }
}

/// Service providing single-turn and voice-group speaker name assignment, unassignment, and preview.
public struct TranscriptSpeakerAssignmentService: Sendable {
    public let editsRepository: TranscriptEditsRepository

    public init(editsRepository: TranscriptEditsRepository) {
        self.editsRepository = editsRepository
    }

    private func loadDocument(resultID: String) throws -> TranscriptDocument {
        guard !resultID.isEmpty,
              !resultID.contains("/"),
              !resultID.contains("\\"),
              !resultID.contains("\0"),
              resultID != ".",
              resultID != ".." else {
            throw TranscriptEditsError.resultNotFound(resultID)
        }
        let resultURL = editsRepository.resultURL(for: resultID)
        do {
            let doc = try TranscriptDocument.load(from: resultURL, recordingDirectory: editsRepository.recordingDirectory)
            guard doc.resultID == resultID else {
                throw TranscriptEditsError.resultNotFound(resultID)
            }
            return doc
        } catch let err as TranscriptEditsError {
            throw err
        } catch {
            throw TranscriptEditsError.resultNotFound(resultID)
        }
    }

    private func validateDisplayName(_ displayName: String) throws {
        guard !displayName.isEmpty,
              !displayName.allSatisfy(\.isWhitespace) else {
            throw TranscriptEditsError.malformed("displayName must not be empty or blank")
        }
    }

    /// Assigns a display name to a single turn.
    public func assignSpeakerName(
        resultID: String,
        turnID: String,
        displayName: String
    ) throws -> TranscriptEdits {
        try validateDisplayName(displayName)
        let doc = try loadDocument(resultID: resultID)
        guard doc.turns.contains(where: { $0.id == turnID }) else {
            throw TranscriptEditsError.invalidReference("Unknown turnID: \(turnID)")
        }

        return try editsRepository.mutateOverrides(resultID: resultID) { currentOverrides in
            let prior = currentOverrides[turnID]
            currentOverrides[turnID] = TranscriptTurnOverride(text: prior?.text, displayName: displayName)
        }
    }

    /// Assigns a display name to all turns in a voice group identified by `speakerID`.
    public func assignSpeakerName(
        resultID: String,
        speakerID: String,
        displayName: String,
        replaceManuallyAssigned: Bool
    ) throws -> TranscriptEdits {
        try validateDisplayName(displayName)
        let doc = try loadDocument(resultID: resultID)
        guard doc.speakers.contains(where: { $0.id == speakerID }) else {
            throw TranscriptEditsError.invalidReference("Unknown speakerID: \(speakerID)")
        }

        let turnsInGroup = doc.turns.filter { $0.speakerID == speakerID }
        return try editsRepository.mutateOverrides(resultID: resultID) { currentOverrides in
            for turn in turnsInGroup {
                let prior = currentOverrides[turn.id]
                let hasManualName = prior?.displayName != nil
                if hasManualName && !replaceManuallyAssigned {
                    continue
                }
                currentOverrides[turn.id] = TranscriptTurnOverride(text: prior?.text, displayName: displayName)
            }
        }
    }

    /// Assigns a display name to all turns in a voice group identified by `voice`.
    public func assignSpeakerName(
        resultID: String,
        voice: TranscriptVoiceKey,
        displayName: String,
        replaceManuallyAssigned: Bool
    ) throws -> TranscriptEdits {
        try validateDisplayName(displayName)
        let doc = try loadDocument(resultID: resultID)
        guard let speaker = doc.speakers.first(where: { $0.sourceID == voice.sourceID && $0.localID == voice.localID }) else {
            throw TranscriptEditsError.invalidReference("Unknown voice: source=\(voice.sourceID), localID=\(voice.localID)")
        }
        return try assignSpeakerName(
            resultID: resultID,
            speakerID: speaker.id,
            displayName: displayName,
            replaceManuallyAssigned: replaceManuallyAssigned
        )
    }

    /// Applies a bulk speaker assignment bound to a previously generated preview.
    /// Validates recording identity, snapshot overrides, revision, and confirmed targets inside transaction.
    public func assignSpeakerName(
        preview: TranscriptBulkAssignmentPreview,
        displayName: String
    ) throws -> TranscriptEdits {
        try validateDisplayName(displayName)

        let canonicalServiceDir = editsRepository.recordingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalPreviewDir = preview.recordingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalServiceDir == canonicalPreviewDir else {
            throw TranscriptEditsError.conflict("Preview belongs to recording at \(canonicalPreviewDir.path), but service is bound to \(canonicalServiceDir.path)")
        }

        let doc = try loadDocument(resultID: preview.resultID)
        guard let speaker = doc.speakers.first(where: { $0.id == preview.speakerID }) else {
            throw TranscriptEditsError.invalidReference("Unknown speakerID: \(preview.speakerID)")
        }
        guard preview.sourceID == speaker.sourceID && preview.localID == speaker.localID else {
            throw TranscriptEditsError.conflict("Fabricated preview: speaker identity does not match document")
        }

        let actualGroupTurns = doc.turns.filter { $0.speakerID == preview.speakerID }
        guard actualGroupTurns.count == preview.totalTurnsInGroup else {
            throw TranscriptEditsError.conflict("Fabricated preview: totalTurnsInGroup mismatch (expected \(actualGroupTurns.count), got \(preview.totalTurnsInGroup))")
        }
        let actualTargetTurnIDs = Set(actualGroupTurns.map(\.id))
        guard actualTargetTurnIDs == preview.targetTurnIDs else {
            throw TranscriptEditsError.conflict("Fabricated preview: targetTurnIDs mismatch")
        }

        return try editsRepository.mutateOverrides(resultID: preview.resultID) { currentOverrides in
            guard let snapshot = editsRepository.loadedSnapshot(for: preview.resultID) else {
                throw TranscriptEditsError.conflict("Snapshot missing for resultID \(preview.resultID)")
            }
            guard snapshot.edits.revision == preview.revision else {
                throw TranscriptEditsError.conflict("Preview is stale: revision changed from \(preview.revision) to \(snapshot.edits.revision)")
            }
            guard snapshot.edits.overrides == preview.snapshotOverrides else {
                throw TranscriptEditsError.conflict("Preview snapshot is stale: overrides have changed since preview generation")
            }

            var expectedReplacedTurnIDs: Set<String> = []
            var expectedAffectedTurnIDs: Set<String> = []
            for turn in actualGroupTurns {
                if currentOverrides[turn.id]?.displayName != nil {
                    expectedReplacedTurnIDs.insert(turn.id)
                    if preview.replaceManuallyAssigned {
                        expectedAffectedTurnIDs.insert(turn.id)
                    }
                } else {
                    expectedAffectedTurnIDs.insert(turn.id)
                }
            }

            guard expectedReplacedTurnIDs == preview.replacedTurnIDs else {
                throw TranscriptEditsError.conflict("Preview is stale: replaced turns mismatch")
            }
            guard expectedAffectedTurnIDs == preview.affectedTurnIDs else {
                throw TranscriptEditsError.conflict("Preview is stale: affected turns mismatch")
            }
            let expectedReplacedCount = preview.replaceManuallyAssigned ? expectedReplacedTurnIDs.count : 0
            guard preview.replacedManualAssignmentsCount == expectedReplacedCount else {
                throw TranscriptEditsError.conflict("Fabricated preview: replacedManualAssignmentsCount mismatch")
            }
            guard preview.affectedTurnsCount == expectedAffectedTurnIDs.count else {
                throw TranscriptEditsError.conflict("Fabricated preview: affectedTurnsCount mismatch")
            }

            for turnID in expectedAffectedTurnIDs {
                let prior = currentOverrides[turnID]
                currentOverrides[turnID] = TranscriptTurnOverride(text: prior?.text, displayName: displayName)
            }
        }
    }

    /// Unassigns any manual display name for a single turn, preserving any corrected text override.
    public func unassignSpeakerName(
        resultID: String,
        turnID: String
    ) throws -> TranscriptEdits {
        let doc = try loadDocument(resultID: resultID)
        guard doc.turns.contains(where: { $0.id == turnID }) else {
            throw TranscriptEditsError.invalidReference("Unknown turnID: \(turnID)")
        }

        return try editsRepository.mutateOverrides(resultID: resultID) { currentOverrides in
            let prior = currentOverrides[turnID]
            if prior?.displayName != nil {
                currentOverrides[turnID] = TranscriptTurnOverride(text: prior?.text, displayName: nil)
            }
        }
    }

    /// Unassigns manual display names for all turns in a voice group, preserving any corrected text overrides.
    public func unassignSpeakerName(
        resultID: String,
        speakerID: String
    ) throws -> TranscriptEdits {
        let doc = try loadDocument(resultID: resultID)
        guard doc.speakers.contains(where: { $0.id == speakerID }) else {
            throw TranscriptEditsError.invalidReference("Unknown speakerID: \(speakerID)")
        }

        let turnsInGroup = doc.turns.filter { $0.speakerID == speakerID }
        return try editsRepository.mutateOverrides(resultID: resultID) { currentOverrides in
            for turn in turnsInGroup {
                if let prior = currentOverrides[turn.id], prior.displayName != nil {
                    currentOverrides[turn.id] = TranscriptTurnOverride(text: prior.text, displayName: nil)
                }
            }
        }
    }

    /// Unassigns manual display names for all turns in a voice group identified by `voice`, preserving any corrected text overrides.
    public func unassignSpeakerName(
        resultID: String,
        voice: TranscriptVoiceKey
    ) throws -> TranscriptEdits {
        let doc = try loadDocument(resultID: resultID)
        guard let speaker = doc.speakers.first(where: { $0.sourceID == voice.sourceID && $0.localID == voice.localID }) else {
            throw TranscriptEditsError.invalidReference("Unknown voice: source=\(voice.sourceID), localID=\(voice.localID)")
        }
        return try unassignSpeakerName(resultID: resultID, speakerID: speaker.id)
    }

    /// Generates preview statistics for assigning a speaker name to a voice group.
    public func previewGroupAssignment(
        resultID: String,
        speakerID: String,
        replaceManuallyAssigned: Bool
    ) throws -> TranscriptBulkAssignmentPreview {
        let doc = try loadDocument(resultID: resultID)
        guard let speaker = doc.speakers.first(where: { $0.id == speakerID }) else {
            throw TranscriptEditsError.invalidReference("Unknown speakerID: \(speakerID)")
        }

        let currentEdits: TranscriptEdits
        if let existing = editsRepository.loadedSnapshot(for: resultID)?.edits {
            currentEdits = existing
        } else {
            currentEdits = try editsRepository.loadEdits(resultID: resultID)
        }
        let turnsInGroup = doc.turns.filter { $0.speakerID == speakerID }

        var replacedTurnIDs: Set<String> = []
        var affectedTurnIDs: Set<String> = []
        for turn in turnsInGroup {
            let hasManual = currentEdits.overrides[turn.id]?.displayName != nil
            if hasManual {
                replacedTurnIDs.insert(turn.id)
                if replaceManuallyAssigned {
                    affectedTurnIDs.insert(turn.id)
                }
            } else {
                affectedTurnIDs.insert(turn.id)
            }
        }

        let replacedCount = replaceManuallyAssigned ? replacedTurnIDs.count : 0
        return TranscriptBulkAssignmentPreview(
            recordingDirectory: editsRepository.recordingDirectory,
            resultID: resultID,
            sourceID: speaker.sourceID,
            localID: speaker.localID,
            speakerID: speaker.id,
            revision: currentEdits.revision,
            replaceManuallyAssigned: replaceManuallyAssigned,
            totalTurnsInGroup: turnsInGroup.count,
            affectedTurnsCount: affectedTurnIDs.count,
            replacedManualAssignmentsCount: replacedCount,
            targetTurnIDs: Set(turnsInGroup.map(\.id)),
            affectedTurnIDs: affectedTurnIDs,
            replacedTurnIDs: replacedTurnIDs,
            snapshotOverrides: currentEdits.overrides
        )
    }

    /// Generates preview statistics for assigning a speaker name to a voice group identified by `voice`.
    public func previewGroupAssignment(
        resultID: String,
        voice: TranscriptVoiceKey,
        replaceManuallyAssigned: Bool
    ) throws -> TranscriptBulkAssignmentPreview {
        let doc = try loadDocument(resultID: resultID)
        guard let speaker = doc.speakers.first(where: { $0.sourceID == voice.sourceID && $0.localID == voice.localID }) else {
            throw TranscriptEditsError.invalidReference("Unknown voice: source=\(voice.sourceID), localID=\(voice.localID)")
        }
        return try previewGroupAssignment(
            resultID: resultID,
            speakerID: speaker.id,
            replaceManuallyAssigned: replaceManuallyAssigned
        )
    }
}

// MARK: - TranscriptReviewSession Controller API Integration

extension TranscriptReviewSession {
    public var speakerAssignmentService: TranscriptSpeakerAssignmentService {
        TranscriptSpeakerAssignmentService(editsRepository: editsRepository)
    }

    public func assignSpeakerName(
        turnID: String,
        displayName: String
    ) throws -> TranscriptEdits {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try speakerAssignmentService.assignSpeakerName(
            resultID: activeResultID,
            turnID: turnID,
            displayName: displayName
        )
    }

    public func assignSpeakerName(
        speakerID: String,
        displayName: String,
        replaceManuallyAssigned: Bool
    ) throws -> TranscriptEdits {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try speakerAssignmentService.assignSpeakerName(
            resultID: activeResultID,
            speakerID: speakerID,
            displayName: displayName,
            replaceManuallyAssigned: replaceManuallyAssigned
        )
    }

    public func assignSpeakerName(
        voice: TranscriptVoiceKey,
        displayName: String,
        replaceManuallyAssigned: Bool
    ) throws -> TranscriptEdits {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try speakerAssignmentService.assignSpeakerName(
            resultID: activeResultID,
            voice: voice,
            displayName: displayName,
            replaceManuallyAssigned: replaceManuallyAssigned
        )
    }

    public func assignSpeakerName(
        preview: TranscriptBulkAssignmentPreview,
        displayName: String
    ) throws -> TranscriptEdits {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        guard preview.resultID == activeResultID else {
            throw TranscriptEditsError.conflict("Preview is for version \(preview.resultID), but active version is \(activeResultID)")
        }
        return try speakerAssignmentService.assignSpeakerName(
            preview: preview,
            displayName: displayName
        )
    }

    public func unassignSpeakerName(turnID: String) throws -> TranscriptEdits {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try speakerAssignmentService.unassignSpeakerName(
            resultID: activeResultID,
            turnID: turnID
        )
    }

    public func unassignSpeakerName(speakerID: String) throws -> TranscriptEdits {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try speakerAssignmentService.unassignSpeakerName(
            resultID: activeResultID,
            speakerID: speakerID
        )
    }

    public func unassignSpeakerName(voice: TranscriptVoiceKey) throws -> TranscriptEdits {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try speakerAssignmentService.unassignSpeakerName(
            resultID: activeResultID,
            voice: voice
        )
    }

    public func previewGroupAssignment(
        speakerID: String,
        replaceManuallyAssigned: Bool
    ) throws -> TranscriptBulkAssignmentPreview {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try speakerAssignmentService.previewGroupAssignment(
            resultID: activeResultID,
            speakerID: speakerID,
            replaceManuallyAssigned: replaceManuallyAssigned
        )
    }

    public func previewGroupAssignment(
        voice: TranscriptVoiceKey,
        replaceManuallyAssigned: Bool
    ) throws -> TranscriptBulkAssignmentPreview {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try speakerAssignmentService.previewGroupAssignment(
            resultID: activeResultID,
            voice: voice,
            replaceManuallyAssigned: replaceManuallyAssigned
        )
    }

    public func undo() throws -> TranscriptEdits {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try editsRepository.undo(resultID: activeResultID)
    }
}
