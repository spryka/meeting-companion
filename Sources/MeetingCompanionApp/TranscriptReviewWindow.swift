import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if !TRANSCRIPT_WINDOW_HARNESS
import MeetingCompanionCore
import MeetingCompanionPlatform
#endif

@MainActor
final class TranscriptReviewWindowManager: ObservableObject {
    let coordinator = TranscriptWindowCoordinator()
    private let isProcessing: @Sendable (URL) async -> Bool
    private let transportFactory: @MainActor () -> any TranscriptPlaybackTransport
    @Published private(set) var current: TranscriptReviewWindowModel?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published var externalModal = false
    var settingsInput: @MainActor () -> Bool = { false }
    @Published var savedRevision = 0
    @Published private(set) var commandNotice: String?
    private var generation = 0
    private var opening: Task<TranscriptReviewWindowModel, Error>?
    private var openingURL: URL?
    var hasForeignInput: Bool { externalModal || current?.currentDraftIdentity != nil }
    var hasInput: Bool { settingsInput() || hasForeignInput }

    func admitNavigation() -> Bool {
        guard !hasInput else {
            commandNotice = "Сохраните или отмените ввод перед этим действием."
            current?.rejectConflictingAction()
            return false
        }
        commandNotice = nil
        return true
    }

    init(isProcessing: @escaping @Sendable (URL) async -> Bool = { _ in false },
         transportFactory: @escaping @MainActor () -> any TranscriptPlaybackTransport = { TranscriptAVPlayerTransport() }) {
        self.isProcessing = isProcessing
        self.transportFactory = transportFactory
    }

    func prepareForRetry(_ recording: URL) async -> Bool {
        guard admitNavigation() else { return false }
        generation += 1
        let expected = generation
        _ = try? await opening?.value
        guard expected == generation, admitNavigation() else { return false }
        opening = nil; openingURL = nil; loading = false
        if let current, current.state.id == RecordingEntry.canonicalURL(recording) { closeCurrent() }
        return true
    }

    @discardableResult
    func open(recordingURL: URL, title: String) async throws -> TranscriptReviewWindowModel {
        guard admitNavigation() else { throw TranscriptEditsError.conflict("Сохраните или отмените ввод.") }
        let key = RecordingEntry.canonicalURL(recordingURL)
        if openingURL == key, let opening { return try await opening.value }
        generation += 1
        let expected = generation
        guard !(await isProcessing(key)) else { throw TranscriptWindowError.readOnlyLegacy("Идёт обработка; откройте текст после её завершения.") }
        guard expected == generation else { throw TranscriptWindowError.closed }
        guard admitNavigation() else { throw TranscriptEditsError.conflict("Сохраните или отмените ввод.") }
        if let current, current.state.id == key, !current.state.isClosed { return current }
        let previous = opening
        loading = true; failure = nil; openingURL = key
        let task = Task { [self] in
            _ = try? await previous?.value
            guard expected == generation, !hasInput else { throw TranscriptWindowError.closed }
            closeLoadedSession()
            let state = try await coordinator.openWindow(for: key).state
            do {
                let model = try await TranscriptReviewWindowModel(state: state, transportFactory: transportFactory)
                model.inputBlocked = { [weak self] in self?.settingsInput() ?? true }
                let processing = await isProcessing(key)
                guard expected == generation, !hasInput, !state.isClosed, !processing else {
                    model.close(); throw TranscriptWindowError.closed
                }
                model.onSaved = { [weak self] in self?.savedRevision += 1 }
                current = model
                return model
            } catch { state.close(); throw error }
        }
        opening = task
        do {
            let model = try await task.value
            if expected == generation { loading = false; opening = nil; openingURL = nil }
            return model
        } catch {
            if expected == generation { loading = false; opening = nil; openingURL = nil; failure = error.localizedDescription }
            throw error
        }
    }

    func closeCurrent() {
        guard admitNavigation() else { return }
        generation += 1
        loading = false; openingURL = nil
        closeLoadedSession()
    }

    private func closeLoadedSession() {
        current?.close(); current?.state.close(); current = nil
    }

    func model(for recordingURL: URL) -> TranscriptReviewWindowModel? {
        current?.state.id == RecordingEntry.canonicalURL(recordingURL) ? current : nil
    }
}

@MainActor
final class TranscriptReviewWindowModel: ObservableObject {
    var inputBlocked: @MainActor () -> Bool = { false }
    struct Row: Identifiable, Sendable {
        let id: String
        let start: Double
        let name: String
        let text: String
        let speakerID: String
        let sourceID: TranscriptDocument.SourceID
        let localID: Int
        let hasManualName: Bool

        init(
            id: String,
            start: Double,
            name: String,
            text: String,
            speakerID: String = "",
            sourceID: TranscriptDocument.SourceID = .host,
            localID: Int = 1,
            hasManualName: Bool = false
        ) {
            self.id = id
            self.start = start
            self.name = name
            self.text = text
            self.speakerID = speakerID
            self.sourceID = sourceID
            self.localID = localID
            self.hasManualName = hasManualName
        }
    }

    enum SpeakerAssignmentScope: String, CaseIterable, Identifiable, Sendable {
        case thisTurn = "Только этой реплике"
        case allVoiceGroup = "Этот голос отсюда до конца"
        var id: String { rawValue }
    }

    struct GroupConfirmationPayload: Equatable {
        let id: UUID
        let draftID: UUID
        let resultID: String
        let turnID: String
        let speakerID: String
        let confirmedName: String
        let preview: TranscriptBulkAssignmentPreview?
        let willReplaceManual: Bool
        let affectedTurnsCount: Int

        init(
            id: UUID = UUID(),
            draftID: UUID,
            resultID: String,
            turnID: String,
            speakerID: String,
            confirmedName: String,
            preview: TranscriptBulkAssignmentPreview? = nil,
            willReplaceManual: Bool = false,
            affectedTurnsCount: Int = 1
        ) {
            self.id = id
            self.draftID = draftID
            self.resultID = resultID
            self.turnID = turnID
            self.speakerID = speakerID
            self.confirmedName = confirmedName
            self.preview = preview
            self.willReplaceManual = willReplaceManual
            self.affectedTurnsCount = affectedTurnsCount
        }
    }

    struct SpeakerAssignmentDraft: Identifiable, Equatable {
        let id: UUID
        let turnID: String
        let speakerID: String
        let sourceID: TranscriptDocument.SourceID
        let localID: Int
        let initialName: String
        var inputName: String
        var scope: SpeakerAssignmentScope
        var pendingConfirmation: GroupConfirmationPayload?
        var preview: TranscriptBulkAssignmentPreview?
        let targetResultID: String
        let calendarAttendees: [String]

        var isConfirmingGroup: Bool {
            pendingConfirmation != nil
        }
    }

    struct PresentationWarningItem: Identifiable, Equatable, Sendable {
        let id: String
        let code: String
        let sourceID: TranscriptDocument.SourceID?
        let sourceLabel: String?
        let message: String
    }

