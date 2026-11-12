import AppKit
import Combine
import Foundation
import EventKit
import MeetingCompanionCore
import MeetingCompanionPlatform
import MeetingCompanionApplication
import SwiftUI

@main
struct MeetingCompanionApp: App {
    @NSApplicationDelegateAdaptor(RecorderAppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) { }
                CommandGroup(replacing: .appSettings) {
                    Button("Настройки…") { delegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .appInfo) {
                    Button("Проверить обновления…") { delegate.checkForUpdates() }
                }
            }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onAttach(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onAttach(window)
            }
        }
    }
}

protocol AudioLevelMonitoring: AnyObject, Sendable {
    func start() async throws
    func stop() async throws
}

@available(macOS 15.0, *)
extension AudioLevelMonitor: AudioLevelMonitoring {}

enum StartMeetingOutcome: Equatable, Sendable {
    case started
    case rejected(reason: String)
    case failed(reason: String)

    var isStarted: Bool {
        if case .started = self { return true }
        return false
    }

    var reason: String? {
        switch self {
        case .started: return nil
        case .rejected(let reason), .failed(let reason): return reason
        }
    }
}

@MainActor
final class RecorderViewModel: ObservableObject {
    typealias AudioLevelMonitorFactory = @Sendable (
        _ micID: String?,
        _ backend: AudioCaptureBackend,
        _ onLevels: @escaping @Sendable (Double, Double) -> Void
    ) async throws -> any AudioLevelMonitoring

    typealias AudioCheckTimeoutSleeper = @Sendable (_ duration: Duration) async throws -> Void
    static let defaultMicrophoneID = "__default__"
    private static let selectedMicrophoneIDKey = "selectedMicrophoneID"

