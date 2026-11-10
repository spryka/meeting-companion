import AppKit
import CoreMedia
import SwiftUI
import Testing
import MeetingCompanionCore
@testable import MeetingCompanionApp

@Suite(.serialized) @MainActor
struct WorkspaceKeyboardTests {
    @Test func refreshShortcutFromSearchAndViewMenuShareAdmission() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        try await fixture.settle { !fixture.model.history.loading }
        let current = try #require(fixture.model.workspace.current)
        current.togglePlayback()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let root = NSMenu()
        NSApp.mainMenu = root
        fixture.delegate.installWorkspaceCommands()
        let view = try #require(root.item(withTitle: "Вид")?.submenu)
        let item = try #require(view.items.first { $0.title == "Обновить библиотеку" })
        #expect(item.keyEquivalent == "r" && item.keyEquivalentModifierMask == .command)
        #expect(root.item(withTitle: "Запись")?.submenu?.items.contains { $0.title == item.title } == false)
        let field = try #require(fixture.searchField)
        #expect(window.makeFirstResponder(field))
        #expect(window.performKeyEquivalent(with: fixture.key("r", code: 15, modifiers: .command)))
        #expect(fixture.model.libraryRefreshPending)
        #expect(!window.validateMenuItem(item))
        try await fixture.settle { !fixture.model.libraryRefreshPending }
        #expect(fixture.model.history.refreshCompletion != nil)
        #expect(fixture.model.workspace.current === current)
        #expect(current.playbackState == .playing)
        let completion = fixture.model.history.refreshCompletion
        #expect(fixture.model.presentSettings())
        #expect(!window.validateMenuItem(item))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        await Task.yield()
        #expect(!fixture.model.libraryRefreshPending)
        #expect(fixture.model.history.refreshCompletion == completion)
    }

    @Test func manualLibraryRefreshAdmitsOnlyOneRequestAndPreservesReview() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        try await fixture.settle { !fixture.model.history.loading }
        let current = try #require(fixture.model.workspace.current)
        let selected = fixture.model.selectedHistoryURL
        fixture.model.history.reportError("Existing save error")
        #expect(fixture.model.requestLibraryRefresh())
        #expect(!fixture.model.requestLibraryRefresh())
        try await fixture.settle { !fixture.model.libraryRefreshPending }
        #expect(fixture.model.history.refreshError == nil)
        #expect(fixture.model.history.refreshCompletion != nil)
        #expect(fixture.model.history.error == "Existing save error")
        #expect(fixture.model.workspace.current === current)
        #expect(fixture.model.selectedHistoryURL == selected)
    }

    @Test(arguments: ["settings", "external", "sheet", "inactive", "hidden", "form"])
    func manualLibraryRefreshRespectsAdmission(blocker: String) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        switch blocker {
        case "settings": #expect(fixture.model.presentSettings())
        case "external": fixture.model.workspace.externalModal = true
        case "sheet": window.beginSheet(sheet, completionHandler: nil)
        case "inactive": window.isKeyboardTarget = { false }
        case "hidden": window.orderOut(nil)
        default: fixture.model.mainPage = .recording
        }
        #expect(!fixture.model.requestLibraryRefresh())
        #expect(!fixture.model.libraryRefreshPending)
        #expect(fixture.model.history.refreshCompletion == nil)
        if window.attachedSheet === sheet { window.endSheet(sheet) }
    }

    @Test func historyManualMissingRootAndSuccessfulRetryOwnOnlyRefreshError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = RecordingHistory()
        await history.refresh(root: root)
        #expect(history.error == nil) // First launch may not have a recordings folder yet.
        history.reportError("Save failed")
        await history.refresh(root: root, manual: true)
        #expect(history.refreshError != nil)
        #expect(!history.loading)
        #expect(history.error == "Save failed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await history.refresh(root: root, manual: true)
        #expect(history.refreshError == nil)
        #expect(history.refreshCompletion != nil)
        #expect(history.error == "Save failed")
    }

    @Test(arguments: [false, true]) func windowResponderRecoversAtNativeLifecycleBoundary(sheet: Bool) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let next = try #require(try await fixture.addLegacyLibrary(["next"]).first)
        let window = fixture.delegate.window!
        let library = try #require(fixture.navigation("library"))
        #expect(window.makeFirstResponder(library))
        #expect(window.makeFirstResponder(window))
        if sheet {
            let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.beginSheet(child, completionHandler: nil)
            window.endSheet(child)
        } else { window.becomeKey() }
        try await fixture.settle("Native lifecycle recovers window-as-responder to library") {
            window.attachedSheet == nil && window.firstResponder === library
        }
        #expect(window.performKeyEquivalent(with: fixture.key("", code: 125)))
        #expect(fixture.model.selectedHistoryURL == next)
    }

    @Test(arguments: ["control", "settings", "sheet", "inactive", "hidden", "minimized"])
    func lifecycleRecoveryPreservesNativeInputAndRechecksGuards(blocker: String) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        let library = try #require(fixture.navigation("library"))
        #expect(window.makeFirstResponder(library))
        #expect(window.makeFirstResponder(window))
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(child, completionHandler: nil)
        window.endSheet(child)
        var editor: NSText?
        var newSheet: NSWindow?
        switch blocker {
        case "control":
            let field = try #require(fixture.searchField)
            field.selectText(nil)
            let activeEditor = try #require(field.currentEditor())
            editor = activeEditor
        case "settings": #expect(fixture.model.presentSettings())
        case "sheet":
            let replacement = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            newSheet = replacement
            window.beginSheet(replacement, completionHandler: nil)
        case "inactive": window.isKeyboardTarget = { false }
        case "hidden": window.orderOut(nil)
        default:
            window.miniaturize(nil)
            try await fixture.settle { window.isMiniaturized }
            #expect(window.makeFirstResponder(window))
            fixture.delegate.windowDidEndSheet(Notification(name: NSWindow.didEndSheetNotification, object: window))
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        if blocker == "control" { #expect(window.firstResponder === editor) }
        else { #expect(window.firstResponder !== library) }
        if let newSheet { window.endSheet(newSheet) }
        if window.isMiniaturized { window.deminiaturize(nil) }
    }

    @Test func escapeClosesSettingsAndReturnsToVisibleNavigation() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        let library = try #require(fixture.navigation("library"))
        window.makeFirstResponder(library)
        fixture.delegate.showSettings()
        try await fixture.settle { fixture.model.settingsPresented && fixture.searchField?.isEnabled == false }
        fixture.pressEscape(in: window)
        try await fixture.settle("Escape dismisses Settings") { !fixture.model.settingsPresented }
        try await fixture.settle { window.firstResponder === library }
        #expect(window.isVisible && fixture.model.mainPage == .history)
    }

    @Test func escapeReturnsFromSettingsToLibraryWhenTranscriptBecomesHidden() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let urls = try await fixture.addLegacyLibrary(["alpha", "beta"])
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        fixture.model.workspaceShowsList = true
        let transcript = try #require(fixture.navigation("transcript"))
        #expect(window.makeFirstResponder(transcript))
        fixture.delegate.showSettings()
        try await fixture.settle { fixture.searchField?.isEnabled == false }
        window.setContentSize(NSSize(width: 640, height: 560))
        try await fixture.settle { (transcript as? WorkspaceNavigationView)?.isUsable == false }
        fixture.pressEscape(in: window)
        try await fixture.settle { !fixture.model.settingsPresented }
        try await fixture.settle("Esc returns to visible library when original transcript is hidden") {
            window.firstResponder === fixture.navigation("library")
        }
        NSApp.sendEvent(fixture.key("", code: 125))
        #expect(fixture.model.selectedHistoryURL == urls[0])
    }

    @Test(arguments: ["recording", "text", "speaker"]) func escapeReturnsFromSheetToOriginalNavigation(kind: String) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = fixture.delegate.window!
        let transcript = try #require(fixture.navigation("transcript"))
        #expect(window.makeFirstResponder(transcript))
        let current = try #require(fixture.model.workspace.current)
        if kind == "recording" { fixture.model.mainPage = .recording }
        else if kind == "text" { current.openTextEditing(for: try #require(current.rows.first).id) }
        else { current.openSpeakerAssignment(for: try #require(current.rows.first).id) }
        try await fixture.settle { window.attachedSheet != nil }
        fixture.pressEscape(in: try #require(window.attachedSheet))
        try await fixture.settle { window.attachedSheet == nil }
        try await fixture.settle("Esc sheet dismissal restores original visible transcript navigation") {
            window.firstResponder === transcript
        }
        #expect(current.currentDraftIdentity == nil && fixture.model.mainPage == .history)
    }

    @Test func escapeClosesOnlySettingsAboveRecordingFormThenCancelsForm() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let window = fixture.delegate.window!
        fixture.model.mainPage = .recording
        try await fixture.settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let title = try #require(fixture.views(sheet.contentView).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Название записи" })
        title.selectText(nil)
        let editor = try #require(sheet.firstResponder as? NSTextView)
        editor.insertText("Synthetic draft title", replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.delegate.showSettings()
        try await fixture.settle { fixture.model.settingsPresented && !title.isEnabled }
        fixture.pressEscape(in: sheet)
        try await fixture.settle("Escape closes only Settings above the form") { !fixture.model.settingsPresented }
        #expect(fixture.model.mainPage == .recording && window.attachedSheet === sheet)
        #expect(title.stringValue == "Synthetic draft title")
        try await fixture.settle { sheet.firstResponder === editor }
        fixture.pressEscape(in: sheet)
        try await fixture.settle { fixture.model.mainPage == .history && window.attachedSheet == nil }
        #expect(!fixture.model.isRecording && !FileManager.default.fileExists(atPath: fixture.model.outputDirectory.path))
    }

    @Test func escapeThroughNestedSettingsRestoresLibraryNavigation() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let next = try #require(try await fixture.addLegacyLibrary(["next"]).first)
        let window = fixture.delegate.window!
        let library = try #require(fixture.navigation("library"))
        #expect(window.makeFirstResponder(library))
        #expect(window.performKeyEquivalent(with: fixture.key("n", code: 45, modifiers: .command)))
        try await fixture.settle("Cmd+N opens recording sheet") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let title = try #require(fixture.views(sheet.contentView).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Название записи" })
        title.selectText(nil)
        let titleEditor = try #require(title.currentEditor())
        fixture.delegate.showSettings()
        try await fixture.settle("Settings disables recording title") { !title.isEnabled }
        fixture.pressEscape(in: sheet)
        try await fixture.settle("First Escape closes Settings and restores enabled title editor") {
            !fixture.model.settingsPresented && title.isEnabled && sheet.firstResponder === titleEditor
        }
        fixture.pressEscape(in: sheet)
        try await fixture.settle("Second Escape closes recording sheet") { window.attachedSheet == nil }
        try await fixture.settle("Nested Settings then form Esc restores library navigation") {
            window.firstResponder === library
        }
        #expect(window.performKeyEquivalent(with: fixture.key("", code: 125)))
        #expect(fixture.model.selectedHistoryURL == next)
    }

    @Test(arguments: [false, true]) func escapeCancelsExistingEditorWithoutSaving(speaker: Bool) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let current = try #require(fixture.model.workspace.current)
        let row = try #require(current.rows.first)
        if speaker { current.openSpeakerAssignment(for: row.id) }
        else { current.openTextEditing(for: row.id); current.updateDraftText("Unsaved synthetic edit") }
        let window = fixture.delegate.window!
        try await fixture.settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        fixture.pressEscape(in: sheet)
        try await fixture.settle("Escape uses the editor Cancel route") {
            current.currentDraftIdentity == nil && window.attachedSheet == nil
        }
        #expect(current.rows.first?.text == row.text && current.rows.first?.name == row.name)
        #expect(!current.state.isClosed && window.isVisible)
    }

    @Test func escapeWithoutModalPreservesSearchAndPlayback() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        let current = try #require(fixture.model.workspace.current)
        current.togglePlayback()
        window.dispatch(.findRecording)
        try await fixture.settle { fixture.model.workspaceSearchRequest == nil && fixture.searchField?.currentEditor() != nil }
        let editor = try #require(fixture.searchField?.currentEditor() as? NSTextView)
        editor.insertText("Synthetic query", replacementRange: NSRange(location: NSNotFound, length: 0))
        let request = fixture.model.workspaceLoadRequest
        fixture.pressEscape(in: window)
        #expect(editor.string == "Synthetic query" && window.isVisible)
        #expect(fixture.model.workspaceLoadRequest == request && fixture.model.workspace.current === current)
        #expect(current.playbackState == .playing && !fixture.model.settingsPresented)
    }

    @Test(arguments: [3.0, 15.0]) func escapeNeverInterruptsRecordingOrAddsCapsuleHotkeys(elapsed: Double) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        // isolatedRecorderModel injects a synthetic capture controller, exporter and processing runner.
        #expect(await fixture.model.startRecordingIntent(customTitle: "Synthetic Escape check"))
        try await fixture.settle { fixture.model.isRecording }
        let session = try #require(fixture.model.activeSessionID)
        fixture.model.elapsed = elapsed
        let recording = try #require(fixture.model.lastFileURL)
        let original = try Data(contentsOf: recording)
        let capsule = try #require(fixture.delegate.capsuleController.panel)
        #expect(!capsule.canBecomeKey)
        fixture.pressEscape(in: capsule)
        #expect(fixture.model.isRecording && fixture.model.activeSessionID == session)
        fixture.delegate.showSettings()
        let window = fixture.delegate.window!
        try await fixture.settle { fixture.model.settingsPresented && fixture.searchField?.isEnabled == false }
        fixture.pressEscape(in: window)
        try await fixture.settle { !fixture.model.settingsPresented }
        fixture.pressEscape(in: window)
        #expect(fixture.model.isRecording && fixture.model.activeSessionID == session)
        #expect(!fixture.model.recordingCancelled && !fixture.model.sessionStopping)
        #expect(try Data(contentsOf: recording) == original)
        // Explicit cleanup of synthetic recording; Escape has left the session running.
        fixture.model.elapsed = 15
        #expect(await fixture.model.stopRecordingIntent(sessionID: session))
        try await fixture.settle { !fixture.model.isRecording && !fixture.model.sessionStopping }
    }

    @Test func nativeSearchFocusFallsBackOnResizeButNeverStealsModalFocus() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        fixture.model.workspaceShowsList = false
        let field = try #require(fixture.searchField)
        field.selectText(nil) // Native entry without the Cmd+F reveal route.
        let editor = try #require(field.currentEditor())
        #expect(window.firstResponder === editor)
        window.setContentSize(NSSize(width: 640, height: 560))
        try await fixture.settle("Native focus without Cmd+F transfers after wide-to-narrow resize") { window.firstResponder === fixture.navigation("transcript") }
        fixture.delegate.showSettings()
        window.makeFirstResponder(window.contentView)
        let settingsResponder = window.firstResponder
        window.setContentSize(NSSize(width: 1100, height: 700))
        try await fixture.settle("Settings rendered after resize") { fixture.model.settingsPresented && fixture.searchField?.isEnabled == false }
        #expect(window.firstResponder === settingsResponder)
        fixture.model.dismissSettings()
        fixture.model.mainPage = .recording
        try await fixture.settle("Recording sheet appears after Settings closes") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let title = try #require(fixture.views(sheet.contentView).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Название записи" })
        title.selectText(nil)
        let titleEditor = try #require(title.currentEditor())
        window.setContentSize(NSSize(width: 640, height: 560))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(sheet.firstResponder === titleEditor && title.currentEditor() === titleEditor)
    }

    @Test func dismissingSettingsAfterHidingSearchTargetsVisibleTranscript() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        fixture.model.workspaceShowsList = false
        let current = fixture.model.workspace.current, selection = fixture.model.selectedHistoryURL
        let field = try #require(fixture.searchField)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("Synthetic retained query", replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.delegate.showSettings()
        try await fixture.settle { !field.isEnabled }
        window.setContentSize(NSSize(width: 640, height: 560))
        try await fixture.settle { fixture.searchField == nil }
        fixture.model.dismissSettings()
        try await fixture.settle("Settings returns focus to visible transcript after search disappears") {
            window.firstResponder === fixture.navigation("transcript")
        }
        #expect(field.stringValue == "Synthetic retained query")
        #expect(fixture.model.workspace.current === current && fixture.model.selectedHistoryURL == selection)
    }

    @Test func commandNOpensOneExistingFormWithoutCapture() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let model = fixture.model, window = fixture.delegate.window!
        let original = model.workspaceLoadRequest
        #expect(window.performKeyEquivalent(with: fixture.key("n", code: 45, modifiers: .command)))
        #expect(model.mainPage == .recording)
        #expect(!model.isRecording && model.workspaceLoadRequest == original)
        try await fixture.settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let title = try #require(fixture.views(sheet.contentView).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Название записи" })
        title.selectText(nil)
        let editor = try #require(sheet.firstResponder as? NSTextView)
        editor.insertText("Сохранить введённое название", replacementRange: NSRange(location: NSNotFound, length: 0))
        let request = model.workspaceLoadRequest
        #expect(window.performKeyEquivalent(with: fixture.key("n", code: 45, modifiers: .command)))
        #expect(model.mainPage == .recording && model.workspaceLoadRequest == request)
        #expect(window.attachedSheet === sheet && title.stringValue == "Сохранить введённое название")
        #expect(!FileManager.default.fileExists(atPath: model.outputDirectory.path))
    }

    @Test func commandFFocusesExistingSearchAndPreservesNarrowSelection() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let model = fixture.model, window = fixture.delegate.window!
        model.workspaceShowsList = false
        let selection = model.selectedHistoryURL, request = model.workspaceLoadRequest
        #expect(window.performKeyEquivalent(with: fixture.key("f", code: 3, modifiers: .command)))
        try await fixture.settle {
            model.workspaceSearchRequest == nil && fixture.searchField?.currentEditor() === window.firstResponder
                && window.firstResponder is NSTextView
        }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("синтетический запрос", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(window.performKeyEquivalent(with: fixture.key("а", code: 3, modifiers: .command)))
        try await fixture.settle {
            model.workspaceSearchRequest == nil && fixture.searchField?.currentEditor() === editor
                && editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count)
        }
        #expect(editor.string == "синтетический запрос")
        #expect(editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count))
        #expect(model.workspaceShowsList && model.selectedHistoryURL == selection)
        #expect(model.workspaceLoadRequest == request)
    }

    @Test func modalAndInactiveWorkspaceRejectCommands() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let model = fixture.model, window = fixture.delegate.window!
        for blocked in ["settings", "rename", "sheet", "hidden"] {
            model.workspace.externalModal = blocked == "rename"
            if blocked == "settings" { _ = model.presentSettings() }
            if blocked == "sheet" { model.mainPage = .recording }
            if blocked == "hidden" { window.orderOut(nil) }
            let page = model.mainPage, showsList = model.workspaceShowsList
            _ = window.performKeyEquivalent(with: fixture.key("n", code: 45, modifiers: .command))
            _ = window.performKeyEquivalent(with: fixture.key("f", code: 3, modifiers: .command))
            #expect(model.mainPage == page && model.workspaceShowsList == showsList)
            model.workspace.externalModal = false
            model.dismissSettings()
            model.mainPage = .history
        }
    }

    @Test func nativeMenuRechecksAdmissionAndDropsStaleSearchFocus() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let model = fixture.model
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        let menu = window.makeCommandMenu()
        #expect(Array(menu.items.prefix(2)).map(\.title) == ["Новая запись", "Найти запись"])
        #expect(Array(menu.items.prefix(2)).map(\.keyEquivalent) == ["n", "f"])
        let item = try #require(menu.items.first)
        #expect(window.validateMenuItem(item))
        window.isKeyboardTarget = { false }
        #expect(!window.validateMenuItem(item))
        _ = window.performKeyEquivalent(with: fixture.key("n", code: 45, modifiers: .command))
        #expect(model.mainPage == .history)
        window.isKeyboardTarget = { true }
        _ = window.performKeyEquivalent(with: fixture.key("f", code: 3, modifiers: .command))
        model.workspace.externalModal = true // Modal appears after dispatch, before the focus callback.
        #expect(!window.validateMenuItem(item))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(model.mainPage == .history)
        try await fixture.settle { model.workspaceSearchRequest == nil }
        #expect(model.workspaceSearchRequest == nil)
        model.workspace.externalModal = false
        window.makeFirstResponder(window.contentView)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!(window.firstResponder is NSTextView))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(model.mainPage == .recording)
    }

    @Test func settingsDisablesActualNativeSearch() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        window.dispatch(.findRecording)
        try await fixture.settle { fixture.model.workspaceSearchRequest == nil && fixture.searchField != nil }
        let field = try #require(fixture.searchField)
        fixture.delegate.showSettings()
        try await fixture.settle { !field.isEnabled }
        let enabled = field.isEnabled
        #expect(!enabled)
    }

    @Test func nativeSearchInputReachesBindingAndProductionSearch() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = ["alpha", "beta"].map {
            RecordingEntry(recording: root.appendingPathComponent($0 + ".m4a"), date: Date(), title: $0, phase: .completed)
        }
        var query = ""
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        window.contentView = NSHostingView(rootView: WorkspaceSearchField(
            text: Binding(get: { query }, set: { query = $0 }), model: fixture.model))
        window.dispatch(.findRecording)
        try await fixture.settle {
            fixture.model.workspaceSearchRequest == nil && fixture.searchField?.currentEditor() === window.firstResponder
                && window.firstResponder is NSTextView
        }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("alpha", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle { query == "alpha" }
        let search = RecordingSearch()
        await search.update(query: query, entries: entries)
        #expect(search.result.matches.map(\.effectiveTitle) == ["alpha"])
    }

    @Test func playbackKeysUseCurrentAudioFromBothNavigationSurfaces() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = fixture.delegate.window!
        let current = try #require(fixture.model.workspace.current)
        for pane in ["library", "transcript"] {
            let surface = try #require(fixture.views(window.contentView).first {
                $0.identifier?.rawValue == "workspace-\(pane)-navigation"
            }, "Missing production keyboard navigation surface")
            #expect(window.makeFirstResponder(surface))
            let selection = fixture.model.selectedHistoryURL
            #expect(window.performKeyEquivalent(with: fixture.key(" ", code: 49)))
            #expect(current.playbackState == .playing)
            _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49, repeatKey: true))
            #expect(current.playbackState == .playing)
            current.setPlaybackRate(1.5)
            _ = window.performKeyEquivalent(with: fixture.key("\u{f703}", code: 124))
            try await fixture.settle { current.playbackPosition == 5 }
            #expect(current.playbackState == .playing && current.playbackRate == 1.5)
            _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
            #expect(current.playbackState == .ready)
            await current.seekPlayback(to: 29)
            _ = window.performKeyEquivalent(with: fixture.key("\u{f703}", code: 124))
            try await fixture.settle { current.playbackPosition == 30 }
            await current.seekPlayback(to: 1)
            _ = window.performKeyEquivalent(with: fixture.key("\u{f702}", code: 123, repeatKey: true))
            try await fixture.settle { current.playbackPosition == 0 }
            #expect(current.playbackState == .ready && current.playbackRate == 1.5)
            #expect(fixture.model.selectedHistoryURL == selection)
        }
    }

    @Test func nativeInputAndStaleModalNeverDispatchPlayback() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        window.dispatch(.findRecording)
        try await fixture.settle { fixture.model.workspaceSearchRequest == nil && fixture.searchField?.currentEditor() != nil }
        let editor = try #require(fixture.searchField?.currentEditor() as? NSTextView)
        let current = try #require(fixture.model.workspace.current)
        editor.setMarkedText("compose", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        for code: UInt16 in [49, 123, 124] {
            _ = window.performKeyEquivalent(with: fixture.key(code == 49 ? " " : "\u{f703}", code: code))
            #expect(current.playbackState == .ready && current.playbackPosition == 0)
        }
        _ = window.performKeyEquivalent(with: fixture.key("\u{f703}", code: 124, modifiers: .option))
        #expect(current.playbackPosition == 0 && editor.hasMarkedText())
        editor.unmarkText()
        editor.selectAll(nil)
        editor.insertText("space stays here ", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "space stays here ")
        let button = NSButton(title: "Native", target: nil, action: nil)
        window.contentView?.addSubview(button)
        #expect(window.makeFirstResponder(button))
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        #expect(current.playbackState == .ready)
        let popup = NSPopUpButton(), slider = NSSlider()
        for control: NSControl in [popup, slider] {
            window.contentView?.addSubview(control)
            window.makeFirstResponder(control)
            _ = window.performKeyEquivalent(with: fixture.key("\u{f703}", code: 124))
            #expect(current.playbackPosition == 0)
        }
        let surface = try #require(fixture.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        window.makeFirstResponder(surface)
        _ = window.performKeyEquivalent(with: fixture.key("\u{f703}", code: 124))
        fixture.model.workspace.externalModal = true
        try await Task.sleep(for: .milliseconds(30))
        #expect(current.playbackPosition == 0)
        fixture.model.workspace.externalModal = false
        fixture.model.selectedHistoryURL = nil
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        #expect(current.playbackState == .ready)
    }

    @Test(arguments: ["unavailable", "failed"])
    func unavailableAudioDoesNotFallBackOrStartProcessing(kind: String) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(playback: kind)
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        let current = try #require(fixture.model.workspace.current)
        #expect(current.playbackState == (kind == "failed" ? .failed : .unavailable))
        let surface = try #require(fixture.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        window.makeFirstResponder(surface)
        for code: UInt16 in [49, 123, 124] { _ = window.performKeyEquivalent(with: fixture.key(" ", code: code)) }
        #expect(current.playbackPosition == 0 && !current.playbackEnabled)
        #expect(!fixture.model.isRecording && fixture.model.transcriptionJobs == 0)
        let items = window.makeCommandMenu().items
        #expect(items.map(\.title).suffix(3) == ["Воспроизвести/Пауза", "Назад на 5 секунд", "Вперёд на 5 секунд"])
        #expect(items.suffix(3).allSatisfy { !window.validateMenuItem($0) })
    }

    @Test func repeatedRelativeSeekKeepsAllStepsDuringAsyncTransport() async throws {
        let fixture = try KeyboardFixture(seekDelay: .milliseconds(80))
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = fixture.delegate.window!
        let current = try #require(fixture.model.workspace.current)
        let surface = try #require(fixture.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        window.makeFirstResponder(surface)
        for index in 0..<3 {
            _ = window.performKeyEquivalent(with: fixture.key("\u{f703}", code: 124, repeatKey: index > 0))
        }
        try await fixture.settle { current.playbackPosition == 15 }
        fixture.transport.onEvent?(.position(2))
        _ = window.performKeyEquivalent(with: fixture.key("\u{f703}", code: 124))
        try await fixture.settle { current.playbackPosition == 7 }
    }

    @Test func nativeMainMenuDispatchesPlaybackOnceAndRespectsIME() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let root = NSMenu(), container = NSMenuItem()
        let commands = window.makeCommandMenu()
        container.submenu = commands
        root.addItem(container)
        NSApp.mainMenu = root
        let surface = try #require(fixture.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        window.makeFirstResponder(surface)
        commands.update()
        #expect(commands.items.suffix(3).allSatisfy { $0.isEnabled })
        #expect(root.performKeyEquivalent(with: fixture.key(" ", code: 49)))
        #expect(fixture.transport.playCount == 1)
        #expect(root.performKeyEquivalent(with: fixture.key("\u{f703}", code: 124)))
        let current = try #require(fixture.model.workspace.current)
        try await fixture.settle { current.playbackPosition == 5 }
        #expect(fixture.transport.seekTargets == [5])
        commands.performActionForItem(at: 2)
        #expect(current.playbackState == .ready && fixture.transport.pauseCount == 1)
        window.dispatch(.findRecording)
        try await fixture.settle { fixture.model.workspaceSearchRequest == nil && fixture.searchField?.currentEditor() != nil }
        let editor = try #require(fixture.searchField?.currentEditor() as? NSTextView)
        editor.setMarkedText("compose", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        commands.update()
        #expect(commands.items.suffix(3).allSatisfy { !$0.isEnabled })
        _ = root.performKeyEquivalent(with: fixture.key(" ", code: 49))
        #expect(current.playbackState == .ready && fixture.transport.playCount == 1)
        editor.unmarkText()
        editor.selectAll(nil)
        editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        let windowConsumed = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        if !windowConsumed { window.sendEvent(fixture.key(" ", code: 49)) }
        #expect(editor.string == "a ")
    }

    @Test func delayedSeekCannotCarryTargetIntoNewSessionOrFailure() async throws {
        let fixture = try KeyboardFixture(seekDelay: .milliseconds(80))
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = fixture.delegate.window!
        let old = try #require(fixture.model.workspace.current)
        let surface = try #require(fixture.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        window.makeFirstResponder(surface)
        _ = window.performKeyEquivalent(with: fixture.key("\u{f703}", code: 124))
        try await fixture.settle { fixture.transport.seekTargets == [5] }
        fixture.model.workspace.closeCurrent()
        try await fixture.loadPlayableRecording(resultID: "res_new")
        let current = try #require(fixture.model.workspace.current)
        try await fixture.settle { fixture.transport.completedSeeks == 1 }
        #expect(old.playbackState == .closed && old.playbackSeekPosition == 0)
        #expect(current !== old && current.currentResultID == "res_new" && current.playbackPosition == 0)
        let newSurface = try #require(fixture.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        window.makeFirstResponder(newSurface)
        fixture.transport.seekSuccess = false
        _ = window.performKeyEquivalent(with: fixture.key("\u{f703}", code: 124))
        try await fixture.settle { current.playbackState == .failed }
        #expect(current.playbackSeekPosition == 0 && current.playbackPosition == 0)
    }

    @Test func twoDistinctSpacePressesCancelBufferedPlaybackStart() async throws {
        let fixture = try KeyboardFixture(bufferedStart: true)
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = fixture.delegate.window!
        let surface = try #require(fixture.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        window.makeFirstResponder(surface)
        for _ in 0..<2 { _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49)) }
        fixture.transport.releaseBuffer()
        #expect(fixture.model.workspace.current?.playbackState == .ready)
        #expect(fixture.transport.playCount == 1 && fixture.transport.pauseCount == 1)
        let current = try #require(fixture.model.workspace.current)
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        current.beginEditing()
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        fixture.transport.releaseBuffer()
        #expect(current.playbackState == .playing)
    }

    @Test func spaceCancelsResumeAfterTransportReturnsToWaiting() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = fixture.delegate.window!
        let surface = try #require(fixture.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        window.makeFirstResponder(surface)
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        fixture.transport.waitForBuffer()
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        fixture.transport.releaseBuffer()
        #expect(fixture.model.workspace.current?.playbackState == .ready)
        #expect(fixture.transport.playCount == 1 && fixture.transport.pauseCount == 1)
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        fixture.transport.onEvent?(.ended)
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        #expect(fixture.model.workspace.current?.playbackState == .playing)
    }

    @Test func seekingThroughEndMustNotDiscardBufferedPlayIntent() async throws {
        let fixture = try KeyboardFixture(bufferedStart: true)
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = fixture.delegate.window!
        let current = try #require(fixture.model.workspace.current)
        let surface = try #require(fixture.views(window.contentView).first { $0.identifier?.rawValue == "workspace-library-navigation" })
        window.makeFirstResponder(surface)
        await current.seekPlayback(to: 29)
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        await current.seekPlayback(to: 30)
        await current.seekPlayback(to: 25)
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        fixture.transport.releaseBuffer()
        #expect(current.playbackState == .ready)
        #expect(fixture.transport.playCount == 1 && fixture.transport.pauseCount == 1)
    }

    @Test func arrowsUseActualSearchResultsAndKeepNarrowLibrary() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let urls = try await fixture.addLegacyLibrary(["alpha", "beta", "gamma"])
        let model = fixture.model, window = fixture.delegate.window!
        let search = RecordingSearch()
        window.contentView = NSHostingView(rootView: RecordingHistoryView(model: model, history: model.history,
            workspace: model.workspace, showSettings: {}, search: search).defaultAppStorage(fixture.defaults))
        try await fixture.settle { fixture.navigation("library") != nil }
        let surface = try #require(fixture.navigation("library"))
        model.selectedHistoryURL = nil
        model.workspaceShowsList = true
        _ = model.requestWorkspaceOpen()
        window.makeFirstResponder(surface)
        for (code, expected): (UInt16, URL) in [(126, urls[0]), (125, urls[1]), (125, urls[2]), (125, urls[2]), (126, urls[1])] {
            _ = window.performKeyEquivalent(with: fixture.key("", code: code))
            #expect(model.selectedHistoryURL == expected && model.workspaceShowsList)
            #expect(window.firstResponder === surface)
        }
        _ = window.performKeyEquivalent(with: fixture.key("f", code: 3, modifiers: .command))
        try await fixture.settle { model.workspaceSearchRequest == nil && fixture.searchField?.currentEditor() != nil }
        let editor = try #require(fixture.searchField?.currentEditor() as? NSTextView)
        editor.insertText("gamma", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle { !search.loading && search.result.matches.map(\.id) == [urls[2]] }
        window.contentView?.layoutSubtreeIfNeeded()
        let before = model.selectedHistoryURL
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        #expect(model.selectedHistoryURL == before) // Search still owns its arrows.
        model.selectedHistoryURL = urls[0]
        window.makeFirstResponder(surface)
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        #expect(model.selectedHistoryURL == urls[2] && model.workspaceShowsList)
        _ = window.performKeyEquivalent(with: fixture.key("", code: 126))
        #expect(model.selectedHistoryURL == urls[2])
        fixture.searchField?.selectText(nil)
        editor.insertText("no matching entry", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle { !search.loading && search.result.matches.isEmpty }
        model.selectedHistoryURL = urls[0]
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(surface)
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        #expect(model.selectedHistoryURL == urls[0])
    }

    @Test func visibleNavigationOwnsInitialFocusAndNativeTabLoop() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.settle("Initial library focus") { fixture.delegate.window.firstResponder === fixture.navigation("library") }
        try await fixture.loadPlayableRecording()
        let window = fixture.delegate.window!
        let library = try #require(fixture.navigation("library")), transcript = try #require(fixture.navigation("transcript"))
        #expect(window.firstResponder === library)
        window.recalculateKeyViewLoop()
        window.sendEvent(fixture.key("\t", code: 48))
        #expect(window.firstResponder !== library)
        // Row actions must remain in the native key-view loop in both directions.
        let selection = fixture.model.selectedHistoryURL
        for _ in 0..<12 where window.firstResponder !== library {
            window.sendEvent(fixture.key("\t", code: 48, modifiers: .shift))
            await Task.yield()
        }
        #expect(window.firstResponder === library)
        #expect(fixture.model.selectedHistoryURL == selection)
        window.makeFirstResponder(transcript)
        fixture.model.workspaceShowsList = true
        window.setContentSize(NSSize(width: 640, height: 560))
        try await fixture.settle("Narrow hidden transcript returns focus to library") { !transcript.acceptsFirstResponder && window.firstResponder === fixture.navigation("library") }
        fixture.model.workspaceShowsList = false
        try await fixture.settle("Narrow detail receives focus") { window.firstResponder === fixture.navigation("transcript") }
        fixture.delegate.showSettings()
        fixture.model.dismissSettings()
        try await fixture.settle("Settings returns detail focus") { window.firstResponder === fixture.navigation("transcript") }
    }

    @Test(arguments: [false, true])
    func transcriptArrowsSeekAdjacentTurnsAndRevealTheirText(playing: Bool) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(longText: true, turnStarts: [1, 5, 10])
        let window = fixture.delegate.window!
        let current = try #require(fixture.model.workspace.current)
        let surface = try #require(fixture.navigation("transcript"))
        let scroll = try #require(surface.enclosingScrollView)
        #expect(window.makeFirstResponder(surface))
        current.setPlaybackRate(1.5)
        if playing { current.togglePlayback() }
        let state = current.playbackState, selection = fixture.model.selectedHistoryURL
        #expect(window.performKeyEquivalent(with: fixture.key("", code: 125)))
        try await fixture.settle("Down seeks to first turn, rather than scrolling one line") { current.playbackPosition == 1 }
        let firstY = scroll.contentView.bounds.origin.y
        #expect(window.performKeyEquivalent(with: fixture.key("", code: 125)))
        try await fixture.settle("Down seeks and reveals next turn beyond long text") {
            current.playbackPosition == 5 && scroll.contentView.bounds.origin.y > firstY + 100
        }
        #expect(window.performKeyEquivalent(with: fixture.key("", code: 126)))
        try await fixture.settle { current.playbackPosition == 1 }
        #expect(current.playbackState == state && current.playbackRate == 1.5)
        #expect(current.follow.isFollowing && window.firstResponder === surface)
        #expect(fixture.model.selectedHistoryURL == selection)
    }

    @Test func legacyTranscriptArrowsScrollActualViewportAndSuspendFollowOnly() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        do {
            let urls = try await fixture.addLegacyLibrary(["long"])
            let txt = urls[0].deletingPathExtension().appendingPathExtension("sources.transcript.txt")
            try String(repeating: "Синтетический длинный текст\n", count: 2000).write(to: txt, atomically: true, encoding: .utf8)
            fixture.model.selectedHistoryURL = urls[0]
            let request = try #require(fixture.model.requestWorkspaceOpen())
            #expect(await fixture.model.loadWorkspace(request))
            fixture.delegate.window.setContentSize(NSSize(width: 1100, height: 700))
            try await fixture.settle { fixture.navigation("transcript")?.enclosingScrollView != nil }
        }
        let window = fixture.delegate.window!
        let current = try #require(fixture.model.workspace.current)
        let surface = try #require(fixture.navigation("transcript"))
        let scroll = try #require(surface.enclosingScrollView, "Text navigation must belong to its actual scroll view")
        window.makeFirstResponder(surface)
        current.togglePlayback()
        current.setPlaybackRate(1.5)
        let before = scroll.contentView.bounds.origin.y
        let position = current.playbackPosition, selection = fixture.model.selectedHistoryURL
        let wasPlaying = current.playbackState
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { scroll.contentView.bounds.origin.y != before }
        #expect(!current.follow.isFollowing && current.playbackState == wasPlaying)
        #expect(current.playbackPosition == position && current.playbackRate == 1.5)
        #expect(fixture.model.selectedHistoryURL == selection)
        let down = scroll.contentView.bounds.origin.y
        _ = window.performKeyEquivalent(with: fixture.key("", code: 126))
        try await fixture.settle { scroll.contentView.bounds.origin.y != down }
    }

    @Test func turnNavigationUsesDisplayOrderAndExternalPlaybackPosition() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 1, 5, 10])
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        for index in current.rows.indices {
            #expect(window.performKeyEquivalent(with: fixture.key("", code: 125)))
            try await fixture.settle {
                current.highlightedTurnID == current.rows[index].id && current.playbackPosition == current.rows[index].start
            }
        }
        let count = fixture.transport.seekTargets.count
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        #expect(fixture.transport.seekTargets.count == count && current.highlightedTurnID == current.rows.last?.id)
        await current.seekPlayback(to: 1.2)
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { current.playbackPosition == 5 && current.highlightedTurnID == current.rows[2].id }
        window.sendEvent(fixture.key("", code: 125, type: .keyUp))
        current.togglePlayback()
        fixture.transport.onEvent?(.position(11))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 126))
        try await fixture.settle { current.playbackPosition == 5 }
        await current.seekPlayback(to: 0)
        _ = window.performKeyEquivalent(with: fixture.key("", code: 126))
        try await fixture.settle { current.highlightedTurnID == current.rows.first?.id && current.playbackPosition == 1 }
        let first = fixture.transport.seekTargets.count
        _ = window.performKeyEquivalent(with: fixture.key("", code: 126))
        #expect(fixture.transport.seekTargets.count == first)
    }

    @Test func rapidTurnNavigationAccumulatesWhileSeekIsPending() async throws {
        let fixture = try KeyboardFixture(seekDelay: .milliseconds(80))
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 5, 10])
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { fixture.transport.seekTargets.count == 1 }
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125, repeatKey: true))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125, repeatKey: true))
        try await fixture.settle {
            fixture.transport.completedSeeks == 2 && current.playbackPosition == 10
        }
        #expect(current.highlightedTurnID == current.rows.last?.id)
        #expect(fixture.transport.seekTargets == [1, 10])
    }

    @Test(arguments: [false, true])
    func heldTurnArrowProgressesAcrossQuantizedPlaybackCallbacks(playing: Bool) async throws {
        let fixture = try KeyboardFixture(seekDelay: .milliseconds(10))
        defer { fixture.close() }
        try await fixture.ready()
        let starts = (0..<80).map { Double($0) * 0.25 + 0.1001 }
        try await fixture.loadPlayableRecording(turnStarts: starts)
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        if playing { current.togglePlayback() }
        let state = current.playbackState
        for index in starts.indices {
            _ = window.performKeyEquivalent(with: fixture.key("", code: 125, repeatKey: index > 0))
            try await fixture.settle { fixture.transport.completedSeeks == index + 1 }
            try #require(fixture.transport.seekTargets.last == starts[index],
                         "Held Down repeated a prior turn at index \(index)")
            let actual = CMTime(seconds: starts[index], preferredTimescale: 600).seconds
            fixture.transport.onEvent?(.position(actual))
            #expect(current.playbackState == state)
        }
        #expect(fixture.transport.seekTargets == starts)
    }

    @Test(arguments: [0.1001, 0.1009])
    func heldTurnArrowKeepsEqualTimestampOrderWhileAudioAdvances(offset: Double) async throws {
        let fixture = try KeyboardFixture(seekDelay: .milliseconds(10))
        defer { fixture.close() }
        try await fixture.ready()
        let starts = (0..<80).map { Double($0 / 2) * 0.25 + offset }
        try await fixture.loadPlayableRecording(turnStarts: starts)
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        current.togglePlayback()
        for index in starts.indices {
            _ = window.performKeyEquivalent(with: fixture.key("", code: 125, repeatKey: index > 0))
            try await fixture.settle { fixture.transport.completedSeeks == index + 1 }
            try #require(fixture.transport.seekTargets.last == starts[index],
                         "Held Down skipped equal-timestamp turn \(index)")
            fixture.transport.onEvent?(.position(CMTime(seconds: starts[index], preferredTimescale: 600).seconds + 0.02))
            #expect(current.highlightedTurnID == current.rows[index].id)
        }
    }

    @Test(arguments: [0.1, 2.0])
    func arrowReleaseRestoresAutomaticPlaybackFocus(duration: Double) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 1.25, 1.5], turnDuration: duration)
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        current.togglePlayback()
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { current.playbackPosition == 1 }
        fixture.transport.onEvent?(.position(1.02))
        #expect(current.highlightedTurnID == current.rows[0].id)
        window.sendEvent(fixture.key("", code: 125, type: .keyUp))
        try await fixture.settle("Real keyUp returns navigation ownership to playback") { current.turnNavigation == nil }
        fixture.transport.onEvent?(.position(min(1 + duration, 1.25)))
        #expect(current.turnNavigation == nil)
        #expect(current.highlightedTurnID == (duration < 0.25 ? nil : current.rows[1].id))
        #expect(current.follow.isFollowing && current.playbackState == .playing)
    }

    @Test func heldTurnArrowCanVisitZeroLengthTurnsAndReturnToFollow() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let starts = [1.0009, 1.0009, 2.0009]
        try await fixture.loadPlayableRecording(turnStarts: starts, turnDuration: 0)
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        current.togglePlayback()
        for index in starts.indices {
            _ = window.performKeyEquivalent(with: fixture.key("", code: 125, repeatKey: index > 0))
            try await fixture.settle { fixture.transport.seekTargets.count == index + 1 }
            fixture.transport.onEvent?(.position(CMTime(seconds: starts[index], preferredTimescale: 600).seconds))
            #expect(current.highlightedTurnID == current.rows[index].id)
        }
        fixture.transport.onEvent?(.ended)
        window.sendEvent(fixture.key("", code: 125, type: .keyUp))
        #expect(current.playbackState == .ready && current.playbackPosition == current.playbackDuration)
        current.returnToPlayback()
        #expect(current.turnNavigation == nil && current.highlightedTurnID == nil)
    }

    @Test func loadingTextTurnDoesNotBlockFollowWhenAudioBecomesReady() async throws {
        let fixture = try KeyboardFixture(holdPreparation: true)
        defer { fixture.transport.releasePreparation(); fixture.close() }
        try await fixture.ready()
        let window = fixture.delegate.window!
        window.setContentSize(NSSize(width: 1100, height: 700))
        let loading = Task { try await fixture.loadPlayableRecording(longText: true, turnStarts: [1, 5, 10]) }
        defer { loading.cancel() }
        try await fixture.settle {
            !fixture.model.workspace.loading && fixture.model.workspace.current?.playbackState == .loading
                && fixture.navigation("transcript")?.acceptsFirstResponder == true
        }
        let current = try #require(fixture.model.workspace.current)
        let surface = try #require(fixture.navigation("transcript"))
        let clip = try #require(surface.enclosingScrollView?.contentView)
        #expect(window.makeFirstResponder(surface))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { clip.bounds.origin.y > 100 }
        let before = clip.bounds.origin.y
        #expect(current.highlightedTurnID == current.rows[0].id && fixture.transport.seekTargets.isEmpty)
        window.sendEvent(fixture.key("", code: 125, type: .keyUp))
        fixture.transport.releasePreparation()
        try await loading.value
        #expect(window.makeFirstResponder(surface))
        _ = window.performKeyEquivalent(with: fixture.key(" ", code: 49))
        fixture.transport.onEvent?(.position(5.1))
        #expect(current.follow.targetID == current.rows[1].id && current.playbackState == .playing)
        #expect(current.turnNavigation == nil && current.highlightedTurnID == current.rows[1].id)
        try await fixture.settle("Ready playback resumes actual turn reveal after loading text navigation") {
            clip.bounds.origin.y > before + 100
        }
        #expect(fixture.transport.seekTargets.isEmpty)
    }

    @Test func quantizedCloseStartsRemainAdjacentAfterPausedTap() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1.0009, 1.0010, 1.5])
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        let first = try #require(current.requestTurnNavigation(by: 1))
        await current.performTurnNavigation(first)
        #expect(current.playbackPosition == 1.0009)
        window.sendEvent(fixture.key("", code: 125, type: .keyUp))
        fixture.transport.onEvent?(.position(CMTime(seconds: 1.0009, preferredTimescale: 600).seconds))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { fixture.transport.completedSeeks == 2 }
        #expect(fixture.transport.seekTargets.last == 1.0010 && current.highlightedTurnID == current.rows[1].id)
    }

    @Test func heldLoadingNavigationKeepsAnchorWhenAudioBecomesReady() async throws {
        let fixture = try KeyboardFixture(holdPreparation: true)
        defer { fixture.transport.releasePreparation(); fixture.close() }
        try await fixture.ready()
        let window = fixture.delegate.window!
        window.setContentSize(NSSize(width: 1100, height: 700))
        let loading = Task { try await fixture.loadPlayableRecording(turnStarts: [1, 5, 10]) }
        defer { loading.cancel() }
        try await fixture.settle {
            !fixture.model.workspace.loading && fixture.model.workspace.current?.playbackState == .loading
                && fixture.navigation("transcript")?.acceptsFirstResponder == true
        }
        let current = try #require(fixture.model.workspace.current)
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125, repeatKey: true))
        #expect(current.highlightedTurnID == current.rows[1].id && fixture.transport.seekTargets.isEmpty)
        fixture.transport.releasePreparation()
        try await loading.value
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125, repeatKey: true))
        try await fixture.settle { fixture.transport.completedSeeks == 1 }
        #expect(fixture.transport.seekTargets == [10] && current.highlightedTurnID == current.rows[2].id)
    }

    @Test func readinessAndFirstHeldDownInSameActorTurnKeepTextOnlyAnchor() async throws {
        let fixture = try KeyboardFixture(holdPreparation: true)
        defer { fixture.transport.releasePreparation(); fixture.close() }
        try await fixture.ready()
        let window = fixture.delegate.window!
        window.setContentSize(NSSize(width: 1100, height: 700))
        let loading = Task { try await fixture.loadPlayableRecording(turnStarts: [1, 5, 10]) }
        defer { loading.cancel() }
        try await fixture.settle {
            !fixture.model.workspace.loading && fixture.model.workspace.current?.playbackState == .loading
                && fixture.navigation("transcript")?.acceptsFirstResponder == true
        }
        let current = try #require(fixture.model.workspace.current)
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        fixture.transport.releasePreparation()
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        #expect(current.highlightedTurnID == current.rows[0].id && fixture.transport.seekTargets.isEmpty)
        try await loading.value
        #expect(current.playbackState == .ready && fixture.transport.seekTargets.isEmpty)
        #expect(current.highlightedTurnID == current.rows[0].id)
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125, repeatKey: true))
        try await fixture.settle { fixture.transport.completedSeeks == 1 }
        #expect(fixture.transport.seekTargets == [5] && current.highlightedTurnID == current.rows[1].id)
    }

    @Test(arguments: ["keyUp", "control", "inactive", "settings", "editor"])
    func heldTurnCursorReturnsOwnershipAtNativeInputBoundary(boundary: String) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 5, 10])
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        current.togglePlayback()
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { current.playbackPosition == 1 }
        fixture.transport.onEvent?(.position(5.1))
        #expect(current.highlightedTurnID == current.rows[0].id)
        switch boundary {
        case "keyUp": window.sendEvent(fixture.key("", code: 125, type: .keyUp))
        case "control": fixture.searchField?.selectText(nil)
        case "inactive": window.resignKey()
        case "settings": #expect(fixture.model.presentSettings())
        default: current.openTextEditing(for: current.rows[0].id)
        }
        try await fixture.settle { current.turnNavigation == nil && current.highlightedTurnID == current.rows[1].id }
        #expect(fixture.transport.seekTargets == [1])
    }

    @Test func heldUpVisitsEveryTurnDespiteForwardPositionCallbacks() async throws {
        let fixture = try KeyboardFixture(seekDelay: .milliseconds(10))
        defer { fixture.close() }
        try await fixture.ready()
        let starts = (0..<40).map { Double($0) * 0.25 + 0.1009 }
        try await fixture.loadPlayableRecording(turnStarts: starts)
        let current = try #require(fixture.model.workspace.current)
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        window.navigateTranscriptTurn(to: current.rows.last!.id)
        try await fixture.settle { current.playbackPosition == starts.last }
        current.togglePlayback()
        for (offset, index) in starts.indices.dropLast().reversed().enumerated() {
            _ = window.performKeyEquivalent(with: fixture.key("", code: 126, repeatKey: offset > 0))
            try await fixture.settle { fixture.transport.completedSeeks == offset + 2 }
            fixture.transport.onEvent?(.position(CMTime(seconds: starts[index], preferredTimescale: 600).seconds + 0.02))
            try #require(fixture.transport.seekTargets.last == starts[index] && current.highlightedTurnID == current.rows[index].id)
        }
    }

    @Test func playbackCallbacksCannotDiscardQueuedTurnNavigation() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 5])
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        fixture.transport.onEvent?(.position(0))
        current.setPlaybackRate(1.5)
        try await fixture.settle("Position/rate callback before Task must not discard pending turn") { current.playbackPosition == 1 }
        #expect(fixture.model.presentSettings())
        let selected = current.highlightedTurnID
        await current.seekPlayback(to: 5)
        #expect(current.highlightedTurnID == selected && current.playbackPosition == 1)
    }

    @Test(arguments: ["settings", "modal", "control", "selection", "closed", "inactive"])
    func deferredTurnNavigationRechecksAdmission(blocker: String) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 5])
        let current = try #require(fixture.model.workspace.current)
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        switch blocker {
        case "settings": #expect(fixture.model.presentSettings())
        case "modal": fixture.model.workspace.externalModal = true
        case "control": fixture.searchField?.selectText(nil)
        case "selection": fixture.model.selectedHistoryURL = nil
        case "closed": current.close()
        default: window.isKeyboardTarget = { false }
        }
        try await fixture.settle { current.turnNavigation == nil }
        #expect(fixture.transport.seekTargets.isEmpty && current.playbackPosition == 0)
    }

    @Test(arguments: ["failure", "closed", "replacement"])
    func pendingTurnSeekCannotRestoreOldNavigation(kind: String) async throws {
        let fixture = try KeyboardFixture(seekDelay: .milliseconds(80))
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 5])
        let old = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { fixture.transport.seekTargets == [1] }
        switch kind {
        case "failure": fixture.transport.seekSuccess = false
        case "closed": old.close()
        default:
            fixture.model.workspace.closeCurrent()
            try await fixture.loadPlayableRecording(resultID: "res_turn_replacement", turnStarts: [2, 6])
        }
        try await fixture.settle { fixture.transport.completedSeeks == 1 && old.turnNavigation == nil }
        #expect(old.playbackPosition == 0)
        if kind == "replacement" {
            let current = try #require(fixture.model.workspace.current)
            #expect(current !== old && current.playbackPosition == 0 && current.turnNavigation == nil)
        }
    }

    @Test(arguments: ["settings", "external", "form", "text", "speaker", "sheet"])
    func turnReviewProbeQueuedCommandCannotSurviveSettingsBounce(modal: String) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 5])
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        switch modal {
        case "settings":
            #expect(fixture.model.presentSettings())
            fixture.model.dismissSettings()
        case "external":
            fixture.model.workspace.externalModal = true
            fixture.model.workspace.externalModal = false
        case "form":
            fixture.model.mainPage = .recording
            fixture.model.mainPage = .history
        case "text":
            current.openTextEditing(for: current.rows[0].id)
            current.cancelTextDraft()
        case "speaker":
            current.openSpeakerAssignment(for: current.rows[0].id)
            current.cancelDraft()
        default:
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            window.beginSheet(sheet, completionHandler: nil)
            window.endSheet(sheet)
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.transport.seekTargets.isEmpty && current.playbackPosition == 0)
        #expect(current.turnNavigation == nil)
    }

    @Test func turnReviewProbeInFlightSeekThenSettings() async throws {
        let fixture = try KeyboardFixture(seekDelay: .milliseconds(80))
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 5])
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { fixture.transport.seekTargets == [1] }
        let selection = fixture.model.selectedHistoryURL, state = current.playbackState
        #expect(fixture.model.presentSettings())
        try await fixture.settle { fixture.transport.completedSeeks == 1 }
        #expect(current.playbackPosition == 1 && fixture.model.selectedHistoryURL == selection)
        #expect(current.playbackState == state)
        fixture.model.dismissSettings()
        await Task.yield()
        #expect(fixture.transport.seekTargets == [1])
    }

    @Test func turnReviewProbeMixedSeekOrderPreservesLastTurn() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 10, 20])
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 124))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle("Last Down wins over earlier queued Right") {
            current.playbackPosition == 10 && current.highlightedTurnID == current.rows[1].id
        }
    }

    @Test func manualScrollAndReturnToFollowReleaseTurnCursor() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(turnStarts: [1, 5, 10])
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        let surface = try #require(fixture.navigation("transcript"))
        #expect(window.makeFirstResponder(surface))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { current.playbackPosition == 1 }
        current.userScrollPhaseChanged(.interacting)
        #expect(!current.follow.isFollowing && current.turnNavigation == nil)
        let request = current.follow.request
        current.setFollow(true)
        #expect(current.turnNavigation == nil && current.follow.isFollowing)
        #expect(current.follow.request > request && current.follow.targetID == current.rows[0].id)
        #expect(current.playbackPosition == 1 && current.playbackState == .ready)
    }

    @Test(arguments: ["unavailable", "failed", "empty"])
    func turnNavigationWithoutAudioOrRowsIsSafe(kind: String) async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording(playback: kind == "empty" ? "ready" : kind,
                                                turnStarts: kind == "empty" ? [] : [1, 5])
        let current = try #require(fixture.model.workspace.current)
        let window = fixture.delegate.window!
        #expect(window.makeFirstResponder(fixture.navigation("transcript")))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        #expect(current.highlightedTurnID == current.rows.last?.id)
        #expect(fixture.transport.seekTargets.isEmpty && fixture.transport.playCount == 0)
    }

    @Test func searchQueryChangesDoNotPinCurrentOrFirstResult() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let urls = try await fixture.addLegacyLibrary(["stream", "standup", "beta"])
        try "Synthetic standup discussion".write(to: urls[0].deletingPathExtension().appendingPathExtension("sources.transcript.txt"), atomically: true, encoding: .utf8)
        let search = RecordingSearch()
        let window = fixture.delegate.window!
        window.contentView = NSHostingView(rootView: RecordingHistoryView(model: fixture.model, history: fixture.model.history,
            workspace: fixture.model.workspace, showSettings: {}, search: search).defaultAppStorage(fixture.defaults))
        fixture.model.selectedHistoryURL = urls[0]
        try await fixture.settle { fixture.searchField != nil }
        for (query, expected) in [("standup", [urls[0], urls[1]]), ("beta", [urls[2]]), ("no_synthetic_match_9385", [])] {
            fixture.searchField?.selectText(nil)
            let editor = try #require(fixture.searchField?.currentEditor() as? NSTextView)
            editor.insertText(query, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await fixture.settle { !search.loading && search.result.matches.map(\.id) == expected }
            #expect(fixture.searchField?.stringValue == query)
            #expect(fixture.model.selectedHistoryURL == urls[0])
        }
    }

    @Test func selectedLibraryCardScrollsIntoViewport() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let urls = try await fixture.addLegacyLibrary((0..<40).map { "entry\($0)" })
        let window = fixture.delegate.window!
        try await fixture.settle { fixture.views(window.contentView).contains { $0 is NSScrollView } }
        let scroll = try #require(fixture.views(window.contentView).compactMap { $0 as? NSScrollView }.first)
        fixture.model.selectedHistoryURL = urls[39]
        let surface = try #require(fixture.navigation("library"))
        window.makeFirstResponder(surface)
        _ = window.performKeyEquivalent(with: fixture.key("", code: 126))
        #expect(fixture.model.selectedHistoryURL == urls[38])
        try await fixture.settle { scroll.contentView.bounds.origin.y > 0 }
    }

    @Test func hidingNarrowLibraryReleasesItsNativeSearchEditor() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        window.setContentSize(NSSize(width: 640, height: 560))
        fixture.model.workspaceShowsList = true
        window.dispatch(.findRecording)
        try await fixture.settle { fixture.model.workspaceSearchRequest == nil && fixture.searchField?.currentEditor() != nil }
        fixture.model.workspaceShowsList = false
        try await fixture.settle("Hidden search editor releases navigation to visible transcript") {
            window.firstResponder === fixture.navigation("transcript")
        }
    }

    @Test func wideSearchRevealPreservesCurrentThenReturnsToCardLayout() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.loadPlayableRecording()
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        let current = try #require(fixture.model.workspace.current)
        fixture.model.workspaceShowsList = false
        window.dispatch(.findRecording)
        try await fixture.settle { fixture.model.workspaceSearchRequest == nil && fixture.searchField?.currentEditor() != nil }
        #expect(fixture.model.workspaceShowsList && fixture.model.workspace.current === current)
        fixture.model.workspaceShowsList = false
        #expect(fixture.model.workspace.current === current && fixture.navigation("library") != nil)
    }

    @Test func lateLibraryOpensCannotReplaceFinalKeyboardSelection() async throws {
        let gate = KeyboardOpenGate()
        defer { Task { await gate.release() } }
        let fixture = try KeyboardFixture(isProcessing: { url in await gate.wait(url); return false })
        defer { fixture.close() }
        try await fixture.ready()
        let urls = try await fixture.addLegacyLibrary(["a", "b", "c"])
        await gate.hold(Array(urls.prefix(2)))
        fixture.model.selectedHistoryURL = urls[0]
        _ = fixture.model.requestWorkspaceOpen()
        try await fixture.observe { await gate.entered(urls[0]) }
        let surface = try #require(fixture.navigation("library"))
        let window = fixture.delegate.window!
        window.makeFirstResponder(surface)
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.observe { await gate.entered(urls[1]) }
        _ = window.performKeyEquivalent(with: fixture.key("", code: 125))
        try await fixture.settle { fixture.model.workspace.current?.state.id == urls[2] }
        await gate.release()
        try await fixture.observe { await gate.finished == 2 }
        await Task.yield()
        #expect(fixture.model.selectedHistoryURL == urls[2] && fixture.model.workspace.current?.state.id == urls[2])
        #expect(window.firstResponder === surface && fixture.model.workspaceShowsList)
    }

}