    struct TextEditingDraft: Identifiable, Equatable {
        let id: UUID
        let turnID: String
        let initialText: String
        var text: String
        let targetResultID: String

        init(
            id: UUID = UUID(),
            turnID: String,
            initialText: String,
            text: String,
            targetResultID: String
        ) {
            self.id = id
            self.turnID = turnID
            self.initialText = initialText
            self.text = text
            self.targetResultID = targetResultID
        }
    }

    var onSaved: (() -> Void)?
    let state: TranscriptWindowState
    @Published private(set) var rows: [Row] = []
    @Published private(set) var currentResultID: String?
    @Published private(set) var legacyText: String?
    @Published private(set) var explanation: String?
    @Published private(set) var error: String?
    @Published private(set) var playbackState: TranscriptPlaybackController.State = .idle
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var playbackDuration: Double = 0
    @Published private(set) var playbackRate: Float = 1.0
    @Published private(set) var waveform: TranscriptWaveform? = nil
    @Published private(set) var waveformMessage: String? = nil
    @Published private(set) var activeTurnIDs: [String] = []
    @Published private(set) var follow = TranscriptFollowState()
    enum DraftIdentity: Equatable {
        case text(draftID: UUID, turnID: String, text: String)
        case speaker(
            draftID: UUID,
            turnID: String,
            inputName: String,
            scope: SpeakerAssignmentScope,
            confirmationID: UUID?
        )
    }

    func resolveForRetry() async -> Bool {
        guard !isClosed, !state.isClosed else { return false }
        guard currentDraftIdentity == nil else { rejectConflictingAction(); return false }
        close(); state.close()
        return true
    }

    var currentDraftIdentity: DraftIdentity? {
        if let textDraft = activeTextDraft {
            return .text(draftID: textDraft.id, turnID: textDraft.turnID, text: textDraft.text)
        } else if let nameDraft = activeDraft {
            return .speaker(
                draftID: nameDraft.id,
                turnID: nameDraft.turnID,
                inputName: nameDraft.inputName,
                scope: nameDraft.scope,
                confirmationID: nameDraft.pendingConfirmation?.id
            )
        }
        return nil
    }

    var isTextDraftDirty: Bool {
        guard let draft = activeTextDraft else { return false }
        return draft.text != draft.initialText
    }

    var isNameDraftDirty: Bool {
        guard let draft = activeDraft else { return false }
        let nameChanged = draft.inputName != draft.initialName
        let groupScope = draft.scope == .allVoiceGroup
        return nameChanged || groupScope
    }

    var hasUnsavedChanges: Bool {
        isTextDraftDirty || isNameDraftDirty
    }

    var isExportAvailable: Bool {
        switch state.mode {
        case .review:
            return currentResultID != nil && !state.isClosed && !isClosed
        case .legacyReadOnly, .corrupt:
            return false
        }
    }

    func rejectConflictingAction() { error = "Сохраните или отмените ввод перед этим действием." }

    func requestWindowClose(onAuthorizedClose: @escaping () -> Void, onCancelled: (() -> Void)? = nil) {
        guard !isClosed, !state.isClosed else { onCancelled?(); return }
        guard currentDraftIdentity == nil else { rejectConflictingAction(); onCancelled?(); return }
        onAuthorizedClose()
    }

    @Published private(set) var activeDraft: SpeakerAssignmentDraft? = nil
    @Published private(set) var activeTextDraft: TextEditingDraft? = nil
    @Published private(set) var calendarAttendees: [String] = []
    @Published private(set) var contextAttendees: [String]? = nil
    @Published private(set) var presentationWarnings: [PresentationWarningItem] = []
    var diarizationWarnings: [String] {
        presentationWarnings.map(\.message)
    }

    func userScrollPhaseChanged(_ phase: ScrollPhase) {
        guard !inputBlocked() else { return }
        switch phase {
        case .tracking, .interacting, .decelerating: follow.manualScroll()
        case .idle, .animating: break
        @unknown default: break
        }
    }

    func beginEditing() {
        follow.beginEditing()
        playback.pause()
    }
    func returnToPlayback() { if !inputBlocked() { follow.returnToPlayback() } }
    func setFollow(_ follow: Bool) {
        guard !isClosed else { return }
        if follow {
            self.follow.returnToPlayback()
        } else {
            self.follow.manualScroll()
        }
    }
    var playbackEnabled: Bool { playbackState == .ready || playbackState == .playing }
    @Published private(set) var playbackMessage: String? = "Для старого TXT или недоступного результата воспроизведение не поддерживается."
    private var playback: TranscriptPlaybackController
    private let transportFactory: @MainActor () -> any TranscriptPlaybackTransport
    private var preparation: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var index: TranscriptIntervalIndex?
    private var isClosed = false

    func togglePlayback() {
        guard !isClosed, !inputBlocked() else { return }
        if playback.state == .playing { playback.pause() }
        else { playback.play() }
    }

    func seekPlayback(to seconds: Double) async {
        guard !isClosed, !inputBlocked() else { return }
        await playback.seek(to: seconds)
    }

    func setPlaybackRate(_ rate: Float) {
        guard !isClosed, !inputBlocked() else { return }
        playback.setPlaybackRate(rate)
        playbackRate = playback.playbackRate
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        preparation?.cancel()
        preparation = nil
        waveformTask?.cancel()
        waveformTask = nil
        waveform = nil
        waveformMessage = nil
        playback.close()
        playbackState = .closed
        follow.close()
        activeDraft = nil
        activeTextDraft = nil
        activeExportRequest = nil
    }

    private func preparePlayback(resultID: String) {
        guard !isClosed, !state.isClosed else { return }
        preparation?.cancel()
        waveformTask?.cancel()
        waveform = nil
        waveformMessage = "Загрузка формы звуковой волны…"
        // Synchronously stop the prior item before a new async task can be scheduled.
        playback.close()
        playback = TranscriptPlaybackController(transport: transportFactory())
        playbackState = .loading
        playbackMessage = "Загрузка аудио текущего результата…"
        playbackPosition = 0
        playbackDuration = 0
        playbackRate = 1.0
        activeTurnIDs = []
        follow.versionChanged()
        playback.onChange = { [weak self] in self?.refreshPlayback() }
        preparation = Task { [weak self] in
            guard let self, !self.isClosed, !Task.isCancelled else { return }
            await self.playback.select(resultID: resultID, recordingDirectory: self.state.recordingDirectory)
            guard !Task.isCancelled else { return }
            if let mix = self.playback.mixURL {
                self.waveformTask = Task { [weak self] in
                    do {
                        let wf = try await TranscriptWaveformExtractor.extractEnvelope(from: mix, sampleCount: 120)
                        guard !Task.isCancelled else { return }
                        self?.waveform = wf
                        self?.waveformMessage = nil
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.waveformMessage = "Форма звуковой волны недоступна: " + error.localizedDescription
                    }
                }
            } else {
                self.waveformMessage = nil
            }
        }
    }

