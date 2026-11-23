import CryptoKit
import Foundation
import MeetingCompanionCore

public final class VoiceLearningCoordinator: @unchecked Sendable {
    public enum PersonChoice: Sendable {
        case existing(UUID)
        case new(UUID)
    }

    public let catalogue: VoiceProfileCatalogueRepository
    private let lock = NSLock()
    private struct FailureKey: Hashable {
        let locator: String
        let resultID: String?
    }
    private var failures: [FailureKey: String] = [:]
    private var libraryRecoveryID: UUID?
    private var libraryRecovered = false
    private var enabledGeneration: UUID?
    private var learningInFlight: Set<UUID> = []
    private var learningObserver: (@Sendable () -> Void)?

    public init(catalogue: VoiceProfileCatalogueRepository) {
        self.catalogue = catalogue
    }

    public var hasReconciliationFailures: Bool { lock.withLock { !failures.isEmpty } }
    public var canMatchVoices: Bool { lock.withLock { libraryRecovered && failures.isEmpty } }
    public var isEnabled: Bool { lock.withLock { enabledGeneration != nil } }
    public var featureGeneration: UUID? { lock.withLock { enabledGeneration } }
    public var completedLibraryGeneration: UUID? {
        lock.withLock { libraryRecovered ? libraryRecoveryID : nil }
    }
    public var matchingLibraryGeneration: UUID? {
        lock.withLock { libraryRecovered && failures.isEmpty ? libraryRecoveryID : nil }
    }

    public func setLearningObserver(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { learningObserver = observer }
    }

    public func setEnabled(_ enabled: Bool, generation: UUID? = nil) {
        lock.withLock {
            if enabled {
                if enabledGeneration == nil { enabledGeneration = generation ?? UUID() }
            } else {
                enabledGeneration = nil
            }
        }
    }

    public enum AutomaticAssignmentOutcome: Equatable, Sendable {
        case applied, skippedFeatureDisabled, skippedLibraryUnavailable, skippedInsufficientProfiles, skippedNoStructuredResult
    }

    public func automaticallyAssign(
        recordingURL: URL, resultID: String, processing: ProcessingService, policy: VoiceMatchPolicy,
        expectedLibraryGeneration: UUID? = nil, expectedFeatureGeneration: UUID? = nil
    ) async throws {
        _ = try await automaticallyAssign(
            recordingURL: recordingURL,
            resultID: resultID,
            policy: policy,
            expectedLibraryGeneration: expectedLibraryGeneration,
            expectedFeatureGeneration: expectedFeatureGeneration
        ) { request in
            try await processing.extractVoiceEmbeddings(request, recordingURL: recordingURL, kind: .automaticAssignment)
        }
    }

