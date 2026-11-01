import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if !TRANSCRIPT_WINDOW_HARNESS
import MeetingCompanionCore
#endif

@MainActor
final class TranscriptReviewWindowManager {
    let coordinator = TranscriptWindowCoordinator()
    private(set) var windows: [URL: NSWindow] = [:]
    private var hosts: [URL: TranscriptWindowHost] = [:]

    func open(recordingURL: URL, title: String,
              persistSelection: @escaping TranscriptReviewSession.PersistSelectionHandler) throws -> NSWindow {
        let opened = try coordinator.openWindow(for: recordingURL, onPersistSelection: persistSelection)
        let state = opened.state
        if let window = windows[state.id] {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return window
        }
        do {
            let model = try TranscriptReviewWindowModel(state: state)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = title
            window.contentMinSize = NSSize(width: 480, height: 320)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TranscriptReviewWindowView(model: model, title: title))
            let host = TranscriptWindowHost(model: model) { [weak self, weak state] in
                guard let self, let state, self.hosts[state.id]?.model.state === state else { return }
                self.windows.removeValue(forKey: state.id)
                self.hosts.removeValue(forKey: state.id)
                state.close()
            }
            hosts[state.id] = host
            windows[state.id] = window
            window.delegate = host
            window.center()
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return window
        } catch {
            state.close()
            throw error
        }
    }

    func model(for recordingURL: URL) -> TranscriptReviewWindowModel? {
        hosts[TranscriptWindowCoordinator.canonicalURL(for: recordingURL)]?.model
    }
}

@MainActor
private final class TranscriptWindowHost: NSObject, NSWindowDelegate {
    let model: TranscriptReviewWindowModel
    private var onClose: (() -> Void)?
    private var isAuthorizedClosing = false

    init(model: TranscriptReviewWindowModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isAuthorizedClosing { return true }
        if model.hasUnsavedChanges {
            model.requestWindowClose { [weak self, weak sender] in
                guard let self, let sender else { return }
                self.isAuthorizedClosing = true
                sender.close()
            }
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
        let callback = onClose
        onClose = nil
        (notification.object as? NSWindow)?.delegate = nil
        callback?()
    }
}

@MainActor
final class TranscriptReviewWindowModel: ObservableObject {
    struct Row: Identifiable {
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
        case allVoiceGroup = "Всему голосу"
        var id: String { rawValue }
    }

    struct GroupConfirmationPayload: Equatable {
        let id: UUID
        let draftID: UUID
        let resultID: String
        let turnID: String
        let speakerID: String
        let confirmedName: String
        let replaceExistingManual: Bool
        let preview: TranscriptBulkAssignmentPreview

        init(
            id: UUID = UUID(),
            draftID: UUID,
            resultID: String,
            turnID: String,
            speakerID: String,
            confirmedName: String,
            replaceExistingManual: Bool,
            preview: TranscriptBulkAssignmentPreview
        ) {
            self.id = id
            self.draftID = draftID
            self.resultID = resultID
            self.turnID = turnID
            self.speakerID = speakerID
            self.confirmedName = confirmedName
            self.replaceExistingManual = replaceExistingManual
            self.preview = preview
        }
    }

    struct SpeakerAssignmentDraft: Identifiable, Equatable {
        let id: UUID
        let turnID: String
        let speakerID: String
        let sourceID: TranscriptDocument.SourceID
        let localID: Int
        let currentName: String
        let initialName: String
        var inputName: String
        var scope: SpeakerAssignmentScope
        var replaceExistingManual: Bool
        var pendingConfirmation: GroupConfirmationPayload?
        var preview: TranscriptBulkAssignmentPreview?
        let targetResultID: String
        let calendarAttendees: [String]

        var isConfirmingGroup: Bool {
            pendingConfirmation != nil
        }
    }

    struct PresentationWarningItem: Identifiable, Equatable {
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

    let state: TranscriptWindowState
    @Published private(set) var rows: [Row] = []
    @Published private(set) var versions: [TranscriptVersionInfo] = []
    @Published private(set) var selectedResultID: String?
    @Published private(set) var legacyText: String?
    @Published private(set) var explanation: String?
    @Published private(set) var error: String?
    @Published private(set) var playbackState: TranscriptPlaybackController.State = .idle
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var playbackDuration: Double = 0
    @Published private(set) var activeTurnIDs: [String] = []
    @Published private(set) var follow = TranscriptFollowState()
    enum DraftIdentity: Equatable {
        case text(draftID: UUID, turnID: String, text: String)
        case speaker(
            draftID: UUID,
            turnID: String,
            inputName: String,
            scope: SpeakerAssignmentScope,
            replaceExistingManual: Bool,
            confirmationID: UUID?
        )
    }

    enum PendingNavigation: Equatable {
        case close
        case switchVersion(targetResultID: String)
    }

    enum UnsavedPromptResolution {
        case save
        case discard
        case stay
    }