    private func refreshPlayback() {
        guard !isClosed, playback.resultID == currentResultID else { return }
        playbackState = playback.state
        playbackPosition = playback.position
        playbackDuration = playback.duration
        playbackRate = playback.playbackRate
        switch playback.state {
        case .unavailable:
            playbackMessage = "Аудио текущего результата не подготовлено. Текст и сохранённые правки доступны; другая дорожка не подставляется."
        case .failed:
            playbackMessage = "Не удалось воспроизвести аудио текущего результата: файл отсутствует, повреждён или недоступен. Текст и сохранённые правки доступны; другая дорожка не подставляется."
        case .ready, .playing: playbackMessage = nil
        case .loading: playbackMessage = "Загрузка аудио текущего результата…"
        case .idle, .closed: break
        }
        activeTurnIDs = index?.activeTurnIDs(at: playback.position) ?? []
        follow.update(activeIDs: activeTurnIDs, playing: playback.state == .playing)
    }

    init(state: TranscriptWindowState, transportFactory: @escaping @MainActor () -> any TranscriptPlaybackTransport = { TranscriptAVPlayerTransport() }) async throws {
        self.state = state
        self.transportFactory = transportFactory
        self.playback = TranscriptPlaybackController(transport: transportFactory())
        switch state.mode {
        case .review(let id):
            guard let session = state.session else { throw TranscriptWindowError.closed }
            let storage = ReviewStorage(session: session)
            let content = try await Task.detached {
                (try Self.loadRows(resultID: id, storage: storage),
                 Self.loadCalendarAttendees(resultID: id, storage: storage),
                 Self.loadContextAttendees(resultID: id, storage: storage),
                 Self.loadPresentationWarnings(resultID: id, storage: storage),
                 try Self.loadIndex(resultID: id, storage: storage))
            }.value
            rows = content.0
            calendarAttendees = content.1
            contextAttendees = content.2
            presentationWarnings = content.3
            currentResultID = id
            index = content.4
            preparePlayback(resultID: id)
        case .legacyReadOnly(let url):
            explanation = "Сохранённый TXT — только чтение. Редактирование и переход по аудио недоступны."
            await loadLegacy(url)
        case .corrupt(let reason, let fallback):
            explanation = "Текущий результат недоступен: " + reason + ". Сохранённый TXT доступен только для чтения."
            if let fallback { await loadLegacy(fallback) }
        }
    }

    private func loadLegacy(_ url: URL) async {
        let directory = state.recordingDirectory
        do {
            legacyText = try await Task.detached {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(directory.path + "/") else {
                    throw TranscriptWindowError.pathEscapesRecording(url.path)
                }
                return try String(contentsOf: resolved, encoding: .utf8)
            }.value
        } catch { self.error = "Не удалось прочитать TXT: " + error.localizedDescription }
    }

    private struct ReviewStorage: Sendable {
        let recordingDirectory: URL
        let editsRepository: TranscriptEditsRepository
        @MainActor init(session: TranscriptReviewSession) {
            recordingDirectory = session.recordingDirectory
            editsRepository = session.editsRepository
        }
    }

    private static func loadRows(resultID: String, session: TranscriptReviewSession) throws -> [Row] {
        try loadRows(resultID: resultID, storage: ReviewStorage(session: session))
    }

    nonisolated private static func loadRows(resultID: String, storage: ReviewStorage) throws -> [Row] {
        let document = try TranscriptDocument.load(from: storage.editsRepository.resultURL(for: resultID),
                                                   recordingDirectory: storage.recordingDirectory)
        guard document.resultID == resultID else {
            throw TranscriptStorageError.currentResultUnavailable(resultID)
        }
        let edits = try storage.editsRepository.loadEdits(resultID: resultID)
        let words = Dictionary(uniqueKeysWithValues: document.words.map { ($0.id, $0.text) })
        let speakers = Dictionary(uniqueKeysWithValues: document.speakers.map { ($0.id, $0) })
        return document.turns.map { turn in
            let override = edits.overrides[turn.id]
            let speaker = speakers[turn.speakerID]
            let displayNumber = speaker?.displayNumber ?? 1
            let sourceID = speaker?.sourceID ?? .host
            let localID = speaker?.localID ?? 1
            return Row(
                id: turn.id,
                start: turn.start,
                name: override?.displayName ?? "Speaker \(displayNumber)",
                text: override?.text ?? turn.wordIDs.compactMap { words[$0] }.joined(separator: " "),
                speakerID: turn.speakerID,
                sourceID: sourceID,
                localID: localID,
                hasManualName: override?.displayName != nil
            )
        }
    }

    private static func loadCalendarAttendees(resultID: String, session: TranscriptReviewSession) -> [String] {
        loadCalendarAttendees(resultID: resultID, storage: ReviewStorage(session: session))
    }

    nonisolated private static func loadCalendarAttendees(resultID: String, storage: ReviewStorage) -> [String] {
        guard let doc = try? TranscriptDocument.load(from: storage.editsRepository.resultURL(for: resultID),
                                                     recordingDirectory: storage.recordingDirectory) else {
            return []
        }
        return doc.context?.attendees ?? []
    }

    private static func loadContextAttendees(resultID: String, session: TranscriptReviewSession) -> [String]? {
        loadContextAttendees(resultID: resultID, storage: ReviewStorage(session: session))
    }

    nonisolated private static func loadContextAttendees(resultID: String, storage: ReviewStorage) -> [String]? {
        guard let doc = try? TranscriptDocument.load(from: storage.editsRepository.resultURL(for: resultID),
                                                     recordingDirectory: storage.recordingDirectory) else {
            return nil
        }
        guard let attendees = doc.context?.attendees, !attendees.isEmpty else { return nil }
        return attendees
    }

    private static func loadPresentationWarnings(resultID: String, session: TranscriptReviewSession) -> [PresentationWarningItem] {
        loadPresentationWarnings(resultID: resultID, storage: ReviewStorage(session: session))
    }

    nonisolated private static func loadPresentationWarnings(resultID: String, storage: ReviewStorage) -> [PresentationWarningItem] {
        guard let doc = try? TranscriptDocument.load(from: storage.editsRepository.resultURL(for: resultID),
                                                     recordingDirectory: storage.recordingDirectory) else {
            return []
        }
        var counts: [String: Int] = [:]
        return doc.presentationWarnings.map { warning in
            let sourceTag = warning.sourceID?.rawValue ?? "global"
            let occurrence = counts[sourceTag + "_" + warning.code, default: 0]
            counts[sourceTag + "_" + warning.code] = occurrence + 1
            let uniqueID = "\(sourceTag)_\(warning.code)_\(occurrence)"
            let sourceLabel: String?
            if let src = warning.sourceID {
                sourceLabel = TranscriptDocument.localizedSourceLabel(for: src)
            } else {
                sourceLabel = nil
            }
            return PresentationWarningItem(
                id: uniqueID,
                code: warning.code,
                sourceID: warning.sourceID,
                sourceLabel: sourceLabel,
                message: warning.message
            )
        }
    }

    private static func loadIndex(resultID: String, session: TranscriptReviewSession) throws -> TranscriptIntervalIndex {
        try loadIndex(resultID: resultID, storage: ReviewStorage(session: session))
    }

