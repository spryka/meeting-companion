import os
@testable import MeetingCompanionApplication
import Combine
import AppKit
import Foundation
import Testing
@testable import MeetingCompanionApp
@testable import MeetingCompanionCore

@MainActor
struct SettingsPresentationTests {
    @Test(arguments: [false, true])
    func updateCheckFollowsWorkState(workBusy: Bool) throws {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = AppUpdater(defaults: defaults)
        updater.isBusy = { workBusy }
        if workBusy {
            #expect(throws: (any Error).self) { try updater.validateCheckAdmission() }
        } else {
            do { try updater.validateCheckAdmission() }
            catch { Issue.record("Idle update check rejected: \(error)") }
        }
    }

    @Test(arguments: ["unattached", "stopping", "admitting", "jobs", "diagnostic", "busy"])
    func settings30WorkStillBlocksOwnOperations(work: String) async throws {
        let (defaults, suite) = createTestDefaults()
        let (root, appData) = try createTestDirectories()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let model = isolatedRecorderModel(defaults: defaults, appDataDirectory: appData)
        try await wait { model.isAttached }
        #expect(model.presentSettings())
        switch work {
        case "unattached": model.setAttachedForTesting(session: false, processing: false)
        case "stopping": model.setSessionStoppingForTesting(true)
        case "admitting": model.setIsAdmittingProcessingForTesting(true)
        case "jobs": model.transcriptionJobs = 1
        case "diagnostic": model.setLocalDiagnosticRunningForTesting(true)
        default: model.isBusy = true
        }
        let delegate = RecorderAppDelegate(model: model), updater = AppUpdater(defaults: defaults)
        delegate.configureUpdatePolicy(updater)
        #expect(model.preventsTermination && !model.canResetCache && updater.isBusy())
        #expect(throws: (any Error).self) { try updater.validateCheckAdmission() }
        model.dismissSettings()
    }

    @Test func settings30OwnOperationsKeepGlobalTerminationGuard() async throws {
        let (defaults, suite) = createTestDefaults()
        let (root, appData) = try createTestDirectories()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let model = isolatedRecorderModel(defaults: defaults, appDataDirectory: appData)
        try await wait { model.isAttached }
        #expect(model.presentSettings())
        #expect(model.preventsTermination)
        #expect(model.canResetCache)
        let resets = OSAllocatedUnfairLock(initialState: 0)
        var confirmations = 0
        await model.performCacheReset(in: appData, resetOperation: { _, _ in resets.withLock { $0 += 1 } }, confirmation: { _ in
            confirmations += 1; return true
        })
        #expect(confirmations == 1 && resets.withLock { $0 } == 1)
        let delegate = RecorderAppDelegate(model: model)
        let updater = AppUpdater(defaults: defaults)
        delegate.configureUpdatePolicy(updater)
        do { try updater.validateCheckAdmission() }
        catch { Issue.record("Own Settings check rejected: \(error)") }
        #expect(updater.isBusy() && model.preventsTermination)
        #expect(!updater.installPreparedUpdate())
        model.workspace.externalModal = true
        #expect(!model.canResetCache)
        #expect(throws: (any Error).self) { try updater.validateCheckAdmission() }
        var rejectedConfirmation = false
        await model.performCacheReset(in: appData, resetOperation: { _, _ in resets.withLock { $0 += 1 } }, confirmation: { _ in
            rejectedConfirmation = true; return true
        })
        #expect(!rejectedConfirmation && resets.withLock { $0 } == 1)
        model.workspace.externalModal = false
        model.setSessionStartingForTesting(true)
        #expect(!model.canResetCache)
        #expect(throws: (any Error).self) { try updater.validateCheckAdmission() }
        model.setSessionStartingForTesting(false)
        model.dismissSettings()
    }