    struct UnsavedChangesPrompt: Identifiable, Equatable {
        let id: UUID
        let navigation: PendingNavigation
        let targetResultID: String
        let expectedDraft: DraftIdentity
    }

    @Published private(set) var unsavedPrompt: UnsavedChangesPrompt? = nil
    private var authorizedCloseAction: (() -> Void)? = nil

    var currentDraftIdentity: DraftIdentity? {
        if let textDraft = activeTextDraft {
            return .text(draftID: textDraft.id, turnID: textDraft.turnID, text: textDraft.text)
        } else if let nameDraft = activeDraft {
            return .speaker(
                draftID: nameDraft.id,
                turnID: nameDraft.turnID,
                inputName: nameDraft.inputName,
                scope: nameDraft.scope,
                replaceExistingManual: nameDraft.replaceExistingManual,
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
        let replaceToggled = draft.replaceExistingManual
        return nameChanged || groupScope || replaceToggled
    }

    var hasUnsavedChanges: Bool {
        isTextDraftDirty || isNameDraftDirty
    }

    func requestVersionSwitch(to targetResultID: String) {
        guard !isClosed, !state.isClosed, targetResultID != selectedResultID, let currentResultID = selectedResultID else { return }
        if let draftIdentity = currentDraftIdentity, hasUnsavedChanges {
            unsavedPrompt = UnsavedChangesPrompt(
                id: UUID(),
                navigation: .switchVersion(targetResultID: targetResultID),
                targetResultID: currentResultID,
                expectedDraft: draftIdentity
            )
        } else {
            switchVersion(to: targetResultID)
        }
    }

    func requestWindowClose(onAuthorizedClose: @escaping () -> Void) {
        guard !isClosed, !state.isClosed, let currentResultID = selectedResultID else { return }
        guard let draftIdentity = currentDraftIdentity, hasUnsavedChanges else {
            onAuthorizedClose()
            return
        }
        authorizedCloseAction = onAuthorizedClose
        unsavedPrompt = UnsavedChangesPrompt(
            id: UUID(),
            navigation: .close,
            targetResultID: currentResultID,
            expectedDraft: draftIdentity
        )
    }

    func resolveUnsavedPrompt(_ resolution: UnsavedPromptResolution, promptID: UUID) {
        guard !isClosed, !state.isClosed else {
            unsavedPrompt = nil
            authorizedCloseAction = nil
            return
        }

        // Strict NOOP for foreign prompt ID or mismatched result:
        guard let prompt = unsavedPrompt, prompt.id == promptID, prompt.targetResultID == selectedResultID else {
            return
        }

        // Matching prompt: verify draft has not changed under prompt
        guard currentDraftIdentity == prompt.expectedDraft else {
            unsavedPrompt = nil
            authorizedCloseAction = nil
            return
        }

        switch resolution {
        case .stay:
            unsavedPrompt = nil
            authorizedCloseAction = nil

        case .discard:
            switch prompt.expectedDraft {
            case .text(let draftID, _, _):
                cancelTextDraft(draftID: draftID)
            case .speaker(let draftID, _, _, _, _, _):
                cancelDraft(draftID: draftID)
            }
            unsavedPrompt = nil
            let closeAction = authorizedCloseAction
            authorizedCloseAction = nil
            switch prompt.navigation {
            case .close:
                closeAction?()
            case .switchVersion(let targetID):
                switchVersion(to: targetID)
            }

        case .save:
            var saveSucceeded = false
            switch prompt.expectedDraft {
            case .text(let draftID, _, _):
                saveTextEditing(draftID: draftID)
                saveSucceeded = (activeTextDraft == nil && error == nil)
            case .speaker(let draftID, _, _, let scope, _, let expectedConfirmationID):
                if scope == .allVoiceGroup {
                    guard let expectedConfID = expectedConfirmationID,
                          let draft = activeDraft,
                          draft.id == draftID,
                          let confirmation = draft.pendingConfirmation,
                          confirmation.id == expectedConfID else {
                        self.error = "Для сохранения группового назначения требуется предварительное подтверждение группы."
                        return
                    }
                    confirmGroupAssignment(confirmation: confirmation)
                    saveSucceeded = (activeDraft == nil && error == nil)
                } else {
                    saveSpeakerAssignment(draftID: draftID)
                    saveSucceeded = (activeDraft == nil && error == nil)
                }
            }

            if saveSucceeded {
                unsavedPrompt = nil
                let closeAction = authorizedCloseAction
                authorizedCloseAction = nil
                switch prompt.navigation {
                case .close:
                    closeAction?()
                case .switchVersion(let targetID):
                    switchVersion(to: targetID)
                }
            } else {
                unsavedPrompt = nil
                authorizedCloseAction = nil
            }
        }
    }

    @Published private(set) var activeDraft: SpeakerAssignmentDraft? = nil {
        didSet { updateCanUndo() }
    }
    @Published private(set) var activeTextDraft: TextEditingDraft? = nil {
        didSet { updateCanUndo() }
    }
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var calendarAttendees: [String] = []
    @Published private(set) var contextAttendees: [String]? = nil
    @Published private(set) var presentationWarnings: [PresentationWarningItem] = []
    var diarizationWarnings: [String] {
        presentationWarnings.map(\.message)
    }

    private func updateCanUndo() {
        guard !isClosed, !state.isClosed, activeDraft == nil, activeTextDraft == nil, let resultID = selectedResultID, let session = state.session else {
            canUndo = false
            return
        }
        canUndo = session.editsRepository.canUndo(resultID: resultID)
    }

    func userScrollPhaseChanged(_ phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting, .decelerating: follow.manualScroll()
        case .idle, .animating: break
        @unknown default: break
        }
    }

    func beginEditing() { follow.beginEditing() }
    func returnToPlayback() { follow.returnToPlayback() }
    var playbackEnabled: Bool { playbackState == .ready || playbackState == .playing }
    @Published private(set) var playbackMessage: String? = "Для старого TXT или недоступного результата воспроизведение не поддерживается."
    private var playback = TranscriptPlaybackController(transport: TranscriptAVPlayerTransport())
    private var preparation: Task<Void, Never>?
    private var index: TranscriptIntervalIndex?
    private var isClosed = false

    func togglePlayback() {
        guard !isClosed else { return }
        if playback.state == .playing { playback.pause() }
        else { playback.play() }
    }

    func seekPlayback(to seconds: Double) async {
        guard !isClosed else { return }
        await playback.seek(to: seconds)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        preparation?.cancel()
        preparation = nil
        playback.close()
        playbackState = .closed
        follow.close()
        activeDraft = nil
        activeTextDraft = nil
        unsavedPrompt = nil
        authorizedCloseAction = nil
        activeExportRequest = nil
        canUndo = false
    }

    private func preparePlayback(resultID: String) {
        guard !isClosed, !state.isClosed else { return }
        preparation?.cancel()
        // Synchronously stop the prior item before a new async task can be scheduled.
        playback.close()
        playback = TranscriptPlaybackController(transport: TranscriptAVPlayerTransport())
        playbackState = .loading
        playbackMessage = "Загрузка аудио выбранной версии…"
        playbackPosition = 0
        playbackDuration = 0
        activeTurnIDs = []
        follow.versionChanged()
        playback.onChange = { [weak self] in self?.refreshPlayback() }
        preparation = Task { [weak self] in
            guard let self, !self.isClosed, !Task.isCancelled else { return }
            await self.playback.select(resultID: resultID, recordingDirectory: self.state.recordingDirectory)
        }
    }

    private func refreshPlayback() {
        guard !isClosed, playback.resultID == selectedResultID else { return }
        playbackState = playback.state
        playbackPosition = playback.position
        playbackDuration = playback.duration
        switch playback.state {
        case .unavailable:
            playbackMessage = "Аудио этой версии не подготовлено. Текст и сохранённые правки доступны; другая дорожка не подставляется."
        case .failed:
            playbackMessage = "Не удалось воспроизвести аудио выбранной версии: файл отсутствует, повреждён или недоступен. Текст и сохранённые правки доступны; другая дорожка не подставляется."
        case .ready, .playing: playbackMessage = nil
        case .loading: playbackMessage = "Загрузка аудио выбранной версии…"
        case .idle, .closed: break
        }
        activeTurnIDs = index?.activeTurnIDs(at: playback.position) ?? []
        follow.update(activeIDs: activeTurnIDs, playing: playback.state == .playing)
    }

    init(state: TranscriptWindowState) throws {
        self.state = state
        switch state.mode {
        case .review(let id):
            guard let session = state.session else { throw TranscriptWindowError.closed }
            versions = try session.selector.availableVersions()
            rows = try Self.loadRows(resultID: id, session: session)
            calendarAttendees = Self.loadCalendarAttendees(resultID: id, session: session)
            contextAttendees = Self.loadContextAttendees(resultID: id, session: session)
            presentationWarnings = Self.loadPresentationWarnings(resultID: id, session: session)
            selectedResultID = id
            updateCanUndo()
            index = try Self.loadIndex(resultID: id, session: session)
            preparePlayback(resultID: id)
        case .legacyReadOnly(let url):
            explanation = "Старый TXT — только чтение. Редактирование и переход по аудио недоступны."
            loadLegacy(url)
        case .unavailable(let version, let fallback):
            explanation = "Выбранная версия \(version) недоступна. Старый TXT показан только для чтения; это не выбранная версия."
            if let fallback { loadLegacy(fallback) }
        case .corrupt(_, let fallback):
            explanation = "Не удалось прочитать структурированный результат или сведения о версии. Старый TXT показан только для чтения; ошибка не исправлена."
            if let fallback { loadLegacy(fallback) }
        }
    }

    private func loadLegacy(_ url: URL) {
        // Recheck final destination at read time; coordinator already validates discovery.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(state.recordingDirectory.path + "/") else {
            error = "Не удалось прочитать TXT: путь выходит за пределы записи."
            return
        }
        do { legacyText = try String(contentsOf: resolved, encoding: .utf8) }
        catch { self.error = "Не удалось прочитать старый TXT." }
    }