    nonisolated private static func loadIndex(resultID: String, storage: ReviewStorage) throws -> TranscriptIntervalIndex {
        let document = try TranscriptDocument.load(from: storage.editsRepository.resultURL(for: resultID), recordingDirectory: storage.recordingDirectory)
        guard document.resultID == resultID else { throw TranscriptStorageError.currentResultUnavailable(resultID) }
        return TranscriptIntervalIndex(document: document)
    }

    func openSpeakerAssignment(for turnID: String) {
        guard !inputBlocked() else { return }
        guard !isClosed, !state.isClosed, !state.isReadOnly, state.session != nil, let resultID = currentResultID else { return }
        guard activeTextDraft == nil, activeDraft == nil else {
            self.error = "Завершите или отмените редактирование текста перед назначением имени."
            return
        }
        guard let row = rows.first(where: { $0.id == turnID }) else { return }
        beginEditing()
        let initial = row.name
        activeDraft = SpeakerAssignmentDraft(
            id: UUID(),
            turnID: row.id,
            speakerID: row.speakerID,
            sourceID: row.sourceID,
            localID: row.localID,
            initialName: initial,
            inputName: initial,
            scope: .thisTurn,
            pendingConfirmation: nil,
            preview: nil,
            targetResultID: resultID,
            calendarAttendees: calendarAttendees.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        saveSpeakerAssignment()
    }

    func updateDraftName(_ name: String, draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, var draft = activeDraft else { return }
        if let id = draftID, draft.id != id { return }
        draft.inputName = name
        draft.preview = nil
        draft.pendingConfirmation = nil
        activeDraft = draft
        error = nil
        saveSpeakerAssignment(draftID: draft.id)
    }

    func selectDraftScope(_ scope: SpeakerAssignmentScope, draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, var draft = activeDraft, state.session != nil else { return }
        if let id = draftID, draft.id != id { return }
        draft.scope = scope
        draft.pendingConfirmation = nil
        draft.preview = nil
        activeDraft = draft
        error = nil
        saveSpeakerAssignment(draftID: draft.id)
    }

    func selectCalendarAttendee(_ attendee: String, draftID: UUID? = nil) {
        updateDraftName(attendee, draftID: draftID)
    }

    func saveSpeakerAssignment(draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, var draft = activeDraft, let session = state.session, let resultID = currentResultID, draft.targetResultID == resultID else {
            activeDraft = nil
            return
        }
        if let id = draftID, draft.id != id { return }

        let trimmed = draft.inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draft.preview = nil
            draft.pendingConfirmation = nil
            activeDraft = draft
            return
        }

        if draft.scope == .allVoiceGroup {
            let preview: TranscriptBulkAssignmentPreview
            do { preview = try session.previewRemainingAssignment(anchorTurnID: draft.turnID, displayName: draft.inputName) }
            catch { self.error = error.localizedDescription; return }
            draft.preview = preview
            draft.pendingConfirmation = GroupConfirmationPayload(
                draftID: draft.id,
                resultID: resultID,
                turnID: draft.turnID,
                speakerID: draft.speakerID,
                confirmedName: draft.inputName,
                preview: preview,
                willReplaceManual: preview.replacedManualAssignmentsCount > 0,
                affectedTurnsCount: preview.affectedTurnsCount
            )
            activeDraft = draft
            return
        } else {
            guard let row = rows.first(where: { $0.id == draft.turnID }) else { return }
            let changes = row.name != draft.inputName
            let willReplace = changes && row.hasManualName
            draft.preview = nil
            draft.pendingConfirmation = GroupConfirmationPayload(
                draftID: draft.id,
                resultID: resultID,
                turnID: draft.turnID,
                speakerID: draft.speakerID,
                confirmedName: draft.inputName,
                preview: nil,
                willReplaceManual: willReplace,
                affectedTurnsCount: changes ? 1 : 0
            )
            activeDraft = draft
            return
        }
    }

    func confirmGroupAssignment(confirmation: GroupConfirmationPayload) {
        guard !isClosed, !state.isClosed, let draft = activeDraft, let session = state.session, let resultID = currentResultID else {
            return
        }
        guard draft.id == confirmation.draftID,
              draft.targetResultID == resultID,
              confirmation.resultID == resultID,
              draft.turnID == confirmation.turnID,
              draft.speakerID == confirmation.speakerID,
              let currentConfirmation = draft.pendingConfirmation,
              currentConfirmation.id == confirmation.id else {
            self.error = "Подтверждение группы устарело или не совпадает с текущим состоянием."
            return
        }

        do {
            if draft.scope == .thisTurn {
                _ = try session.assignSpeakerName(turnID: draft.turnID, displayName: confirmation.confirmedName)
            } else if let preview = confirmation.preview {
                _ = try session.assignSpeakerName(preview: preview, displayName: confirmation.confirmedName)
            }
            rows = try Self.loadRows(resultID: resultID, session: session)
            activeDraft = nil
            error = nil
            onSaved?()
        } catch {
            self.error = "Ошибка назначения имени: \(error.localizedDescription)"
        }
    }

    func confirmGroupAssignment(draftID: UUID? = nil) {
        guard let draft = activeDraft, let confirmation = draft.pendingConfirmation else {
            self.error = "Подтверждение группы не сформировано."
            return
        }
        if let id = draftID, draft.id != id { return }
        confirmGroupAssignment(confirmation: confirmation)
    }

    func cancelDraft(draftID: UUID? = nil) {
        guard let draft = activeDraft else { return }
        if let id = draftID, draft.id != id { return }
        activeDraft = nil
    }

    // MARK: - Section 4.4a Text Editing Operations

    func openTextEditing(for turnID: String) {
        guard !inputBlocked() else { return }
        guard !isClosed, !state.isClosed, !state.isReadOnly, state.session != nil, let resultID = currentResultID else { return }
        guard activeDraft == nil else {
            self.error = "Завершите или отмените назначение имени перед редактированием текста."
            return
        }
        guard activeTextDraft == nil else { return }
        guard let row = rows.first(where: { $0.id == turnID }) else { return }
        beginEditing()
        activeTextDraft = TextEditingDraft(
            id: UUID(),
            turnID: row.id,
            initialText: row.text,
            text: row.text,
            targetResultID: resultID
        )
        error = nil
    }

    func updateDraftText(_ text: String, draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, var draft = activeTextDraft else { return }
        if let id = draftID, draft.id != id { return }
        draft.text = text
        activeTextDraft = draft
    }

    func cancelTextDraft(draftID: UUID? = nil) {
        guard let draft = activeTextDraft else { return }
        if let id = draftID, draft.id != id { return }
        activeTextDraft = nil
    }

