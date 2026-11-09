import AppKit
import SwiftUI
import QuickLook
import MeetingCompanionCore
import MeetingCompanionApplication
import UniformTypeIdentifiers

struct RecorderWorkspaceView: View {
    @ObservedObject var model: RecorderViewModel
    let showSettings: () -> Void

    var body: some View {
        RecordingHistoryView(model: model, history: model.history, workspace: model.workspace, showSettings: showSettings)
            .disabled(model.settingsPresented || model.trashOwnsInput)
            .allowsHitTesting(!model.settingsPresented && !model.trashOwnsInput)
            .accessibilityHidden(model.settingsPresented || model.trashOwnsInput)
            .overlay { if model.settingsPresented && model.mainPage != .recording { WorkspaceSettingsOverlay(model: model) } }
            .overlay { if model.recordingTrash != nil { RecordingTrashOverlay(model: model) } }
            .task(id: model.trashCompletion?.id) {
                guard model.history.notice != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { model.history.clearNotice() }
            }
            .sheet(isPresented: Binding(get: { model.mainPage == .recording }, set: { if !$0 { model.mainPage = .history } })) {
                    FullRecorderView(viewModel: model, showSettings: showSettings)
                .background(ODColors.surface)
            }
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

// Native tab stops share the workspace's AppKit key-view loop.
private struct RecordingRowButton: NSViewRepresentable {
    let label: String
    let help: String
    var focusRequest: UUID? = nil
    let onFocus: (Bool) -> Void
    var onVerticalKey: ((Int) -> Void)? = nil
    var onDelete: (@MainActor () async -> Void)? = nil
    let action: () -> Void

    final class Button: NSButton {
        var onFocus: ((Bool) -> Void)?
        var activate: (() -> Void)?
        var verticalAction: ((Int) -> Void)?
        var deleteAction: (@MainActor () async -> Void)?
        var focusRequest: UUID?
        private var appliedFocusRequest: UUID?
        override var acceptsFirstResponder: Bool { isEnabled }
        override var canBecomeKeyView: Bool {
            isEnabled && !isHiddenOrHasHiddenAncestor && bounds.width > 0 && bounds.height > 0
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 125 || event.keyCode == 126,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                if canBecomeKeyView, let window = window as? WorkspaceWindow,
                   window.admitsNavigationKeys, window.firstResponder === self {
                    verticalAction?(event.keyCode == 125 ? 1 : -1)
                }
                return
            }
            if event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                if !event.isARepeat, let window = window as? WorkspaceWindow,
                   window.admitsNavigationKeys, window.firstResponder === self { invoke() }
                return
            }
            if event.keyCode == 51 || event.keyCode == 117,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                if !event.isARepeat {
                    Task { [weak self] in
                        guard let self, self.isEnabled, let window = self.window as? WorkspaceWindow,
                              window.admitsNavigationKeys, window.firstResponder === self else { return }
                        await self.deleteAction?()
                    }
                }
                return
            }
            if event.keyCode == 48, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
                return
            }
            super.keyDown(with: event)
        }
        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            DispatchQueue.main.async { [weak self] in self?.onFocus?(true) }
            return true
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { DispatchQueue.main.async { [weak self] in self?.onFocus?(false) } }
            return result
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            requestFocus()
        }
        func requestFocus() {
            guard let focusRequest, focusRequest != appliedFocusRequest, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusRequest == focusRequest, self.appliedFocusRequest != focusRequest,
                      self.isEnabled, let window = self.window as? WorkspaceWindow, window.admitsNavigationKeys else { return }
                if window.makeFirstResponder(self) { self.appliedFocusRequest = focusRequest }
            }
        }
        @objc func invoke() { if isEnabled { activate?() } }
    }

    func makeNSView(context: Context) -> Button {
        let button = Button(title: "", target: nil, action: nil)
        button.target = button
        button.action = #selector(Button.invoke)
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        return button
    }

    func updateNSView(_ button: Button, context: Context) {
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(help)
        button.toolTip = help
        button.onFocus = onFocus
        button.deleteAction = onDelete
        button.activate = action
        button.verticalAction = onVerticalKey
        button.focusRequest = focusRequest
        button.requestFocus()
    }
}