@_cdecl("MeetingKeyboardUATStart") @MainActor
func meetingKeyboardUATStart() {
    NSApp.delegate = KeyboardNativeHost.delegate
    Task { @MainActor in
        do { try await KeyboardNativeHost.start() }
        catch { print("Native keyboard host failed: \(error)"); NSApp.stop(nil) }
    }
}

@_cdecl("MeetingKeyboardUATStop") @MainActor
func meetingKeyboardUATStop() { KeyboardNativeHost.stop() }

@MainActor private enum KeyboardNativeHost {
    static let delegate = KeyboardUATDelegate()
    static var fixture: KeyboardFixture?
    static var deadline: Timer?
    static var stateProbe: Timer?
    static var lastState: Data?

    static func start() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["KEYBOARD_UAT_ROOT"])
        let fixture = try KeyboardFixture()
        self.fixture = fixture
        try await fixture.ready()
        let library = try await fixture.addLegacyLibrary(["stream", "standup", "beta", "gamma"])
        try "Synthetic standup discussion".write(to: library[0].deletingPathExtension().appendingPathExtension("sources.transcript.txt"), atomically: true, encoding: .utf8)
        try await fixture.loadPlayableRecording(longText: true, turnStarts: [1, 5, 10])
        let window = try #require(fixture.delegate.window as? WorkspaceWindow)
        let menu = NSMenu(), app = NSMenuItem(), applicationMenu = NSMenu(title: "Keyboard UAT")
        let finish = NSMenuItem(title: "Завершить проверку", action: #selector(NSApplication.stop(_:)), keyEquivalent: "q")
        finish.target = NSApp
        applicationMenu.addItem(finish)
        app.submenu = applicationMenu
        menu.addItem(app)
        NSApp.mainMenu = menu
        fixture.delegate.installWorkspaceCommands()
        window.title = "Meeting Companion — keyboard UAT (synthetic)"
        window.isKeyboardTarget = { [weak window] in NSApp.isActive && window?.isKeyWindow == true }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
            "syntheticRecordings": fixture.model.outputDirectory.path], options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("host-ready.json"))
        deadline = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { _ in
            MainActor.assumeIsolated {
                NSApp.stop(nil)
                if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(wake, atStart: true)
                }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        stateProbe = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { recordState(in: directory) }
        }
    }

    static func recordState(in directory: URL) {
        guard let fixture, let window = fixture.delegate.window as? WorkspaceWindow else { return }
        func responder(_ value: NSResponder?) -> String {
            guard let value else { return "nil" }
            return String(describing: type(of: value)) + ":" + ((value as? NSView)?.identifier?.rawValue ?? "")
        }
        let event = NSApp.currentEvent
        let isKeyEvent = event?.type == .keyDown || event?.type == .keyUp
        let transcript = fixture.navigation("transcript") as? WorkspaceNavigationView
        let state: [String: Any] = [
            "active": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
            "workspaceWindow": window.windowNumber, "workspaceIsKey": window.isKeyWindow,
            "firstResponder": responder(window.firstResponder),
            "sheetResponder": responder(window.attachedSheet?.firstResponder),
            "sheetWindow": window.attachedSheet?.windowNumber ?? -1,
            "admitsNavigation": window.admitsNavigationKeys, "settings": fixture.model.settingsPresented,
            "page": fixture.model.mainPage.rawValue, "showsList": fixture.model.workspaceShowsList,
            "libraryUsable": (fixture.navigation("library") as? WorkspaceNavigationView)?.isUsable ?? false,
            "transcriptUsable": transcript?.isUsable ?? false,
            "selection": fixture.model.selectedHistoryURL?.lastPathComponent ?? "",
            "playback": String(describing: fixture.model.workspace.current?.playbackState),
            "position": fixture.model.workspace.current?.playbackPosition ?? -1,
            "follow": fixture.model.workspace.current?.follow.isFollowing ?? false,
            "scrollY": transcript?.enclosingScrollView?.contentView.bounds.origin.y ?? -1,
            "eventType": event?.type.rawValue ?? 0, "keyCode": isKeyEvent ? Int(event!.keyCode) : -1
        ]
        do {
            let bytes = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .prettyPrinted])
            guard bytes != lastState else { return }
            try bytes.write(to: directory.appendingPathComponent("native-state.json"), options: .atomic)
            lastState = bytes
        } catch {
            print("Native UAT state probe failed: \(error)")
            stateProbe?.invalidate()
        }
    }

    static func stop() {
        deadline?.invalidate(); stateProbe?.invalidate()
        fixture?.close(); fixture = nil; lastState = nil
    }
}