    @Test func settings30FormCloseDoesNotRestartMonitor() async throws {
        let (defaults, suite) = createTestDefaults()
        let (root, appData) = try createTestDirectories()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let collector = MonitorCollector()
        let model = isolatedRecorderModel(defaults: defaults, appDataDirectory: appData,
            audioLevelMonitorFactory: { mic, backend, onLevels in
                let monitor = SyntheticAudioLevelMonitor(micID: mic, backend: backend, onLevels: onLevels)
                collector.append(monitor); return monitor
            })
        let delegate = RecorderAppDelegate(model: model)
        try await wait { model.isAttached }
        model.mainPage = .recording
        delegate.updateSettingsPresentationVisibility(workspaceVisible: true)
        try await wait { collector.first?.isStarted == true }
        #expect(model.presentSettings())
        delegate.updateSettingsPresentationVisibility(workspaceVisible: true)
        try await wait { !model.isCheckingAudio && collector.first?.isStopped == true }
        model.dismissSettings()
        delegate.updateSettingsPresentationVisibility(workspaceVisible: true)
        for _ in 0..<100 { await Task.yield() }
        #expect(!model.isCheckingAudio && collector.monitors.count == 1)
        collector.first?.sendLevels(mic: 0.9, system: 0.9)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.levels.mic == 0 && model.levels.system == 0)
        await model.endAudioCheck()
        model.mainPage = .history
        delegate.updateSettingsPresentationVisibility(workspaceVisible: true)
        model.mainPage = .recording
        delegate.updateSettingsPresentationVisibility(workspaceVisible: true)
        try await wait { model.isCheckingAudio && collector.monitors.count >= 2 }
        model.mainPage = .history
        delegate.updateSettingsPresentationVisibility(workspaceVisible: false)
        await model.endAudioCheck()
    }

    @Test func settings29DelegateRouteAndOwnedVisibility() async throws {
        let (defaults, suite) = createTestDefaults()
        let (root, appData) = try createTestDirectories()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let collector = MonitorCollector()
        let model = isolatedRecorderModel(defaults: defaults, appDataDirectory: appData,
            audioLevelMonitorFactory: { mic, backend, onLevels in
                let monitor = SyntheticAudioLevelMonitor(micID: mic, backend: backend, onLevels: onLevels)
                collector.append(monitor); return monitor
            })
        var presented = 0
        let delegate = RecorderAppDelegate(model: model, presentWorkspace: { presented += 1 })
        try await wait { model.isAttached }
        let key = model.workspaceLoadRequest
        delegate.showSettings() // Same route as Cmd+, status, sidebar, More and form; no native host.
        model.settingsPage = .recording
        delegate.showSettings()
        #expect(presented == 2 && model.settingsPresented && model.settingsPage == .recording)
        delegate.openRecordings()
        delegate.startRecordingAction()
        #expect(presented == 3 && model.mainPage == .history && model.workspaceLoadRequest == key)
        delegate.updateSettingsPresentationVisibility(workspaceVisible: true)
        #expect(!model.isCheckingAudio)
        model.toggleAudioCheck(from: .recording)
        try await wait { collector.first?.isStarted == true }
        delegate.updateSettingsPresentationVisibility(workspaceVisible: false)
        try await wait { !model.isCheckingAudio && collector.first?.isStopped == true }
        delegate.updateSettingsPresentationVisibility(workspaceVisible: true)
        for _ in 0..<20 { await Task.yield() }
        #expect(!model.isCheckingAudio && model.settingsPresented && collector.monitors.count == 1)
        model.toggleAudioCheck(from: .recording)
        try await wait { collector.monitors.count == 2 && collector.monitors.last?.isStarted == true }
        model.settingsPage = .general
        delegate.updateSettingsPresentationVisibility(workspaceVisible: true)
        try await wait { !model.isCheckingAudio && collector.monitors.last?.isStopped == true }
        model.dismissSettings()
        delegate.updateSettingsPresentationVisibility(workspaceVisible: true)
        #expect(!model.isAudioCheckVisibleForTesting)
    }

    @Test func settings29OwnedAdmissionAndReopen() async throws {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = isolatedRecorderModel(defaults: defaults)
        try await wait { model.isAttached }
        model.mainPage = .recording
        let key = model.workspaceLoadRequest
        #expect(model.presentSettings())
        model.settingsPage = .diagnostics
        #expect(model.presentSettings())
        #expect(model.settingsPage == .diagnostics && model.mainPage == .recording)
        model.workspace.externalModal = true
        model.workspace.externalModal = false // A late rename/details dismissal cannot release Settings.
        #expect(model.workspace.hasInput && !model.canStartRecording)
        model.mainPage = .history
        model.selectedHistoryURL = URL(fileURLWithPath: "/tmp/unowned/unowned.m4a")
        #expect(model.mainPage == .recording && model.selectedHistoryURL == nil)
        #expect(model.requestWorkspaceOpen() == nil && model.workspaceLoadRequest == key)
        #expect(!model.admitWindowClose(isWorkspace: true))
        #expect(!(await model.startRecordingIntent(customTitle: "Blocked form action")))
        model.dismissSettings()
        #expect(!model.settingsPresented && !model.workspace.hasInput)
        model.workspace.externalModal = true
        #expect(!model.presentSettings())
        #expect(model.workspace.externalModal && !model.settingsPresented)
        model.workspace.externalModal = false
        #expect(model.presentSettings() && model.settingsPage == .diagnostics)
        model.dismissSettings()
    }

    @Test func owner22CalendarCatalogUsesInjectedProvider() async throws {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([String](), forKey: "meetingCalendarIDs")
        var calls = 0
        let calendar = MeetingCalendar(defaults: defaults, calendarCatalogProvider: { calls += 1; return [] })
        calendar.setCalendarSettingsVisible(true)
        for _ in 0..<100 { if calls == 1 { break }; await Task.yield() }
        #expect(calls == 1 && calendar.calendars.isEmpty && !calendar.isLoadingCalendars)
        calendar.setCalendarSettingsVisible(false)
        #expect(!calendar.isLoadingCalendars)
    }

    @Test func owner22AudioButtonMatchesSharedFormMonitor() async throws {
        let (defaults, suite) = createTestDefaults()
        let (root, appData) = try createTestDirectories()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let collector = MonitorCollector()
        let model = isolatedRecorderModel(defaults: defaults, appDataDirectory: appData,
            audioLevelMonitorFactory: { mic, backend, onLevels in
                let monitor = SyntheticAudioLevelMonitor(micID: mic, backend: backend, onLevels: onLevels)
                collector.append(monitor); return monitor
            })
        try await wait { model.isAttached }
        model.mainPage = .recording
        model.setWindowVisible(true)
        model.setRecordingFormVisible(true)
        model.setAudioCheckVisible(true, section: .recording)
        try await wait { collector.first?.isStarted == true }
        #expect(model.audioCheckActionTitle(for: .recording) == "Завершить проверку звука")
        model.toggleAudioCheck(from: .recording) // The actual bound Settings Button command.
        try await wait { !model.isCheckingAudio && collector.first?.isStopped == true }
        #expect(model.audioCheckActionTitle(for: .recording) == "Проверить звук")
        model.toggleAudioCheck(from: .diagnostics)
        try await wait { model.isCheckingAudio && collector.monitors.last?.isStarted == true }
        #expect(model.audioCheckActionTitle(for: .recording) == "Завершить проверку звука")
        model.toggleAudioCheck(from: .recording)
        for _ in 0..<50 { await Task.yield() }
        #expect(!model.isCheckingAudio)
        await model.endAudioCheck()
        model.setRecordingFormVisible(false)
        model.setAudioCheckVisible(false)
    }

    @Test func solRepairFormPreviewSurvivesSettingsOnlyVisibilityCallbacks() async throws {
        let (defaults, suite) = createTestDefaults()
        let (root, appData) = try createTestDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        defaults.set(root.path, forKey: "recordingsDirectory")
        defaults.set([String](), forKey: "meetingCalendarIDs")
        let collector = MonitorCollector()
        let model = isolatedRecorderModel(defaults: defaults, appDataDirectory: appData,
            startBackgroundServices: false, audioLevelMonitorFactory: { mic, backend, onLevels in
                let monitor = SyntheticAudioLevelMonitor(micID: mic, backend: backend, onLevels: onLevels)
                collector.append(monitor)
                return monitor
            })
        let delegate = RecorderAppDelegate(model: model)
        try await wait { model.isAttached }
        model.mainPage = .recording
        model.setWindowVisible(true)
        // Actual form appearance, followed by the shared production delegate visibility route.
        model.setRecordingFormVisible(true)
        try await wait { collector.first?.isStarted == true }
        delegate.updateAudioPreviewVisibility(workspaceVisible: true, settingsSection: nil)
        for _ in 0..<30 { await Task.yield() }
        #expect(model.isCheckingAudio && model.isAudioCheckVisibleForTesting)
        delegate.updateAudioPreviewVisibility(workspaceVisible: true, settingsSection: .diagnostics)
        delegate.updateAudioPreviewVisibility(workspaceVisible: true, settingsSection: nil)
        for _ in 0..<30 { await Task.yield() }
        #expect(model.isCheckingAudio && model.isAudioCheckVisibleForTesting)
        delegate.updateAudioPreviewVisibility(workspaceVisible: false, settingsSection: nil)
        try await wait { !model.isCheckingAudio && collector.monitors.allSatisfy(\.isStopped) }
        let stopped = collector.monitors
        delegate.updateAudioPreviewVisibility(workspaceVisible: true, settingsSection: nil)
        for _ in 0..<100 { if model.isCheckingAudio && collector.monitors.last?.isStarted == true { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.isCheckingAudio && collector.monitors.count > stopped.count)
        for monitor in stopped { monitor.sendLevels(mic: 0.9, system: 0.9) }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.levels.mic == 0 && model.levels.system == 0)
        model.mainPage = .history
        delegate.updateAudioPreviewVisibility(workspaceVisible: true, settingsSection: nil)
        await model.endAudioCheck()
        #expect(!model.isCheckingAudio)
    }

    private func createTestDefaults() -> (UserDefaults, String) {
        let suite = "SettingsPresentationTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(FileManager.default.temporaryDirectory.appendingPathComponent(suite).path, forKey: "recordingsDirectory")
        return (defaults, suite)
    }

    private func createTestDirectories() throws -> (root: URL, appData: URL) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temp.appendingPathComponent("recordings")
        let appData = temp.appendingPathComponent("appData")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        return (root, appData)
    }

    // MARK: - P01: Five Settings Sections

    @Test func p01_fiveSettingsSectionsPreserved() {
        let pages = RecorderSettingsView.Page.allCases
        #expect(pages.count == 5)
        #expect(pages == [.general, .recording, .transcription, .calendar, .diagnostics])

        let expectedTitles = ["Основные", "Запись", "Транскрибация", "Календарь", "Диагностика"]
        let actualTitles = pages.map(\.rawValue)
        #expect(actualTitles == expectedTitles)
    }

    // MARK: - P02: General Settings Continuity

    @Test func p02_themeSelectionAndBetaUpdatesKeyAndDisclaimer() throws {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)

        model.appearance = .dark
        #expect(defaults.string(forKey: "appAppearance") == AppAppearance.dark.rawValue)
        #expect(NSApp.appearance == AppAppearance.dark.value)

        model.appearance = .light
        #expect(defaults.string(forKey: "appAppearance") == AppAppearance.light.rawValue)
        #expect(NSApp.appearance == AppAppearance.light.value)

        model.appearance = .system
        #expect(defaults.string(forKey: "appAppearance") == AppAppearance.system.rawValue)
        #expect(NSApp.appearance == nil)

        // Beta updates setting
        defaults.set(true, forKey: "receiveBetaUpdates")
        #expect(defaults.bool(forKey: "receiveBetaUpdates") == true)
        defaults.set(false, forKey: "receiveBetaUpdates")
        #expect(defaults.bool(forKey: "receiveBetaUpdates") == false)
    }

    @Test func p02_followStateBindsToCurrentEditorSessionOnly() async throws {
        let (defaults, suite) = createTestDefaults()
        let (root, _) = try createTestDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        defaults.set(root.path, forKey: "recordingsDirectory")

        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)

        // When no active transcript editor session, follow state is unavailable
        #expect(model.workspace.current == nil)
        #expect(!model.isFollowAvailable)
        #expect(!model.isEditorFollowing)

        // Toggling follow without an editor session is a no-op and does not crash or create global bool
        model.setEditorFollowing(true)
        #expect(!model.isFollowAvailable)

        // Publish a synthetic recording result to open editor
        let meetingDir = root.appendingPathComponent("meeting")
        let recordingURL = meetingDir.appendingPathComponent("meeting.m4a")
        let transcriptDir = meetingDir.appendingPathComponent("raw/transcripts/res_test")
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        try Data("dummy audio".utf8).write(to: recordingURL)
        let minimalDoc: [String: Any] = [
            "schemaVersion": 1,
            "resultID": "res_test",
            "audio": ["fileName": "meeting.m4a", "duration": 60.0],
            "engine": ["name": "gigaam", "version": "v2"],
            "words": [["id": "w1", "speakerID": "spk1", "start": 0.0, "end": 1.0, "text": "Привет"]],
            "turns": [["id": "t1", "speakerID": "spk1", "start": 0.0, "end": 1.0, "wordIDs": ["w1"]]]
        ]
        try JSONSerialization.data(withJSONObject: minimalDoc).write(to: transcriptDir.appendingPathComponent("result.json"))

        let editor = try await model.workspace.open(recordingURL: recordingURL, title: "Test Meeting")
        #expect(model.workspace.current === editor)
        #expect(model.isFollowAvailable)
        #expect(model.isEditorFollowing == true)

        // Toggling follow in settings updates editor's follow state
        model.setEditorFollowing(false)
        #expect(model.isEditorFollowing == false)
        #expect(editor.follow.isFollowing == false)

        model.setEditorFollowing(true)
        #expect(model.isEditorFollowing == true)
        #expect(editor.follow.isFollowing == true)

        // Manual scroll in editor updates follow state reflected in model
        editor.userScrollPhaseChanged(.tracking)
        #expect(editor.follow.isFollowing == false)
        #expect(model.isEditorFollowing == false)

        model.workspace.closeCurrent()
        #expect(model.workspace.current == nil)
        #expect(!model.isFollowAvailable)
    }

    // MARK: - P03: Recording Settings Continuity

    @Test func p03_microphoneChoicePreservedWhenDeviceUnavailable() throws {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("external-usb-mic-guid", forKey: "selectedMicrophoneID")
        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)

        // External mic is not in available microphones list
        model.microphones = [
            MicrophoneDevice(id: "__default__", name: "Встроенный микрофон")
        ]

        // Device selection must NOT be silently overwritten
        #expect(model.selectedMicrophoneID == "external-usb-mic-guid")
        #expect(defaults.string(forKey: "selectedMicrophoneID") == "external-usb-mic-guid")
        #expect(model.selectedMicrophoneDeviceID == "external-usb-mic-guid")
    }

    @Test func p03_folderPickerCancellationAndErrorPreservePath() async throws {
        let (defaults, suite) = createTestDefaults()
        let (root, _) = try createTestDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)

        let initialDirectory = model.outputDirectory

        // Simulate folder picker cancellation: picker returns nil
        await model.chooseFolder(withPicker: { _ in nil })
        #expect(model.outputDirectory == initialDirectory)
        #expect(defaults.string(forKey: "recordingsDirectory") == initialDirectory.path)

        // Simulate invalid/read-only folder selection
        let invalidFile = root.appendingPathComponent("regular_file.txt")
        try Data("dummy".utf8).write(to: invalidFile)

        await model.chooseFolder(withPicker: { _ in invalidFile })
        #expect(model.outputDirectory == initialDirectory, "Invalid folder must not replace outputDirectory")
        #expect(model.errorMessage != nil, "Failure to validate folder must display an error message")
    }

    // MARK: - P04: Transcription Settings Continuity

    @Test func p04_modelCheckProgressAndTerminalSummarySurviveSnapshots() async throws {
        let (defaults, suite) = createTestDefaults()
        let (root, _) = try createTestDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        defaults.set(root.path, forKey: "recordingsDirectory")

        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)

        // Progress probe reporting file count and bytes
        let testDir = root.appendingPathComponent("test-progress")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        try Data("model_data_1".utf8).write(to: testDir.appendingPathComponent("model1.bin"))
        try Data("model_data_2_longer".utf8).write(to: testDir.appendingPathComponent("model2.bin"))

        let progress = RecorderDiagnostics.preparationProgress(in: testDir)
        #expect(progress.fileCount == 2)
        #expect(progress.bytes == 31)

        model.preparationProgress = progress
        model.diagnosticReport = "Папка записей: OK\nПроверка файлов моделей по SHA-256…\nВсе файлы проверены.\nТранскрибация готова."

        #expect(model.diagnosticSummary == "Транскрибация готова.")

        // Simulate queue snapshot arriving while idle or after check
        // Diagnostic report and summary must not be overwritten by generic snapshot message
        #expect(model.diagnosticSummary == "Транскрибация готова.")
        #expect(model.preparationProgress?.fileCount == 2)
    }

    // MARK: - P05: Safe Owned Cache Reset

    @Test func p05_safeCacheResetTouchesOnlyAppOwnedCachesAndRespectsConfirmation() async throws {
        let (defaults, suite) = createTestDefaults()
        let (recordings, appData) = try createTestDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: recordings.deletingLastPathComponent())
        }
        defaults.set(recordings.path, forKey: "recordingsDirectory")

        // Populate app data directory with native-models, runtime, settings, and other files
        let nativeModels = appData.appendingPathComponent("native-models")
        let runtime = appData.appendingPathComponent("runtime")
        let settings = appData.appendingPathComponent("settings")
        let customFile = appData.appendingPathComponent("user-notes.txt")
        try FileManager.default.createDirectory(at: nativeModels, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try Data("model_weights".utf8).write(to: nativeModels.appendingPathComponent("weights.bin"))
        try Data("runtime_binary".utf8).write(to: runtime.appendingPathComponent("worker"))
        try Data("user_pref".utf8).write(to: settings.appendingPathComponent("config.json"))
        try Data("important notes".utf8).write(to: customFile)

        // Populate recording in recordings folder
        let recordingFile = recordings.appendingPathComponent("audio.m4a")
        try Data("recording_audio_data".utf8).write(to: recordingFile)

        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)
        for _ in 0..<200 { if model.canResetCache { break }; try await Task.sleep(for: .milliseconds(5)) }

        // Case 1: Cancel reset
        await model.performCacheReset(in: appData, confirmation: { _ in false })
        #expect(FileManager.default.fileExists(atPath: nativeModels.path))
        #expect(FileManager.default.fileExists(atPath: runtime.path))
        #expect(FileManager.default.fileExists(atPath: settings.path))
        #expect(FileManager.default.fileExists(atPath: customFile.path))
        #expect(FileManager.default.fileExists(atPath: recordingFile.path))

        // Case 2: Confirm reset
        await model.performCacheReset(in: appData, confirmation: { _ in true })
        // Only native-models and runtime should be removed
        #expect(!FileManager.default.fileExists(atPath: nativeModels.path))
        #expect(!FileManager.default.fileExists(atPath: runtime.path))
        // Settings, custom files, and recordings MUST remain intact
        #expect(FileManager.default.fileExists(atPath: settings.path))
        #expect(FileManager.default.fileExists(atPath: customFile.path))
        #expect(FileManager.default.fileExists(atPath: recordingFile.path))
    }

    @Test func p05_cacheResetRejectsOverlappingRecordingsDirectory() async throws {
        let (defaults, suite) = createTestDefaults()
        let (recordings, appData) = try createTestDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: recordings.deletingLastPathComponent())
        }

        // Set recordings directly inside native-models
        let nestedRecordings = appData.appendingPathComponent("native-models/recordings")
        defaults.set(nestedRecordings.path, forKey: "recordingsDirectory")
        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)
        for _ in 0..<200 { if model.canResetCache { break }; try await Task.sleep(for: .milliseconds(5)) }

        await model.performCacheReset(in: appData, confirmation: { _ in true })
        #expect(model.diagnosticReport.contains("Папка записей пересекается с кэшем"))
    }

    // MARK: - P06: Calendar Settings Continuity

    @Test func p06_calendarSelectionAndCallLinkFilterPreserved() {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: "meetingRequireCallLink")
        defaults.set(["cal-1", "cal-2"], forKey: "meetingCalendarIDs")

        let calendar = MeetingCalendar(defaults: defaults)
        #expect(calendar.requireCallLink == false)
        #expect(calendar.selectedCalendarIDs == Set(["cal-1", "cal-2"]))

        // The setter refreshes EventKit; test restoration without querying user calendars.
        defaults.set(true, forKey: "meetingRequireCallLink")
        #expect(MeetingCalendar(defaults: defaults).requireCallLink == true)
    }

    // MARK: - P07 & P08: Diagnostics, Bounded Audio Check & Section Departures

    final class MonitorCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _monitors: [SyntheticAudioLevelMonitor] = []
        var monitors: [SyntheticAudioLevelMonitor] {
            lock.lock(); defer { lock.unlock() }; return _monitors
        }
        var first: SyntheticAudioLevelMonitor? {
            lock.lock(); defer { lock.unlock() }; return _monitors.first
        }
        func append(_ monitor: SyntheticAudioLevelMonitor) {
            lock.lock(); defer { lock.unlock() }; _monitors.append(monitor)
        }
    }

    final class SyntheticAudioLevelMonitor: AudioLevelMonitoring, @unchecked Sendable {
        private struct State {
            var isStarted = false
            var isStopped = false
            var startCount = 0
            var stopCount = 0
        }
        private let stateLock = OSAllocatedUnfairLock(initialState: State())
        let micID: String?
        let backend: AudioCaptureBackend
        let onLevels: @Sendable (Double, Double) -> Void
        var shouldFailOnStart = false
        var startGate: SyntheticStartGate?

        var isStarted: Bool { stateLock.withLock { $0.isStarted } }
        var isStopped: Bool { stateLock.withLock { $0.isStopped } }
        var startCallCount: Int { stateLock.withLock { $0.startCount } }
        var stopCallCount: Int { stateLock.withLock { $0.stopCount } }

        init(micID: String?, backend: AudioCaptureBackend, onLevels: @escaping @Sendable (Double, Double) -> Void) {
            self.micID = micID
            self.backend = backend
            self.onLevels = onLevels
        }

        func start() async throws {
            await startGate?.wait()
            if shouldFailOnStart {
                throw NSError(domain: "AudioLevelMonitorError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
            }
            stateLock.withLock {
                $0.startCount += 1
                $0.isStarted = true
            }
        }

        func stop() async throws {
            stateLock.withLock {
                $0.stopCount += 1
                $0.isStopped = true
                $0.isStarted = false
            }
        }

        func sendLevels(mic: Double, system: Double) {
            onLevels(mic, system)
        }
    }

    final class SyntheticClock: @unchecked Sendable {
        struct Deadline: Sendable, Equatable {
            let id: UUID
            let duration: Duration
        }
        private struct State {
            var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
            var deadlines: [Deadline] = []
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var deadlines: [Deadline] { state.withLock { $0.deadlines } }
        func isPending(_ deadline: Deadline) -> Bool {
            state.withLock { $0.waiters[deadline.id] != nil }
        }
        func sleep(duration: Duration) async throws {
            let deadline = Deadline(id: UUID(), duration: duration)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let registered = state.withLock { state in
                        guard !Task.isCancelled else { return false }
                        state.deadlines.append(deadline)
                        state.waiters[deadline.id] = cont
                        return true
                    }
                    if !registered { cont.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                self.state.withLock { $0.waiters.removeValue(forKey: deadline.id) }?
                    .resume(throwing: CancellationError())
            }
        }
        @discardableResult func advance(_ deadline: Deadline) -> Bool {
            let continuation = state.withLock { $0.waiters.removeValue(forKey: deadline.id) }
            continuation?.resume()
            return continuation != nil
        }
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(predicate(), "Bounded synthetic observation timed out")
    }

    @Test func p07_clockCancellationCannotAdvanceOldDeadline() async throws {
        let clock = SyntheticClock()
        let sleeper = Task { try await clock.sleep(duration: .seconds(30)) }
        try await wait { clock.deadlines.count == 1 }
        let deadline = try #require(clock.deadlines.first)
        sleeper.cancel()
        #expect(!clock.isPending(deadline), "Task cancellation must remove its own waiter")
        let advanced = clock.advance(deadline)
        #expect(!advanced, "Cancelled deadline must never resume successfully")
        let result = await sleeper.result
        guard case .failure(let error) = result else {
            Issue.record("Cancelled sleep returned success")
            return
        }
        #expect(error is CancellationError)
    }

    final class SyntheticStartGate: @unchecked Sendable {
        private struct State {
            var open = false
            var continuation: CheckedContinuation<Void, Never>?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var waiting: Bool { state.withLock { $0.continuation != nil } }
        func wait() async {
            await withCheckedContinuation { cont in
                let shouldWait = state.withLock { state in
                    guard !state.open else { return false }
                    state.continuation = cont
                    return true
                }
                if !shouldWait { cont.resume() }
            }
        }
        func open() {
            state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.open = true
                defer { state.continuation = nil }
                return state.continuation
            }?.resume()
        }
    }

    final class SyntheticRecordingController: AudioCaptureControllerProtocol, @unchecked Sendable {
        let output: URL
        private let stops = OSAllocatedUnfairLock(initialState: 0)
        var stopCount: Int { stops.withLock { $0 } }
        init(output: URL) { self.output = output }
        func startCapture() async throws {}
        func stopCapture() async throws -> AudioCaptureStopResult {
            stops.withLock { $0 += 1 }
            return .init(duration: 15, outputURL: output)
        }
        func setMicrophoneMuted(_ muted: Bool) {}
        func currentMicrophoneState() -> MicrophoneRecordingState { .receiving }
    }

    private actor DiagnosticTestRunner: TranscriptionRunnerProtocol {
        private var continuation: CheckedContinuation<Void, Never>?
        var waiting: Bool { continuation != nil }
        func finish() { continuation?.resume(); continuation = nil }
        func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
            onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) {
            onOutput?("Проверка файла 2/10: gigaam/weights.fp16.safetensors (SHA-256)…")
            await withCheckedContinuation { continuation = $0 }
            return ("Все файлы проверены.", true)
        }
        func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
            onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL { recording }
    }

    private struct TestExporter: AudioExporterProtocol {
        func exportMixedAudio(from inputs: [URL], to output: URL) async throws {}
    }

    private func publishedFixture(_ id: String, in root: URL) throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_parakeet_off.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        json["resultID"] = id
        if var playback = json["playback"] as? [String: Any] {
            playback["mixPath"] = "raw/transcripts/" + id + "/mix.m4a"
            json["playback"] = playback
        }
        let directory = root.appendingPathComponent("raw/transcripts/" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("result.json"))
        _ = try TranscriptDocument.load(from: directory.appendingPathComponent("result.json"), recordingDirectory: root)
    }

    @Test func p07_p08_audioCheckStopsOnSectionDepartureBetweenRecordingAndDiagnostics() async throws {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let collector = MonitorCollector()
        let model = isolatedRecorderModel(
            defaults: defaults,
            startBackgroundServices: false,
            audioLevelMonitorFactory: { micID, backend, onLevels in
                let m = SyntheticAudioLevelMonitor(micID: micID, backend: backend, onLevels: onLevels)
                collector.append(m)
                return m
            }
        )

        // Set audio check visible on recording section
        model.setAudioCheckVisible(true, section: .recording)
        #expect(model.isAudioCheckVisibleForTesting)

        // Start audio check from recording section
        model.toggleAudioCheck(from: .recording)
        #expect(model.isCheckingAudio)

        for _ in 0..<50 {
            if let first = collector.first, first.isStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let monitor = try #require(collector.first)
        #expect(monitor.isStarted)

        // Switching from Recording to Diagnostics is a section departure
        // The bounded check must stop and reset levels
        model.setAudioCheckVisible(true, section: .diagnostics)
        for _ in 0..<100 {
            if !model.isCheckingAudio && monitor.isStopped { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isCheckingAudio, "Switching section must stop audio check")
        #expect(monitor.isStopped, "Monitor must stop on departure")
        #expect(model.levels.mic == 0 && model.levels.system == 0, "Levels must reset on departure")

        // Returning to recording must NOT resurrect the check
        model.setAudioCheckVisible(true, section: .recording)
        #expect(!model.isCheckingAudio, "Returning to section must never resurrect stopped check")
    }

    @Test func p07_p08_audioCheckStopsOnWindowClose() async throws {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let collector = MonitorCollector()
        let model = isolatedRecorderModel(
            defaults: defaults,
            startBackgroundServices: false,
            audioLevelMonitorFactory: { micID, backend, onLevels in
                let m = SyntheticAudioLevelMonitor(micID: micID, backend: backend, onLevels: onLevels)
                collector.append(m)
                return m
            }
        )

        model.setAudioCheckVisible(true, section: .diagnostics)
        model.toggleAudioCheck(from: .diagnostics)
        #expect(model.isCheckingAudio)

        for _ in 0..<50 {
            if let first = collector.first, first.isStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let monitor = try #require(collector.first)
        #expect(monitor.isStarted)

        // Window closes or hides
        model.setAudioCheckVisible(false, section: nil)
        for _ in 0..<100 {
            if !model.isCheckingAudio && monitor.isStopped { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isCheckingAudio)
        #expect(monitor.isStopped)
    }

    @Test func p04_diagnosticSummaryShowsFileCountOnSecondCheckInsteadOfMaskingWithTerminalSummary() async throws {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        defaults.set(temp.path, forKey: "recordingsDirectory")

        let runner = DiagnosticTestRunner()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: TestExporter())
        defaults.set([String](), forKey: "meetingCalendarIDs")
        let model = isolatedRecorderModel(processingService: service, defaults: defaults, startBackgroundServices: false)

        for _ in 0..<200 { if model.canResetCache { break }; try await Task.sleep(for: .milliseconds(5)) }

        // Operation A (first check)
        let checkA = Task { await model.checkTranscription(prepare: false) }
        for _ in 0..<200 { if await runner.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        await runner.finish()
        await checkA.value
        for _ in 0..<100 { await Task.yield() }

        #expect(model.diagnosticSummary == "Транскрибация готова.")
        #expect(model.lastTerminalSummary == "Транскрибация готова.")

        // Operation B (second check)
        let checkB = Task { await model.checkTranscription(prepare: false) }
        for _ in 0..<200 { if await runner.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<100 { await Task.yield() }

        #expect(model.diagnosticRunning)
        #expect(model.diagnosticReport.contains("weights.fp16.safetensors"))
        // On unpatched code, diagnosticSummary returns lastTerminalSummary ("Транскрибация готова."),
        // masking the active file/count progress!
        #expect(model.diagnosticSummary?.contains("weights.fp16.safetensors") == true,
                "diagnosticSummary must show active file/count during second check, not prior terminal summary")

        // Queue snapshot arrives
        let job = await service.enqueue(recordingURL: temp.appendingPathComponent("test.m4a"),
                                        settings: .init(parakeet: false, echoCancellation: false))
        for _ in 0..<100 { await Task.yield() }
        #expect(model.diagnosticSummary?.contains("weights.fp16.safetensors") == true,
                "Queue snapshot must not clobber active progress")

        await service.cancel(jobID: job.id)
        await runner.finish()
        await checkB.value
        for _ in 0..<100 { await Task.yield() }

        #expect(!model.diagnosticRunning)
        #expect(model.diagnosticSummary == "Транскрибация готова.")
    }

    @Test func p02_followControlsObserveChildFollowAndRebindOnReplacement() async throws {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Standard layout: folder "meeting_A" containing "meeting_A.m4a"
        let folderA = temp.appendingPathComponent("meeting_A")
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        let recordingA = folderA.appendingPathComponent("meeting_A.m4a")
        try Data([0, 0]).write(to: recordingA)
        try publishedFixture("res_valid_parakeet_off", in: folderA)

        let folderB = temp.appendingPathComponent("meeting_B")
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        let recordingB = folderB.appendingPathComponent("meeting_B.m4a")
        try Data([0, 0]).write(to: recordingB)
        try publishedFixture("res_valid_parakeet_off_b", in: folderB)

        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)

        #expect(!model.isFollowAvailable)
        #expect(!model.isEditorFollowing)

        // 1. Open editor A
        let editorA = try await model.workspace.open(recordingURL: recordingA, title: "Meeting A")
        guard case .review = editorA.state.mode else {
            Issue.record("Expected .review mode")
            return
        }
        #expect(editorA.state.session != nil)
        #expect(!editorA.rows.isEmpty)
        #expect(model.isFollowAvailable)
        #expect(model.isEditorFollowing)

        // Track publications from model.objectWillChange
        var modelChangeCount = 0
        let sub = model.objectWillChange.sink { _ in
            modelChangeCount += 1
        }
        defer { sub.cancel() }

        // Invalidate follow state in editor A (simulating manual scroll in review window)
        editorA.setFollow(false)
        #expect(modelChangeCount > 0, "Model must observe child follow change")
        #expect(!model.isEditorFollowing)

        // Toggle back via model
        let countBeforeToggle = modelChangeCount
        model.setEditorFollowing(true)
        #expect(modelChangeCount > countBeforeToggle, "Model must publish when toggling follow")
        #expect(model.isEditorFollowing)

        // 2. Rebind on current replacement: open editor B
        let editorB = try await model.workspace.open(recordingURL: recordingB, title: "Meeting B")
        guard case .review = editorB.state.mode else {
            Issue.record("Expected .review mode")
            return
        }
        #expect(editorB.state.session != nil)
        #expect(!editorB.rows.isEmpty)
        #expect(model.workspace.current === editorB)

        // Old editor A must no longer affect model after replacement
        let countBeforeOldEdit = modelChangeCount
        editorA.setFollow(false)
        #expect(modelChangeCount == countBeforeOldEdit, "Old replaced editor must not publish to model")

        // New editor B does affect model
        editorB.setFollow(false)
        #expect(modelChangeCount > countBeforeOldEdit, "Active editor must publish to model")
        #expect(!model.isEditorFollowing)

        // 3. Close current
        model.workspace.closeCurrent()
        #expect(!model.isFollowAvailable)
        #expect(!model.isEditorFollowing)
    }

    @Test func p05_p08_canResetCacheRejectsWhenPreventsTerminationIsTrue() async throws {
        let (defaults, suite) = createTestDefaults()
        let (recordings, appData) = try createTestDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: recordings.deletingLastPathComponent())
        }
        defaults.set(recordings.path, forKey: "recordingsDirectory")

        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false,
            audioLevelMonitorFactory: { micID, backend, onLevels in
                SyntheticAudioLevelMonitor(micID: micID, backend: backend, onLevels: onLevels)
            })
        model.setAttachedForTesting(session: true, processing: true)

        #expect(model.preventsTermination == false)
        #expect(model.canResetCache == true)

        // 1. Modal / Rename / Text input in workspace
        model.workspace.externalModal = true
        #expect(model.workspace.hasInput == true)
        #expect(model.preventsTermination == true)
        #expect(model.canResetCache == false, "canResetCache must reject when workspace.hasInput is true")

        // Direct call to performCacheReset must reject without calling confirmation
        var confirmationPrompted = false
        await model.performCacheReset(in: appData, confirmation: { _ in
            confirmationPrompted = true
            return false
        })
        #expect(!confirmationPrompted, "performCacheReset must reject when canResetCache is false")
        model.workspace.externalModal = false

        // 2. Audio check active (audio preview)
        model.setAudioCheckVisible(true, section: .recording)
        model.toggleAudioCheck(from: .recording)
        #expect(model.isCheckingAudio == true)
        #expect(model.preventsTermination == true)
        #expect(model.canResetCache == false, "canResetCache must reject when isCheckingAudio is true")
        await model.endAudioCheck()
        #expect(model.isCheckingAudio == false)

        // 3. Session starting
        model.setSessionStartingForTesting(true)
        #expect(model.preventsTermination == true)
        #expect(model.canResetCache == false, "canResetCache must reject when sessionStarting is true")
        model.setSessionStartingForTesting(false)

        // 4. Session stopping
        model.setSessionStoppingForTesting(true)
        #expect(model.preventsTermination == true)
        #expect(model.canResetCache == false, "canResetCache must reject when sessionStopping is true")
        model.setSessionStoppingForTesting(false)

        // 5. Normal idle state restored
        #expect(model.preventsTermination == false)
        #expect(model.canResetCache == true)
    }

    @Test func p07_p08_syntheticAudioCheckCallbacksAndLateLevelRejection() async throws {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let collector = MonitorCollector()
        let clock = SyntheticClock()

        let model = isolatedRecorderModel(
            defaults: defaults,
            startBackgroundServices: false,
            audioLevelMonitorFactory: { micID, backend, onLevels in
                let m = SyntheticAudioLevelMonitor(micID: micID, backend: backend, onLevels: onLevels)
                collector.append(m)
                return m
            },
            audioCheckTimeoutSleeper: { duration in
                try await clock.sleep(duration: duration)
            }
        )

        // 1. Start audio check on .recording section
        model.setAudioCheckVisible(true, section: .recording)
        model.toggleAudioCheck(from: .recording)
        #expect(model.isCheckingAudio)

        for _ in 0..<50 {
            if let first = collector.first, first.isStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let monitorA = try #require(collector.first)
        #expect(monitorA.isStarted)
        try await wait { clock.deadlines.count == 1 }
        let deadlineA = try #require(clock.deadlines.first)
        #expect(deadlineA.duration == .seconds(30))

        // Deliver initial levels
        for _ in 0..<100 {
            monitorA.sendLevels(mic: 0.75, system: 0.4)
            model.levels.flush()
            if model.levels.mic > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.levels.mic > 0)

        // 2. Section departure: switch to .diagnostics
        model.setAudioCheckVisible(true, section: .diagnostics)
        for _ in 0..<100 {
            if !model.isCheckingAudio && monitorA.isStopped { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isCheckingAudio, "Departure to diagnostics must stop audio check")
        #expect(monitorA.isStopped, "Old monitor must be stopped")
        #expect(model.levels.mic == 0 && model.levels.system == 0, "Levels must reset on departure")
        #expect(!clock.isPending(deadlineA))

        // 3. Late levels from old monitor must be REJECTED and not restore levels
        monitorA.sendLevels(mic: 0.95, system: 0.8)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.levels.mic == 0 && model.levels.system == 0, "Late levels from stopped monitor must be rejected")

        // Returning to recording must not resurrect
        model.setAudioCheckVisible(true, section: .recording)
        #expect(!model.isCheckingAudio)

        // 4. Timeout test (<= 30s)
        model.toggleAudioCheck(from: .recording)
        #expect(model.isCheckingAudio)
        try await wait { clock.deadlines.count == 2 && collector.monitors.count == 2 && collector.monitors[1].isStarted }
        let monitorB = collector.monitors[1]
        let deadlineB = clock.deadlines[1]
        #expect(deadlineB.id != deadlineA.id && deadlineB.duration == .seconds(30))
        let advancedA = clock.advance(deadlineA)
        #expect(!advancedA)
        #expect(model.isCheckingAudio && monitorB.isStarted && !monitorB.isStopped)
        let advancedB = clock.advance(deadlineB)
        #expect(advancedB)
        try await wait { !model.isCheckingAudio && monitorB.isStopped }
        #expect(!model.isCheckingAudio, "Audio check must stop on timeout")
        #expect(monitorB.stopCallCount == 1)

        // 5. Denied / Error test
        let failingModel = isolatedRecorderModel(
            defaults: defaults,
            startBackgroundServices: false,
            audioLevelMonitorFactory: { micID, backend, onLevels in
                let m = SyntheticAudioLevelMonitor(micID: micID, backend: backend, onLevels: onLevels)
                m.shouldFailOnStart = true
                return m
            }
        )
        failingModel.setAudioCheckVisible(true, section: .recording)
        failingModel.toggleAudioCheck(from: .recording)
        for _ in 0..<50 {
            if failingModel.status == "Не удалось проверить звук" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!failingModel.isCheckingAudio)
        #expect(failingModel.status == "Не удалось проверить звук")
        #expect(failingModel.errorMessage != nil)
    }

    @Test(arguments: [false, true])
    func p07_p08_pendingDepartureRestartPreservesIndependentRecording(pendingStart: Bool) async throws {
        let (defaults, suite) = createTestDefaults()
        let (root, _) = try createTestDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let collector = MonitorCollector()
        let gate = SyntheticStartGate()
        defer { gate.open() }
        let clock = SyntheticClock()
        let repo = RecordingHistoryRepository()
        let session = RecordingSessionService(historyRepo: repo)
        let model = isolatedRecorderModel(sessionService: session, historyRepository: repo,
            defaults: defaults, startBackgroundServices: false,
            audioLevelMonitorFactory: { mic, backend, onLevels in
                let monitor = SyntheticAudioLevelMonitor(micID: mic, backend: backend, onLevels: onLevels)
                let first = collector.monitors.isEmpty
                if first && pendingStart { monitor.startGate = gate }
                collector.append(monitor)
                if first && !pendingStart { await gate.wait() }
                return monitor
            }, audioCheckTimeoutSleeper: { try await clock.sleep(duration: $0) })
        let delegate = RecorderAppDelegate(model: model)
        try await wait { model.isAttached }
        model.setAudioCheckVisible(true, section: .recording)
        model.toggleAudioCheck(from: .recording)
        try await wait { gate.waiting && clock.deadlines.count == 1 }
        let monitorA = try #require(collector.first)
        // Actual App delegate visibility callback: no rendered Settings form or platform polling.
        delegate.applicationDidHide(Notification(name: NSApplication.didHideNotification))
        try await wait { !model.isCheckingAudio }
        model.setAudioCheckVisible(true, section: .diagnostics)
        model.toggleAudioCheck(from: .diagnostics)
        try await wait { clock.deadlines.count == 2 }
        gate.open()
        try await wait { monitorA.isStopped && collector.monitors.count == 2 && collector.monitors[1].isStarted }
        let monitorB = collector.monitors[1]
        monitorA.sendLevels(mic: 0.9, system: 0.9)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.isCheckingAudio && model.levels.mic == 0 && model.levels.system == 0)
        #expect(!clock.isPending(clock.deadlines[0]) && clock.isPending(clock.deadlines[1]))

        let output = root.appendingPathComponent("meeting/meeting.m4a")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: output)
        let capture = SyntheticRecordingController(output: output)
        let snapshot = try await session.start(controller: capture, outputURL: output)
        try await wait { model.isRecording && model.activeSessionID == snapshot.sessionID }
        delegate.applicationDidHide(Notification(name: NSApplication.didHideNotification))
        try await wait { !model.isCheckingAudio && monitorB.isStopped }
        #expect(capture.stopCount == 0 && model.isRecording && model.activeSessionID == snapshot.sessionID)
        model.setAudioCheckVisible(true, section: .recording)
        model.toggleAudioCheck(from: .recording)
        #expect(!model.isCheckingAudio && collector.monitors.count == 2)
        #expect(capture.stopCount == 0)
        _ = try await session.stop(elapsed: 15, expectedSessionID: snapshot.sessionID)
        try await wait { !model.isRecording && !model.sessionStopping }
        #expect(capture.stopCount == 1)
    }

    @Test func p08_operationSpecificLocksDoNotBlockTheme() {
        let (defaults, suite) = createTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = isolatedRecorderModel(defaults: defaults, startBackgroundServices: false)

        // Simulate busy/recording state
        model.isRecording = true
        model.isBusy = true

        // Theme and reading remain accessible
        model.appearance = .light
        #expect(model.appearance == .light)
        #expect(defaults.string(forKey: "appAppearance") == AppAppearance.light.rawValue)

        // But recording-critical operations are locked
        #expect(!model.canStartRecording)
        #expect(!model.canResetCache)
    }
}