    private static func loadRows(resultID: String, session: TranscriptReviewSession) throws -> [Row] {
        let document = try TranscriptDocument.load(from: session.editsRepository.resultURL(for: resultID),
                                                   recordingDirectory: session.recordingDirectory)
        guard document.resultID == resultID else {
            throw TranscriptVersionSelectionError.selectedVersionUnavailable(resultID)
        }
        let edits = try session.editsRepository.loadEdits(resultID: resultID)
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
        guard let doc = try? TranscriptDocument.load(from: session.editsRepository.resultURL(for: resultID),
                                                     recordingDirectory: session.recordingDirectory) else {
            return []
        }
        return doc.context?.attendees ?? []
    }

    private static func loadContextAttendees(resultID: String, session: TranscriptReviewSession) -> [String]? {
        guard let doc = try? TranscriptDocument.load(from: session.editsRepository.resultURL(for: resultID),
                                                     recordingDirectory: session.recordingDirectory) else {
            return nil
        }
        guard let attendees = doc.context?.attendees, !attendees.isEmpty else { return nil }
        return attendees
    }

    private static func loadPresentationWarnings(resultID: String, session: TranscriptReviewSession) -> [PresentationWarningItem] {
        guard let doc = try? TranscriptDocument.load(from: session.editsRepository.resultURL(for: resultID),
                                                     recordingDirectory: session.recordingDirectory) else {
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
        let document = try TranscriptDocument.load(from: session.editsRepository.resultURL(for: resultID), recordingDirectory: session.recordingDirectory)
        guard document.resultID == resultID else { throw TranscriptVersionSelectionError.selectedVersionUnavailable(resultID) }
        return TranscriptIntervalIndex(document: document)
    }

    func switchVersion(to resultID: String) {
        guard !isClosed, !state.isClosed, resultID != selectedResultID else { return }
        do {
            guard let session = state.session, !state.isClosed, !isClosed else { throw TranscriptWindowError.closed }
            // Prepare a complete matching view before persistence; publish only on success.
            let nextRows = try Self.loadRows(resultID: resultID, session: session)
            let nextIndex = try Self.loadIndex(resultID: resultID, session: session)
            try state.switchVersion(to: resultID)
            guard !isClosed, !state.isClosed else { return }
            rows = nextRows
            selectedResultID = resultID
            calendarAttendees = Self.loadCalendarAttendees(resultID: resultID, session: session)
            contextAttendees = Self.loadContextAttendees(resultID: resultID, session: session)
            presentationWarnings = Self.loadPresentationWarnings(resultID: resultID, session: session)
            activeDraft = nil
            activeTextDraft = nil
            unsavedPrompt = nil
            authorizedCloseAction = nil
            activeExportRequest = nil
            exportNotice = nil
            updateCanUndo()
            index = nextIndex
            error = nil
            preparePlayback(resultID: resultID)
        } catch {
            guard !isClosed, !state.isClosed else { return }
            self.error = "Не удалось переключить версию. Предыдущая расшифровка сохранена в окне."
        }
    }

    func openSpeakerAssignment(for turnID: String) {
        guard !isClosed, !state.isClosed, !state.isReadOnly, state.session != nil, let resultID = selectedResultID else { return }
        guard activeTextDraft == nil else {
            self.error = "Завершите или отмените редактирование текста перед назначением имени."
            return
        }
        guard let row = rows.first(where: { $0.id == turnID }) else { return }
        beginEditing()
        let initial = row.hasManualName ? row.name : ""
        activeDraft = SpeakerAssignmentDraft(
            id: UUID(),
            turnID: row.id,
            speakerID: row.speakerID,
            sourceID: row.sourceID,
            localID: row.localID,
            currentName: row.name,
            initialName: initial,
            inputName: initial,
            scope: .thisTurn,
            replaceExistingManual: false,
            pendingConfirmation: nil,
            preview: nil,
            targetResultID: resultID,
            calendarAttendees: calendarAttendees
        )
    }

    func updateDraftName(_ name: String, draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, var draft = activeDraft else { return }
        if let id = draftID, draft.id != id { return }
        draft.inputName = name
        draft.pendingConfirmation = nil
        activeDraft = draft
    }

    func selectDraftScope(_ scope: SpeakerAssignmentScope, draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, var draft = activeDraft, let session = state.session else { return }
        if let id = draftID, draft.id != id { return }
        draft.scope = scope
        draft.pendingConfirmation = nil
        if scope == .allVoiceGroup {
            do {
                draft.preview = try session.previewGroupAssignment(speakerID: draft.speakerID, replaceManuallyAssigned: draft.replaceExistingManual)
            } catch {
                draft.preview = nil
                self.error = error.localizedDescription
            }
        } else {
            draft.preview = nil
        }
        activeDraft = draft
    }

    func toggleReplaceExistingManual(_ replace: Bool, draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, var draft = activeDraft, let session = state.session else { return }
        if let id = draftID, draft.id != id { return }
        draft.replaceExistingManual = replace
        draft.pendingConfirmation = nil
        if draft.scope == .allVoiceGroup {
            do {
                draft.preview = try session.previewGroupAssignment(speakerID: draft.speakerID, replaceManuallyAssigned: replace)
            } catch {
                draft.preview = nil
                self.error = error.localizedDescription
            }
        }
        activeDraft = draft
    }

    func selectCalendarAttendee(_ attendee: String, draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, var draft = activeDraft else { return }
        if let id = draftID, draft.id != id { return }
        draft.inputName = attendee
        draft.pendingConfirmation = nil
        activeDraft = draft
    }

    func saveSpeakerAssignment(draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, var draft = activeDraft, let session = state.session, let resultID = selectedResultID, draft.targetResultID == resultID else {
            activeDraft = nil
            return
        }
        if let id = draftID, draft.id != id { return }

        let trimmed = draft.inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.error = "Имя говорящего не может быть пустым."
            return
        }

        if draft.scope == .allVoiceGroup {
            guard let preview = draft.preview else {
                self.error = "Превью массового назначения не сформировано."
                return
            }
            draft.pendingConfirmation = GroupConfirmationPayload(
                draftID: draft.id,
                resultID: resultID,
                turnID: draft.turnID,
                speakerID: draft.speakerID,
                confirmedName: draft.inputName,
                replaceExistingManual: draft.replaceExistingManual,
                preview: preview
            )
            activeDraft = draft
            return
        }

        do {
            _ = try session.assignSpeakerName(turnID: draft.turnID, displayName: draft.inputName)
            rows = try Self.loadRows(resultID: resultID, session: session)
            activeDraft = nil
            updateCanUndo()
            error = nil
        } catch {
            self.error = "Ошибка назначения имени: \(error.localizedDescription)"
        }
    }

