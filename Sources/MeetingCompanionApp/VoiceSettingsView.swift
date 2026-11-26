import AppKit
import SwiftUI
import MeetingCompanionCore

struct VoiceSettingsView: View {
    @ObservedObject var model: RecorderViewModel
    @State private var directory: VoiceDirectorySnapshot?
    @State private var catalogueBytes = 0
    @State private var localCatalogueUpdate = 0
    @State private var expandedID: UUID?
    @State private var search = ""
    @State private var showsHelp = false
    @State private var loadError: String?
    @State private var operationError: String?
    @State private var confirmation: Removal?
    @State private var confirmationSource: Control?
    @State private var isRemoving = false
    @State private var completedRemoval: Removal?
    @State private var notice: String?
    @FocusState private var focus: Control?

    private struct CatalogueRequest: Equatable {
        let catalogueUpdate: Int
        let voiceJobs: Int
        let learningEnabled: Bool
        let retry: Int
    }

    private enum Control: Hashable {
        case search, row(UUID), reset(UUID), personMenu(UUID), catalogueMenu
    }

    private enum Removal {
        case samples(VoiceDirectorySnapshot.Row), person(VoiceDirectorySnapshot.Row), catalogue

        var title: String {
            switch self {
            case .samples: "Сбросить обучение?"
            case .person: "Удалить человека?"
            case .catalogue: "Удалить всех людей?"
            }
        }

        var action: String {
            switch self {
            case .samples: "Сбросить обучение"
            case .person: "Удалить человека"
            case .catalogue: "Удалить всех людей"
            }
        }

        var source: Control {
            switch self {
            case .samples(let row): .reset(row.id)
            case .person(let row): .personMenu(row.id)
            case .catalogue: .catalogueMenu
            }
        }

        var message: String {
            switch self {
            case .samples(let row):
                "\(name(row)). Эталоны и календарные привязки будут удалены. Карточка, записи, расшифровки и сохранённые имена останутся."
            case .person(let row):
                "\(name(row)). Карточка, эталоны и календарные привязки будут удалены. Записи, расшифровки и сохранённые имена останутся."
            case .catalogue:
                "Все люди, календарные привязки и эталоны будут удалены. Записи, расшифровки и сохранённые имена останутся."
            }
        }