    @discardableResult
    public func automaticallyAssign(
        recordingURL: URL, resultID: String, policy: VoiceMatchPolicy,
        expectedLibraryGeneration: UUID? = nil, expectedFeatureGeneration: UUID? = nil,
        openWriter: TranscriptEditsRepository? = nil,
        extract: @escaping @Sendable (VoiceEmbeddingProtocol.Request) async throws -> VoiceEmbeddingProtocol.Response
    ) async throws -> AutomaticAssignmentOutcome {
        enum Precondition { case ok(UUID, UUID), disabled, libraryUnavailable }
        let check = lock.withLock { () -> Precondition in
            guard let enabledGeneration,
                  expectedFeatureGeneration == nil || expectedFeatureGeneration == enabledGeneration else {
                return .disabled
            }
            guard libraryRecovered, failures.isEmpty, let libraryRecoveryID,
                  expectedLibraryGeneration == nil || expectedLibraryGeneration == libraryRecoveryID else {
                return .libraryUnavailable
            }
            return .ok(enabledGeneration, libraryRecoveryID)
        }
        let (enabled, recovery): (UUID, UUID)
        switch check {
        case .disabled: return .skippedFeatureDisabled
        case .libraryUnavailable: return .skippedLibraryUnavailable
        case .ok(let feature, let library): (enabled, recovery) = (feature, library)
        }

        let baseline = try catalogue.load()
        let hasProfiles = baseline.catalogue.availableAggregates.filter {
            $0.embeddingSpaceID == VoiceEmbeddingProtocol.embeddingSpaceID
        }.count >= 2

        let storage = TranscriptResultStorage(recordingURL: recordingURL)
        guard let result = try storage.currentResultDirectory(), result.lastPathComponent == resultID,
              let document = try storage.currentDocument(), document.resultID == resultID else {
            return .skippedNoStructuredResult
        }
        let quality = try VoiceAudioQuality.load(in: result, for: document)
        let canonicalDirectory = RecordingEntry.canonicalURL(recordingURL).deletingLastPathComponent()
        let sharesWriter = openWriter.map { Self.locator($0.recordingDirectory) == Self.locator(canonicalDirectory) } ?? false
        let writer = Self.writer(in: canonicalDirectory, sharing: openWriter)
        let edits = try writer.loadEdits(resultID: resultID)
        let originalEdits = writer.loadedSnapshot(for: resultID)?.data
        var sourceFingerprints: [TranscriptDocument.SourceID: String] = [:]
        if hasProfiles {
            let qualityBySource = Dictionary(uniqueKeysWithValues: (quality?.sources ?? []).map { ($0.id, $0.fingerprint) })
            let root = writer.recordingDirectory
            for source in document.sources {
                if let fingerprint = qualityBySource[source.id] {
                    sourceFingerprints[source.id] = fingerprint
                } else if let fingerprint = try? Self.audioFingerprint(source.recognitionAudioPath, in: root) {
                    sourceFingerprints[source.id] = fingerprint
                }
            }
        }
        let plan = try VoiceAutomaticAssignment.plan(
            document: document, edits: edits, quality: quality,
            hasProfiles: hasProfiles, sourceFingerprints: sourceFingerprints
        )
        let windows = plan.queries.map(\.window)
        var features: [UUID: VoiceEmbeddingProtocol.Feature] = [:]
        func extractBatched(_ targetWindows: [VoiceEmbeddingProtocol.Window]) async throws -> AutomaticAssignmentOutcome? {
            for start in stride(from: 0, to: targetWindows.count, by: VoiceEmbeddingProtocol.windowLimit) {
                try Task.checkCancellation()
                let currentCheck = lock.withLock { () -> Precondition in
                    guard enabledGeneration == enabled else { return .disabled }
                    guard libraryRecoveryID == recovery, libraryRecovered, failures.isEmpty else { return .libraryUnavailable }
                    return .ok(enabled, recovery)
                }
                switch currentCheck {
                case .disabled: return .skippedFeatureDisabled
                case .libraryUnavailable: return .skippedLibraryUnavailable
                case .ok: break
                }
                let batch = Array(targetWindows[start..<min(start + VoiceEmbeddingProtocol.windowLimit, targetWindows.count)])
                let request = VoiceEmbeddingProtocol.Request(resultID: resultID, windows: batch)
                let response = try await extract(request)
                for feature in response.features { features[feature.windowID] = feature }
            }
            return nil
        }
        if let abortOutcome = try await extractBatched(windows) {
            return abortOutcome
        }
        let contacts = document.context?.calendarParticipants?.map(\.address) ?? []
        let rescuePlan = VoiceAutomaticAssignment.rescuePlan(
            for: plan, responses: features, catalogue: baseline.catalogue,
            edits: edits, contacts: contacts, policy: policy
        )
        if !rescuePlan.extraWindows.isEmpty, let abortOutcome = try await extractBatched(rescuePlan.extraWindows) {
            return abortOutcome
        }
        let overrides = VoiceAutomaticAssignment.overrides(
            for: plan, rescuePlan: rescuePlan, responses: features, catalogue: baseline.catalogue,
            edits: edits, contacts: contacts, policy: policy
        )
        let terminalOutcome: AutomaticAssignmentOutcome = hasProfiles ? .applied : .skippedInsufficientProfiles
        guard !overrides.isEmpty else { return terminalOutcome }

        if !sharesWriter { try writer.acquireWriteLock() }
        defer { if !sharesWriter { writer.releaseWriteLock() } }
        guard try storage.currentResultDirectory()?.lastPathComponent == resultID else {
            return .skippedNoStructuredResult
        }
        _ = try writer.loadEdits(resultID: resultID)
        guard writer.loadedSnapshot(for: resultID)?.data == originalEdits else { return terminalOutcome }
        return try lock.withLock {
            try Task.checkCancellation()
            guard enabledGeneration == enabled else { return .skippedFeatureDisabled }
            guard libraryRecoveryID == recovery, libraryRecovered, failures.isEmpty else { return .skippedLibraryUnavailable }
            func saveOverrides() throws {
                _ = try writer.saveEdits(resultID: resultID, overrides: overrides)
            }
            if hasProfiles {
                try catalogue.withVerifiedSnapshot(baseline, saveOverrides)
            } else {
                // Refusal metadata makes no identity claim and needs no catalogue write or lock.
                try saveOverrides()
            }
            return terminalOutcome
        }
    }

    public func noteLearningFailure(eventID: UUID, reason: String) {
        guard let current = try? catalogue.load(),
              let index = current.catalogue.learningRecords?.firstIndex(where: { $0.id == eventID }),
              let record = current.catalogue.learningRecords?[index], Self.isPending(record, in: current.catalogue) else { return }
        _ = try? catalogue.update(current) { $0.learningRecords?[index].outcome = reason }
    }