@MainActor private final class KeyboardUATDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private actor KeyboardOpenGate {
    private var blocked = Set<URL>()
    private var visits = Set<URL>()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var finished = 0
    func hold(_ urls: [URL]) { blocked = Set(urls) }
    func entered(_ url: URL) -> Bool { visits.contains(url) }
    func wait(_ url: URL) async {
        visits.insert(url)
        if blocked.contains(url) {
            await withCheckedContinuation { waiting.append($0) }
            finished += 1
        }
    }
    func release() { blocked = []; let pending = waiting; waiting = []; pending.forEach { $0.resume() } }
}

@MainActor private final class KeyboardTransport: TranscriptPlaybackTransport {
    let seekDelay: Duration
    let bufferedStart: Bool
    var playCount = 0, pauseCount = 0, completedSeeks = 0
    var seekTargets: [Double] = []
    var seekSuccess = true
    private var holdPreparation: Bool
    private var preparation: CheckedContinuation<Void, Never>?
    private var pendingStart = false
    init(seekDelay: Duration = .zero, bufferedStart: Bool = false, holdPreparation: Bool = false) {
        self.seekDelay = seekDelay; self.bufferedStart = bufferedStart; self.holdPreparation = holdPreparation
    }
    var onEvent: (@MainActor @Sendable (TranscriptPlaybackEvent) -> Void)?
    func prepare(url: URL) async throws -> Double {
        if holdPreparation { await withCheckedContinuation { preparation = $0 } }
        return 30
    }
    func releasePreparation() {
        holdPreparation = false
        preparation?.resume(); preparation = nil
    }
    func play() { playCount += 1; pendingStart = true; if !bufferedStart { releaseBuffer() } }
    func pause() { pauseCount += 1; pendingStart = false; onEvent?(.playing(false)) }
    func releaseBuffer() { if pendingStart { pendingStart = false; onEvent?(.playing(true)) } }
    func waitForBuffer() { pendingStart = true; onEvent?(.playing(false)) }
    func seek(to seconds: Double) async -> Bool {
        seekTargets.append(seconds)
        if seekDelay > .zero { try? await Task.sleep(for: seekDelay) }
        completedSeeks += 1
        return seekSuccess
    }
    func stop() { pendingStart = false }
}