    func saveTextEditing(draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, let draft = activeTextDraft, let session = state.session, let resultID = currentResultID, draft.targetResultID == resultID else {
            activeTextDraft = nil
            return
        }
        if let id = draftID, draft.id != id { return }

        do {
            _ = try session.editsRepository.saveTurnOverride(resultID: resultID, turnID: draft.turnID, text: draft.text, displayName: nil)
            rows = try Self.loadRows(resultID: resultID, session: session)
            activeTextDraft = nil
            error = nil
            onSaved?()
        } catch {
            self.error = "Ошибка сохранения текста: \(error.localizedDescription)"
        }
    }

    func copySavedText(write: @MainActor (String) -> Bool = { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }) {
        guard !inputBlocked() else { return }
        guard canCopySavedText else { self.error = "Сохранённый текст недоступен для копирования."; return }
        if let legacyText {
            if !write(legacyText) { self.error = "Не удалось скопировать сохранённый текст." }
            return
        }
        guard let session = state.session, let id = currentResultID else { return }
        do {
            let document = try TranscriptDocument.load(from: session.editsRepository.resultURL(for: id), recordingDirectory: state.recordingDirectory)
            let edits = try session.editsRepository.loadEdits(resultID: id)
            let text = try TranscriptExportFormatter().format(document: document, edits: edits, recordingDirectory: state.recordingDirectory)
            if !write(text) { self.error = "Не удалось скопировать сохранённый текст." }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: - Section 4.5b Export Implementation

    struct ExportRequest: Identifiable, Equatable {
        let id: UUID
        let resultID: String
        let recordingURL: URL
        let frozenDocument: TranscriptDocument
        let frozenEdits: TranscriptEdits
        let hasDirtyDraft: Bool

        static func == (lhs: ExportRequest, rhs: ExportRequest) -> Bool {
            lhs.id == rhs.id && lhs.resultID == rhs.resultID && lhs.recordingURL == rhs.recordingURL && lhs.frozenEdits == rhs.frozenEdits && lhs.hasDirtyDraft == rhs.hasDirtyDraft
        }
    }

    @Published private(set) var activeExportRequest: ExportRequest? = nil
    @Published private(set) var exportNotice: String? = nil

    var canExport: Bool {
        isExportAvailable
    }
    var canCopySavedText: Bool {
        !isClosed && !state.isClosed && (legacyText != nil || isExportAvailable)
    }

    typealias SavePanelRunner = @MainActor (_ panel: NSSavePanel, _ completion: @escaping (_ response: NSApplication.ModalResponse, _ destinationURL: URL?) -> Void) -> Void
    typealias OverwriteConsentHandler = @MainActor (_ destinationURL: URL) -> Bool

    @MainActor
    var defaultSavePanelRunner: SavePanelRunner {
        { panel, completion in
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                panel.beginSheetModal(for: window) { response in
                    let dest = response == .OK ? panel.url : nil
                    completion(response, dest)
                }
            } else {
                let response = panel.runModal()
                let dest = response == .OK ? panel.url : nil
                completion(response, dest)
            }
        }
    }

    @MainActor
    var defaultOverwriteConsentHandler: OverwriteConsentHandler {
        { destinationURL in
            let alert = NSAlert()
            alert.messageText = "Файл уже существует"
            alert.informativeText = "Файл «\(destinationURL.lastPathComponent)» уже существует. Перезаписать его сохранённым состоянием текущего результата расшифровки?"
            alert.addButton(withTitle: "Перезаписать")
            alert.addButton(withTitle: "Отмена")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    @MainActor
    func configureSavePanel(hasDirtyDraft: Bool = false) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcript.txt"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        if hasDirtyDraft {
            panel.message = "Экспорт сохранённого состояния текущей расшифровки, зафиксированного на момент запроса. Несохранённые изменения черновика исключены."
        } else {
            panel.message = "Экспорт сохранённого состояния текущей расшифровки, зафиксированного на момент запроса."
        }
        return panel
    }

    @MainActor
    func requestExport(
        savePanelRunner: SavePanelRunner? = nil,
        overwriteConsentHandler: OverwriteConsentHandler? = nil
    ) {
        guard !inputBlocked() else { return }
        guard canExport, !isClosed, !state.isClosed, let resultID = currentResultID, let session = state.session else { return }

        self.activeExportRequest = nil
        self.error = nil

        let dirtyDraft = hasUnsavedChanges || activeDraft != nil || activeTextDraft != nil
        if dirtyDraft {
            self.exportNotice = "Внимание: открыт несохранённый черновик. Экспортируется только сохранённое состояние; черновик исключён из экспорта."
        } else {
            self.exportNotice = nil
        }

        let frozenDocument: TranscriptDocument
        let frozenEdits: TranscriptEdits
        do {
            let resultURL = session.editsRepository.resultURL(for: resultID)
            frozenDocument = try TranscriptDocument.load(from: resultURL, recordingDirectory: state.recordingDirectory)
            guard frozenDocument.resultID == resultID else {
                throw TranscriptStorageError.currentResultUnavailable(resultID)
            }
            let readOnlyRepo = TranscriptEditsRepository(recordingDirectory: state.recordingDirectory)
            frozenEdits = try readOnlyRepo.loadEdits(resultID: resultID)
        } catch {
            self.error = "Ошибка подготовки экспорта: \(error.localizedDescription)"
            return
        }

        let requestID = UUID()
        let request = ExportRequest(
            id: requestID,
            resultID: resultID,
            recordingURL: state.recordingURL,
            frozenDocument: frozenDocument,
            frozenEdits: frozenEdits,
            hasDirtyDraft: dirtyDraft
        )
        self.activeExportRequest = request

        let panel = configureSavePanel(hasDirtyDraft: dirtyDraft)
        let runner: SavePanelRunner = savePanelRunner ?? defaultSavePanelRunner

        runner(panel) { [weak self] response, destinationURL in
            self?.handleSavePanelCompletion(
                requestID: requestID,
                response: response,
                destinationURL: destinationURL,
                overwriteConsentHandler: overwriteConsentHandler
            )
        }
    }

    @MainActor
    func handleSavePanelCompletion(
        requestID: UUID,
        response: NSApplication.ModalResponse,
        destinationURL: URL?,
        overwriteConsentHandler: OverwriteConsentHandler? = nil
    ) {
        guard !isClosed, !state.isClosed, !inputBlocked() else { return }
        guard let activeRequest = activeExportRequest, activeRequest.id == requestID else {
            return
        }

        guard case .review = state.mode,
              currentResultID == activeRequest.resultID,
              state.recordingURL == activeRequest.recordingURL else {
            return
        }

        guard response == .OK, let destinationURL else {
            self.activeExportRequest = nil
            return
        }

        let destStandard = destinationURL.standardizedFileURL
        let currentlyExists = FileManager.default.fileExists(atPath: destStandard.path)

        let allowOverwrite: Bool
        if currentlyExists {
            let consentHandler = overwriteConsentHandler ?? defaultOverwriteConsentHandler
            let consent = consentHandler(destStandard)
            guard consent else {
                if self.activeExportRequest?.id == requestID {
                    self.activeExportRequest = nil
                }
                return
            }
            allowOverwrite = true
        } else {
            allowOverwrite = false
        }

        guard !isClosed, !state.isClosed, !inputBlocked() else {
            self.activeExportRequest = nil
            return
        }
        guard let currentActive = activeExportRequest, currentActive.id == requestID else {
            return
        }
        guard case .review = state.mode,
              currentResultID == activeRequest.resultID,
              state.recordingURL == activeRequest.recordingURL else {
            self.activeExportRequest = nil
            return
        }

        self.activeExportRequest = nil

        do {
            let writer = TranscriptExportWriter(recordingDirectory: state.recordingDirectory)
            try writer.export(
                document: activeRequest.frozenDocument,
                edits: activeRequest.frozenEdits,
                to: destinationURL,
                allowOverwrite: allowOverwrite
            )
            self.error = nil
            if activeRequest.hasDirtyDraft {
                self.exportNotice = "Экспорт успешно сохранён: \(destinationURL.lastPathComponent). Внимание: несохранённый черновик исключён."
            } else {
                self.exportNotice = "Экспорт успешно сохранён: \(destinationURL.lastPathComponent)"
            }
        } catch {
            self.error = "Ошибка экспорта: \(error.localizedDescription)"
        }
        }
}

// MARK: - Waveform Scrubber Component (Genuine 120-bar Envelope)

struct WaveformScrubberView: View {
    let waveform: TranscriptWaveform?
    let position: Double
    let duration: Double
    let isEnabled: Bool
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double? = nil