    public func resumeCommitted(
        recordings: [URL], processing: ProcessingService, policy: VoiceProfileUpdatePolicy,
        openWriter: TranscriptEditsRepository? = nil, expectedLibraryGeneration: UUID? = nil
    ) async {
        guard let generation = featureGeneration, let library = completedLibraryGeneration,
              expectedLibraryGeneration == nil || expectedLibraryGeneration == library,
              let value = try? catalogue.load().catalogue else { return }
        let permitted = Set(recordings.filter(RecordingPaths.isStandardLayout).map {
            Self.locator(RecordingEntry.canonicalURL($0).deletingLastPathComponent())
        })
        let records = (value.learningRecords ?? []).filter {
            $0.event.personIntent?.featureGeneration == generation && permitted.contains($0.recordingLocator)
        }
        struct Batch: Hashable { let locator: String; let resultID: String; let revision: Int }
        let batches = Dictionary(grouping: records) {
            Batch(locator: $0.recordingLocator, resultID: $0.resultID, revision: $0.event.editsRevision)
        }
        for key in batches.keys.sorted(by: { ($0.locator, $0.resultID, $0.revision) < ($1.locator, $1.resultID, $1.revision) }) {
            guard !Task.isCancelled, completedLibraryGeneration == library, featureGeneration == generation else { return }
            guard let batch = batches[key], batch.contains(where: { $0.outcome == nil && Self.isPending($0, in: value) }) else { continue }
            let directory = URL(fileURLWithPath: key.locator)
            guard failure(for: directory) == nil else { continue }
            let writer = Self.writer(in: directory, sharing: openWriter)
            await learnCommitted(events: batch.map(\.event), writer: writer, processing: processing,
                                 policy: policy, expectedGeneration: generation)
        }
    }

    private static func writer(in directory: URL, sharing openWriter: TranscriptEditsRepository?) -> TranscriptEditsRepository {
        if let openWriter, locator(openWriter.recordingDirectory) == locator(directory) { return openWriter }
        return TranscriptEditsRepository(recordingDirectory: directory)
    }

    public func learnCommitted(
        events: [TranscriptLearningEvent], writer: TranscriptEditsRepository, processing: ProcessingService,
        policy: VoiceProfileUpdatePolicy, expectedGeneration: UUID
    ) async {
        let selected = events.filter(\.allowsLearning)
        let ids = Set(selected.map(\.eventID))
        guard !ids.isEmpty, lock.withLock({
            guard ids.isDisjoint(with: learningInFlight) else { return false }
            learningInFlight.formUnion(ids)
            return true
        }) else { return }
        defer {
            let notify = lock.withLock {
                learningInFlight.subtract(ids)
                return learningObserver
            }
            notify?()
        }
        let baseline = try? catalogue.load().catalogue
        var windowsByPerson: [UUID: Int] = [:]
        var pendingIDs: Set<UUID> = []
        for record in baseline?.learningRecords ?? [] where ids.contains(record.id) {
            if let person = record.event.assignment?.personID {
                windowsByPerson[person, default: 0] += record.extractedWindows ?? 0
            }
            if let baseline, record.outcome == nil, Self.isPending(record, in: baseline) {
                pendingIDs.insert(record.id)
            }
        }
        let plan = Self.learningPlan(selected, reservingDenseFor: pendingIDs, writer: writer)
        var remainingDense: [UUID: Int] = [:]
        for (event, count) in plan {
            if let person = event.assignment?.personID { remainingDense[person, default: 0] += count }
        }
        for (event, denseCount) in plan {
            guard !Task.isCancelled, featureGeneration == expectedGeneration else { return }
            guard let person = event.assignment?.personID else { continue }
            let remaining = max(0, 4 - windowsByPerson[person, default: 0])
            remainingDense[person, default: 0] -= denseCount
            // Only use spare capacity for this turn's sparse windows after reserving later dense windows.
            let limit = remaining - min(max(0, remaining - denseCount), remainingDense[person, default: 0])
            do {
                let processed = try await learn(eventID: event.eventID, writer: writer, processing: processing,
                    policy: policy, expectedGeneration: expectedGeneration, maximumWindows: limit)
                windowsByPerson[person, default: 0] += processed
            } catch is CancellationError {
                return
            } catch {
                windowsByPerson[person] = 4
                if featureGeneration == expectedGeneration {
                    noteLearningFailure(eventID: event.eventID, reason: error.localizedDescription)
                }
            }
        }
    }