    func confirmGroupAssignment(confirmation: GroupConfirmationPayload) {
        guard !isClosed, !state.isClosed, let draft = activeDraft, let session = state.session, let resultID = selectedResultID else {
            return
        }
        guard draft.id == confirmation.draftID,
              draft.targetResultID == resultID,
              confirmation.resultID == resultID,
              draft.turnID == confirmation.turnID,
              draft.speakerID == confirmation.speakerID,
              draft.scope == .allVoiceGroup,
              let currentConfirmation = draft.pendingConfirmation,
              currentConfirmation.id == confirmation.id else {
            self.error = "Подтверждение группы устарело или не совпадает с текущим состоянием."
            return
        }

        do {
            _ = try session.assignSpeakerName(preview: confirmation.preview, displayName: confirmation.confirmedName)
            rows = try Self.loadRows(resultID: resultID, session: session)
            activeDraft = nil
            updateCanUndo()
            error = nil
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

    func resetSpeakerName(draftID: UUID? = nil) {
        guard !isClosed, !state.isClosed, let draft = activeDraft, let session = state.session, let resultID = selectedResultID, draft.targetResultID == resultID else {
            activeDraft = nil
            return
        }
        if let id = draftID, draft.id != id { return }
        do {
            _ = try session.unassignSpeakerName(turnID: draft.turnID)
            rows = try Self.loadRows(resultID: resultID, session: session)
            activeDraft = nil
            updateCanUndo()
            error = nil
        } catch {
            self.error = "Ошибка сброса имени: \(error.localizedDescription)"
        }
    }

    func cancelDraft(draftID: UUID? = nil) {
        guard let draft = activeDraft else { return }
        if let id = draftID, draft.id != id { return }
        activeDraft = nil
    }

    // MARK: - Section 4.4a Text Editing Operations

    func openTextEditing(for turnID: String) {
        guard !isClosed, !state.isClosed, !state.isReadOnly, state.session != nil, let resultID = selectedResultID else { return }
        guard activeDraft == nil else {
            self.error = "Завершите или отмените назначение имени перед редактированием текста."
            return
        }
        if let currentTextDraft = activeTextDraft {
            if currentTextDraft.turnID == turnID { return }
            if currentTextDraft.text != currentTextDraft.initialText {
                self.error = "Завершите или отмените текущее редактирование текста перед переходом к другой реплике."
                return
            }
        }
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
        guard !isClosed, !state.isClosed, let draft = activeTextDraft, let session = state.session, let resultID = selectedResultID, draft.targetResultID == resultID else {
            activeTextDraft = nil
            return
        }
        if let id = draftID, draft.id != id { return }

        do {
            _ = try session.editsRepository.saveTurnOverride(resultID: resultID, turnID: draft.turnID, text: draft.text, displayName: nil)
            rows = try Self.loadRows(resultID: resultID, session: session)
            activeTextDraft = nil
            updateCanUndo()
            error = nil
        } catch {
            self.error = "Ошибка сохранения текста: \(error.localizedDescription)"
        }
    }

    func undoLastEdit() {
        guard !isClosed, !state.isClosed, let session = state.session, let resultID = selectedResultID else { return }
        guard activeDraft == nil && activeTextDraft == nil else {
            self.error = "Отмените или сохраните текущий ввод перед отменой предыдущих сохранённых правок."
            return
        }
        guard session.editsRepository.canUndo(resultID: resultID) else { return }
        do {
            _ = try session.undo()
            rows = try Self.loadRows(resultID: resultID, session: session)
            updateCanUndo()
            error = nil
        } catch {
            self.error = "Ошибка отмены: \(error.localizedDescription)"
        }
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

    var isExportAvailable: Bool {
        guard !isClosed, !state.isClosed else { return false }
        switch state.mode {
        case .review:
            return selectedResultID != nil
        case .legacyReadOnly, .unavailable, .corrupt:
            return false
        }
    }

    var canExport: Bool {
        isExportAvailable
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
            alert.informativeText = "Файл «\(destinationURL.lastPathComponent)» уже существует. Перезаписать его сохранённым состоянием выбранной версии расшифровки?"
            alert.addButton(withTitle: "Перезаписать")
            alert.addButton(withTitle: "Отмена")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    @MainActor
    func configureSavePanel(resultID: String? = nil, hasDirtyDraft: Bool = false) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcript.txt"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        let versionLabel = resultID.map { "выбранной версии \($0)" } ?? "выбранной версии"
        if hasDirtyDraft {
            panel.message = "Экспорт сохранённого состояния \(versionLabel), зафиксированного на момент запроса. Несохранённые изменения черновика исключены."
        } else {
            panel.message = "Экспорт сохранённого состояния \(versionLabel), зафиксированного на момент запроса."
        }
        return panel
    }

    @MainActor
    func requestExport(
        savePanelRunner: SavePanelRunner? = nil,
        overwriteConsentHandler: OverwriteConsentHandler? = nil
    ) {
        guard canExport, !isClosed, !state.isClosed, let resultID = selectedResultID, let session = state.session else { return }

        // Invalidate prior active export request immediately at the start of a replacement request:
        self.activeExportRequest = nil

        self.error = nil

        let dirtyDraft = hasUnsavedChanges || activeDraft != nil || activeTextDraft != nil
        if dirtyDraft {
            self.exportNotice = "Внимание: открыт несохранённый черновик. Экспортируется только последняя сохранённая версия; черновик исключён из экспорта."
        } else {
            self.exportNotice = nil
        }

        let frozenDocument: TranscriptDocument
        let frozenEdits: TranscriptEdits
        do {
            let resultURL = session.editsRepository.resultURL(for: resultID)
            frozenDocument = try TranscriptDocument.load(from: resultURL, recordingDirectory: state.recordingDirectory)
            guard frozenDocument.resultID == resultID else {
                throw TranscriptVersionSelectionError.selectedVersionUnavailable(resultID)
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

        let panel = configureSavePanel(resultID: resultID, hasDirtyDraft: dirtyDraft)
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
        guard !isClosed, !state.isClosed else { return }
        guard let activeRequest = activeExportRequest, activeRequest.id == requestID else {
            return
        }

        guard case .review = state.mode,
              selectedResultID == activeRequest.resultID,
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
                // Declined overwrite consent: cancel immediately with zero output
                if self.activeExportRequest?.id == requestID {
                    self.activeExportRequest = nil
                }
                return
            }
            allowOverwrite = true
        } else {
            // File did not exist at selection; race-created destination is NOT authorized to overwrite.
            allowOverwrite = false
        }

        // Revalidate generation, window close, version switch, and replacement request AFTER modal consent:
        guard !isClosed, !state.isClosed else {
            self.activeExportRequest = nil
            return
        }
        guard let currentActive = activeExportRequest, currentActive.id == requestID else {
            return
        }
        guard case .review = state.mode,
              selectedResultID == activeRequest.resultID,
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

private struct TranscriptReviewWindowView: View {
    @ObservedObject var model: TranscriptReviewWindowModel
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2).textSelection(.enabled)
                Spacer()
                if !model.state.isReadOnly {
                    Button("Отменить изменение") {
                        model.undoLastEdit()
                    }
                    .disabled(!model.canUndo)
                    .accessibilityLabel("Отменить последнее изменение")
                    .accessibilityIdentifier("transcript-undo")
                }
                if model.isExportAvailable {
                    Button("Экспортировать…") {
                        model.requestExport()
                    }
                    .disabled(!model.canExport)
                    .accessibilityLabel("Экспортировать расшифровку в файл")
                    .accessibilityIdentifier("transcript-export")
                }
                if let selected = model.selectedResultID, model.versions.count > 1 {
                    Picker("Версия", selection: Binding(get: { model.selectedResultID ?? selected },
                                                       set: { model.requestVersionSwitch(to: $0) })) {
                        ForEach(model.versions, id: \.resultID) { version in
                            Text(version.date.formatted(date: .abbreviated, time: .shortened) + " · " + version.resultID)
                                .tag(version.resultID)
                        }
                    }.frame(maxWidth: 340)
                }
            }
            if model.state.isReadOnly {
                Text("Только чтение").font(.caption).foregroundStyle(.secondary)
            }
            if let explanation = model.explanation {
                Text(explanation).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityLabel("Ошибка: " + error)
            }
            if let notice = model.exportNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: notice.contains("Внимание") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(notice.contains("Внимание") ? .orange : .green)
                    Text(notice).font(.callout).textSelection(.enabled)
                }
                .padding(6)
                .background((notice.contains("Внимание") ? Color.orange : Color.green).opacity(0.12))
                .cornerRadius(6)
                .accessibilityIdentifier("transcript-export-notice")
            }

            if let prompt = model.unsavedPrompt {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Несохранённые изменения").font(.headline)
                    }
                    Text(prompt.navigation == .close ? "В расшифровке есть несохранённые изменения. Сохранить их перед закрытием окна?" : "В расшифровке есть несохранённые изменения. Сохранить их перед сменой версии?")
                        .font(.callout)
                    HStack {
                        Button("Сохранить") {
                            model.resolveUnsavedPrompt(.save, promptID: prompt.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("transcript-unsaved-save")

                        Button("Отбросить") {
                            model.resolveUnsavedPrompt(.discard, promptID: prompt.id)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("transcript-unsaved-discard")

                        Button("Остаться") {
                            model.resolveUnsavedPrompt(.stay, promptID: prompt.id)
                        }
                        .accessibilityIdentifier("transcript-unsaved-stay")
                    }
                }
                .padding(12)
                .background(Color.yellow.opacity(0.15))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4), lineWidth: 1))
                .accessibilityIdentifier("transcript-unsaved-prompt")
                Divider()
            }

