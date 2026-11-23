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

public enum TranscriptNameAssignmentScope: Equatable, Sendable {
    case single, remaining, group
}

public enum TranscriptPersonSelection: Equatable, Sendable {
    case asEntered
    case explicit(UUID?)
    case confirmed(TranscriptVoicePersonIntent)
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
    public let anchorTurnID: String?
    public let confirmedName: String?
    public let scope: TranscriptNameAssignmentScope?
    public let personID: UUID?
    fileprivate let personSelection: TranscriptPersonSelection
    fileprivate let nameOrigin: String?

    public var canResolveTypedPerson: Bool {
        personSelection == .asEntered && nameOrigin == "manual" && !affectedTurnIDs.isEmpty
    }

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
        snapshotOverrides: [String: TranscriptTurnOverride] = [:],
        anchorTurnID: String? = nil, confirmedName: String? = nil,
        scope: TranscriptNameAssignmentScope? = nil,
        personID: UUID? = nil,
        personSelection: TranscriptPersonSelection = .asEntered,
        nameOrigin: String? = nil
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
        self.anchorTurnID = anchorTurnID
        self.confirmedName = confirmedName
        self.scope = scope
        self.personID = personID
        self.personSelection = personSelection
        self.nameOrigin = nameOrigin
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

    public static func nameComparisonKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "ru_RU"))
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
            let turn = doc.turns.first { $0.id == turnID }!
            let original = "Speaker \(doc.speakers.first { $0.id == turn.speakerID }?.displayNumber ?? 1)"
            guard (prior?.displayName ?? original) != displayName else { return }
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
                let hasManualName = prior?.protectsNameFromBulkReplacement == true
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
        displayName: String,
        learnVoice: Bool = false,
        typedPerson: TranscriptVoicePersonIntent? = nil
    ) throws -> TranscriptEdits {
        try validateDisplayName(displayName)

        let canonicalServiceDir = editsRepository.recordingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalPreviewDir = preview.recordingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalServiceDir == canonicalPreviewDir else {
            throw TranscriptEditsError.conflict("Preview belongs to recording at \(canonicalPreviewDir.path), but service is bound to \(canonicalServiceDir.path)")
        }

        if let anchor = preview.anchorTurnID, let scope = preview.scope,
           let origin = preview.nameOrigin {
            guard preview.confirmedName == displayName else { throw TranscriptEditsError.conflict("Preview name changed") }
            let intent: TranscriptVoicePersonIntent?
            if case .confirmed(let person) = preview.personSelection { intent = person }
            else if preview.canResolveTypedPerson, learnVoice { intent = typedPerson }
            else { intent = nil }
            return try editsRepository.mutateOverrides(resultID: preview.resultID, learnVoice: learnVoice,
                                                       personIntent: intent) { overrides in
                let current = try previewAssignment(
                    resultID: preview.resultID, anchorTurnID: anchor, scope: scope, displayName: displayName,
                    person: preview.personSelection, replaceManuallyAssigned: preview.replaceManuallyAssigned
                )
                guard current == preview else { throw TranscriptEditsError.conflict("Preview is stale") }
                if let intent, intent.personID != preview.personID {
                    let named = try previewAssignment(resultID: preview.resultID, anchorTurnID: anchor, scope: scope,
                        displayName: displayName, person: .confirmed(intent), replaceManuallyAssigned: preview.replaceManuallyAssigned)
                    guard named.affectedTurnIDs == preview.affectedTurnIDs else {
                        throw TranscriptEditsError.invalidReference("Выберите человека, чтобы проверить изменения назначения.")
                    }
                }
                for id in preview.affectedTurnIDs {
                    overrides[id] = TranscriptTurnOverride(
                        text: overrides[id]?.text, displayName: displayName,
                        assignment: TranscriptNameAssignment(personID: intent?.personID ?? preview.personID, origin: origin)
                    )
                }
            }
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
                if currentOverrides[turn.id]?.protectsNameFromBulkReplacement == true {
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

    public func previewRemainingAssignment(
        resultID: String, anchorTurnID: String, displayName: String, replaceManuallyAssigned: Bool = false
    ) throws -> TranscriptBulkAssignmentPreview {
        try previewAssignment(
            resultID: resultID, anchorTurnID: anchorTurnID, scope: .remaining,
            displayName: displayName, replaceManuallyAssigned: replaceManuallyAssigned
        )
    }

    public func previewAssignment(
        resultID: String,
        anchorTurnID: String,
        scope: TranscriptNameAssignmentScope,
        displayName: String,
        person: TranscriptPersonSelection = .asEntered,
        replaceManuallyAssigned: Bool = false
    ) throws -> TranscriptBulkAssignmentPreview {
        try validateDisplayName(displayName)
        let doc = try loadDocument(resultID: resultID)
        guard let anchor = doc.turns.firstIndex(where: { $0.id == anchorTurnID }),
              let speaker = doc.speakers.first(where: { $0.id == doc.turns[anchor].speakerID }) else {
            throw TranscriptEditsError.invalidReference(anchorTurnID)
        }
        let turns: [TranscriptDocument.Turn]
        switch scope {
        case .single: turns = [doc.turns[anchor]]
        case .remaining: turns = doc.turns[anchor...].filter { $0.speakerID == speaker.id }
        case .group: turns = doc.turns.filter { $0.speakerID == speaker.id }
        }
        let edits = try editsRepository.loadedSnapshot(for: resultID)?.edits ?? editsRepository.loadEdits(resultID: resultID)
        let source = edits.overrides[anchorTurnID]
        let machinePersonID = source?.assignment?.isMachineAssigned == true ? source?.assignment?.personID : nil
        let nameKey = Self.nameComparisonKey(displayName)
        let resolvedPersonID: UUID?
        let comparesIdentity: Bool
        switch person {
        case .asEntered:
            resolvedPersonID = (source?.displayName).map(Self.nameComparisonKey) == nameKey ? source?.assignment?.personID : nil
            comparesIdentity = resolvedPersonID != nil
        case .explicit(let personID):
            resolvedPersonID = personID
            comparesIdentity = true
        case .confirmed(let intent):
            guard (intent.nameToCreate.map(Self.nameComparisonKey) ?? nameKey) == nameKey else {
                throw TranscriptEditsError.conflict("Имя нового человека изменилось.")
            }
            resolvedPersonID = intent.personID
            comparesIdentity = true
        }
        let keepsMachineOrigin = resolvedPersonID != nil && resolvedPersonID == machinePersonID
        let candidates = turns.filter { turn in
            let prior = edits.overrides[turn.id]
            let name = prior?.displayName ?? "Speaker \(speaker.displayNumber)"
            return name != displayName || (comparesIdentity && prior?.assignment?.personID != resolvedPersonID)
        }
        let protected = Set(candidates.filter { edits.overrides[$0.id]?.protectsNameFromBulkReplacement == true }.map(\.id))
        let mayReplace = scope == .single || replaceManuallyAssigned
        let affected = Set(candidates.map(\.id)).subtracting(mayReplace ? [] : protected)
        return TranscriptBulkAssignmentPreview(recordingDirectory: editsRepository.recordingDirectory, resultID: resultID,
            sourceID: speaker.sourceID, localID: speaker.localID, speakerID: speaker.id, revision: edits.revision,
            replaceManuallyAssigned: replaceManuallyAssigned, totalTurnsInGroup: turns.count, affectedTurnsCount: affected.count,
            replacedManualAssignmentsCount: mayReplace ? protected.count : 0,
            targetTurnIDs: Set(turns.map(\.id)), affectedTurnIDs: affected,
            replacedTurnIDs: protected, snapshotOverrides: edits.overrides, anchorTurnID: anchorTurnID, confirmedName: displayName,
            scope: scope, personID: resolvedPersonID, personSelection: person,
            nameOrigin: keepsMachineOrigin ? "derivedVoiceMatch" : "manual")
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
            let hasManual = currentEdits.overrides[turn.id]?.protectsNameFromBulkReplacement == true
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
        displayName: String,
        learnVoice: Bool = false,
        typedPerson: TranscriptVoicePersonIntent? = nil
    ) throws -> TranscriptEdits {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        guard preview.resultID == activeResultID else {
            throw TranscriptEditsError.conflict("Preview is for version \(preview.resultID), but active version is \(activeResultID)")
        }
        return try speakerAssignmentService.assignSpeakerName(
            preview: preview,
            displayName: displayName,
            learnVoice: learnVoice,
            typedPerson: typedPerson
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

    public func previewRemainingAssignment(
        anchorTurnID: String, displayName: String, replaceManuallyAssigned: Bool = false
    ) throws -> TranscriptBulkAssignmentPreview {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try speakerAssignmentService.previewRemainingAssignment(
            resultID: activeResultID, anchorTurnID: anchorTurnID, displayName: displayName,
            replaceManuallyAssigned: replaceManuallyAssigned
        )
    }

    public func previewAssignment(
        anchorTurnID: String,
        scope: TranscriptNameAssignmentScope,
        displayName: String,
        person: TranscriptPersonSelection = .asEntered,
        replaceManuallyAssigned: Bool = false
    ) throws -> TranscriptBulkAssignmentPreview {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try speakerAssignmentService.previewAssignment(
            resultID: activeResultID, anchorTurnID: anchorTurnID, scope: scope,
            displayName: displayName, person: person, replaceManuallyAssigned: replaceManuallyAssigned
        )
    }

    public func undo() throws -> TranscriptEdits {
        guard !isClosed else { throw TranscriptReviewSessionError.closed }
        return try editsRepository.undo(resultID: activeResultID)
    }
}