    @discardableResult
    public func learn(
        eventID: UUID, writer: TranscriptEditsRepository, processing: ProcessingService,
        policy: VoiceProfileUpdatePolicy, expectedGeneration: UUID? = nil, maximumWindows: Int = 4
    ) async throws -> Int {
        guard let enabled = featureGeneration, expectedGeneration == nil || expectedGeneration == enabled else { return 0 }
        let baseline = try catalogue.load().catalogue
        guard let record = baseline.learningRecords?.first(where: { $0.id == eventID }),
              Self.isPending(record, in: baseline),
              record.outcome == nil,
              record.event.personIntent?.featureGeneration.map({ $0 == enabled }) != false,
              let assignment = record.event.assignment, let personID = assignment.personID,
              record.recordingLocator == Self.locator(writer.recordingDirectory) else { return 0 }

        let root = writer.recordingDirectory
        let recording = root.appendingPathComponent(root.lastPathComponent).appendingPathExtension("m4a")
        let storage = TranscriptResultStorage(recordingURL: recording)
        guard let result = try storage.currentResultDirectory(), result.lastPathComponent == record.resultID,
              let document = try storage.currentDocument(), document.resultID == record.resultID,
              let turn = document.turns.first(where: { $0.id == record.event.turnID }),
              let speaker = document.speakers.first(where: { $0.id == turn.speakerID }),
              let source = document.sources.first(where: { $0.id == speaker.sourceID }),
              try writer.readEditsSnapshot(resultID: record.resultID).edits.overrides[turn.id]?.assignment == assignment else { return 0 }

        var samples: [VoiceProfileSample] = []
        var extractedWindows = 0
        if maximumWindows > 0 {
            let quality = try VoiceAudioQuality.load(in: result, for: document)
            let evidence = quality?.sources.first { $0.id == source.id }
            let fingerprint = try evidence?.fingerprint ?? Self.audioFingerprint(source.recognitionAudioPath, in: root)
            let candidates = Self.learningWindows(turn: turn, source: source, document: document, evidence: evidence,
                                                  fingerprint: fingerprint)
            let windows = Array((candidates.dense + candidates.sparse).prefix(maximumWindows))
            if !windows.isEmpty {
                let rate = Double(VoiceEmbeddingProtocol.sampleRate)
                let meetingFingerprint = try Self.meetingFingerprint(in: root, quality: quality, document: document)
                let request = VoiceEmbeddingProtocol.Request(resultID: record.resultID, windows: windows)
                let response = try await processing.extractVoiceEmbeddings(request, recordingURL: recording, kind: .learning)
                extractedWindows = windows.count
                samples = zip(windows, response.features).compactMap { window, feature in
                    guard let embedding = feature.embedding else { return nil }
                    return .init(personID: personID, embeddingSpaceID: response.embeddingSpaceID, embedding: embedding,
                                 recordingLocator: record.recordingLocator, resultID: record.resultID, turnID: turn.id,
                                 sourceID: window.sourceID, start: Double(window.startFrame) / rate, end: Double(window.endFrame) / rate,
                                 pcmFingerprint: feature.pcmFingerprint, assignment: assignment, policyID: policy.id,
                                 recordingFingerprint: meetingFingerprint)
                }
            }
        }

        try writer.withLockedEditsSnapshot(resultID: record.resultID) { snapshot in
            guard snapshot.edits.overrides[turn.id]?.assignment == assignment,
                  try storage.currentResultDirectory()?.lastPathComponent == record.resultID else { return }
            try lock.withLock {
                try Task.checkCancellation()
                guard enabledGeneration == enabled else { return }
                let current = try catalogue.load()
                guard let index = current.catalogue.learningRecords?.firstIndex(where: { $0.id == record.id }),
                      let latest = current.catalogue.learningRecords?[index], Self.isPending(latest, in: current.catalogue),
                      latest.recordingLocator == record.recordingLocator else { return }
                _ = try catalogue.update(current) { value in
                    let retained = policy.apply(samples, to: &value)
                    value.learningRecords?[index].extractedWindows = extractedWindows
                    value.learningRecords?[index].stage = retained > 0 ? .applied : .skipped
                    if retained > 0 { value.learningRecords?[index].outcome = nil }
                    else if maximumWindows == 0 { value.learningRecords?[index].outcome = "Лимит фрагментов этой правки достигнут." }
                    else if samples.isEmpty { value.learningRecords?[index].outcome = "Недостаточно чистой речи." }
                    else { value.learningRecords?[index].outcome = "Нет новых пригодных эталонов." }
                }
            }
        }
        return extractedWindows
    }

    private static func isPending(_ record: VoiceProfileLearningRecord, in catalogue: VoiceProfileCatalogue) -> Bool {
        record.stage == .committed && record.event.allowsLearning &&
            record.event.personIntent?.catalogueID == catalogue.instanceID &&
            record.catalogueGeneration == catalogue.generation &&
            catalogue.people.contains { $0.id == record.event.assignment?.personID && $0.generation == record.personGeneration }
    }