struct RecordingHistoryView: View {
    @ObservedObject var model: RecorderViewModel
    @ObservedObject var history: RecordingHistory
    @ObservedObject var workspace: TranscriptReviewWindowManager
    let showSettings: () -> Void

    @StateObject private var search: RecordingSearch
    @StateObject private var windowState = AppWindowState()
    @State private var query = ""
    @State private var renameTarget: RecordingEntry?
    @State private var renameTitle = ""
    @State private var renameError: String?
    @State private var renameSaving = false
    @State private var moreHovered = false
    @StateObject private var libraryNavigation = WorkspaceNavigationView(.library)
    private enum RowControl: Hashable { case select(URL), trash(URL) }
    @State private var rowControl: RowControl?
    @State private var rowFocusTarget: URL?
    @State private var rowFocusRequest: UUID?
    @State private var hoveredTrash: URL?
    @State private var trashFocusOrder: [URL] = []
    @State private var focusedTrashCompletion: UUID?

    init(model: RecorderViewModel, history: RecordingHistory, workspace: TranscriptReviewWindowManager,
         showSettings: @escaping () -> Void, search: RecordingSearch = RecordingSearch()) {
        self.model = model
        self.history = history
        self.workspace = workspace
        self.showSettings = showSettings
        _search = StateObject(wrappedValue: search)
    }