            if let attendees = model.contextAttendees {
                HStack(alignment: .top, spacing: 6) {
                    Text("Приглашены:").font(.caption).bold().foregroundStyle(.secondary)
                    Text(attendees.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .accessibilityIdentifier("transcript-attendees-header")
            }

            ForEach(model.presentationWarnings) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        if let sourceLabel = item.sourceLabel {
                            Text(sourceLabel).font(.caption).bold().foregroundStyle(.secondary)
                        }
                        Text(item.message).font(.callout)
                    }
                }
                .padding(6)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
                .accessibilityIdentifier("transcript-warning-item")
            }
            Divider()

            if let draft = model.activeDraft {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Назначить имя говорящего").font(.headline)
                        Spacer()
                        Button("Закрыть") { model.cancelDraft(draftID: draft.id) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("transcript-speaker-form-close")
                    }
                    TextField("Имя говорящего", text: Binding(
                        get: { model.activeDraft?.inputName ?? "" },
                        set: { model.updateDraftName($0, draftID: draft.id) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("transcript-speaker-name-input")

                    if !draft.calendarAttendees.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Подсказки из календаря:").font(.caption).foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(draft.calendarAttendees, id: \.self) { attendee in
                                        Button(attendee) {
                                            model.selectCalendarAttendee(attendee, draftID: draft.id)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityIdentifier("transcript-calendar-attendee-" + attendee)
                                    }
                                }
                            }
                        }
                    }