    private static func learningPlan(
        _ events: [TranscriptLearningEvent],
        reservingDenseFor pendingIDs: Set<UUID>,
        writer: TranscriptEditsRepository
    ) -> [(event: TranscriptLearningEvent, denseCount: Int)] {
        guard pendingIDs.count > 1 else { return events.map { ($0, 0) } }
        let root = writer.recordingDirectory
        let recording = root.appendingPathComponent(root.lastPathComponent).appendingPathExtension("m4a")
        let storage = TranscriptResultStorage(recordingURL: recording)
        guard let result = try? storage.currentResultDirectory(),
              let document = try? storage.currentDocument(),
              result.lastPathComponent == document.resultID else { return events.map { ($0, 0) } }
        let quality = try? VoiceAudioQuality.load(in: result, for: document)
        let speakersByID = Dictionary(uniqueKeysWithValues: document.speakers.map { ($0.id, $0) })
        let sourcesByID = Dictionary(uniqueKeysWithValues: document.sources.map { ($0.id, $0) })
        let turnsByID = Dictionary(uniqueKeysWithValues: document.turns.map { ($0.id, $0) })
        let evidenceByID = Dictionary(uniqueKeysWithValues: (quality?.sources ?? []).map { ($0.id, $0) })
        let syntheticFingerprint = String(repeating: "0", count: 64)
        var dense: [(TranscriptLearningEvent, Int)] = []
        var sparse: [(TranscriptLearningEvent, Int)] = []
        for event in events {
            if pendingIDs.contains(event.eventID), let turn = turnsByID[event.turnID],
               let speaker = speakersByID[turn.speakerID],
               let source = sourcesByID[speaker.sourceID] {
                let evidence = evidenceByID[source.id]
                let fp = evidence?.fingerprint ?? syntheticFingerprint
                let windows = learningWindows(turn: turn, source: source, document: document,
                                              evidence: evidence, fingerprint: fp)
                if !windows.dense.isEmpty {
                    dense.append((event, windows.dense.count))
                    continue
                }
            }
            sparse.append((event, 0))
        }
        return dense + sparse
    }

    private static func learningWindows(
        turn: TranscriptDocument.Turn, source: TranscriptDocument.Source, document: TranscriptDocument,
        evidence: VoiceAudioQuality.Source?, fingerprint: String
    ) -> (dense: [VoiceEmbeddingProtocol.Window], sparse: [VoiceEmbeddingProtocol.Window]) {
        guard case .windows(let intervals) = VoiceWindowSelector.select(turn: turn, source: source, document: document,
            evidence: evidence, actualFingerprint: fingerprint, purpose: .learning) else { return ([], []) }
        let rate = Double(VoiceEmbeddingProtocol.sampleRate)
        let all = intervals.compactMap { interval -> VoiceEmbeddingProtocol.Window? in
            guard let start = Int(exactly: (interval.start * rate).rounded(.up)),
                  let end = Int(exactly: (interval.end * rate).rounded(.down)), start >= 0, end > start,
                  (48_000...96_000).contains(end - start) else { return nil }
            return .init(sourceID: source.id, sourceFingerprint: fingerprint, startFrame: start, endFrame: end)
        }
        var dense: [VoiceEmbeddingProtocol.Window] = [], sparse: [VoiceEmbeddingProtocol.Window] = []
        for window in all {
            if VoiceWindowSelector.isDenseSpeechWindow(
                start: Double(window.startFrame) / rate,
                end: Double(window.endFrame) / rate,
                speakerID: turn.speakerID,
                document: document
            ) {
                dense.append(window)
            } else {
                sparse.append(window)
            }
        }
        return (dense, sparse)
    }

    private static func meetingFingerprint(in root: URL, quality: VoiceAudioQuality?, document: TranscriptDocument) throws -> String {
        try quality?.recordingFingerprint ?? VoiceAudioQuality.recordingFingerprint(
            originalFingerprints: Dictionary(uniqueKeysWithValues: document.sources.map {
                ($0.id, try audioFingerprint($0.originalAudioPath, in: root))
            }))
    }

    private static func audioFingerprint(_ path: String, in root: URL) throws -> String {
        let audio = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard audio.pathComponents.starts(with: root.resolvingSymlinksInPath().standardizedFileURL.pathComponents),
              try audio.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw TranscriptEditsError.invalidReference("Исходная дорожка недоступна.")
        }
        let handle = try FileHandle(forReadingFrom: audio)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func failure(for recordingDirectory: URL) -> String? {
        let locator = Self.locator(recordingDirectory)
        return lock.withLock { failures.first { $0.key.locator == locator }?.value }
    }

    public func personSelection(_ choice: PersonChoice, displayName: String) throws -> TranscriptPersonSelection {
        .confirmed(try personIntent(choice, displayName: displayName, catalogue: catalogueWithIdentity()))
    }

    public func personForManuallyEnteredName(_ displayName: String) throws -> TranscriptVoicePersonIntent? {
        let value = try catalogueWithIdentity()
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = TranscriptSpeakerAssignmentService.nameComparisonKey(name)
        let matches = value.people.filter {
            TranscriptSpeakerAssignmentService.nameComparisonKey($0.displayName) == key
        }
        guard matches.count <= 1 else { return nil }
        let choice = matches.first.map { PersonChoice.existing($0.id) } ?? .new(UUID())
        return try personIntent(choice, displayName: name, catalogue: value)
    }