    private var currentFraction: Double {
        if let drag = dragFraction { return drag }
        guard duration > 0 else { return 0 }
        return min(1.0, max(0.0, position / duration))
    }

    var body: some View {
        GeometryReader { geometry in
            let count = 120
            let samples = waveform?.envelope ?? []
            let width = geometry.size.width
            let barWidth = max(1.5, min(3.0, (width / CGFloat(count)) * 0.55))
            let activeFrac = currentFraction

            Canvas { context, size in
                for i in samples.indices {
                    let sampleVal = CGFloat(samples[i])
                    let barH = max(4.0, sampleVal * (size.height - 8))
                    let x = CGFloat(i) * (size.width / CGFloat(count)) + (size.width / CGFloat(count) - barWidth) / 2
                    let y = (size.height - barH) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barH)
                    let barFraction = Double(i) / Double(count)
                    let color = barFraction <= activeFrac ? ODColors.accent : ODColors.track
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled, duration > 0 else { return }
                        let frac = min(1.0, max(0.0, Double(value.location.x / width)))
                        dragFraction = frac
                        onSeek(frac * duration)
                    }
                    .onEnded { value in
                        guard isEnabled, duration > 0 else { return }
                        let frac = min(1.0, max(0.0, Double(value.location.x / width)))
                        dragFraction = nil
                        onSeek(frac * duration)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Позиция воспроизведения")
            .accessibilityValue(TranscriptExportFormatter.formatTimestamp(seconds: position))
            .focusable(isEnabled)
            .onKeyPress(.leftArrow) {
                guard isEnabled, duration > 0 else { return .ignored }
                onSeek(max(0, position - 5))
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard isEnabled, duration > 0 else { return .ignored }
                onSeek(min(duration, position + 5))
                return .handled
            }
            .accessibilityAdjustableAction { direction in
                guard isEnabled, duration > 0 else { return }
                switch direction {
                case .increment:
                    onSeek(min(duration, position + 5))
                case .decrement:
                    onSeek(max(0, position - 5))
                @unknown default:
                    break
                }
            }
        }
        .frame(height: 36)
    }

}

// MARK: - Document & Turn Presentation

struct TranscriptReviewWindowView: View {
    @ObservedObject var model: TranscriptReviewWindowModel
    let title: String
    var entryDate: Date? = nil
    var entryDuration: Double? = nil
    var workspaceWidth: CGFloat = 1392
    private var narrow: Bool { workspaceWidth <= 767 }
    private var compact: Bool { workspaceWidth <= 1023 }
    @State private var scrollPosition: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        documentHeader

                        if let error = model.error {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(ODColors.red)
                                .textSelection(.enabled)
                                .padding(.bottom, 12)
                        }
                        if let notice = model.exportNotice {
                            Text(notice)
                                .font(.system(size: 13))
                                .foregroundColor(ODColors.ink)
                                .textSelection(.enabled)
                                .padding(.bottom, 12)
                        }

                        if let text = model.legacyText {
                            Text(text)
                                .font(.system(size: 16))
                                .lineSpacing(6)
                                .foregroundColor(ODColors.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        } else {
                            transcriptTurns(proxy: proxy)
                        }
                    }
                    .padding(.horizontal, narrow ? 16 : compact ? 24 : 48)
                    .padding(.top, narrow ? 28 : compact ? 32 : workspaceWidth >= 1392 ? 48 : 40)
                    .padding(.bottom, compact ? (narrow ? 28 : 32) : 48)
                    .frame(maxWidth: 840)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollPosition(id: $scrollPosition, anchor: .top)
                .onScrollPhaseChange { _, phase in model.userScrollPhaseChanged(phase) }
                .onChange(of: model.follow.request) { _, _ in
                    guard model.follow.isFollowing, let target = model.follow.targetID else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
            }