        private func name(_ row: VoiceDirectorySnapshot.Row) -> String {
            [row.person.displayName, row.subtitle].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var rows: [VoiceDirectorySnapshot.Row] { directory?.rows(matching: search) ?? [] }
    private var hasQuery: Bool { !TranscriptSpeakerAssignmentService.nameComparisonKey(search).isEmpty }
    private var removalDisabled: Bool { isRemoving || completedRemoval != nil || loadError != nil }

    private var catalogueRequest: CatalogueRequest {
        CatalogueRequest(catalogueUpdate: model.voiceCatalogueUpdate, voiceJobs: model.voiceJobs,
                         learningEnabled: model.voiceIdentityEnabled, retry: localCatalogueUpdate)
    }

    var body: some View {
        let request = catalogueRequest
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            Text("Голоса")
                .font(.system(size: 24, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 24)
            recognition
                .padding(.bottom, 20)
            Section {
                directoryContents
            } header: {
                directoryHeader
            }
        }
        .task(id: model.isResettingCache) {
            if !model.isResettingCache { model.checkVoiceModel(prepare: false) }
        }
        .task(id: request) { await reload(request) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { notification in
            guard let window = notification.object as? WorkspaceWindow, window.model === model,
                  let source = confirmationSource else { return }
            confirmationSource = nil
            restoreFocus(to: source)
        }
        .onChange(of: search) { _, _ in
            if let expandedID, !rows.contains(where: { $0.id == expandedID }) { self.expandedID = nil }
        }
        .alert(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { removal in
            Button("Отмена", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(removal.action, role: .destructive) { Task { await remove(removal) } }
        } message: { removal in
            Text(removal.message)
        }
    }

    private var recognition: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(recognitionTitle).font(.system(size: 15, weight: .semibold))
                        Button {
                            showsHelp.toggle()
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(ODColors.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Как работает распознавание голосов")
                        .popover(isPresented: $showsHelp, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Как запоминается голос").fontWeight(.semibold)
                                Text("Когда вы вручную назначаете или исправляете имя, подходящие фрагменты пополняют профиль. Автоимена в обучение не попадают.")
                                Text("Профили хранятся на этом Mac отдельно от записей и сохраняются при выключении функции.")
                            }
                            .font(.system(size: 13)).frame(width: 286, alignment: .leading).padding(16)
                        }
                    }
                    Text(recognitionHint).font(.system(size: 13)).foregroundStyle(ODColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Toggle(recognitionTitle, isOn: $model.voiceIdentityEnabled).labelsHidden()
            }
            if model.voiceIdentityEnabled, model.voiceModelStatus != .ready {
                if case .unavailable(let reason) = model.voiceModelStatus {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { modelReason(reason); prepareButton }
                        VStack(alignment: .leading, spacing: 8) { modelReason(reason); prepareButton }
                    }
                } else if model.voiceModelStatus.isBusy {
                    ProgressView(model.voiceModelStatus.title).controlSize(.small)
                        .font(.system(size: 12))
                } else {
                    modelReason("Готовность модели ещё не проверена.")
                }
            }
            Divider().padding(.top, 6)
        }
    }

    private var recognitionTitle: String {
        model.automaticVoiceNamesAvailable ? "Узнавать знакомые голоса" : "Запоминать голоса"
    }

    private var recognitionHint: String {
        if !model.voiceIdentityEnabled { return "Распознавание и обучение приостановлены. Профили сохранены." }
        if !model.automaticVoiceNamesAvailable { return "Автоимена станут доступны после калибровки." }
        return "В новых записях знакомые участники будут подписаны по имени."
    }

    private func modelReason(_ reason: String) -> some View {
        Text(reason).font(.system(size: 12)).foregroundStyle(ODColors.muted)
    }

    private var prepareButton: some View {
        Button("Подготовить модель") { model.checkVoiceModel(prepare: true) }
            .disabled(model.preventsSettingsOperation)
    }

    private var directoryHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                directoryTitle
                Spacer(minLength: 16)
                searchField.frame(width: 220)
                catalogueMenu
            }
            .frame(minWidth: 440)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    directoryTitle
                    Spacer(minLength: 0)
                    catalogueMenu
                }
                searchField
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .background(ODColors.surface)
    }

    private var directoryTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Люди").font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let directory, loadError == nil {
                Text(hasQuery ? "\(rows.count) из \(directory.rows.count)" : "\(directory.rows.count)")
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(ODColors.muted)
            }
        }
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ODColors.muted)
                .accessibilityHidden(true)
            TextField("Найти человека", text: $search)
                .textFieldStyle(.plain)
                .accessibilityLabel("Найти человека по имени, контакту или подписи")
                .focused($focus, equals: .search)
            if !search.isEmpty {
                Button {
                    search = ""
                    focus = .search
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ODColors.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
            }
        }
        .font(.system(size: 14)).padding(.horizontal, 12).frame(height: 36)
        .background(ODColors.toolbar, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            focus == .search ? ODColors.accent : ODColors.line, lineWidth: focus == .search ? 2 : 1
        ).allowsHitTesting(false))
    }

    private var catalogueMenu: some View {
        Menu {
            if directory != nil, loadError == nil {
                Text("На диске: \(ByteCountFormatter.string(fromByteCount: Int64(catalogueBytes), countStyle: .file))")
            }
            Button("Удалить всех людей…", role: .destructive) { requestConfirmation(.catalogue) }
                .disabled(removalDisabled || directory?.rows.isEmpty != false)
        } label: {
            menuIcon
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
        .accessibilityLabel("Действия со списком людей")
        .focused($focus, equals: .catalogueMenu)
    }

    @ViewBuilder private var directoryContents: some View {
        if let loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text(loadError).foregroundStyle(ODColors.red).textSelection(.enabled)
                if directory != nil { Text("Показан последний загруженный список.").foregroundStyle(ODColors.muted) }
                Button("Повторить чтение") { localCatalogueUpdate &+= 1 }
            }
            .font(.system(size: 12)).padding(.vertical, 8)
        }
        if let operationError {
            Text(operationError).font(.system(size: 12)).foregroundStyle(ODColors.red)
                .textSelection(.enabled).padding(.vertical, 8)
        }
        if let notice {
            Text(notice).font(.system(size: 12)).foregroundStyle(ODColors.muted).padding(.vertical, 8)
        }
        if let directory {
            Divider()
            if loadError == nil, directory.rows.isEmpty {
                emptyMessage("Голосовых профилей пока нет",
                             hint: "Назначьте имя вручную в транскрипте, чтобы начать обучение.")
            } else if loadError == nil, rows.isEmpty {
                emptyMessage("Никого не нашли", hint: "Попробуйте другое имя или календарный адрес.")
            } else {
                ForEach(rows) { row in
                    personRow(row)
                    Divider()
                }
            }
        } else if loadError == nil {
            ProgressView("Загружаем профили…").controlSize(.small).padding(.vertical, 12)
        }
    }

    private func emptyMessage(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.medium)
            Text(hint).foregroundStyle(ODColors.muted)
        }
        .font(.system(size: 13)).padding(12)
    }

    private func personRow(_ row: VoiceDirectorySnapshot.Row) -> some View {
        let expanded = expandedID == row.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedID = expanded ? nil : row.id
            } label: {
                ViewThatFits(in: .horizontal) {
                    rowLabel(row, expanded: expanded, compact: false).frame(minWidth: 440)
                    rowLabel(row, expanded: expanded, compact: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .row(row.id))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focus == .row(row.id) ? ODColors.accent : .clear, lineWidth: 2)
                .allowsHitTesting(false))
            .accessibilityLabel([row.person.displayName, row.subtitle].compactMap { $0 }.joined(separator: ", "))
            .accessibilityValue("\(row.status.rawValue), \(expanded ? "развёрнуто" : "свёрнуто")")

            if expanded { personDetails(row) }
        }
        .background(expanded ? ODColors.toolbar : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func rowLabel(_ row: VoiceDirectorySnapshot.Row, expanded: Bool, compact: Bool) -> some View {
        HStack(spacing: 12) {
            monogram(row.person.displayName, expanded: expanded)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.person.displayName).font(.system(size: 15, weight: .medium))
                    .lineLimit(expanded ? nil : 1)
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(ODColors.muted)
                        .lineLimit(expanded ? nil : 1)
                }
                if compact { statusLabel(row.status) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if !compact, row.status != .ready {
                statusLabel(row.status)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 134, alignment: .trailing)
            }
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10)).foregroundStyle(ODColors.muted)
                .frame(width: 14).accessibilityHidden(true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48)
    }

    @ViewBuilder private func statusLabel(_ status: VoiceDirectorySnapshot.Status) -> some View {
        if status != .ready {
            Text(status.rawValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(status == .updating ? ODColors.muted : ODColors.warning)
        }
    }

    private func monogram(_ name: String, expanded: Bool) -> some View {
        let initials = String(name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)).uppercased()
        return Text(initials)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(expanded ? ODColors.selectedInk : ODColors.muted)
            .frame(width: 32, height: 32)
            .background(expanded ? ODColors.selected : ODColors.sidebar, in: Circle())
            .overlay(Circle().strokeBorder(expanded ? .clear : ODColors.line))
            .accessibilityHidden(true)
    }

    private func personDetails(_ row: VoiceDirectorySnapshot.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let contacts = row.person.calendarBindings.filter { $0 != row.subtitle }
            ForEach(contacts.indices, id: \.self) { index in
                Text(contacts[index]).foregroundStyle(ODColors.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { profileSummary(row) }
                VStack(alignment: .leading, spacing: 4) { profileSummary(row) }
            }
            if let failure = row.failure {
                if row.hasCompatibleProfile { Text("Ранее сохранённый профиль доступен") }
                Text(failure).foregroundStyle(ODColors.muted).textSelection(.enabled)
            } else if row.status == .insufficientSpeech {
                Text("Назначьте имя в следующих встречах. Подбор подходящих фрагментов автоматический.")
                    .foregroundStyle(ODColors.muted)
            }
            HStack(spacing: 8) {
                Button("Сбросить обучение…") { requestConfirmation(.samples(row)) }
                    .focused($focus, equals: .reset(row.id))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(focus == .reset(row.id) ? ODColors.accent : .clear, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                Menu {
                    Button("Удалить человека…", role: .destructive) { requestConfirmation(.person(row)) }
                } label: { menuIcon }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                .accessibilityLabel("Другие действия с профилем \(row.person.displayName)")
                .focused($focus, equals: .personMenu(row.id))
            }
            .disabled(removalDisabled)
        }
        .font(.system(size: 12))
        .padding(.leading, 56).padding(.trailing, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func profileSummary(_ row: VoiceDirectorySnapshot.Row) -> some View {
        if row.status == .ready {
            Label("Голос знаком", systemImage: "checkmark.circle").foregroundStyle(ODColors.green)
        }
        Text(loadError == nil ? meetingCount(row.meetingCount) : "Число встреч неизвестно")
            .foregroundStyle(ODColors.muted)
    }

    private var menuIcon: some View {
        Image(systemName: "ellipsis").foregroundStyle(ODColors.muted)
            .frame(width: 34, height: 32).contentShape(Rectangle())
    }

    private func meetingCount(_ count: Int) -> String {
        let unit: String
        switch (count % 100, count % 10) {
        case (11...14, _): unit = "встреч"
        case (_, 1): unit = "встреча"
        case (_, 2...4): unit = "встречи"
        default: unit = "встреч"
        }
        return "\(count) \(unit) с ручной разметкой"
    }

    private func requestConfirmation(_ removal: Removal) {
        confirmationSource = removal.source
        confirmation = removal
    }

    private func restoreFocus(to source: Control) {
        Task { @MainActor in
            guard model.settingsPage == .voices, model.settingsPresented else { return }
            switch source {
            case .reset(let id), .personMenu(let id):
                focus = expandedID == id && !removalDisabled ? source : .search
            default:
                focus = source
            }
        }
    }

    private func reload(_ request: CatalogueRequest) async {
        let coordinator = model.voiceLearning
        do {
            let (bytes, snapshot) = try await Task.detached {
                let result = try coordinator.catalogue.load()
                let snapshot = VoiceDirectorySnapshot(catalogue: result.catalogue,
                    activeLearningEvents: coordinator.activeLearningEventIDs)
                return (result.sizeInBytes, snapshot)
            }.value
            guard !Task.isCancelled, request == catalogueRequest else { return }
            directory = snapshot
            catalogueBytes = bytes
            loadError = nil
            if let expandedID, !rows.contains(where: { $0.id == expandedID }) {
                self.expandedID = nil
            }
            if let completedRemoval {
                self.completedRemoval = nil
                switch completedRemoval {
                case .samples(let row):
                    notice = "Обучение сброшено."
                    restoreFocus(to: .reset(row.id))
                case .person, .catalogue:
                    restoreFocus(to: .search)
                }
            }
        } catch {
            guard !Task.isCancelled, request == catalogueRequest else { return }
            loadError = "Не удалось загрузить голосовые профили. " + error.localizedDescription
        }
    }

    private func remove(_ removal: Removal) async {
        guard !removalDisabled else { return }
        isRemoving = true
        operationError = nil
        notice = nil
        defer { isRemoving = false }
        let coordinator = model.voiceLearning
        do {
            try await Task.detached {
                switch removal {
                case .samples(let row): try coordinator.resetPerson(row.id, delete: false)
                case .person(let row): try coordinator.resetPerson(row.id, delete: true)
                case .catalogue: try coordinator.deleteCatalogue()
                }
            }.value
            completedRemoval = removal
            model.voiceCatalogueMutationDidCommit()
        } catch {
            operationError = error.localizedDescription
            restoreFocus(to: removal.source)
        }
    }
}