    private func catalogueWithIdentity() throws -> VoiceProfileCatalogue {
        let snapshot = try catalogue.load()
        return snapshot.catalogue.instanceID != nil ? snapshot.catalogue : try catalogue.update(snapshot) { _ in }.catalogue
    }

    private func personIntent(_ choice: PersonChoice, displayName: String,
                              catalogue value: VoiceProfileCatalogue) throws -> TranscriptVoicePersonIntent {
        guard let catalogueID = value.instanceID else { throw VoiceProfileCatalogueError.malformed }
        switch choice {
        case .existing(let id):
            guard let person = value.people.first(where: { $0.id == id }) else {
                throw TranscriptEditsError.invalidReference("Человек больше не доступен.")
            }
            return .init(personID: id, nameToCreate: nil, catalogueID: catalogueID,
                         catalogueGeneration: value.generation, personGeneration: person.generation,
                         featureGeneration: featureGeneration)
        case .new(let id):
            guard !value.people.contains(where: { $0.id == id }), value.deletedPersonIDs?.contains(id) != true,
                  !displayName.allSatisfy(\.isWhitespace) else {
                throw TranscriptEditsError.invalidReference("Укажите имя нового человека.")
            }
            return .init(personID: id, nameToCreate: displayName, catalogueID: catalogueID,
                         catalogueGeneration: value.generation, personGeneration: 0, featureGeneration: featureGeneration)
        }
    }

    public func resetPerson(_ personID: UUID, delete: Bool) throws {
        _ = try catalogue.update(catalogue.load()) { value in
            guard let index = value.people.firstIndex(where: { $0.id == personID }) else {
                throw TranscriptEditsError.invalidReference("Человек больше не доступен.")
            }
            value.samples.removeAll { $0.personID == personID }
            value.aggregates.removeAll { $0.personID == personID }
            value.seenSamples?.removeValue(forKey: personID)
            if delete {
                value.people.remove(at: index)
                value.deletedPersonIDs = (value.deletedPersonIDs ?? []).union([personID])
            } else {
                guard value.people[index].generation < UInt64.max else { throw VoiceProfileCatalogueError.malformed }
                value.people[index].generation += 1
                value.people[index].calendarBindings.removeAll()
            }
        }
    }

    public func deleteCatalogue() throws {
        _ = try catalogue.update(catalogue.load()) { value in
            guard value.generation < UInt64.max else { throw VoiceProfileCatalogueError.malformed }
            value.generation += 1
            value.people.removeAll()
            value.samples.removeAll()
            value.aggregates.removeAll()
            value.learningRecords = nil
            value.deletedPersonIDs = nil
            value.seenSamples = nil
        }
    }

    public func confirmCalendarBinding(personID: UUID, address: String, in document: TranscriptDocument) throws {
        let matches = document.context?.calendarParticipants?.filter { $0.address == address } ?? []
        guard matches.count == 1 else {
            throw TranscriptEditsError.invalidReference("Контакт участника встречи неоднозначен.")
        }
        _ = try catalogue.update(catalogue.load()) { value in
            guard let index = value.people.firstIndex(where: { $0.id == personID }) else {
                throw TranscriptEditsError.invalidReference("Человек больше не доступен.")
            }
            guard !value.people.contains(where: { $0.id != personID && $0.calendarBindings.contains(address) }) else {
                throw TranscriptEditsError.conflict("Контакт уже привязан к другому человеку.")
            }
            if !value.people[index].calendarBindings.contains(address) {
                value.people[index].calendarBindings.append(address)
            }
        }
    }

    public func observe(_ phase: TranscriptEditsRepository.LearningCommitPhase,
                        _ commit: TranscriptEditsRepository.LearningCommit) {
        let locator = Self.locator(commit.recordingDirectory)
        do {
            switch phase {
            case .preparing:
                try prepare(commit, locator: locator)
            case .committed:
                try confirmTransfer(commit.saved, locator: locator)
            case .aborted:
                try discardUncommitted(commit.events)
            }
        } catch {
            let key = FailureKey(locator: locator, resultID: commit.saved.edits.resultID)
            lock.withLock { failures[key] = error.localizedDescription }
        }
    }

    private func discardUncommitted(_ events: [TranscriptLearningEvent]) throws {
        let snapshot = try catalogue.load()
        let ids = Set(events.map(\.eventID))
        guard (snapshot.catalogue.learningRecords ?? []).contains(where: { ids.contains($0.id) && $0.stage == .prepared }) else {
            return
        }
        _ = try catalogue.update(snapshot) { value in
            guard var records = value.learningRecords else { return }
            for index in records.indices where ids.contains(records[index].id) && records[index].stage == .prepared {
                records[index].stage = .aborted
            }
            value.learningRecords = records
        }
    }