    let defaults: UserDefaults
    let appDataDirectory: URL
    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appAppearance")
            NSApplication.shared.appearance = appearance.value
        }
    }

    @Published var outputDirectory: URL {
        willSet { history.invalidateRefresh() }
        didSet {
            defaults.set(outputDirectory.path, forKey: "recordingsDirectory")
            let root = outputDirectory
            Task {
                guard outputDirectory == root else { return }
                await history.refresh(root: root)
            }
        }
    }
    let calendar: MeetingCalendar
    let historyRepository: RecordingHistoryRepository
    let recordingSessionService: RecordingSessionService
    let processingService: ProcessingService
    let history: RecordingHistory
    let workspace: TranscriptReviewWindowManager
    @Published private(set) var recordingTrash: RecordingTrashPresentation?
    @Published private(set) var trashAdmitting = false
    @Published private(set) var trashCompletion: RecordingTrashCompletion?
    let recordingTrashOperation: @Sendable (URL) throws -> Void
    var trashOwnsInput: Bool { trashAdmitting || recordingTrash != nil }

    @Published private(set) var libraryRefreshPending = false
    var libraryRefreshTarget: @MainActor () -> Bool = { false }

    private var admitsLibraryRefresh: Bool {
        libraryRefreshTarget() && mainPage == .history && isAttached
            && !settingsPresented && !trashOwnsInput && !workspace.hasInput
            && !workspace.nativeInput() && !workspace.loading
    }

    var canRefreshLibrary: Bool {
        admitsLibraryRefresh && !libraryRefreshPending && !history.loading
    }

    @discardableResult
    func requestRecordingForm() -> Bool {
        guard canStartRecording, !workspace.nativeInput() else { return false }
        mainPage = .recording
        return mainPage == .recording
    }

    @discardableResult
    func requestLibraryRefresh() -> Bool {
        guard canRefreshLibrary else { return false }
        libraryRefreshPending = true
        let root = outputDirectory
        Task { [weak self] in
            guard let self else { return }
            defer { self.libraryRefreshPending = false }
            guard self.admitsLibraryRefresh, !self.history.loading, self.outputDirectory == root else { return }
            await self.history.refresh(root: root, manual: true, preservingMissing: { @MainActor [weak self] in
                guard let self, self.workspace.hasInput || self.workspace.nativeInput(),
                      let selected = self.selectedHistoryURL else { return [] }
                return [selected]
            })
            guard self.outputDirectory == root, self.history.refreshError == nil,
                  let selected = self.selectedHistoryURL, self.history.entry(selected) == nil,
                  !self.workspace.hasInput, !self.workspace.nativeInput() else { return }
            self.workspace.closeCurrent()
            self.historySelection = nil
            self.workspaceOpenGeneration += 1
        }
        return true
    }

    func renameRecording(_ recording: URL, displayTitle: String) async throws {
        guard !trashOwnsInput, !settingsPresented else {
            throw TranscriptEditsError.conflict("Сначала завершите открытое подтверждение.")
        }
        try await history.rename(recording, displayTitle: displayTitle)
    }

    func trashUnavailableReason(_ entry: RecordingEntry) -> String? {
        if !RecordingPaths.isStandardLayout(entry.recording) { return "Доступно только для записи в отдельной папке" }
        let jobs = (latestProcessingSnapshot?.queued ?? []) + (latestProcessingSnapshot?.admitting ?? []) + [latestProcessingSnapshot?.active].compactMap { $0 }
        if entry.phase.isWorking || pendingProcessingEnqueues.values.contains(entry.id)
            || jobs.contains(where: { $0.recordingURL == entry.id })
            || lastFileURL == entry.id && (isRecording || sessionStarting || sessionStopping) {
            return "Дождитесь завершения работы с записью"
        }
        return nil
    }

    @discardableResult
    func requestRecordingTrash(_ recording: URL) async -> Bool {
        guard !trashOwnsInput, workspace.admitNavigation(), !workspace.nativeInput(), isAttached, !workspace.loading,
              !workspaceRequested || completedWorkspaceLoadRequest == workspaceLoadRequest,
              let entry = history.entry(recording) else { return false }
        if let reason = trashUnavailableReason(entry) { history.reportError(reason, recording: recording); return false }
        history.clearNotice()
        trashAdmitting = true
        workspace.current?.invalidateQueuedPlaybackSeek()
        defer { trashAdmitting = false }
        do {
            let repository = historyRepository, root = outputDirectory
            let target = try await Task.detached { try repository.prepareTrash(recording, root: root) }.value
            guard !Task.isCancelled, !settingsPresented, !workspace.nativeInput(), !workspace.externalModal,
                  workspace.current?.currentDraftIdentity == nil, root == outputDirectory else { return false }
            recordingTrash = RecordingTrashPresentation(target: target, title: entry.effectiveTitle)
            return true
        } catch { history.reportError(error.localizedDescription, recording: recording); return false }
    }

    func cancelRecordingTrash() {
        guard recordingTrash?.pending != true else { return }
        recordingTrash = nil
        if workspace.current == nil, selectedHistoryURL != nil { _ = requestWorkspaceOpen() }
    }

    func confirmRecordingTrash() async {
        guard let presentation = recordingTrash, !presentation.pending,
              presentation.error == nil || presentation.retryAllowed else { return }
        recordingTrash?.pending = true
        recordingTrash?.error = nil
        recordingTrash?.retryAllowed = false
        let repository = historyRepository, operation = recordingTrashOperation
        let hadReview = workspace.model(for: presentation.target.recording) != nil
        var reservation: UUID?
        do {
            let token = try await Task.detached { try repository.reserveTrash(presentation.target) }.value
            reservation = token
            guard await workspace.prepareForTrash(presentation.target.recording, ownsModal: { [weak self] in
                self?.recordingTrash?.id == presentation.id && self?.recordingTrash?.pending == true
            }) else { throw TranscriptEditsError.conflict("Сохраните или отмените ввод перед этим действием.") }
            try Task.checkCancellation()
            let outcome = try await Task.detached { try repository.trash(presentation.target, reservation: token, operation: operation) }.value
            reservation = nil
            await history.synchronize()
            if historySelection == presentation.target.recording {
                historySelection = nil
                workspaceOpenGeneration += 1
            }
            history.progress.removeValue(forKey: presentation.target.recording)
            if let preview = audioPreviewURL, preview.path.hasPrefix(presentation.target.folder.path + "/") { audioPreviewURL = nil }
            if lastFileURL == presentation.target.recording {
                lastFileURL = nil; capsuleDismissed = true; capsuleJobID = nil
                cancelCapsuleDeadline(); transcriptionState = .idle
            }
            trashCompletion = RecordingTrashCompletion(recording: presentation.target.recording)
            switch outcome {
            case .moved:
                recordingTrash = nil
                history.reportNotice("Запись перемещена в Корзину")
            case .unconfirmed(let reason):
                recordingTrash?.error = "Исходная папка отсутствует. Результат перемещения не подтверждён. " + reason
                recordingTrash?.pending = false
            }
        } catch {
            if let reservation { await Task.detached { repository.releaseTrash(presentation.target, id: reservation) }.value }
            recordingTrash?.error = error.localizedDescription
            recordingTrash?.retryAllowed = (error as? RecordingTrashFailure)?.retryAllowed ?? false
            if hadReview, workspace.current == nil, selectedHistoryURL == presentation.target.recording {
                _ = try? await workspace.reopenAfterFailedTrash(recordingURL: presentation.target.recording, title: presentation.title,
                    ownsModal: { [weak self] in self?.recordingTrash?.id == presentation.id })
            }
            recordingTrash?.pending = false
        }
    }
    @Published private(set) var settingsPresented = false
    @Published var settingsPage: RecorderSettingsView.Page = .general {
        didSet { onSettingsVisibilityChange?() }
    }
    var onSettingsVisibilityChange: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    @discardableResult
    func presentSettings() -> Bool {
        if settingsPresented { return true }
        guard workspace.admitNavigation() else { return false }
        if mainPage == .recording { formAudioCheckNeedsExplicitStart = true }
        workspace.current?.invalidateQueuedPlaybackSeek()
        settingsPresented = true
        onSettingsVisibilityChange?()
        return true
    }

    func dismissSettings() {
        settingsPresented = false
        onSettingsVisibilityChange?()
    }
    enum MainPage: String, CaseIterable, Identifiable {
        case recording, history
        var id: Self { self }
        var title: String { self == .recording ? "Запись" : "История" }
    }
    @Published private var pageSelection = MainPage.history
    var mainPage: MainPage {
        get { pageSelection }
        set {
            guard newValue != pageSelection, workspace.admitNavigation() else { return }
            if newValue == .recording { workspace.current?.invalidateQueuedPlaybackSeek() }
            pageSelection = newValue
            if newValue != .recording { formAudioCheckNeedsExplicitStart = false }
        }
    }
    @Published private var historySelection: URL?
    var selectedHistoryURL: URL? {
        get { historySelection }
        set { guard newValue != historySelection, workspace.admitNavigation() else { return }; historySelection = newValue }
    }
    @Published private(set) var workspaceRequested = false
    @Published private var workspaceOpenGeneration = 0
    struct WorkspaceLoadRequest: Equatable {
        let requested: Bool
        let generation: Int
        let url: URL?
        let phase: RecordingEntry.Phase?
        let jobs: Int
    }
    private var completedWorkspaceLoadRequest: WorkspaceLoadRequest?
    var workspaceLoadRequest: WorkspaceLoadRequest {
        WorkspaceLoadRequest(requested: workspaceRequested, generation: workspaceOpenGeneration,
            url: selectedHistoryURL, phase: selectedHistoryURL.flatMap { history.entry($0)?.phase }, jobs: transcriptionJobs)
    }

    @discardableResult
    func requestWorkspaceOpen() -> WorkspaceLoadRequest? {
        guard workspace.admitNavigation() else { return nil }
        mainWindowRequested = true
        workspaceRequested = true
        workspaceOpenGeneration += 1
        return workspaceLoadRequest
    }

    @discardableResult
    func loadWorkspace(_ request: WorkspaceLoadRequest) async -> Bool {
        guard !Task.isCancelled, request.requested, request == workspaceLoadRequest,
              let url = request.url, let entry = history.entry(url),
              workspace.admitNavigation() else { return false }
        defer {
            if !Task.isCancelled, request == workspaceLoadRequest, !workspace.hasInput {
                completedWorkspaceLoadRequest = request
            }
        }
        do {
            let target = try await workspace.open(recordingURL: url, title: entry.effectiveTitle)
            return !Task.isCancelled && request == workspaceLoadRequest && !workspace.hasInput
                && workspace.current === target && target.state.id == url && !target.state.isClosed
        } catch { return false }
    }

    @Published private var workspaceListVisible = true
    @Published var workspaceSearchRequest: UUID?
    var workspaceShowsList: Bool {
        get { workspaceListVisible }
        set { guard workspace.admitNavigation() else { return }; workspaceListVisible = newValue }
    }

    func admitWindowClose(isWorkspace: Bool) -> Bool {
        guard isWorkspace else { return true }
        guard workspace.admitNavigation() else { return false }
        workspaceRequested = false
        workspaceOpenGeneration += 1
        mainWindowRequested = false
        workspace.closeCurrent()
        return true
    }

    @discardableResult
    func showTranscript(_ recording: URL) -> WorkspaceLoadRequest? {
        guard workspace.admitNavigation() else { return nil }
        selectedHistoryURL = RecordingEntry.canonicalURL(recording)
        mainPage = .history
        workspaceShowsList = false
        return requestWorkspaceOpen()
    }

    func selectLibraryRecording(_ recording: URL) {
        guard workspace.admitNavigation() else { return }
        selectedHistoryURL = RecordingEntry.canonicalURL(recording)
        _ = requestWorkspaceOpen()
    }

    @Published var audioPreviewURL: URL?
    @Published var reminderMeeting: MeetingContext?
    @Published var mainWindowRequested = false
    private var meetingTransitionInProgress = false
    var onAfterStopRecordingInMeetingTransitionForTesting: (@MainActor () async -> Void)?
    private var historySubscription: AnyCancellable?
    private var capsuleTimer: Timer?
    typealias CapsuleTimerScheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Timer
    private let scheduleCapsuleTimer: CapsuleTimerScheduler
    private var capsuleDeadlineID: UUID?
    private var capsuleJobID: UUID?
    private var pendingCapsuleEnqueue: UUID?
    @Published private var pendingProcessingEnqueues: [UUID: URL] = [:]
    private var latestProcessingSnapshot: ProcessingService.Snapshot?
    private var activeRecordingURL: URL?
    private(set) var recordingMeetingID: String?

    @Published private var meetingSelection = MeetingSelection()
    private var calendarSubscription: AnyCancellable?
    private var meetingSelectionTimer: Timer?
    var selectedMeeting: MeetingContext? {
        get { meetingSelection.meeting }
        set {
            guard !settingsPresented else { return }
            meetingSelection.select(newValue)
            refreshMeetingSelection()
        }
    }
    @Published var isBusy = false
    @Published var isRecording = false { didSet { updateLevelVisibility() } }
    @Published var recordingSaveError: String?
    @Published private(set) var microphoneMuted = false
    @Published private(set) var microphoneState: MicrophoneRecordingState = .receiving
    var microphoneCaptureHint: String {
        switch microphoneState {
        case .receiving: return ""
        case .silent: return "Проверьте микрофон: долго нет звука"
        case .missing: return "Микрофон не записывается"
        case .reconnecting: return "Переподключаем микрофон…"
        }
    }
    @Published private(set) var mutedMicrophoneActivity = false
    private var muteActivity = MutedMicrophoneActivity()

    func toggleMicrophoneMute(sessionID: UUID? = nil) {
        guard isRecording, !isBusy else { return }
        guard let sessionID, sessionID == activeSessionID else {
            errorMessage = RecordingSessionService.ServiceError.staleCommand.localizedDescription
            return
        }
        let muted = !microphoneMuted
        Task {
            let accepted = await recordingSessionService.setMicrophoneMuted(muted, expectedSessionID: sessionID)
            let state = await recordingSessionService.currentMicrophoneState()
            guard activeSessionID == sessionID, isRecording else { return }
            guard accepted else {
                errorMessage = RecordingSessionService.ServiceError.staleCommand.localizedDescription
                return
            }
            microphoneMuted = muted
            microphoneState = state
            muteActivity = MutedMicrophoneActivity()
            mutedMicrophoneActivity = false
            levels.reset()
        }
    }

    @Published private(set) var processingRoutes: [URL: ProcessingProgressSnapshot] = [:]
    var capsuleProgress: ProcessingProgressSnapshot? {
        guard let lastFileURL, let snapshot = processingRoutes[lastFileURL], snapshot.jobID == capsuleJobID else { return nil }
        return snapshot
    }

    @Published var capsuleDismissed = false
    @Published private(set) var transcriptionWarnings: [String] = []
    @Published private(set) var lastRecordingTitle = "Запись встречи"
    @Published var improveTerms: Bool {
        didSet {
            defaults.set(improveTerms, forKey: "improveTechnicalTerms")
            transcriptionReady = false
            let selected = improveTerms
            Task {
                let result = try? await Transcription.checkDependencies(availability: true, parakeet: selected)
                guard improveTerms == selected else { return }
                transcriptionReady = result?.succeeded ?? false
            }
        }
    }
    @Published var echoCancellation: Bool {
        didSet { defaults.set(echoCancellation, forKey: "echoCancellation") }
    }
    @Published var activeSessionID: UUID?
    @Published private(set) var sessionStarting = false
    private var preparingCapture = false
    @Published private(set) var isAdmittingProcessing = false
    var onPresentWorkspace: (() -> Void)?

    var showsRecordingCapsule: Bool {
        isRecording || sessionStarting || sessionStopping || (!capsuleDismissed && (recordingCancelled || recordingSaveError != nil || transcriptionState != .idle))
    }
    var showsProcessingCapsule: Bool { !isRecording && !sessionStarting && !sessionStopping && !recordingCancelled && recordingSaveError == nil && showsRecordingCapsule }
    @Published private(set) var recordingCancelled = false
    var showsCancelRecording: Bool { isRecording && elapsed < 10 }

    func dismissCapsule() {
        guard !sessionStarting, !sessionStopping, !showsProcessingCapsule else { return }
        capsuleDismissed = true
    }

    func prepareForAutomaticReminder() {
        guard !isRecording, pendingCapsuleEnqueue == nil, transcriptionJobs == 0 else { return }
        if case .running = transcriptionState { return }
        capsuleDismissed = true
    }

    @Published var processingNavigationNotice: String?
    func showProcessingDetails() {
        guard let lastFileURL, history.entry(lastFileURL) != nil else { return }
        guard showTranscript(lastFileURL) != nil else {
            processingNavigationNotice = workspace.commandNotice
            return
        }
        processingNavigationNotice = nil
        onPresentWorkspace?()
    }

    @Published private var recordingOvertime: RecordingOvertime?
    var showsOvertimeReminder: Bool {
        guard isRecording, !isBusy, recordingSaveError == nil, let startedAt else { return false }
        return recordingOvertime?.needsReminder(at: startedAt.addingTimeInterval(elapsed)) ?? false
    }
    var overtimeMessage: String {
        recordingOvertime?.hasMeeting == true ? "Время встречи истекло" : "Запись длится больше часа"
    }
    func postponeOvertimeReminder() {
        recordingOvertime?.postpone(at: Date())
    }

    func openResults() {
        guard case .completed = transcriptionState,
              !isRecording, !sessionStarting, !sessionStopping,
              let lastFileURL, let entry = history.entry(lastFileURL), entry.phase == .completed,
              entry.capabilities.canReview || entry.capabilities.hasSavedText,
              showTranscript(lastFileURL) != nil else { return }
        let deadlineID = capsuleDeadlineID, jobID = capsuleJobID, terminalState = transcriptionState
        onPresentWorkspace?()
        let request = workspaceLoadRequest
        Task {
            let opened = await loadWorkspace(request)
            guard opened, !workspace.hasInput, request == workspaceLoadRequest, request.url == entry.id,
                  workspace.current?.state.id == entry.id, workspace.failure == nil,
                  self.lastFileURL == lastFileURL, transcriptionState == terminalState,
                  capsuleDeadlineID == deadlineID, capsuleJobID == jobID,
                  pendingCapsuleEnqueue == nil, transcriptionJobs == 0, !isAdmittingProcessing,
                  !isRecording, !sessionStarting, !sessionStopping,
                  !recordingCancelled, recordingSaveError == nil else { return }
            capsuleDismissed = true
        }
    }
    @Published var elapsed: TimeInterval = 0
    @Published var status = "Готов к записи"
    @Published var lastFileURL: URL?
    @Published private(set) var transcriptionState: TranscriptionState = .idle
    var lastTranscriptURL: URL? { transcriptionState.transcript }
    @Published var transcriptionJobs = 0
    @Published var transcriptionReady: Bool {
        didSet { defaults.set(transcriptionReady, forKey: "transcriptionPrepared") }
    }
    var transcriptionStatus: String {
        if let url = lastFileURL, let entry = history.entry(url), [.queued, .saving].contains(entry.phase) { return entry.status + "…" }
        return transcriptionState.text
    }
    @Published var captureBackend: AudioCaptureBackend {
        didSet {
            defaults.set(captureBackend.rawValue, forKey: "captureBackend")
            captureCheck = nil
            refreshAccess()
        }
    }
    private var captureCheck: RecorderDiagnostics.Access?
    @Published var diagnosticAccess: [RecorderDiagnostics.Access] = []
    @Published var diagnosticReport = ""
    @Published private var localDiagnosticRunning = false
    @Published private var preparationState: ProcessingService.PreparationState = .idle
    var diagnosticRunning: Bool { localDiagnosticRunning || preparationState != .idle }
    var diagnosticStatusText: String {
        if isResettingCache { return "Сброс кэша…" }
        if diagnosticRunning { return preparationState == .preparing ? "Скачивание и проверка моделей…" : "Проверка моделей…" }
        return transcriptionReady ? "Готово" : "Требуется проверка или подготовка"
    }
    @Published private(set) var lastTerminalSummary: String?
    var diagnosticSummary: String? {
        if diagnosticRunning {
            return diagnosticReport.split(separator: "\n").last.map(String.init)
        }
        if let lastTerminalSummary, !lastTerminalSummary.isEmpty {
            return lastTerminalSummary
        }
        return diagnosticReport.split(separator: "\n").last.map(String.init)
    }
    var isFollowAvailable: Bool { workspace.current != nil }
    var isEditorFollowing: Bool { workspace.current?.follow.isFollowing ?? false }
    func setEditorFollowing(_ follow: Bool) {
        workspace.current?.setFollow(follow)
    }
    private func rebindCurrentEditor(_ current: TranscriptReviewWindowModel?) {
        currentEditorSubscription?.cancel()
        currentEditorSubscription = current?.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }
    private(set) var activeAudioCheckSection: RecorderSettingsView.Page?
    private var recordingFormVisible = false
    private var formAudioCheckNeedsExplicitStart = false
    private var settingsAudioCheckVisible = false
    private var settingsAudioCheckSection: RecorderSettingsView.Page?
    private var audioCheckVisibilityTransition = false
    var isAudioCheckVisibleForTesting: Bool { isAudioCheckVisible }
    @Published private var sessionAttached = false
    @Published private var processingAttached = false
    @Published private(set) var sessionStopping = false
    private var sessionObservation: Task<Void, Never>?
    private var processingObservation: Task<Void, Never>?
    private var shouldCheckDependenciesAfterAttachment = false
    @Published private(set) var isResettingCache = false
    @Published var diagnosticStartedAt: Date?
    @Published var preparationProgress: RecorderDiagnostics.PreparationProgress?
    private var progressProbeRunning = false
    @Published var errorMessage: String?
    @Published var microphones: [MicrophoneDevice] = []
    @Published var selectedMicrophoneID: String {
        didSet {
            defaults.set(selectedMicrophoneID, forKey: RecorderViewModel.selectedMicrophoneIDKey)
        }
    }
    let levels = AudioLevels()
    var preventsTermination: Bool {
        workspace.hasInput || hasBlockingWork
    }
    var preventsSettingsOperation: Bool { workspace.hasForeignInput || hasBlockingWork }
    private var hasBlockingWork: Bool {
        resetCommitBlockedByWork || localDiagnosticRunning || isResettingCache
    }
    private var resetCommitBlockedByWork: Bool {
        !sessionAttached || !processingAttached || preparingCapture || sessionStarting || sessionStopping || isRecording || isBusy || transcriptionJobs > 0 || isAdmittingProcessing || !pendingProcessingEnqueues.isEmpty || preparationState != .idle || isCheckingAudio
    }

    var onRecordingStarted: (() -> Void)?
    @Published var isCapsuleVisible = false { didSet { updateLevelVisibility() } }
    var isAttached: Bool { sessionAttached && processingAttached }
    var canStartRecording: Bool {
        isAttached && !isRecording && !sessionStarting && !sessionStopping && !isBusy && !diagnosticRunning && !workspace.hasInput
    }

    func setAttachedForTesting(session: Bool, processing: Bool) {
        sessionAttached = session
        processingAttached = processing
    }

    func setMicrophoneMutedForTesting(_ muted: Bool) {
        microphoneMuted = muted
    }

    func setLocalDiagnosticRunningForTesting(_ running: Bool) {
        localDiagnosticRunning = running
    }

    func setSessionStoppingForTesting(_ stopping: Bool) {
        sessionStopping = stopping
    }

    func setSessionStartingForTesting(_ starting: Bool) {
        sessionStarting = starting
    }

    func setIsAdmittingProcessingForTesting(_ admitting: Bool) {
        isAdmittingProcessing = admitting
    }

    func setRecordingMeetingIDForTesting(_ id: String?) {
        recordingMeetingID = id
    }

    @discardableResult
    func startRecordingIntent(customTitle: String? = nil) async -> Bool {
        guard canStartRecording else { return false }
        let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let customTitle, let title, title.isEmpty || title.count > 120 || customTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            errorMessage = "Название: от 1 до 120 символов, без управляющих символов."
            return false
        }
        isBusy = true
        await startRecording(meeting: selectedMeeting, displayTitle: title)
        return isRecording
    }

    @discardableResult
    func stopRecordingIntent(sessionID: UUID? = nil) async -> Bool {
        guard sessionAttached, processingAttached, isRecording, !sessionStopping, !isBusy else {
            return false
        }
        guard let sessionID, sessionID == activeSessionID else {
            errorMessage = RecordingSessionService.ServiceError.staleCommand.localizedDescription
            return false
        }
        guard elapsed >= 10 else { errorMessage = "Для записи короче 10 секунд выберите явную отмену."; return false }
        isBusy = true
        return await stopRecording(expectedSessionID: sessionID, cancelShort: false)
    }

    @discardableResult
    func cancelRecordingIntent(sessionID: UUID? = nil) async -> Bool {
        guard sessionAttached, processingAttached, isRecording, !sessionStopping, !isBusy else {
            return false
        }
        guard let sessionID, sessionID == activeSessionID else {
            errorMessage = RecordingSessionService.ServiceError.staleCommand.localizedDescription
            return false
        }
        guard showsCancelRecording else {
            errorMessage = RecordingSessionService.ServiceError.shortCancellationExpired.localizedDescription
            return false
        }
        isBusy = true
        return await stopRecording(expectedSessionID: sessionID, cancelShort: true)
    }


    private var isWindowVisible = false
    private var isAudioCheckVisible = false
    private var isLevelDisplayActive = false
    @Published private(set) var isCheckingAudio = false { didSet { updateLevelVisibility() } }
    private var audioCheckTimeout: Task<Void, Never>?
    private var recorder: Recorder?
    private let captureControllerFactory: (@MainActor (URL, String?, AudioCaptureBackend) async throws -> any AudioCaptureControllerProtocol)?
    private let shortRecordingTrash: (@Sendable (URL) throws -> Void)?
    private var workspaceSubscription: AnyCancellable?
    private var currentEditorSubscription: AnyCancellable?
    private var currentLevelMonitorID: UUID?
    private let audioLevelMonitorFactory: AudioLevelMonitorFactory?
    private let audioCheckTimeoutSleeper: AudioCheckTimeoutSleeper?
    private let audioCheckTimeoutDuration: Duration
    private let microphoneProvider: (() -> [MicrophoneDevice])?
    private let accessProvider: (() -> [RecorderDiagnostics.Access])?
    private var levelMonitor: (any AudioLevelMonitoring)?
    private var levelMonitorTask: Task<Void, Never>?
    private var startedAt: Date?
    private var timer: Timer?

    var elapsedText: String {
        formatClock(elapsed)
    }

    var selectedMicrophoneDeviceID: String? {
        selectedMicrophoneID == Self.defaultMicrophoneID ? nil : selectedMicrophoneID
    }

    init(
        sessionService: RecordingSessionService? = nil,
        processingService: ProcessingService? = nil,
        historyRepository: RecordingHistoryRepository? = nil,
        workspace: TranscriptReviewWindowManager? = nil,
        defaults: UserDefaults = .standard,
        appDataDirectory: URL = RecorderDiagnostics.dataDirectory,
        startBackgroundServices: Bool = true,
        captureControllerFactory: (@MainActor (URL, String?, AudioCaptureBackend) async throws -> any AudioCaptureControllerProtocol)? = nil,
        shortRecordingTrash: (@Sendable (URL) throws -> Void)? = nil,
        recordingTrashOperation: (@Sendable (URL) throws -> Void)? = nil,
        audioLevelMonitorFactory: AudioLevelMonitorFactory? = nil,
        audioCheckTimeoutSleeper: AudioCheckTimeoutSleeper? = nil,
        audioCheckTimeoutDuration: Duration = .seconds(30),
        microphoneProvider: (() -> [MicrophoneDevice])? = nil,
        accessProvider: (() -> [RecorderDiagnostics.Access])? = nil,
        calendarCatalogProvider: (() -> [EKCalendar])? = nil,
        capsuleTimerScheduler: CapsuleTimerScheduler? = nil
    ) {
        self.scheduleCapsuleTimer = capsuleTimerScheduler ?? { interval, action in
            Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
                Task { @MainActor in action() }
            }
        }
        self.captureControllerFactory = captureControllerFactory
        self.shortRecordingTrash = shortRecordingTrash
        self.recordingTrashOperation = recordingTrashOperation ?? { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        self.audioLevelMonitorFactory = audioLevelMonitorFactory
        self.audioCheckTimeoutSleeper = audioCheckTimeoutSleeper
        self.audioCheckTimeoutDuration = audioCheckTimeoutDuration
        self.microphoneProvider = microphoneProvider
        self.accessProvider = accessProvider
        self.defaults = defaults
        self.appDataDirectory = appDataDirectory
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: "appAppearance") ?? "") ?? .system
        self.outputDirectory = defaults.string(forKey: "recordingsDirectory").map { URL(fileURLWithPath: $0) } ?? RecordingPaths.defaultOutputDirectory
        self.improveTerms = defaults.bool(forKey: "improveTechnicalTerms")
        self.echoCancellation = defaults.bool(forKey: "echoCancellation")
        self.transcriptionReady = defaults.bool(forKey: "transcriptionPrepared")
        self.captureBackend = AudioCaptureBackend(rawValue: defaults.string(forKey: "captureBackend") ?? "") ?? .coreAudioTap
        self.selectedMicrophoneID = defaults.string(forKey: Self.selectedMicrophoneIDKey) ?? Self.defaultMicrophoneID
        self.calendar = MeetingCalendar(defaults: defaults, calendarCatalogProvider: calendarCatalogProvider)
        let repo = historyRepository ?? RecordingHistoryRepository()
        self.historyRepository = repo
        self.recordingSessionService = sessionService ?? RecordingSessionService(historyRepo: repo)
        let proc = processingService ?? ProcessingService(
            transcriptionRunner: PlatformTranscriptionRunner(),
            audioExporter: PlatformAudioExporter(),
            historyRepository: repo
        )
        self.workspace = workspace ?? TranscriptReviewWindowManager(isProcessing: { await proc.isProcessing(recordingURL: $0) })
        self.processingService = proc
        self.history = RecordingHistory(repository: repo)
        self.workspace.settingsInput = { [weak self] in self?.settingsPresented ?? false }
        self.workspace.trashInput = { [weak self] in self?.trashOwnsInput ?? false }

        self.workspaceSubscription = self.workspace.$current.sink { [weak self] current in
            self?.rebindCurrentEditor(current)
            self?.objectWillChange.send()
        }
        if let current = self.workspace.current {
            rebindCurrentEditor(current)
        }

        // Retire the old setting; unknown combined backends fall back to unprocessed Core Audio Tap.
        defaults.removeObject(forKey: "microphoneVoiceProcessing")
        defaults.set(captureBackend.rawValue, forKey: "captureBackend")
        calendarSubscription = calendar.$events.sink { [weak self] events in
            self?.refreshMeetingSelection(events: events)
        }
        historySubscription = history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if startBackgroundServices {
            Task { await history.refresh(root: outputDirectory) }
            refreshMicrophones()
            refreshAccess()
            startTimer()
            shouldCheckDependenciesAfterAttachment = !transcriptionReady
        }

        let session = self.recordingSessionService
        sessionObservation = Task { [weak self] in
            let stream = await session.observe()
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                self?.applySessionSnapshot(snapshot)
            }
        }
        processingObservation = Task { [weak self] in
            let stream = await proc.observe()
            for await update in stream {
                guard !Task.isCancelled else { break }
                switch update {
                case .snapshot(let snapshot): self?.applyProcessingSnapshot(snapshot)
                case .event(let event): await self?.handleProcessingEvent(event)
                }
            }
        }
    }

    deinit {
        sessionObservation?.cancel()
        processingObservation?.cancel()
    }

    private func applySessionSnapshot(_ snapshot: RecordingSessionSnapshot) {
        sessionAttached = true
        defer { checkDependenciesAfterAttachment() }
        recordingMeetingID = snapshot.meetingID
        sessionStopping = false
        switch snapshot.phase {
        case .starting:
            cancelCapsuleDeadline()
            pendingCapsuleEnqueue = nil
            capsuleJobID = nil
            sessionStarting = true
            isRecording = false
            sessionStopping = false
            activeSessionID = snapshot.sessionID
        case .recording(let url, let date):
            cancelCapsuleDeadline()
            sessionStarting = false
            isRecording = true
            sessionStopping = false
            activeRecordingURL = url
            activeSessionID = snapshot.sessionID
            lastFileURL = url
            startedAt = date
            elapsed = max(0, Date().timeIntervalSince(date))
            lastRecordingTitle = history.entry(url)?.effectiveTitle ?? snapshot.meetingSummary ?? "Запись встречи"
            status = "Идёт запись"
        case .stopping(let url):
            sessionStarting = false
            isRecording = false
            activeRecordingURL = url
            sessionStopping = true
            status = "Сохранение…"
        case .idle, .cancelledShort, .failed:
            sessionStarting = preparingCapture
            isRecording = false
            sessionStopping = false
            activeSessionID = nil
            activeRecordingURL = nil
        }
    }

    private func applyProcessingSnapshot(_ snapshot: ProcessingService.Snapshot) {
        latestProcessingSnapshot = snapshot
        let isInitialAttachment = !processingAttached
        processingAttached = true
        defer { checkDependenciesAfterAttachment() }
        preparationState = snapshot.preparation
        transcriptionJobs = snapshot.jobCount
        isAdmittingProcessing = !snapshot.admitting.isEmpty
        history.progress = snapshot.progress
        processingRoutes = snapshot.routes
        if isInitialAttachment, snapshot.preparation != .idle {
            diagnosticReport = snapshot.preparation == .preparing ? "Скачивание и проверка моделей…" : "Проверка транскрибации…"
        }
        if !recordingCancelled, !isRecording, !sessionStarting, !sessionStopping,
           let job = snapshot.active ?? snapshot.queued.first ?? snapshot.admitting.first {
            cancelCapsuleDeadline()
            capsuleJobID = job.id
            pendingCapsuleEnqueue = nil
            lastFileURL = job.recordingURL
            lastRecordingTitle = history.entry(job.recordingURL)?.effectiveTitle ?? "Запись встречи"
            transcriptionState = .running(snapshot.progress[job.recordingURL])
        }
    }

    private func checkDependenciesAfterAttachment() {
        guard sessionAttached, processingAttached, shouldCheckDependenciesAfterAttachment else { return }
        shouldCheckDependenciesAfterAttachment = false
        Task { await checkTranscription(prepare: false) }
    }

    private func handleProcessingEvent(_ event: ProcessingService.Event) async {
        await history.synchronize()
        switch event {
        case .enqueued(let job), .started(let job):
            if lastFileURL == job.recordingURL, !isRecording, !sessionStarting, !sessionStopping {
                cancelCapsuleDeadline()
                capsuleJobID = job.id
                pendingCapsuleEnqueue = nil
            }
            syncProcessingPresentation(job.recordingURL)
        case .progress(let job, let progress):
            guard capsuleJobID == job.id else { return }
            history.progress[job.recordingURL] = progress
            syncProcessingPresentation(job.recordingURL)
        case .completed(let job, _, let warning), .failed(let job, _, let warning), .cancelled(let job, let warning):
            history.progress.removeValue(forKey: job.recordingURL)
            if let warning { history.reportError(warning, recording: job.recordingURL) }
            if capsuleJobID == job.id, pendingCapsuleEnqueue == nil {
                syncProcessingPresentation(job.recordingURL)
            }
        case .persistenceWarning(let job, let warning): history.reportError(warning, recording: job.recordingURL)
        case .dependenciesChecked(let output, let succeeded):
            transcriptionReady = succeeded
            let summary = succeeded ? "Транскрибация готова." : "Проверка транскрибации не пройдена."
            lastTerminalSummary = summary
            diagnosticReport = output + "\n" + summary
        }
    }

    func setWindowVisible(_ visible: Bool) {
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        updateLevelVisibility()
        refreshMeetingSelection()
    }

    private func refreshMeetingSelection(events: [MeetingContext]? = nil) {
        meetingSelectionTimer?.invalidate()
        guard !isRecording, !isBusy else { return }
        let events = events ?? calendar.events
        let now = Date()
        var selection = meetingSelection
        selection.refresh(events: events, now: now)
        if selection != meetingSelection { meetingSelection = selection }
        guard isWindowVisible, let boundary = MeetingSelection.nextBoundary(events: events, now: now) else { return }
        meetingSelectionTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, boundary.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshMeetingSelection() }
        }
    }

    func setAudioCheckVisible(_ visible: Bool, section: RecorderSettingsView.Page? = nil) {
        guard settingsAudioCheckVisible != visible || settingsAudioCheckSection != section else { return }
        settingsAudioCheckVisible = visible
        settingsAudioCheckSection = section
        refreshAudioCheckVisibility()
    }

    func setRecordingFormVisible(_ visible: Bool) {
        guard recordingFormVisible != visible else { return }
        recordingFormVisible = visible
        refreshAudioCheckVisibility()
    }

    private func refreshAudioCheckVisibility() {
        isAudioCheckVisible = recordingFormVisible || settingsAudioCheckVisible
        let section = recordingFormVisible ? nil : settingsAudioCheckSection
        updateLevelVisibility()
        if isCheckingAudio && (!isAudioCheckVisible || activeAudioCheckSection != section) {
            guard !audioCheckVisibilityTransition else { return }
            currentLevelMonitorID = nil
            audioCheckVisibilityTransition = true
            Task {
                await endAudioCheck()
                audioCheckVisibilityTransition = false
                refreshAudioCheckVisibility()
            }
        } else if recordingFormVisible && !formAudioCheckNeedsExplicitStart && !isCheckingAudio && !audioCheckVisibilityTransition {
            toggleAudioCheck(from: nil)
        }
    }

    func handleLevels(mic: Double, system: Double) {
        if system.isFinite { updateCaptureCheck(succeeded: true) }
        if mic.isFinite {
            let active = muteActivity.receive(mic, muted: microphoneMuted)
            if active != mutedMicrophoneActivity { mutedMicrophoneActivity = active }
        }
        guard isWindowVisible || isCapsuleVisible else { return }
        levels.receive(mic: microphoneMuted ? 0 : mic, system: system)
    }

    private func updateLevelVisibility() {
        let active = (isRecording && (isWindowVisible || isCapsuleVisible)) || (isCheckingAudio && isAudioCheckVisible)
        guard active != isLevelDisplayActive else { return }
        isLevelDisplayActive = active
        levels.setActive(active)
    }

    func toggleAudioCheck(from section: RecorderSettingsView.Page? = nil) {
        guard !isRecording, !isBusy, !diagnosticRunning, isAudioCheckVisible else { return }
        if isCheckingAudio {
            isCheckingAudio = false
            activeAudioCheckSection = nil
            Task { await endAudioCheck() }
            return
        }
        isCheckingAudio = true
        activeAudioCheckSection = section
        updateLevelVisibility()
        let duration = audioCheckTimeoutDuration
        let sleeper = audioCheckTimeoutSleeper
        audioCheckTimeout = Task { [weak self] in
            do {
                if let sleeper {
                    try await sleeper(duration)
                } else {
                    try await Task.sleep(for: duration)
                }
            }
            catch { return }
            await self?.endAudioCheck()
        }
        Task { await startLevelMonitor(reportErrors: true) }
    }

    func audioCheckActionTitle(for _: RecorderSettingsView.Page) -> String {
        isCheckingAudio ? "Завершить проверку звука" : "Проверить звук"
    }

    func toggleAudioCheck() {
        toggleAudioCheck(from: nil)
    }

    func endAudioCheck() async {
        isCheckingAudio = false
        activeAudioCheckSection = nil
        currentLevelMonitorID = nil
        audioCheckTimeout?.cancel()
        audioCheckTimeout = nil
        levels.reset()
        updateLevelVisibility()
        await stopLevelMonitor()
    }

    func chooseFolder(withPicker picker: ((URL) async -> URL?)? = nil) async {
        guard !isRecording, !isBusy, !diagnosticRunning else { return }
        let chosen: URL?
        if let picker {
            chosen = await picker(outputDirectory)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = outputDirectory
            chosen = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url = chosen else { return }
        do {
            try RecorderDiagnostics.checkFolder(url)
            outputDirectory = url
            errorMessage = nil
        } catch {
            errorMessage = "Выбранная папка недоступна: " + error.localizedDescription
        }
    }

    func chooseFolder() {
        Task { await chooseFolder(withPicker: nil) }
    }

    func openFolder() {
        NSWorkspace.shared.open(outputDirectory)
    }

    func revealLastFile() {
        guard let lastFileURL else {
            openFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: lastFileURL.path) ? lastFileURL : lastFileURL.deletingLastPathComponent()])
    }

    var canResetCache: Bool {
        !preventsSettingsOperation
    }

    func performCacheReset(in requestedDirectory: URL? = nil,
                           resetOperation: (@Sendable (URL, URL) throws -> Void)? = nil,
                           confirmation: (@MainActor (Int64) async -> Bool)? = nil) async {
        let directory = requestedDirectory ?? appDataDirectory
        guard !Task.isCancelled, canResetCache else { return }
        localDiagnosticRunning = true
        isResettingCache = true
        defer { localDiagnosticRunning = false; isResettingCache = false }
        let recordings = outputDirectory
        do {
            let bytes = try await Task.detached {
                let targets = try RecorderDiagnostics.cacheDirectories(in: directory, recordings: recordings)
                return targets.reduce(Int64(0)) { $0 + RecorderDiagnostics.preparationProgress(in: $1).bytes }
            }.value
            let confirmed: Bool
            if let confirmation {
                confirmed = await confirmation(bytes)
            } else {
                let alert = NSAlert()
                alert.messageText = "Сбросить кэш транскрибации?"
                alert.informativeText = "Будет удалён локальный кэш моделей и подготовки Meeting Companion (" +
                    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) +
                    "). Для транскрибации потребуется скачать их заново. Записи, тексты, настройки и разрешения сохранятся."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Отмена")
                alert.addButton(withTitle: "Сбросить кэш")
                confirmed = (alert.runModal() == .alertSecondButtonReturn)
            }
            guard confirmed, !Task.isCancelled else { return }
            let work = await processingService.currentSnapshot()
            let preparation = await processingService.currentPreparationState
            guard work.active == nil, work.queued.isEmpty, preparation == .idle,
                  !Task.isCancelled, !workspace.hasForeignInput, !resetCommitBlockedByWork,
                  isResettingCache, localDiagnosticRunning, outputDirectory == recordings else { return }
            // No async handoff between final admission and the destructive operation.
            lastTerminalSummary = nil
            transcriptionReady = false
            diagnosticReport = "Удаление локального кэша моделей и подготовки…"
            if let resetOperation { try resetOperation(directory, recordings) }
            else { try RecorderDiagnostics.resetCache(in: directory, recordings: recordings) }
            preparationProgress = nil
            transcriptionState = .idle
            let summary = "Кэш сброшен. Нажмите «Скачать модели» перед транскрибацией."
            lastTerminalSummary = summary
            diagnosticReport = summary
        } catch {
            guard !Task.isCancelled, !workspace.hasForeignInput, !resetCommitBlockedByWork else { return }
            let errorText = "Ошибка сброса кэша: " + error.localizedDescription
            diagnosticReport = errorText
            lastTerminalSummary = errorText
        }
    }

    func resetCache() async {
        await performCacheReset()
    }

    func resetCache() {
        Task { await resetCache() }
    }

    func checkTranscription(prepare: Bool) async {
        guard sessionAttached, processingAttached, !sessionStopping, !diagnosticRunning, !isRecording, !isBusy, transcriptionJobs == 0 else { return }
        lastTerminalSummary = nil
        localDiagnosticRunning = true
        diagnosticStartedAt = Date()
        defer { localDiagnosticRunning = false; diagnosticStartedAt = nil; preparationProgress = nil }
        refreshAccess()
        diagnosticReport = "Проверка папки записей…"
        do {
            let directory = outputDirectory
            try await Task.detached { try RecorderDiagnostics.checkFolder(directory) }.value
            diagnosticReport = "Папка записей: OK\n" +
                (prepare ? "Проверка локальных моделей перед скачиванием…" : "Проверка файлов моделей по SHA-256…")
            let result = try await processingService.checkOrPrepareDependencies(
                prepare: prepare,
                parakeet: improveTerms
            ) { [weak self] output in
                Task { @MainActor in
                    guard let self, self.diagnosticRunning else { return }
                    self.diagnosticReport = "Папка записей: OK\n" + output
                }
            }
            transcriptionReady = result.succeeded
            let summary = result.succeeded ? "Транскрибация готова." : "Не удалось подготовить транскрибацию. Подробности выше."
            lastTerminalSummary = summary
            diagnosticReport = "Папка записей: OK\n" + result.output + "\n" + summary
            calendar.refresh()
        } catch {
            let errorText = "Ошибка: " + error.localizedDescription
            diagnosticReport = errorText
            lastTerminalSummary = errorText
        }
    }

    private func updateCaptureCheck(succeeded: Bool) {
        let result = RecorderDiagnostics.Access(name: "Системный звук",
            message: succeeded ? "захват проверен" : "проверка захвата не пройдена",
            state: succeeded ? .granted : .denied)
        guard captureCheck != result else { return }
        captureCheck = result
        refreshAccess()
    }

    func refreshAccess() {
        let access = accessProvider?() ?? RecorderDiagnostics.access(coreAudioTap: captureBackend == .coreAudioTap, captureCheck: captureCheck)
        if access != diagnosticAccess { diagnosticAccess = access }
    }

    func refreshPreparationProgress() {
        guard diagnosticRunning, !progressProbeRunning else { return }
        progressProbeRunning = true
        Task {
            defer { progressProbeRunning = false }
            let progress = await Task.detached(priority: .utility) {
                RecorderDiagnostics.preparationProgress(in: self.appDataDirectory)
            }.value
            if diagnosticRunning && preparationProgress != progress { preparationProgress = progress }
        }
    }

    func transcribeLastRecording() {
        guard let lastFileURL else { return }
        retryRecording(lastFileURL)
    }

    func prepareRecordingRetry(_ recording: URL) async -> Bool {
        guard await workspace.prepareForRetry(recording) else { return false }
        history.clearError(for: recording)
        return true
    }

    func retryRecording(_ recording: URL) {
        guard workspace.admitNavigation() else { return }
        guard sessionAttached, processingAttached, !sessionStopping, !isBusy, !diagnosticRunning, let entry = history.entry(recording), !entry.phase.isWorking else { return }
        if !entry.capabilities.canRetry {
            history.reportError(entry.capabilities.reason ?? "Исходные WAV отсутствуют или недоступны; повторная обработка невозможна.", recording: recording)
            return
        }
        if !isRecording {
            lastFileURL = recording
            lastRecordingTitle = entry.effectiveTitle
            recordingSaveError = nil
        }
        enqueue(recording, stopped: nil)
    }

    @discardableResult
    func startMeeting(
        _ meeting: MeetingContext?,
        expectedSessionID: UUID?,
        onOutcome: (@MainActor @Sendable (StartMeetingOutcome) -> Void)? = nil
    ) -> Task<StartMeetingOutcome, Never> {
        guard !meetingTransitionInProgress else {
            let reason = "Переход между записями уже выполняется."
            errorMessage = reason
            let outcome = StartMeetingOutcome.rejected(reason: reason)
            onOutcome?(outcome)
            return Task { outcome }
        }
        guard workspace.admitNavigation() else {
            let reason = workspace.commandNotice ?? "Сохраните или отмените ввод перед этим действием."
            errorMessage = reason
            let outcome = StartMeetingOutcome.rejected(reason: reason)
            onOutcome?(outcome)
            return Task { outcome }
        }
        guard sessionAttached, processingAttached, !sessionStarting, !sessionStopping, !isBusy, !diagnosticRunning else {
            let reason = "Meeting Companion занят выполнением операции."
            errorMessage = reason
            let outcome = StartMeetingOutcome.rejected(reason: reason)
            onOutcome?(outcome)
            return Task { outcome }
        }
        guard expectedSessionID == activeSessionID, expectedSessionID != nil || !isRecording else {
            let reason = RecordingSessionService.ServiceError.staleCommand.localizedDescription
            errorMessage = reason
            let outcome = StartMeetingOutcome.rejected(reason: reason)
            onOutcome?(outcome)
            return Task { outcome }
        }
        calendar.refresh()
        if let meeting {
            guard calendar.events.contains(where: { $0.id == meeting.id && $0 == meeting }) else {
                let reason = isRecording
                    ? "Встреча изменилась или удалена. Выберите её заново; текущая запись продолжается."
                    : "Встреча изменилась или удалена. Выберите её заново."
                errorMessage = reason
                let outcome = StartMeetingOutcome.rejected(reason: reason)
                onOutcome?(outcome)
                return Task { outcome }
            }
        }

        meetingTransitionInProgress = true
        isBusy = true
        let cancelShort = showsCancelRecording

        return Task { @MainActor [weak self] in
            guard let self else {
                return StartMeetingOutcome.rejected(reason: "Объект деинициализирован.")
            }
            defer {
                self.meetingTransitionInProgress = false
                self.isBusy = false
            }
            if let expectedSessionID {
                let stopped = await self.stopRecording(expectedSessionID: expectedSessionID, cancelShort: cancelShort)
                if !stopped {
                    let reason = self.recordingSaveError ?? self.errorMessage ?? "Не удалось завершить предыдущую запись."
                    self.errorMessage = reason
                    let outcome = StartMeetingOutcome.failed(reason: reason)
                    onOutcome?(outcome)
                    return outcome
                }
            }
            await self.onAfterStopRecordingInMeetingTransitionForTesting?()

            guard self.workspace.admitNavigation() else {
                let reason = self.workspace.commandNotice ?? "Сохраните или отмените ввод перед этим действием."
                self.errorMessage = reason
                let outcome = StartMeetingOutcome.rejected(reason: reason)
                onOutcome?(outcome)
                return outcome
            }
            guard self.sessionAttached, self.processingAttached, !self.sessionStarting, !self.sessionStopping, !self.diagnosticRunning, !self.isRecording, self.activeSessionID == nil else {
                let reason = "Состояние сессии изменилось. Запуск новой записи отменён."
                self.errorMessage = reason
                let outcome = StartMeetingOutcome.rejected(reason: reason)
                onOutcome?(outcome)
                return outcome
            }
            self.calendar.refresh()
            let freshMeeting: MeetingContext?
            if let meeting {
                guard let found = self.calendar.events.first(where: { $0.id == meeting.id && $0 == meeting }) else {
                    let reason = "Встреча изменилась или удалена. Выберите её заново."
                    self.errorMessage = reason
                    let outcome = StartMeetingOutcome.rejected(reason: reason)
                    onOutcome?(outcome)
                    return outcome
                }
                freshMeeting = found
            } else {
                freshMeeting = nil
            }

            self.isBusy = true
            self.selectedMeeting = freshMeeting
            await self.startRecording(meeting: freshMeeting)
            if self.isRecording {
                let outcome = StartMeetingOutcome.started
                onOutcome?(outcome)
                return outcome
            } else {
                let reason = self.errorMessage ?? "Не удалось начать запись."
                self.errorMessage = reason
                let outcome = StartMeetingOutcome.failed(reason: reason)
                onOutcome?(outcome)
                return outcome
            }
        }
    }

    private func enqueue(_ recording: URL, stopped: StoppedRecording?) {
        guard let entry = history.entry(recording) else { return }
        if stopped == nil && !entry.capabilities.canRetry {
            history.reportError(entry.capabilities.reason ?? "Исходные WAV отсутствуют или недоступны; повторная обработка невозможна.", recording: recording)
            return
        }
        let settings = ProcessingJobSettings(
            parakeet: improveTerms,
            echoCancellation: echoCancellation
        )
        let presentationID = UUID()
        guard historyRepository.reserveWork(recording, id: presentationID) else {
            history.reportError("Дождитесь завершения работы с записью", recording: recording)
            return
        }
        pendingProcessingEnqueues[presentationID] = RecordingEntry.canonicalURL(recording)
        if lastFileURL == recording && !isRecording {
            cancelCapsuleDeadline()
            recordingCancelled = false
            pendingCapsuleEnqueue = presentationID
            capsuleDismissed = false
            transcriptionState = .running(nil)
        }
        Task {
            defer {
                historyRepository.releaseWork(recording, id: presentationID)
                pendingProcessingEnqueues.removeValue(forKey: presentationID)
            }
            let job = await processingService.enqueue(
                recordingURL: recording,
                settings: settings,
                stoppedCapture: stopped
            )
            if pendingCapsuleEnqueue == presentationID {
                pendingCapsuleEnqueue = nil
                capsuleJobID = job.id
                await history.synchronize()
                syncProcessingPresentation(recording)
            }
        }
    }

    private func cancelCapsuleDeadline() {
        capsuleTimer?.invalidate()
        capsuleTimer = nil
        capsuleDeadlineID = nil
    }

    func syncProcessingPresentation(_ recording: URL) {
        guard !recordingCancelled, lastFileURL == recording, !isRecording, !sessionStarting, !sessionStopping,
              pendingCapsuleEnqueue == nil, let entry = history.entry(recording) else { return }
        cancelCapsuleDeadline()
        transcriptionWarnings = entry.problems.map(\.message)
        switch entry.phase {
        case .completed: transcriptionState = .completed(entry.currentTranscriptURL ?? entry.currentResultURL ?? entry.transcript)
        case .failed, .interrupted:
            transcriptionState = .failed(entry.problems.last(where: \.isError)?.message ?? entry.status)
        case .queued, .saving, .processing: transcriptionState = .running(history.progress[recording])
        case .recording: transcriptionState = .idle
        }
        if entry.phase == .completed || entry.phase == .failed {
            let deadlineID = UUID(), jobID = capsuleJobID
            capsuleDeadlineID = deadlineID
            capsuleTimer = scheduleCapsuleTimer(60) { [weak self] in
                    guard let self, self.capsuleDeadlineID == deadlineID, self.capsuleJobID == jobID,
                          self.pendingCapsuleEnqueue == nil, self.lastFileURL == recording,
                          !self.isRecording, !self.sessionStarting, !self.sessionStopping,
                          self.transcriptionJobs == 0, !self.isAdmittingProcessing else { return }
                    switch self.transcriptionState {
                    case .completed, .failed: break
                    default: return
                    }
                    self.capsuleDismissed = true
            }
        }
    }

    func refreshMicrophones() {
        microphones = microphoneProvider?() ?? Microphones.available()
    }

    func restartLevelMonitor() {
        guard isCheckingAudio, !isRecording else { return }
        Task { await startLevelMonitor(reportErrors: true) }
    }


    private func startRecording(meeting: MeetingContext?, displayTitle: String? = nil) async {
        preparingCapture = true
        sessionStarting = true
        cancelCapsuleDeadline()
        pendingCapsuleEnqueue = nil
        capsuleJobID = nil
        recordingCancelled = false
        capsuleDismissed = false
        defer {
            preparingCapture = false
            sessionStarting = false
            isBusy = false
            refreshMeetingSelection()
            restartLevelMonitor()
        }
        var attemptedURL: URL?
        do {
            errorMessage = nil
            recordingSaveError = nil
            microphoneMuted = false
            microphoneState = .receiving
            mutedMicrophoneActivity = false
            muteActivity = MutedMicrophoneActivity()
            await endAudioCheck()
            let directory = outputDirectory
            let outputURL = try await Task.detached {
                RecordingEntry.canonicalURL(try RecordingPaths.makeOutputURL(outputDirectory: directory))
            }.value
            attemptedURL = outputURL
            var preparedRecorder: Recorder?
            let controller: any AudioCaptureControllerProtocol
            if let captureControllerFactory {
                controller = try await captureControllerFactory(outputURL, selectedMicrophoneDeviceID, captureBackend)
            } else {
                let recorder = try await Recorder(
                    outputURL: outputURL,
                    outputKind: .m4a,
                    microphoneDeviceID: selectedMicrophoneDeviceID,
                    backend: captureBackend,
                    onLevels: { [weak self] mic, system in
                        Task { @MainActor in
                            guard let self else { return }
                            if system.isFinite { self.updateCaptureCheck(succeeded: true) }
                            if mic.isFinite {
                                let active = self.muteActivity.receive(mic, muted: self.microphoneMuted)
                                if active != self.mutedMicrophoneActivity { self.mutedMicrophoneActivity = active }
                            }
                            self.handleLevels(mic: mic, system: system)
                        }
                    }
                )
                preparedRecorder = recorder
                controller = PlatformAudioCaptureController(recorder: recorder)
            }
            let sessionConfig = RecordingSessionService.Configuration(
                outputURL: outputURL,
                meetingID: meeting?.id,
                meetingSummary: meeting?.summary,
                captureBackend: captureBackend.rawValue,
                microphoneDeviceUID: selectedMicrophoneDeviceID,
                prompt: nil,
                controller: controller
            )
            let sessionSnapshot = try await recordingSessionService.start(configuration: sessionConfig)
            self.recorder = preparedRecorder
            isRecording = true
            sessionStarting = false
            activeSessionID = sessionSnapshot.sessionID

            recordingMeetingID = meeting?.id
            activeRecordingURL = outputURL
            lastFileURL = outputURL
            cancelCapsuleDeadline()
            mainWindowRequested = false
            recordingCancelled = false
            transcriptionState = .idle
            capsuleDismissed = false
            lastRecordingTitle = displayTitle ?? meeting?.summary ?? "Запись встречи"
            elapsed = 0
            levels.reset()
            startedAt = Date()
            recordingOvertime = RecordingOvertime(start: startedAt!, meetingEnd: meeting?.end)
            status = "Идёт запись"
            await history.synchronize()
            if let displayTitle {
                do { try await history.updateThrowing(outputURL) { $0.displayTitle = displayTitle } }
                catch { errorMessage = "Запись идёт, но название не сохранено: " + error.localizedDescription }
            }
            if let meeting {
                calendar.acknowledge(meeting)
                do { try await Task.detached { try meeting.save(beside: outputURL) }.value }
                catch {
                    let message = "Запись идёт, но контекст не сохранён: " + error.localizedDescription
                    errorMessage = message
                    await history.updateStatus(outputURL) { $0.addProblem(.context, message) }
                }
            }
            await history.updateStatus(outputURL) { $0.readArtifacts() }
            lastRecordingTitle = displayTitle ?? meeting?.summary ?? "Запись встречи"
            onRecordingStarted?()
        } catch {
            if let url = attemptedURL {
                let message = error.localizedDescription
                let title = meeting?.summary ?? "Запись встречи"
                let entry = await Task.detached {
                    var entry = RecordingEntry(recording: url, date: Date(), title: title, phase: .failed)
                    entry.addProblem(.capture, message, error: true)
                    return entry
                }.value
                await history.put(entry)
            }
            updateCaptureCheck(succeeded: false)
            errorMessage = error.localizedDescription
            status = "Ошибка"
        }
    }

    private func stopRecording(expectedSessionID: UUID, cancelShort: Bool) async -> Bool {
        defer {
            isBusy = false
            refreshMeetingSelection()
            restartLevelMonitor()
        }
        do {
            let stopResult = try await recordingSessionService.stop(elapsed: elapsed, expectedSessionID: expectedSessionID, cancelShort: cancelShort, trash: shortRecordingTrash)
            self.recorder = nil
            levels.reset()
            elapsed = stopResult.duration
            lastFileURL = stopResult.outputURL
            activeRecordingURL = nil
            recordingMeetingID = nil
            errorMessage = nil
            mutedMicrophoneActivity = false
            isRecording = false
            sessionStopping = false
            activeSessionID = nil

            if stopResult.wasCancelledShort {
                lastFileURL = nil
                transcriptionState = .idle
                transcriptionWarnings = []
                status = "Короткая запись отменена"
                recordingCancelled = true
                capsuleDismissed = false
                cancelCapsuleDeadline()
                let deadlineID = UUID()
                capsuleDeadlineID = deadlineID
                capsuleTimer = scheduleCapsuleTimer(2) { [weak self] in
                        guard let self, self.capsuleDeadlineID == deadlineID,
                              self.recordingCancelled, self.pendingCapsuleEnqueue == nil,
                              !self.sessionStarting, !self.sessionStopping, !self.isRecording else { return }
                        self.recordingCancelled = false
                        if let snapshot = self.latestProcessingSnapshot,
                           snapshot.active != nil || !snapshot.queued.isEmpty || !snapshot.admitting.isEmpty {
                            self.capsuleDismissed = false
                            self.applyProcessingSnapshot(snapshot)
                        } else {
                            self.capsuleDismissed = true
                        }
                }
                return true
            }

            status = "Исходные дорожки сохранены"
            await history.synchronize()
            for warning in stopResult.warnings { history.reportError(warning, recording: stopResult.outputURL) }
            enqueue(stopResult.outputURL, stopped: stopResult.stoppedCapture as? StoppedRecording)
            return true
        } catch let error as RecordingSessionService.ServiceError where error == .staleCommand || error == .shortCancellationExpired || error == .notRecording {
            errorMessage = error.localizedDescription
            return false
        } catch {
            self.recorder = nil
            recordingSaveError = error.localizedDescription
            if let url = activeRecordingURL {
                let message = error.localizedDescription
                await history.updateStatus(url) { $0.phase = .failed; $0.addProblem(.saving, message, error: true) }
            }
            activeRecordingURL = nil
            recordingMeetingID = nil
            errorMessage = "Не удалось завершить запись: " + error.localizedDescription
            status = "Ошибка"
            return false
        }
    }

    private func startLevelMonitor(reportErrors: Bool) async {
        let previous = levelMonitorTask
        previous?.cancel()
        let task = Task { @MainActor [self] in
            await previous?.value
            await stopCurrentLevelMonitor()
            guard !Task.isCancelled, isCheckingAudio, !isRecording, !isBusy, recordingSaveError == nil, isAudioCheckVisible else { return }

            assert(levelMonitor == nil, "Previous audio preview must stop before another starts")
            let monitorID = UUID()
            self.currentLevelMonitorID = monitorID
            let monitorSection = self.activeAudioCheckSection
            do {
                let onLevels: @Sendable (Double, Double) -> Void = { [weak self] mic, system in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.currentLevelMonitorID == monitorID else { return }
                        guard self.isCheckingAudio, self.isAudioCheckVisible else { return }
                        guard self.activeAudioCheckSection == monitorSection else { return }
                        if system.isFinite { self.updateCaptureCheck(succeeded: true) }
                        self.levels.receive(mic: mic, system: system)
                    }
                }
                let monitor: any AudioLevelMonitoring
                if let factory = self.audioLevelMonitorFactory {
                    monitor = try await factory(
                        self.selectedMicrophoneDeviceID,
                        self.captureBackend,
                        onLevels
                    )
                } else {
                    monitor = try await AudioLevelMonitor(
                        microphoneDeviceID: selectedMicrophoneDeviceID,
                        backend: captureBackend,
                        onLevels: onLevels
                    )
                }
                guard !Task.isCancelled, self.currentLevelMonitorID == monitorID else {
                    try? await monitor.stop()
                    return
                }
                try await monitor.start()
                if Task.isCancelled || self.currentLevelMonitorID != monitorID {
                    try? await monitor.stop()
                    return
                }
                levelMonitor = monitor
                if reportErrors && status == "Не удалось проверить звук" {
                    errorMessage = nil
                    status = "Готов к записи"
                }
            } catch {
                if !Task.isCancelled, self.currentLevelMonitorID == monitorID {
                    updateCaptureCheck(succeeded: false)
                    isCheckingAudio = false
                    activeAudioCheckSection = nil
                    currentLevelMonitorID = nil
                    audioCheckTimeout?.cancel()
                    audioCheckTimeout = nil
                    levels.reset()
                    updateLevelVisibility()
                    if reportErrors {
                        errorMessage = error.localizedDescription
                        status = "Не удалось проверить звук"
                    }
                }
            }
        }
        levelMonitorTask = task
        await task.value
    }

    private func stopLevelMonitor() async {
        let previous = levelMonitorTask
        previous?.cancel()
        let task = Task { @MainActor [self] in
            await previous?.value
            await stopCurrentLevelMonitor()
        }
        levelMonitorTask = task
        await task.value
    }

    private func stopCurrentLevelMonitor() async {
        guard let monitor = levelMonitor else { return }
        levelMonitor = nil
        try? await monitor.stop()
        levels.reset()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isRecording, !self.isBusy, let startedAt = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(startedAt)
                    let state = await self.recordingSessionService.currentMicrophoneState()
                    if state != self.microphoneState {
                        self.microphoneState = state
                        self.status = self.microphoneCaptureHint.isEmpty ? "Идёт запись" : self.microphoneCaptureHint
                    }
                }

            }
        }
    }

}

struct ContentView: View {
    @ObservedObject var viewModel: RecorderViewModel
    let showSettings: () -> Void

    var body: some View {
        RecorderWorkspaceView(model: viewModel, showSettings: showSettings)
            .frame(minWidth: 480, minHeight: 480)
    }
}

struct LevelMetersView: View {
    @ObservedObject var levels: AudioLevels

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Уровни звука")
                .font(.headline)
            LevelMeterRow(label: "Микрофон", level: levels.mic, color: .green)
            LevelMeterRow(label: "Система", level: levels.system, color: .blue)
        }
    }
}

struct LevelMeterRow: View {
    let label: String
    let level: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 84, alignment: .leading)
                .foregroundStyle(.secondary)
            ThinMeter(level: level, color: color)
        }
    }
}

struct ThinMeter: View {
    let level: Double
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < Int(level * 10) ? color : Color.secondary.opacity(0.18))
            }
        }
        .frame(height: 8)
    }

}