@MainActor private final class KeyboardFixture {
    let suite = "workspace-keyboard-" + UUID().uuidString
    let defaults: UserDefaults
    let model: RecorderViewModel
    let delegate: RecorderAppDelegate
    let transport: KeyboardTransport
    init(seekDelay: Duration = .zero, bufferedStart: Bool = false, holdPreparation: Bool = false,
         isProcessing: @escaping @Sendable (URL) async -> Bool = { _ in false }) throws {
        _ = NSApplication.shared
        defaults = try #require(UserDefaults(suiteName: suite))
        let transport = KeyboardTransport(seekDelay: seekDelay, bufferedStart: bufferedStart, holdPreparation: holdPreparation)
        self.transport = transport
        model = isolatedRecorderModel(workspace: TranscriptReviewWindowManager(isProcessing: isProcessing, transportFactory: { transport }), defaults: defaults)
        model.setAttachedForTesting(session: true, processing: true)
        delegate = RecorderAppDelegate(model: model)
        delegate.setUpPresentation()
        // The CLI test runner has no application event loop; responder routing stays native.
        (delegate.window as? WorkspaceWindow)?.isKeyboardTarget = { true }
        delegate.window.setContentSize(NSSize(width: 640, height: 560))
        delegate.window.makeKeyAndOrderFront(nil)
        delegate.window.contentView?.layoutSubtreeIfNeeded()
    }
    func ready() async throws {
        try await Task.sleep(for: .milliseconds(30))
        delegate.window.becomeKey() // Drive the production host entrypoint without activating the CLI runner.
        try #require(model.canStartRecording)
    }
    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false, type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: delegate.window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code)!
    }
    func pressEscape(in target: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: target.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(event)
    }
    func views(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views($0) }
    }
    var searchField: NSTextField? {
        views(delegate.window.contentView).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-library-search" }
    }
    func navigation(_ pane: String) -> NSView? {
        views(delegate.window.contentView).first { $0.identifier?.rawValue == "workspace-\(pane)-navigation" }
    }
    func settle(_ label: String = "Native responder outcome did not settle", _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = predicate()
        try #require(satisfied, "\(label)")
    }
    func observe(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = await predicate()
        try #require(satisfied, "Native async outcome did not settle")
    }
    func addLegacyLibrary(_ names: [String]) async throws -> [URL] {
        var urls: [URL] = []
        for (index, name) in names.enumerated() {
            let folder = model.outputDirectory.appendingPathComponent("meeting_" + name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("meeting_\(name).m4a")
            try Data().write(to: url)
            try "Synthetic text \(name)".write(to: folder.appendingPathComponent("meeting_\(name).sources.transcript.txt"), atomically: true, encoding: .utf8)
            var entry = RecordingEntry.load(recording: url)
            entry.date = Date(timeIntervalSince1970: Double(names.count - index) * 86400)
            await model.history.put(entry, persist: false)
            urls.append(url)
        }
        return urls
    }
    func loadPlayableRecording(playback: String = "ready", resultID: String = "res_valid_parakeet_off", longText: Bool = false, turnStarts: [Double]? = nil, turnDuration: Double = 0.4) async throws {
        let root = model.outputDirectory.appendingPathComponent("meeting_keyboard")
        let result = root.appendingPathComponent("raw/transcripts/" + resultID)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_parakeet_off.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        json["resultID"] = resultID
        json["playback"] = ["status": "ready", "mixPath": "raw/transcripts/\(resultID)/mix.m4a"]
        if let turnStarts {
            let originalWords = try #require(json["words"] as? [[String: Any]])
            let originalTurns = try #require(json["turns"] as? [[String: Any]])
            var words: [[String: Any]] = [], baseline: [[String: Any]] = [], turns: [[String: Any]] = []
            for (index, start) in turnStarts.enumerated() {
                var word = originalWords[index.isMultiple(of: 2) ? 0 : 2]
                word["id"] = "w_\(index)"; word["start"] = start; word["end"] = start + turnDuration
                word["text"] = "Synthetic turn \(index)"
                words.append(word)
                word["id"] = "bw_\(index)"; baseline.append(word)
                var turn = originalTurns[index % 2]
                turn["id"] = "turn_\(index)"; turn["start"] = start; turn["end"] = start + turnDuration
                turn["wordIDs"] = ["w_\(index)"]
                turns.append(turn)
            }
            json["words"] = words; json["baselineWords"] = baseline; json["turns"] = turns
        }
        if longText {
            for key in ["words", "baselineWords"] {
                var words = try #require(json[key] as? [[String: Any]])
                words[0]["text"] = String(repeating: "Синтетический длинный текст ", count: 2000)
                json[key] = words
            }
        }
        if playback == "unavailable" {
            json["playback"] = ["status": "unavailable", "mixPath": NSNull()]
            json["warnings"] = [["code": "playback-unavailable", "sourceID": NSNull(), "message": "Synthetic unavailable audio"] as [String: Any]]
        }
        try JSONSerialization.data(withJSONObject: json).write(to: result.appendingPathComponent("result.json"))
        _ = try TranscriptDocument.load(from: result.appendingPathComponent("result.json"), recordingDirectory: root)
        if playback != "failed" { try Data([0]).write(to: result.appendingPathComponent("mix.m4a")) }
        let recording = root.appendingPathComponent("meeting_keyboard.m4a")
        try Data().write(to: recording)
        await model.history.put(RecordingEntry.load(recording: recording), persist: false)
        model.selectedHistoryURL = recording
        let request = try #require(model.requestWorkspaceOpen())
        #expect(await model.loadWorkspace(request))
        try await settle {
            guard let state = model.workspace.current?.playbackState else { return false }
            return state == .ready || state == .unavailable || state == .failed
        }
        delegate.window.setContentSize(NSSize(width: 1100, height: 700))
        try await Task.sleep(for: .milliseconds(50))
    }
    func close() {
        model.workspace.externalModal = false
        model.dismissSettings()
        model.mainPage = .history
        _ = model.admitWindowClose(isWorkspace: true)
        delegate.window.orderOut(nil)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: model.outputDirectory)
    }
}