    var body: some View {
        let loadRequest = model.workspaceLoadRequest
        GeometryReader { geometry in
            let narrow = geometry.size.width <= 767
            let isWide = geometry.size.width >= 1024
            let sidebarWidth: CGFloat = narrow ? geometry.size.width : (isWide ? 304 : 264)
            HStack(spacing: 0) {
                if narrow ? model.workspaceShowsList : true {
                    VStack(spacing: 0) {
                        sidebarHeader(narrow: narrow, compact: !isWide)
                        sidebarContent
                        sidebarFooter
                    }
                    .frame(minWidth: narrow ? nil : sidebarWidth, idealWidth: sidebarWidth, maxWidth: narrow ? .infinity : sidebarWidth)
                    .background(ODColors.sidebar)

                    if !narrow {
                        Rectangle().fill(ODColors.line).frame(width: 1)
                    }
                }

                VStack(spacing: 0) {
                    if let notice = history.notice {
                        Text(notice).font(.system(size: 12)).foregroundStyle(ODColors.muted).padding(8)
                    }
                    if let error = history.error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(ODColors.red)
                            .textSelection(.enabled)
                            .padding(8)
                    }

                    if let url = model.selectedHistoryURL, let entry = history.entry(url) {
                        if workspace.loading {
                            ProgressView("Открываем текст…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let snapshot = processingDetails(for: entry) {
                            ProcessingDetailsView(snapshot: snapshot, entry: entry) { model.retryRecording(entry.id) }
                        } else if let current = workspace.current, current.state.id == entry.id, !entry.phase.isWorking,
                                  current.currentResultID != nil || current.legacyText != nil {
                            TranscriptReviewWindowView(model: current, title: entry.effectiveTitle, entryDate: entry.date, entryDuration: entry.duration, workspaceWidth: geometry.size.width,
                                keyboardNavigationVisible: !narrow || !model.workspaceShowsList)
                        } else if entry.phase.isWorking {
                            Text("Подготовка обработки…").font(.system(size: 14)).foregroundStyle(ODColors.muted)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                entryHeading(entry)
                                Spacer()
                                ODIconView(.warning, size: 28, color: ODColors.warning)
                                Text(entry.capabilities.canRetry || entry.availableFiles.contains(entry.recording) ? "Аудио сохранено" : "Аудио недоступно")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(ODColors.ink)
                                let errors = entry.problems.filter(\.isError).map(\.message).joined(separator: "\n")
                                Text(errors.isEmpty ? (entry.capabilities.reason ?? workspace.failure ?? entry.status) : errors)
                                    .font(.system(size: 13))
                                    .foregroundColor(ODColors.muted)
                                    .textSelection(.enabled)
                                if entry.capabilities.canRetry {
                                    Button("Повторить распознавание") {
                                        model.retryRecording(entry.id)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)
                                    .disabled(model.isBusy || model.diagnosticRunning)
                                }
                                Spacer()
                            }
                            .padding(32)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                    } else {
                        ContentUnavailableView(
                            "Выбери запись",
                            systemImage: "doc.text",
                            description: Text("Выбери встречу в библиотеке")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(width: narrow && model.workspaceShowsList ? 0 : nil)
                .opacity(narrow && model.workspaceShowsList ? 0 : 1)
                .accessibilityHidden(narrow && model.workspaceShowsList)
                .clipped()
            }
            .background(ODColors.surface)
            .background(WindowAccessor { window in
                windowState.attach(window)
                windowState.updateHeader(
                    brand: AnyView(WorkspaceBrand(narrow: narrow, compact: !isWide)),
                    actions: AnyView(documentToolbar(narrow: narrow, compact: !isWide)
                        .disabled(model.settingsPresented || model.trashOwnsInput)
                        .allowsHitTesting(!model.settingsPresented && !model.trashOwnsInput)
                        .accessibilityHidden(model.settingsPresented || model.trashOwnsInput)),
                    width: geometry.size.width, sidebarWidth: sidebarWidth,
                    narrow: narrow, showsList: model.workspaceShowsList)
            })
        }
        .quickLookPreview($model.audioPreviewURL)
        .task {
            if !history.initialLoadComplete { await history.refresh(root: model.outputDirectory) }
            if model.selectedHistoryURL == nil { model.selectedHistoryURL = history.entries.first?.id }
        }
        .task(id: loadRequest) { _ = await model.loadWorkspace(loadRequest) }
        .task(id: SearchRequest(query: query, entries: history.entries, savedRevision: workspace.savedRevision)) {
            await search.update(query: query, entries: history.entries)
        }
        .sheet(item: $renameTarget) { target in renameSheet(target) }
    }

    func processingDetails(for entry: RecordingEntry) -> ProcessingProgressSnapshot? {
        guard let snapshot = model.processingRoutes[entry.id], entry.phase.isWorking || snapshot.failure != nil else { return nil }
        return snapshot
    }

    func renameSheet(_ target: RecordingEntry) -> some View {
            ODDialog(title: "Название встречи", close: { if !renameSaving { renameTarget = nil; workspace.externalModal = false } }) {
                ODField(title: "Название") {
                TextField("Название", text: $renameTitle)
                    .odInput()
                }

                if let message = renameError ?? workspace.commandNotice {
                    Text(message)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

            } actions: {
                    Button("Отмена") {
                        renameTarget = nil
                        workspace.externalModal = false
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(renameSaving)

                    Button("Сохранить") {
                        guard !renameSaving else { return }
                        renameSaving = true
                        Task {
                            do {
                                try await model.renameRecording(target.id, displayTitle: renameTitle)
                                renameTarget = nil
                                workspace.externalModal = false
                            } catch {
                                renameError = error.localizedDescription
                            }
                            renameSaving = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ODButtonStyle(primary: true))
                    .disabled(renameSaving)
            }
            .interactiveDismissDisabled()
    }

    private func entryHeading(_ entry: RecordingEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.phase.isWorking ? entry.status : "Обработка не завершена")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(entry.phase.isWorking ? ODColors.muted : ODColors.red)
            Text(entry.effectiveTitle).font(.system(size: 32, weight: .semibold)).tracking(-0.8)
            Text(entry.date.formatted(date: .long, time: .shortened)).font(.system(size: 13)).foregroundStyle(ODColors.muted)
        }
    }

    private func sidebarHeader(narrow: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 16) {
            // Title row with badge and plus
            HStack(alignment: .center) {
                Text("Записи")
                    .font(.system(size: narrow ? 28 : 22, weight: .semibold))
                    .foregroundColor(ODColors.ink)
                Spacer()
                Text("\(visibleEntries.count)")
                    .font(.system(size: 12))
                    .foregroundColor(ODColors.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(minWidth: 24)
                    .background(ODColors.hover, in: RoundedRectangle(cornerRadius: 6))
                Button(action: { model.mainPage = .recording }) {
                    ODIconView(.plus, size: 16, color: ODColors.ink)
                        .frame(width: 36, height: 36)
                        .background(ODColors.hover, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Новая запись")
            }

            // Search input (font 14)
            HStack(spacing: 8) {
                ODIconView(.search, size: 16, color: ODColors.muted)
                WorkspaceSearchField(text: Binding(get: { query }, set: { if !workspace.hasInput { query = $0 } }), model: model)
                    .odLineBox(size: 14, height: 21.7)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(ODColors.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ODColors.line, lineWidth: 1))

            if search.loading {
                ProgressView("Поиск…").controlSize(.small)
            }
            if !search.result.failures.isEmpty {
                Text("Часть записей не прочитана: " + search.result.failures.joined(separator: "; "))
                    .font(.caption)
                    .foregroundColor(ODColors.warning)
            }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 20)
        }
    }

    private var sidebarContent: some View {
        ScrollViewReader { proxy in
        Group {
            if !history.initialLoadComplete {
                ProgressView("Загружаем записи…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.entries.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Записей пока нет", systemImage: "tray", description: Text("Начните новую запись встречи."))
            } else if visibleEntries.isEmpty && !search.loading {
                ContentUnavailableView("Совпадений нет", systemImage: "magnifyingglass", description: Text(search.result.failures.isEmpty ? "Попробуйте другой запрос." : "Поиск неполный: некоторые файлы недоступны."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let groups = groupedEntries
                        ForEach(groups, id: \.title) { group in
                            Text(group.title)
                                .font(.system(size: 12, weight: .semibold))
                                .odLineBox(size: 12, height: 18.6)
                                .tracking(0.2)
                                .foregroundColor(ODColors.muted)
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                                .padding(.bottom, 8)

                            ForEach(group.entries) { entry in
                                recordCard(entry).id(entry.id)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceNavigationFocus(surface: libraryNavigation, onVerticalKey: { direction in
            let entries = groupedEntries.flatMap(\.entries)
            guard !entries.isEmpty else { return }
            let next = model.selectedHistoryURL.flatMap { selected in entries.firstIndex { $0.id == selected } }
                .map { $0 + direction } ?? 0
            guard entries.indices.contains(next) else { return }
            model.selectLibraryRecording(entries[next].id)
            proxy.scrollTo(entries[next].id)
            libraryNavigation.focus()
        }, onDeleteKey: {
            guard let selected = model.selectedHistoryURL, let entry = history.entry(selected) else { return }
            await requestTrash(entry)
        }))
        .contentShape(Rectangle())
        .onTapGesture { libraryNavigation.focus() }
        .onChange(of: model.trashCompletion?.id) { _, _ in focusAfterTrash(proxy) }
        .onChange(of: model.recordingTrash?.id) { _, _ in focusAfterTrash(proxy) }
        }
    }

    private func focusAfterTrash(_ proxy: ScrollViewProxy) {
        guard !model.trashOwnsInput, let completion = model.trashCompletion, focusedTrashCompletion != completion.id else { return }
        focusedTrashCompletion = completion.id
        let live = Set(visibleEntries.map(\.id))
        let index = trashFocusOrder.firstIndex(of: completion.recording) ?? 0
        let neighbors = Array(trashFocusOrder.dropFirst(index + 1)) + Array(trashFocusOrder.prefix(index).reversed())
        if let next = (neighbors + visibleEntries.map(\.id)).first(where: { live.contains($0) }) {
            proxy.scrollTo(next)
            DispatchQueue.main.async {
                guard !model.trashOwnsInput, model.trashCompletion?.id == completion.id else { return }
                rowFocusTarget = next
                rowFocusRequest = completion.id
            }
        } else { model.workspaceSearchRequest = UUID() }
    }

    private func requestTrash(_ entry: RecordingEntry) async {
        guard !workspace.hasInput, model.selectedHistoryURL == entry.id else { return }
        trashFocusOrder = groupedEntries.flatMap(\.entries).map(\.id)
        _ = await model.requestRecordingTrash(entry.id)
    }

    private func selectRecording(_ entry: RecordingEntry) {
        guard !workspace.hasInput else { return }
        model.selectLibraryRecording(entry.id)
        model.workspaceShowsList = false
        libraryNavigation.focus()
    }

    private func navigateFromRow(_ entry: RecordingEntry, by direction: Int) {
        guard !workspace.hasInput else { return }
        if model.selectedHistoryURL == nil {
            model.selectLibraryRecording(entry.id)
            libraryNavigation.focus()
        } else { libraryNavigation.onVerticalKey?(direction) }
    }

    private func recordCard(_ entry: RecordingEntry) -> some View {
        let isSelected = entry.id == model.selectedHistoryURL
        let reason = model.trashUnavailableReason(entry)
        let trashFocused = rowControl == .trash(entry.id)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.effectiveTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? ODColors.selectedInk : ODColors.ink)
                    .lineLimit(2)
                    .odLineBox(size: 15, height: 21)

                HStack {
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                    Spacer()
                    if let dur = entry.duration {
                        Text(formatClock(dur))
                    }
                }
                .font(.system(size: 12))
                .odLineBox(size: 12, height: 15.6)
                .foregroundColor(ODColors.muted)
                .padding(.top, 5)

                HStack(spacing: 6) {
                    ODIconView(entry.phase == .failed || !entry.problems.isEmpty ? .warning : entry.phase == .completed ? .check : .clock, size: 13, color: ODColors.muted)
                    Text(entry.phase == .completed ? (entry.problems.isEmpty ? "Транскрипт готов" : "Готово · есть замечание") : entry.phase.text)
                        .font(.system(size: 12))
                        .foregroundColor(ODColors.muted)
                        .lineLimit(1)
                }
                .odLineBox(size: 12, height: 15.6)
                .padding(.top, 7)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
            .overlay {
                RecordingRowButton(label: entry.effectiveTitle, help: "Открыть запись",
                    focusRequest: rowFocusTarget == entry.id ? rowFocusRequest : nil,
                    onFocus: { focused in rowControl = focused ? .select(entry.id) : rowControl == .select(entry.id) ? nil : rowControl },
                    onVerticalKey: { navigateFromRow(entry, by: $0) },
                    onDelete: { await requestTrash(entry) },
                    action: { selectRecording(entry) })
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(rowControl == .select(entry.id) ? ODColors.accent : .clear, lineWidth: 2).allowsHitTesting(false))
            Image(systemName: "trash").font(.system(size: 16))
                .foregroundStyle(trashFocused || hoveredTrash == entry.id ? ODColors.red : ODColors.muted)
                .frame(width: 28, height: 28).contentShape(Rectangle())
                .accessibilityHidden(true)
                .overlay {
                    RecordingRowButton(label: "Переместить запись \(entry.effectiveTitle) в Корзину", help: reason ?? "В Корзину…",
                        onFocus: { focused in rowControl = focused ? .trash(entry.id) : rowControl == .trash(entry.id) ? nil : rowControl },
                        onVerticalKey: { navigateFromRow(entry, by: $0) },
                        onDelete: { await requestTrash(entry) },
                        action: { Task { await requestTrash(entry) } })
                }
        .disabled(!isSelected || reason != nil || workspace.hasInput)
        .accessibilityHidden(!isSelected)
        .help(reason ?? "В Корзину…")
        .onHover { hoveredTrash = $0 ? entry.id : nil }
        .opacity(isSelected ? 1 : 0)
        .padding(.trailing, 8)
        }
        .background(isSelected ? ODColors.selected : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? ODColors.accent.opacity(0.12) : Color.clear, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            ODIconView(.shield, size: 16, color: ODColors.muted)
            Text("Локальная обработка\nДанные остаются на Mac")
                .font(.system(size: 11)).foregroundStyle(ODColors.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: showSettings) {
                ODIconView(.settings, size: 16, color: ODColors.muted).frame(width: 36, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Настройки")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(ODColors.line).frame(height: 1) }
        .background(ODColors.sidebar)
    }

    private func documentToolbar(narrow: Bool, compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 16) {
            if narrow && !model.workspaceShowsList {
                Button(action: { if !workspace.hasInput { model.workspaceShowsList = true } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Все записи")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
            } else {
                Text("Транскрипт")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(ODColors.muted)
            }

            Spacer()

            if let url = model.selectedHistoryURL, let entry = history.entry(url) {
                Button(action: { exportTranscript(entry) }) {
                    ODIconView(.export, size: 16, color: ODColors.ink)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(workspace.hasInput || workspace.model(for: entry.id)?.canExport != true)
                .help(workspace.model(for: entry.id)?.canExport == true ? "Экспорт сохранённого текста" : "Экспорт доступен для открытого сохранённого транскрипта")
                .accessibilityLabel("Экспорт")

                Menu {
                    Button { model.retryRecording(entry.id) } label: {
                        Label("Повторить обработку", systemImage: "arrow.clockwise")
                    }
                    .disabled(!entry.capabilities.canRetry || entry.phase.isWorking || model.isBusy || model.diagnosticRunning || workspace.hasInput)
                    .help(entry.capabilities.canRetry ? "Получить новый текст из исходных дорожек" : entry.capabilities.reason ?? "Повторная обработка недоступна")
                    Button {
                        guard !workspace.hasInput, RecordingPaths.isStandardLayout(entry.recording), !entry.phase.isWorking else { return }
                        renameTitle = entry.effectiveTitle
                        renameError = nil
                        workspace.externalModal = true
                        renameTarget = entry
                    } label: { Label("Переименовать", systemImage: "pencil") }
                    .disabled(!RecordingPaths.isStandardLayout(entry.recording) || entry.phase.isWorking || workspace.hasInput)

                    Button {
                        guard !workspace.hasInput else { return }
                        if let current = workspace.model(for: entry.id) {
                            current.copySavedText()
                        }
                    } label: { Label("Копировать транскрипт", systemImage: "doc.on.doc") }
                    .disabled(workspace.hasInput || workspace.model(for: entry.id)?.canCopySavedText != true)

                    Button(action: showSettings) { Label("Настройки", systemImage: "gearshape") }
                    Divider()
                    let reason = model.trashUnavailableReason(entry)
                    Button(role: .destructive) { Task { await requestTrash(entry) } } label: {
                        Label("В Корзину…", systemImage: "trash")
                    }
                    .disabled(reason != nil || workspace.hasInput)
                    .help(reason ?? "В Корзину…")
                    .accessibilityHint(reason ?? "В Корзину…")
                } label: {
                    ODIconView(.more, size: 20, color: ODColors.muted)
                        .frame(width: 36, height: 36)
                        .background(moreHovered ? ODColors.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain)
                .menuIndicator(.hidden)
                .onHover { moreHovered = $0 }
                .disabled(workspace.hasInput)
                .accessibilityLabel("Дополнительные действия")

                if !narrow { Rectangle().fill(ODColors.line).frame(width: 1, height: 20) }
            }

            Button(action: { model.mainPage = .recording }) {
                HStack(spacing: 6) {
                    ODIconView(.record, size: 16, color: ODColors.primaryButtonForeground)
                    Text("Новая запись")
                        .font(.system(size: narrow ? 13 : 14, weight: .medium))
                        .foregroundColor(ODColors.primaryButtonForeground)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(ODColors.accent, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, narrow ? 12 : compact ? 16 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(narrow ? Color.clear : ODColors.toolbar)
        .overlay(alignment: .bottom) {
            if !narrow { Rectangle().frame(height: 1).foregroundColor(ODColors.line) }
        }
    }

    private struct GroupedEntries: Identifiable {
        let title: String
        let entries: [RecordingEntry]
        var id: String { title }
    }

    private var groupedEntries: [GroupedEntries] {
        var groups: [GroupedEntries] = []
        for entry in visibleEntries {
            let groupTitle = entry.dateGroupTitle
            if let index = groups.firstIndex(where: { $0.title == groupTitle }) {
                let existing = groups[index]
                groups[index] = GroupedEntries(title: existing.title, entries: existing.entries + [entry])
            } else {
                groups.append(GroupedEntries(title: groupTitle, entries: [entry]))
            }
        }
        return groups
    }

    private struct SearchRequest: Equatable {
        let query: String
        let entries: [RecordingEntry]
        let savedRevision: Int
    }
    private var visibleEntries: [RecordingEntry] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return history.entries }
        let live = Set(history.entries.map(\.id))
        return search.result.matches.filter { live.contains($0.id) }
    }

    private func exportTranscript(_ entry: RecordingEntry) {
        guard !workspace.hasInput, let current = workspace.model(for: entry.id) else { return }
        current.requestExport()
    }

}

struct ProcessingDetailsView: View {
    let snapshot: ProcessingProgressSnapshot
    let entry: RecordingEntry
    let retry: () -> Void

    static func fraction(for progress: TranscriptionProgress) -> Double? {
        guard progress.state == nil, [.echo, .gigaam, .speakers, .parakeet].contains(progress.stage) else { return nil }
        return progress.stageFraction
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.effectiveTitle).font(.system(size: 28, weight: .semibold)).foregroundStyle(ODColors.ink)
                        Text(entry.date.formatted(date: .long, time: .shortened) + (entry.duration.map { " · " + formatClock($0) } ?? ""))
                            .font(.system(size: 13)).foregroundStyle(ODColors.muted)
                    }
                    if geometry.size.width - 48 - 32 - 200 >= 280 {
                        HStack(alignment: .top, spacing: 32) {
                            route.frame(width: 200)
                            details.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        details
                        route
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .background(ODColors.surface)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private var route: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(snapshot.route.enumerated()), id: \.element) { index, station in
                let state = snapshot.states[station] ?? .future
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        ProcessingStationSymbol(state: state, size: 24)
                        if index < snapshot.route.count - 1 {
                            Rectangle().fill(ODColors.track).frame(width: 2).frame(minHeight: 32)
                        }
                    }.frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(station.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(ODColors.ink)
                        Text(status(state)).font(.system(size: 12)).foregroundStyle(ODColors.muted)
                        if let reason = snapshot.reasons[station] {
                            Text(reason).font(.system(size: 12)).foregroundStyle(ODColors.warning).textSelection(.enabled)
                        }
                    }.padding(.bottom, 16)
                }
                .frame(minHeight: 56, alignment: .topLeading)
                .accessibilityElement(children: .combine)
            }
        }.accessibilityLabel("Маршрут обработки")
    }
    var phaseTitle: String {
        snapshot.failure != nil ? "Не удалось обработать" : snapshot.terminal ? "Готово" : snapshot.current?.title ?? "В очереди"
    }
    var activityText: String { snapshot.current == nil ? "Ожидает начала обработки." : "Выполняется…" }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(snapshot.current == nil ? snapshot.countText : "Этап \(snapshot.currentIndex + 1) из \(snapshot.route.count)")
                .font(.system(size: 12)).foregroundStyle(ODColors.muted)
            Text(phaseTitle)
                .font(.system(size: 24, weight: .semibold)).foregroundStyle(ODColors.ink)
            if let model = snapshot.current?.model { Text(model).font(.system(size: 14)).foregroundStyle(ODColors.muted) }
            if snapshot.current?.hasSources == true, let channel = snapshot.local?.channel {
                Text(channel == "host" ? "Микрофон · дорожка 1 из 2" : "Системный звук · дорожка 2 из 2")
                    .font(.system(size: 13)).foregroundStyle(ODColors.muted)
            }
            if let fraction = snapshot.localFraction, let local = snapshot.local {
                HStack {
                    Text(local.stage == .echo ? "Обработано кадров аудио" : "\(local.completed) из \(local.total) \(local.stage == .speakers ? "слов" : "окон")")
                    Spacer()
                    Text("\(Int(fraction * 100))%")
                }.font(.system(size: 13)).foregroundStyle(ODColors.muted)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ODColors.track)
                        Capsule().fill(ODColors.accent).frame(width: geometry.size.width * fraction)
                    }
                }.frame(height: 4)
                .accessibilityLabel("Прогресс текущей дорожки: \(Int(fraction * 100)) процентов")
            } else if !snapshot.terminal {
                Text(activityText).font(.system(size: 13)).foregroundStyle(ODColors.muted)
            }
            ForEach(snapshot.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(ODColors.warning).textSelection(.enabled)
            }
            if snapshot.failure != nil, entry.capabilities.canRetry {
                Button("Повторить распознавание", action: retry).buttonStyle(.borderedProminent)
            }
            Text(snapshot.terminal ? "Запись и доступные журналы не удаляются." : "Можно выбрать другую встречу или закрыть окно. Обработка продолжится.")
                .font(.system(size: 13)).foregroundStyle(ODColors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func status(_ state: ProcessingProgressSnapshot.State) -> String {
        switch state {
        case .completed: "Завершено"
        case .warning: "Завершено · замечание"
        case .current: "Сейчас"
        case .future: "Далее"
        case .skipped: "Пропущено"
        case .failed: "Ошибка"
        }
    }
}