    public func reconcile(writer: TranscriptEditsRepository, resultID: String) throws {
        let locator = Self.locator(writer.recordingDirectory)
        let key = FailureKey(locator: locator, resultID: resultID)
        do {
            try writer.withLockedEditsSnapshot(resultID: resultID) {
                try confirmTransfer($0, locator: locator)
            }
        } catch {
            lock.withLock { failures[key] = error.localizedDescription }
            throw error
        }
    }

    private func confirmTransfer(_ snapshot: TranscriptEditsRepository.LoadedSnapshot, locator: String) throws {
        let resultID = snapshot.edits.resultID
        let value = try transfer(snapshot, locator: locator)
        guard !(value.learningRecords ?? []).contains(where: {
            $0.recordingLocator == locator && $0.resultID == resultID && $0.stage == .prepared
        }) else {
            throw TranscriptEditsError.conflict("Не удалось подтвердить исход сохранения имени.")
        }
        lock.withLock { _ = failures.removeValue(forKey: FailureKey(locator: locator, resultID: resultID)) }
    }

    public func preserveOutboxes(recording: URL, writer: TranscriptEditsRepository, includeHistory: Bool) throws {
        try writer.acquireWriteLock()
        let storage = TranscriptResultStorage(recordingURL: recording)
        let results = try storage.publishedResultDirectories()
        for result in includeHistory ? results : Array(results.prefix(1)) {
            let resultID = result.lastPathComponent
            if try !writer.hasStoredEdits(resultID: resultID) {
                let locator = Self.locator(writer.recordingDirectory)
                let pending = try catalogue.load().catalogue.learningRecords ?? []
                guard pending.contains(where: {
                    $0.stage == .prepared && $0.recordingLocator == locator && $0.resultID == resultID
                }) else { continue }
            }
            try reconcile(writer: writer, resultID: resultID)
        }
    }

    public func beginLibraryReconciliation() -> UUID {
        let id = UUID()
        lock.withLock {
            libraryRecoveryID = id
            libraryRecovered = false
        }
        return id
    }

    public func reconcileLibrary(recordings: [URL], scanComplete: Bool, id: UUID,
                                 openWriters: [TranscriptEditsRepository] = []) {
        guard scanComplete, lock.withLock({ libraryRecoveryID == id }),
              let value = try? catalogue.load().catalogue else { return }
        let references = value.samples.map(\.recordingLocator) +
            (value.learningRecords ?? []).filter { $0.stage == .prepared }.map(\.recordingLocator)
        let referencedRecordings = references.compactMap { path -> URL? in
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
            return directory.appendingPathComponent(directory.lastPathComponent).appendingPathExtension("m4a")
        }
        for recording in Set(recordings + referencedRecordings) {
            guard lock.withLock({ libraryRecoveryID == id }) else { return }
            guard RecordingPaths.isStandardLayout(recording) else { continue }
            let storage = TranscriptResultStorage(recordingURL: recording)
            let locator = Self.locator(storage.recordingDirectory)
            let key = FailureKey(locator: locator, resultID: nil)
            let results: [URL]
            do {
                results = try storage.publishedResultDirectories()
                lock.withLock { _ = failures.removeValue(forKey: key) }
            } catch {
                lock.withLock { failures[key] = error.localizedDescription }
                continue
            }
            guard !results.isEmpty else { continue }
            let writer = openWriters.first { Self.locator($0.recordingDirectory) == locator }
                ?? TranscriptEditsRepository(recordingDirectory: storage.recordingDirectory)
            for result in results {
                guard lock.withLock({ libraryRecoveryID == id }) else { return }
                // Reconcile records errors for the precise result without a second, recording-wide entry.
                do { try reconcile(writer: writer, resultID: result.lastPathComponent) }
                catch { break }
            }
        }
        lock.withLock {
            if libraryRecoveryID == id { libraryRecovered = true }
        }
    }

    private func prepare(_ commit: TranscriptEditsRepository.LearningCommit, locator: String) throws {
        let previous = Self.fingerprint(commit.previous.data)
        let saved = Self.fingerprint(commit.saved.data)
        _ = try catalogue.update(catalogue.load()) { value in
            var records = value.learningRecords ?? []
            for event in commit.events {
                let person = value.people.first { $0.id == event.assignment?.personID }
                records.append(VoiceProfileLearningRecord(
                    event: event, recordingLocator: locator, resultID: commit.saved.edits.resultID,
                    previousFingerprint: previous, savedFingerprint: saved, catalogueGeneration: value.generation,
                    personGeneration: event.personIntent?.personGeneration ?? person?.generation, stage: .prepared
                ))
            }
            value.learningRecords = records
        }
    }