            playerFooter
        }
        .background(ODColors.surface)
        .sheet(isPresented: Binding(get: { model.currentDraftIdentity != nil }, set: { _ in })) {
            editingSheet.interactiveDismissDisabled()
        }
    }

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.legacyText != nil {
                HStack(spacing: 6) {
                    ODIconView(.copy, size: 14, color: ODColors.muted)
                    Text("Архивный текст")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ODColors.muted)
                }
                .odLineBox(size: 12, height: 18.6)
                .padding(.bottom, 16)
            } else if model.state.isReadOnly {
                HStack(spacing: 6) {
                    ODIconView(.shield, size: 14, color: ODColors.muted)
                    Text("Только чтение")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ODColors.muted)
                }
                .odLineBox(size: 12, height: 18.6)
                .padding(.bottom, 16)
            } else if !model.rows.isEmpty {
                HStack(spacing: 6) {
                    ODIconView(.check, size: 14, color: ODColors.green)
                    Text("Транскрипт готов")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ODColors.green)
                }
                .odLineBox(size: 12, height: 18.6)
                .padding(.bottom, 16)
            }

            Text(title)
                .font(.system(size: min(32, max(24, workspaceWidth * 0.025)), weight: .semibold))
                .tracking(-0.8)
                .foregroundColor(ODColors.ink)
                .odLineBox(size: min(32, max(24, workspaceWidth * 0.025)), height: min(32, max(24, workspaceWidth * 0.025)) * 1.25)
                .textSelection(.enabled)
                .padding(.bottom, 16)

            ViewThatFits(in: .horizontal) {
            HStack(spacing: narrow ? 12 : 16) {
                if let entryDate {
                    let formatter: DateFormatter = {
                        let f = DateFormatter()
                        f.locale = Locale(identifier: "ru_RU")
                        f.dateFormat = "d MMMM yyyy · HH:mm"
                        return f
                    }()
                    HStack(spacing: 6) {
                        ODIconView(.calendar, size: 14, color: ODColors.muted)
                        Text(formatter.string(from: entryDate))
                    }
                }

                let dur = entryDuration ?? (model.playbackDuration > 0 ? model.playbackDuration : nil)
                if let dur, dur > 0 {
                    HStack(spacing: 6) {
                        ODIconView(.clock, size: 14, color: ODColors.muted)
                        Text(Self.clock(seconds: dur))
                    }
                }

                if !model.rows.isEmpty {
                    let speakers = Set(model.rows.map(\.speakerID)).count
                    HStack(spacing: 6) {
                        ODIconView(.people, size: 14, color: ODColors.muted)
                        Text("\(speakers) говорящих")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let entryDate { Text(entryDate.formatted(date: .long, time: .shortened)) }
                if let duration = entryDuration, duration > 0 { Text(Self.clock(seconds: duration)) }
                if !model.rows.isEmpty { Text("\(Set(model.rows.map(\.speakerID)).count) говорящих") }
            }
            }
            .font(.system(size: 13))
            .odLineBox(size: 13, height: 20.15)
            .foregroundColor(ODColors.muted)

            if let attendees = model.contextAttendees {
                Text("Приглашены: " + attendees.joined(separator: ", "))
                    .font(.system(size: 13))
                    .foregroundColor(ODColors.muted)
                    .textSelection(.enabled)
                    .padding(.bottom, 12)
            }

            if let explanation = model.explanation {
                Text(explanation)
                    .font(.system(size: 13))
                    .foregroundColor(ODColors.muted)
                    .textSelection(.enabled)
                    .padding(.bottom, 12)
            }

            ForEach(model.presentationWarnings) { item in
                DisclosureGroup {
                    Text(item.message)
                        .font(.system(size: 13))
                        .foregroundColor(ODColors.ink)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                } label: {
                    HStack(spacing: 8) {
                        ODIconView(.warning, size: 14, color: ODColors.warning)
                        Text(item.sourceLabel.map { $0 + ": " } ?? "Есть замечание к разделению голосов")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(ODColors.warning)
                    }
                }
                .padding(12)
                .background(ODColors.warningBg, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8).padding(.bottom, 0)
            }

            Rectangle()
                .fill(ODColors.line)
                .frame(height: 1)
                .padding(.top, 28)
                .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 24) {
                Text("Транскрипт")
                    .font(.system(size: 14, weight: .semibold))
                    .odLineBox(size: 14, height: 18.9)
                    .foregroundColor(ODColors.ink)
                Text("Нажми на имя, чтобы сменить спикера, или «Редактировать», чтобы исправить текст.")
                    .font(.system(size: 13))
                    .odLineBox(size: 13, height: 20.15)
                    .foregroundColor(ODColors.muted)
            }
            .padding(.bottom, 16)
        }
    }

    private func transcriptTurns(proxy: ScrollViewProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(model.rows) { row in
                HStack(alignment: .top, spacing: narrow ? 8 : 16) {
                    Button(action: { Task { await model.seekPlayback(to: row.start) } }) {
                        Text(Self.clock(seconds: row.start))
                            .font(.system(size: 12)).monospacedDigit()
                            .odLineBox(size: 12, height: 15.6)
                            .foregroundColor(model.activeTurnIDs.contains(row.id) ? ODColors.accent : ODColors.muted)
                            .frame(width: narrow ? 44 : 48, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.playbackEnabled)
                    .accessibilityLabel("Перейти к " + Self.clock(seconds: row.start))

                    VStack(alignment: .leading, spacing: 8) {
                        ODWrappingChips(trailingLast: true) {
                            HStack(spacing: 8) {
                            Circle()
                                .fill(row.sourceID == .host ? ODColors.accent : ODColors.muted)
                                .frame(width: 6, height: 6)

                            if !model.state.isReadOnly {
                                Button(action: { model.openSpeakerAssignment(for: row.id) }) {
                                    HStack(spacing: 4) {
                                        Text(row.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .odLineBox(size: 13, height: 16.9)
                                            .foregroundColor(ODColors.ink)
                                        Text("▾")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(ODColors.muted)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(ODColors.surface, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ODColors.line, lineWidth: 1))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Имя говорящего: " + row.name)
                            } else {
                                Text(row.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(ODColors.ink)
                            }

                            }

                            if !model.state.isReadOnly {
                                Button("Редактировать") {
                                    model.openTextEditing(for: row.id)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundColor(ODColors.muted)
                                .accessibilityLabel("Изменить текст в " + Self.clock(seconds: row.start))
                            }
                        }

                        Text(row.text)
                            .font(.system(size: 16))
                            .odLineBox(size: 16, height: 28)
                            .foregroundColor(ODColors.ink)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, narrow ? 8 : 12)
                .padding(.vertical, narrow ? 12 : 16)
                .background(
                    model.activeTurnIDs.contains(row.id)
                        ? ODColors.surface.mix(with: ODColors.selected, by: 0.65)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .id(row.id)
            }
        }
        .scrollTargetLayout()
    }

    private var playerFooter: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: compact ? 12 : 20) {
                    playButton
                    waveformScrubber.frame(minWidth: 120)
                    timeReadout.fixedSize()
                    speedMenu.fixedSize()
                }
                VStack(spacing: 12) {
                    HStack(spacing: 12) { playButton; waveformScrubber.frame(minWidth: 120) }
                    HStack(spacing: 12) { timeReadout; Spacer(); speedMenu }
                }
            }
            HStack(spacing: 8) {
                if let message = model.waveformMessage ?? model.playbackMessage {
                    Text(message).font(.system(size: narrow ? 10 : 11)).foregroundStyle(ODColors.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(model.follow.isFollowing ? "Следовать за текстом" : "Следование выключено") {
                    guard !model.inputBlocked() else { return }
                    model.setFollow(!model.follow.isFollowing)
                }
                .buttonStyle(.plain)
                .font(.system(size: narrow ? 10 : 11)).foregroundStyle(ODColors.accent)
                .padding(4)
                .disabled(model.playbackState == .closed)
                .accessibilityValue(model.follow.isFollowing ? "Включено" : "Выключено")
            }
        }
        .padding(.horizontal, narrow ? 12 : compact ? 16 : 28)
        .padding(.top, narrow ? 12 : 16)
        .padding(.bottom, narrow ? 12 : compact ? 16 : 12)
        .background(ODColors.toolbar)
        .overlay(alignment: .top) { Rectangle().fill(ODColors.line).frame(height: 1) }
    }

    private var playButton: some View {
        Button(action: model.togglePlayback) {
            ODIconView(model.playbackState == .playing ? .pause : .play, size: 19, color: ODColors.ink)
                .frame(width: 44, height: 44)
                .background(ODColors.surface, in: Circle())
                .overlay(Circle().strokeBorder(ODColors.line))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!model.playbackEnabled)
        .accessibilityLabel(model.playbackState == .playing ? "Пауза" : "Воспроизвести")
    }

    private var waveformScrubber: some View {
        WaveformScrubberView(waveform: model.waveform, position: model.playbackPosition,
            duration: model.playbackDuration, isEnabled: model.playbackEnabled,
            onSeek: { target in Task { await model.seekPlayback(to: target) } })
    }

    private var timeReadout: some View {
        HStack(spacing: 2) {
            Text(Self.clock(seconds: model.playbackPosition)).foregroundStyle(ODColors.ink)
            Text(" / " + Self.clock(seconds: model.playbackDuration)).foregroundStyle(ODColors.muted)
        }
        .font(.system(size: narrow ? 11 : 12)).monospacedDigit()
    }

    private var speedMenu: some View {
        Menu {
            ForEach([1, 1.25, 1.5, 2] as [Float], id: \.self) { rate in
                Button(String(format: "%g×", rate)) { model.setPlaybackRate(rate) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(String(format: "%g×", model.playbackRate))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
            }
            .font(.system(size: 12))
            .foregroundStyle(ODColors.ink)
            .padding(6)
            .frame(minWidth: 48, maxWidth: narrow ? 62 : 70)
            .background(ODColors.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ODColors.line))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.playbackEnabled).accessibilityLabel("Скорость воспроизведения")
    }

    var editingSheet: some View {
        ODDialog(title: model.activeTextDraft != nil ? "Исправить реплику" : "Сменить спикера", width: 560, close: {
            if let draft = model.activeTextDraft { model.cancelTextDraft(draftID: draft.id) }
            if let draft = model.activeDraft { model.cancelDraft(draftID: draft.id) }
        }) {
            if let draft = model.activeTextDraft {
                if let row = model.rows.first(where: { $0.id == draft.turnID }) {
                    Text("\(Self.clock(seconds: row.start)) · \(row.name)")
                        .font(.system(size: 13))
                        .foregroundColor(ODColors.muted)
                }

                ODField(title: "Текст реплики") {
                TextEditor(text: Binding(get: { model.activeTextDraft?.text ?? "" }, set: { model.updateDraftText($0, draftID: draft.id) }))
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(ODColors.toolbar, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ODColors.line))
                    .frame(height: 192)
                    .accessibilityLabel("Текст реплики")
                Text("До сохранения можно отменить ввод. После сохранения текст можно исправить повторно.")
                    .font(.system(size: 12)).foregroundStyle(ODColors.muted)
                }

                if let error = model.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

            } else if let draft = model.activeDraft {
                if let row = model.rows.first(where: { $0.id == draft.turnID }) {
                    Text("\(Self.clock(seconds: row.start)) · \(row.name) (\(TranscriptDocument.localizedSourceLabel(for: draft.sourceID)) · Голос \(draft.localID))")
                        .font(.system(size: 13))
                        .foregroundColor(ODColors.muted)
                }

                Text(draft.calendarAttendees.isEmpty ? "В сохранённом контексте нет приглашённых. Можно выбрать имя из транскрипта или ввести своё." : "Приглашённые из календаря — только подсказки. Календарь не определяет, кому принадлежит голос.")
                    .font(.system(size: 14)).odLineBox(size: 14, height: 22.4)
                    .foregroundStyle(ODColors.muted)

                let suggestions = Array(Set(draft.calendarAttendees + model.rows.map(\.name))).sorted()
                ODWrappingChips {
                    ForEach(suggestions, id: \.self) { name in
                        Button(name) { model.selectCalendarAttendee(name, draftID: draft.id) }
                            .buttonStyle(ODButtonStyle())
                    }
                }

                ODField(title: "Имя спикера") {
                    TextField("Введи имя", text: Binding(get: { model.activeDraft?.inputName ?? "" }, set: { model.updateDraftName($0, draftID: draft.id) }))
                        .textFieldStyle(.plain).font(.system(size: 15))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(ODColors.toolbar, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ODColors.line))
                        .accessibilityLabel("Имя говорящего")
                    Text("Можно выбрать подсказку или вписать своё имя.")
                        .font(.system(size: 12)).foregroundStyle(ODColors.muted)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Какие реплики изменить?").font(.system(size: 14, weight: .semibold))
                    ForEach(TranscriptReviewWindowModel.SpeakerAssignmentScope.allCases) { scope in
                        Button { model.selectDraftScope(scope, draftID: draft.id) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: draft.scope == scope ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(draft.scope == scope ? ODColors.accent : ODColors.muted)
                                Text(scope.rawValue).font(.system(size: 14))
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(draft.scope == scope ? .isSelected : [])
                        .accessibilityValue(draft.scope == scope ? "Выбрано" : "Не выбрано")
                    }
                }

                if let confirmation = draft.pendingConfirmation {
                    let changedRows = draft.scope == .thisTurn
                        ? model.rows.filter { $0.id == draft.turnID && confirmation.affectedTurnsCount > 0 }
                        : model.rows.filter { confirmation.preview?.affectedTurnIDs.contains($0.id) == true }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(confirmation.affectedTurnsCount) реплик → \(confirmation.confirmedName)")
                            .fontWeight(.semibold)
                        Text("Группа: \(draft.sourceID.rawValue) / \(draft.localID). Другие голоса и предыдущие реплики не изменятся. Ручных назначений будет заменено: \(confirmation.preview?.replacedManualAssignmentsCount ?? (confirmation.willReplaceManual && confirmation.affectedTurnsCount > 0 ? 1 : 0)).")
                        ForEach(Array(changedRows.prefix(3))) { row in
                            Text("• " + Self.clock(seconds: row.start) + " · " + row.name + ": " + String(row.text.prefix(96)) + (row.text.count > 96 ? "…" : ""))
                                .padding(.leading, 8)
                        }
                        if changedRows.count > 3 { Text("И ещё реплик: \(changedRows.count - 3)") }
                    }
                    .font(.system(size: 14)).odLineBox(size: 14, height: 22.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(ODColors.toolbar, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ODColors.line))
                } else {
                    Text("Введи имя, чтобы увидеть изменения.")
                        .font(.system(size: 14)).foregroundStyle(ODColors.muted)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ODColors.toolbar, in: RoundedRectangle(cornerRadius: 8))
                }

                if let error = model.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

            }
        } actions: {
            if let draft = model.activeTextDraft {
                Button("Отменить") { model.cancelTextDraft(draftID: draft.id) }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { model.saveTextEditing(draftID: draft.id) }
                    .buttonStyle(ODButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            } else if let draft = model.activeDraft {
                    Button("Отменить") { model.cancelDraft(draftID: draft.id) }
                        .keyboardShortcut(.cancelAction)
                    Button("Подтвердить замену") {
                        if let confirmation = draft.pendingConfirmation { model.confirmGroupAssignment(confirmation: confirmation) }
                    }
                        .buttonStyle(ODButtonStyle(primary: true))
                        .disabled((draft.pendingConfirmation?.affectedTurnsCount ?? 0) == 0)
                        .keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 16))
    }

    private static func clock(seconds: Double) -> String { formatClock(seconds) }
    private static func timestamp(_ seconds: Double) -> String { TranscriptExportFormatter.formatTimestamp(seconds: seconds) }
}