                    Picker("Область действия", selection: Binding(
                        get: { model.activeDraft?.scope ?? .thisTurn },
                        set: { model.selectDraftScope($0, draftID: draft.id) }
                    )) {
                        ForEach(TranscriptReviewWindowModel.SpeakerAssignmentScope.allCases) { scope in
                            let sourceLabel = draft.sourceID == .host ? "Микрофон" : "Системный звук"
                            Text(scope == .thisTurn ? "Только этой реплике" : "Всему голосу (\(sourceLabel) · Голос \(draft.localID))").tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("transcript-speaker-scope-picker")

                    if draft.scope == .allVoiceGroup {
                        Toggle("Заменять существующие ручные назначения", isOn: Binding(
                            get: { model.activeDraft?.replaceExistingManual ?? false },
                            set: { model.toggleReplaceExistingManual($0, draftID: draft.id) }
                        ))
                        .accessibilityIdentifier("transcript-speaker-replace-manual-toggle")

                        if let preview = draft.preview {
                            Text("Затрагивает: \(preview.affectedTurnsCount) из \(preview.totalTurnsInGroup) реплик; заменяет ручных: \(preview.replacedManualAssignmentsCount)")
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("transcript-speaker-preview-summary")
                        }

                        if let confirmation = draft.pendingConfirmation {
                            let sourceLabel = draft.sourceID == .host ? "Микрофон" : "Системный звук"
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Подтвердите массовое назначение имени «\(confirmation.confirmedName)» для группы \(sourceLabel) · Голос \(draft.localID): будет изменено \(confirmation.preview.affectedTurnsCount) реплик.")
                                    .font(.callout).bold()
                                HStack {
                                    Button("Подтвердить") { model.confirmGroupAssignment(confirmation: confirmation) }
                                        .buttonStyle(.borderedProminent)
                                        .accessibilityIdentifier("transcript-speaker-confirm-group")
                                    Button("Отмена") { model.cancelDraft(draftID: draft.id) }
                                        .accessibilityIdentifier("transcript-speaker-cancel-group")
                                }
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }

                    if !draft.isConfirmingGroup {
                        HStack {
                            Button("Сохранить") { model.saveSpeakerAssignment(draftID: draft.id) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("transcript-speaker-save")
                            Button("Отмена") { model.cancelDraft(draftID: draft.id) }
                                .accessibilityIdentifier("transcript-speaker-cancel")
                            if draft.currentName != "Speaker \(draft.localID)" {
                                Spacer()
                                Button("Сбросить имя") {
                                    model.resetSpeakerName(draftID: draft.id)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("transcript-speaker-reset")
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
                Divider()
            }

            ScrollViewReader { proxy in
            ScrollView {
                if let legacyText = model.legacyText {
                    Text(legacyText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.rows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Button(Self.timestamp(row.start)) {
                                        Task { await model.seekPlayback(to: row.start) }
                                    }.disabled(!model.playbackEnabled)
                                        .accessibilityIdentifier("transcript-turn-" + row.id)
                                    if model.state.isReadOnly {
                                        Text(row.name).font(.headline).textSelection(.enabled)
                                    } else {
                                        Button(action: {
                                            model.openSpeakerAssignment(for: row.id)
                                        }) {
                                            Text(row.name).font(.headline)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Назначить имя для реплики " + row.id)
                                        .accessibilityIdentifier("transcript-speaker-" + row.id)

                                        Button(action: {
                                            model.openTextEditing(for: row.id)
                                        }) {
                                            Image(systemName: "pencil")
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Редактировать текст реплики " + row.id)
                                        .accessibilityIdentifier("transcript-edit-text-" + row.id)
                                    }
                                }

                                if let textDraft = model.activeTextDraft, textDraft.turnID == row.id {
                                    VStack(alignment: .leading, spacing: 6) {
                                        TextEditor(text: Binding(
                                            get: { model.activeTextDraft?.text ?? "" },
                                            set: { model.updateDraftText($0, draftID: textDraft.id) }
                                        ))
                                        .frame(minHeight: 60)
                                        .padding(4)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                        .accessibilityIdentifier("transcript-text-editor-" + row.id)

                                        HStack {
                                            Button("Сохранить текст") {
                                                model.saveTextEditing(draftID: textDraft.id)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .accessibilityIdentifier("transcript-text-save-" + row.id)

                                            Button("Отмена") {
                                                model.cancelTextDraft(draftID: textDraft.id)
                                            }
                                            .accessibilityIdentifier("transcript-text-cancel-" + row.id)
                                        }
                                    }
                                    .padding(6)
                                    .background(Color.secondary.opacity(0.08))
                                    .cornerRadius(8)
                                } else {
                                    Text(row.text).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(model.activeTurnIDs.contains(row.id) ? Color.accentColor.opacity(0.15) : Color.clear)
                                .id(row.id)
                        }
                    }
                }
            }
            .onScrollPhaseChange { _, phase in model.userScrollPhaseChanged(phase) }
            .onChange(of: model.follow.request) { _, _ in
                guard model.follow.isFollowing, let target = model.follow.targetID else { return }
                proxy.scrollTo(target, anchor: .center)
            }
            }
            if !model.follow.isFollowing && model.playbackState != .closed {
                Button("Вернуться к воспроизведению") { model.returnToPlayback() }
                    .accessibilityLabel("Вернуться к воспроизведению")
                    .accessibilityIdentifier("transcript-return-to-playback")
            }
            Divider()
            HStack {
                Button(model.playbackState == .playing ? "Пауза" : "Воспроизвести") { model.togglePlayback() }
                    .disabled(!model.playbackEnabled)
                    .accessibilityIdentifier("transcript-play-pause")
                Text(Self.timestamp(model.playbackPosition) + " / " + Self.timestamp(model.playbackDuration))
                    .monospacedDigit().accessibilityIdentifier("transcript-playback-time")
                Slider(value: Binding(get: { model.playbackPosition }, set: { position in
                    Task { await model.seekPlayback(to: position) }
                }), in: 0...max(1, model.playbackDuration))
                    .disabled(!model.playbackEnabled)
                    .accessibilityLabel("Позиция воспроизведения")
                    .accessibilityIdentifier("transcript-playback-seek")
            }
            if let message = model.playbackMessage {
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel(message)
                    .accessibilityIdentifier("transcript-audio-status")
            }
        }.padding(20).frame(minWidth: 440, minHeight: 280)
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00" }
        // Input is validated finite/nonnegative; format without a narrowing Int conversion.
        return String(format: "%02.0f:%02.0f:%02.0f", floor(seconds / 3600), floor(seconds / 60).truncatingRemainder(dividingBy: 60), floor(seconds).truncatingRemainder(dividingBy: 60))
    }
}