    private func transfer(_ snapshot: TranscriptEditsRepository.LoadedSnapshot, locator: String) throws -> VoiceProfileCatalogue {
        let edits = snapshot.edits
        let fingerprint = Self.fingerprint(snapshot.data)
        let outbox = edits.pendingLearningEvents ?? []
        let savedEvents = Dictionary(uniqueKeysWithValues: outbox.map { ($0.eventID, $0) })
        let eventsByTurn = Dictionary(grouping: outbox, by: \.turnID)
        let latestByTurn = Dictionary(outbox.map { ($0.turnID, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.editsRevision > rhs.editsRevision ? lhs : rhs
        })
        let baseline = try catalogue.load()
        guard !outbox.isEmpty || (baseline.catalogue.learningRecords ?? []).contains(where: {
            $0.recordingLocator == locator && $0.resultID == edits.resultID && $0.stage == .prepared
        }) else { return baseline.catalogue }

        return try catalogue.update(baseline) { value in
            var records = value.learningRecords ?? []
            var revocations: Set<UUID> = []
            for index in records.indices where records[index].resultID == edits.resultID {
                let record = records[index]
                guard record.recordingLocator == locator || savedEvents[record.id] != nil else { continue }
                guard record.stage == .prepared || record.stage == .committed else { continue }
                if let savedEvent = savedEvents[record.id] {
                    guard savedEvent == record.event else {
                        throw TranscriptEditsError.conflict("Изменилось отложенное событие назначения имени.")
                    }
                    if record.stage == .prepared, let revoked = record.event.previousAssignment?.assignmentID {
                        revocations.insert(revoked)
                    }
                    records[index].recordingLocator = locator
                    let stillCurrent = latestByTurn[record.event.turnID]?.eventID == record.id &&
                        edits.overrides[record.event.turnID]?.assignment == record.event.assignment
                    if !stillCurrent {
                        records[index].stage = .superseded
                    } else {
                        let generationMatches: Bool
                        generationMatches = record.event.personIntent.map {
                            Self.confirm($0, in: &value, allowCreation: record.stage == .prepared)
                        } ?? false
                        records[index].stage = generationMatches && record.event.allowsLearning ? .committed : .skipped
                    }
                } else if record.stage == .prepared {
                    let later = (eventsByTurn[record.event.turnID] ?? []).filter {
                        $0.editsRevision >= record.event.editsRevision
                    }
                    let saved = edits.overrides[record.event.turnID]
                    let previous = saved?.assignment ?? saved?.legacyImportAssignment(
                        resultID: edits.resultID, turnID: record.event.turnID, personID: nil)
                    if record.previousFingerprint == fingerprint ||
                        (edits.revision >= record.event.editsRevision &&
                            previous == record.event.previousAssignment) ||
                        later.contains(where: { $0.previousAssignment == record.event.previousAssignment }) {
                        records[index].stage = .aborted
                    } else if later.contains(where: { $0.previousAssignment == record.event.assignment }) {
                        if let revoked = record.event.previousAssignment?.assignmentID { revocations.insert(revoked) }
                        records[index].stage = .superseded
                    }
                }
            }
            let transferredIDs = Set(records.map(\.id))
            for event in outbox where !transferredIDs.contains(event.eventID) {
                if let revoked = event.previousAssignment?.assignmentID { revocations.insert(revoked) }
                let intent = event.personIntent
                let stillCurrent = latestByTurn[event.turnID]?.eventID == event.eventID &&
                    edits.overrides[event.turnID]?.assignment == event.assignment
                let confirmed = stillCurrent && (intent.map { Self.confirm($0, in: &value, allowCreation: true) } ?? false)
                records.append(VoiceProfileLearningRecord(
                    event: event, recordingLocator: locator, resultID: edits.resultID,
                    previousFingerprint: nil, savedFingerprint: fingerprint, catalogueGeneration: value.generation,
                    personGeneration: intent?.personGeneration,
                    stage: confirmed && event.allowsLearning ? .committed : .skipped
                ))
            }
            value.revokeSamples(assignments: revocations)
            value.learningRecords = records
        }.catalogue
    }

    private static func confirm(_ intent: TranscriptVoicePersonIntent, in catalogue: inout VoiceProfileCatalogue,
                                allowCreation: Bool) -> Bool {
        guard let catalogueID = intent.catalogueID, catalogue.instanceID == catalogueID,
              catalogue.generation == intent.catalogueGeneration,
              catalogue.deletedPersonIDs?.contains(intent.personID) != true else { return false }
        if let existing = catalogue.people.first(where: { $0.id == intent.personID }) {
            return existing.generation == intent.personGeneration &&
                (intent.nameToCreate == nil || existing.displayName == intent.nameToCreate)
        }
        guard allowCreation, let name = intent.nameToCreate, intent.personGeneration == 0 else { return false }
        catalogue.people.append(.init(id: intent.personID, displayName: name))
        return true
    }

    private static func locator(_ directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func fingerprint(_ bytes: Data?) -> String? {
        bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}
