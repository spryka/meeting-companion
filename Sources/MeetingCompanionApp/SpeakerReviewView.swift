import SwiftUI
import MeetingCompanionCore

struct SpeakerReviewView: View {
    static let createPersonOptionID = "__create_new_person__"

    static func nextHighlightedSuggestionID(current: String?, in optionIDs: [String], step: Int) -> String? {
        guard !optionIDs.isEmpty else { return nil }
        guard let current, let index = optionIDs.firstIndex(of: current) else {
            return step >= 0 ? optionIDs.first : optionIDs.last
        }
        let next = ((index + step) % optionIDs.count + optionIDs.count) % optionIDs.count
        return optionIDs[next]
    }

    @ObservedObject var model: TranscriptReviewWindowModel
    var title: String = "Имена участников"
    var transcriptReturnTurnID: String? = nil
    var onTranscriptJump: () -> Void = {}
    @State private var showOtherTurns = false
    @State private var suggestionsOpen = false
    @State private var filterSuggestions = false
    @State private var highlightedSuggestionID: String?
    @FocusState private var nameFocused: Bool
    @FocusState private var focusedVoice: TranscriptVoiceKey?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width <= 640
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.system(size: 13)).foregroundStyle(ODColors.muted)
                        .lineLimit(1).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if compact && !model.voiceListVisible && !model.voiceReviewComplete {
                        Button("Голоса") { _ = model.requestVoiceList() }.buttonStyle(ODButtonStyle(compact: true))
                    }
                    Button("К транскрипту") { model.returnToTranscript(turnID: transcriptReturnTurnID) }
                        .buttonStyle(ODButtonStyle(compact: true))
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                if let notice = model.voiceLearningNotice {
                    Text("Имя сохранено. Профиль не обновлён. \(notice)")
                        .font(.system(size: 12)).foregroundStyle(ODColors.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                if compact {
                    if model.voiceListVisible || model.voiceReviewComplete {
                        voiceList
                    } else {
                        detail
                    }
                } else {
                    HStack(spacing: 0) {
                        voiceList.frame(width: geometry.size.width <= 820 ? 196 : 254)
                        Divider()
                        if model.voiceReviewComplete { emptyState }
                        else { detail }
                    }
                }
            }
            .background(ODColors.surface)
        }
        .disclosureGroupStyle(FullWidthDisclosureStyle())
        .onAppear { nameFocused = true }
        .onChange(of: model.voiceSelectionRevision) { _, _ in
            nameFocused = true
            closeSuggestions()
        }
        .onChange(of: model.selectedVoiceID) { _, _ in
            showOtherTurns = false
            closeSuggestions()
        }
        .onExitCommand {
            if suggestionsOpen {
                closeSuggestions()
                return
            }
            model.cancelVoiceInput()
            model.returnToTranscript(turnID: transcriptReturnTurnID)
        }
    }

    private func closeSuggestions() {
        suggestionsOpen = false
        filterSuggestions = false
        highlightedSuggestionID = nil
    }

    private var emptyState: some View {
        Text("Неопознанных голосов нет").font(.system(size: 14)).foregroundStyle(ODColors.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var voiceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            voiceFilter.padding(.horizontal, 12).padding(.top, 12)
            if model.visibleVoiceGroups.isEmpty && model.voiceReviewComplete {
                emptyState
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.visibleVoiceGroups) { group in
                            Button {
                                model.selectVoice(group.id)
                                nameFocused = true
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(group.title).font(.system(size: 14, weight: .semibold))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(status(group)).font(.system(size: 12))
                                            .foregroundStyle(ODColors.muted)
                                        Text("\(source(group.id)) · \(group.rows.count) реплик").font(.system(size: 12))
                                            .foregroundStyle(ODColors.muted)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(model.selectedVoiceID == group.id ? ODColors.selectedInk : ODColors.ink)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedVoiceID == group.id ? ODColors.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).padding(.horizontal, 8)
                            .focused($focusedVoice, equals: group.id)
                            .accessibilityLabel("\(group.originalName), \(group.title), \(source(group.id)), \(group.rows.count) реплик, \(status(group))")
                            .accessibilityAddTraits(model.selectedVoiceID == group.id ? .isSelected : [])
                            .id(group.id)
                        }
                    }.padding(.bottom, 16)
                }
                .onAppear { if let id = model.selectedVoiceID { proxy.scrollTo(id); focusedVoice = id } }
                .onChange(of: model.selectedVoiceID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            }
        }
        .background(ODColors.sidebar)
    }

    private var voiceFilter: some View {
        HStack(spacing: 4) {
            filterButton("Все \(model.voiceGroups.count)", onlyUnrecognized: false)
            filterButton("Неопознанные \(model.voiceGroups.filter { !$0.fullyNamed }.count)", onlyUnrecognized: true)
        }
        .padding(4).frame(maxWidth: .infinity, alignment: .leading)
        .background(ODColors.toolbar, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Показать голоса")
    }

    private func filterButton(_ title: String, onlyUnrecognized: Bool) -> some View {
        let selected = model.showOnlyUnrecognizedVoices == onlyUnrecognized
        return Button { model.setUnrecognizedVoiceFilter(onlyUnrecognized) } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? ODColors.selectedInk : ODColors.muted)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(selected ? ODColors.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var detail: some View {
        ScrollView {
            if let group = model.selectedVoice, let draft = model.voiceDraft,
               let row = group.rows.first(where: { $0.id == draft.anchorTurnID }) {
                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        HStack { turnHeading(row); Spacer(); secondaryAction }
                        VStack(alignment: .leading, spacing: 4) { turnHeading(row); secondaryAction }
                    }
                    Text(row.text).font(.system(size: 16)).lineSpacing(5)
                        .foregroundStyle(ODColors.ink).textSelection(.enabled)
                    if let origin = row.nameOriginLabel {
                        Text("\(row.name) · \(origin)").font(.system(size: 12)).foregroundStyle(ODColors.muted)
                    } else if let refusal = row.voiceRefusal {
                        Text(refusal.label).font(.system(size: 12)).foregroundStyle(ODColors.muted)
                    }
                    fragmentProgress(row)
                    if model.canConfirmSavedVoiceName {
                        Button("Подтвердить имя для обучения") {
                            model.confirmVoiceAssignment(draft, confirmSavedName: true)
                        }
                        .buttonStyle(ODButtonStyle(compact: true))
                        .accessibilityHint("Использовать только эту реплику")
                    } else if model.voiceLearningConfirmedTurnID == row.id {
                        Text("Имя подтверждено. Реплика передана на проверку для обучения.")
                            .font(.system(size: 12)).foregroundStyle(ODColors.muted)
                    }
                    Divider()
                    assignment
                    if group.rows.count > 1 {
                        Divider()
                        DisclosureGroup("Другие реплики · \(group.rows.count - 1)", isExpanded: $showOtherTurns) {
                            ForEach(group.rows.filter { $0.id != row.id }) { other in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { fragmentButton(other); Spacer(); contextLink(other) }
                                    Button {
                                        model.selectVoice(group.id, anchorTurnID: other.id, scope: .single)
                                    } label: {
                                        Text(other.text).font(.system(size: 14)).multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Выбрать реплику для назначения имени")
                                    fragmentProgress(other)
                                }.padding(.vertical, 8)
                            }
                        }.font(.system(size: 13))
                    }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func turnHeading(_ row: TranscriptReviewWindowModel.Row) -> some View {
        HStack {
            Text("Реплика").font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
            fragmentButton(row)
            contextLink(row)
        }
    }

    @ViewBuilder private func fragmentProgress(_ row: TranscriptReviewWindowModel.Row) -> some View {
        if model.fragmentTurnID == row.id {
            let duration = min(row.end, model.playbackDuration) - row.start
            let elapsed = min(duration, max(0, model.playbackPosition - row.start))
            let elapsedText = formatClock(elapsed.rounded(.down))
            let durationText = formatClock(duration.rounded(.down))
            HStack(spacing: 8) {
                ProgressView(value: elapsed, total: max(0.001, duration))
                    .progressViewStyle(FragmentProgressStyle()).frame(width: 120)
                    .accessibilityLabel("Прослушивание фрагмента")
                    .accessibilityValue("\(elapsedText) из \(durationText)")
                Text("\(elapsedText) / \(durationText)")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(ODColors.muted)
                    .accessibilityHidden(true)
            }
        }
    }

    private struct FragmentProgressStyle: ProgressViewStyle {
        func makeBody(configuration: Configuration) -> some View {
            GeometryReader { geometry in
                Capsule().fill(ODColors.segmentProgressTrack)
                    .overlay(alignment: .leading) {
                        Capsule().fill(ODColors.segmentProgressFill)
                            .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                    }
            }
            .frame(height: 2)
            .frame(height: 3)
        }
    }

    private func fragmentButton(_ row: TranscriptReviewWindowModel.Row) -> some View {
        Button {
            Task { await model.playVoiceTurn(row.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.fragmentTurnID == row.id && model.playbackState == .playing ? "pause" : "play")
                    .frame(width: 12)
                Text(formatClock(row.start)).monospacedDigit()
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(ODColors.accent).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(!model.playbackEnabled || row.end <= row.start || row.start >= model.playbackDuration)
        .accessibilityLabel((model.fragmentTurnID == row.id && model.playbackState == .playing ? "Пауза, " : "Прослушать фрагмент с ") + formatClock(row.start))
        .help(model.playbackMessage ?? (row.end <= row.start ? "У реплики нет доступного аудиоинтервала." : "Микс текущего результата, включая перекрытия голосов"))
    }

    private func contextLink(_ row: TranscriptReviewWindowModel.Row) -> some View {
        Button("В транскрипте") {
            model.returnToTranscript(turnID: row.id)
            if !model.voiceReviewVisible { onTranscriptJump() }
        }
        .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(ODColors.muted)
    }

    private var assignment: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let draft = model.voiceDraft {
                let allSections = model.voiceNameSuggestionSections(query: "")
                let sections = model.voiceNameSuggestionSections(query: filterSuggestions ? draft.inputName : "")
                let flatSuggestions = sections.flatMap(\.items)
                let trimmedInput = draft.inputName.trimmingCharacters(in: .whitespacesAndNewlines)
                let canCreatePerson = model.voiceIdentityActions != nil && !trimmedInput.isEmpty
                let hasComboboxOptions = !allSections.isEmpty || model.voiceIdentityActions != nil
                let navigableIDs = flatSuggestions.map(\.id) + (canCreatePerson ? [Self.createPersonOptionID] : [])

                Text("Имя участника").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                    TextField("Найти или добавить человека", text: Binding(
                        get: { model.voiceDraft?.inputName ?? "" },
                        set: { newValue in
                            guard let current = model.voiceDraft?.inputName,
                                  !newValue.utf8.elementsEqual(current.utf8) else { return }
                            model.updateVoiceName(newValue)
                            filterSuggestions = true
                            suggestionsOpen = true
                            highlightedSuggestionID = nil
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded {
                        guard !model.voiceRequiresReopen else { return }
                        nameFocused = true
                        filterSuggestions = false
                        suggestionsOpen = true
                        highlightedSuggestionID = nil
                    })
                    .accessibilityLabel("Имя участника")
                    .focused($nameFocused)
                    .disabled(model.voiceRequiresReopen)
                    .onSubmit {
                        if suggestionsOpen {
                            if highlightedSuggestionID == Self.createPersonOptionID, canCreatePerson {
                                model.selectVoicePerson(nil)
                                closeSuggestions()
                                return
                            }
                            if let target = flatSuggestions.first(where: { $0.id == highlightedSuggestionID }) {
                                model.selectVoiceSuggestion(target)
                                closeSuggestions()
                                return
                            }
                        }
                        closeSuggestions()
                        if model.canConfirmVoice, let draft = model.voiceDraft {
                            model.confirmVoiceAssignment(draft)
                        }
                    }

                    if case .confirmed = draft.person {
                        Image(systemName: "waveform")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ODColors.accent)
                            .help("Сохранённый профиль голоса")
                            .accessibilityLabel("Сохранённый профиль голоса")
                    }
                    if !draft.inputName.isEmpty && !model.voiceRequiresReopen {
                        Button {
                            model.updateVoiceName("")
                            filterSuggestions = false
                            suggestionsOpen = true
                            highlightedSuggestionID = nil
                            nameFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(ODColors.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Очистить имя")
                    }
                    if hasComboboxOptions {
                        Button {
                            nameFocused = true
                            if suggestionsOpen {
                                closeSuggestions()
                            } else {
                                filterSuggestions = false
                                suggestionsOpen = true
                                highlightedSuggestionID = nil
                            }
                        } label: {
                            Image(systemName: suggestionsOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ODColors.muted)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.voiceRequiresReopen)
                        .accessibilityLabel(suggestionsOpen ? "Скрыть список участников" : "Показать список участников")
                    }
                }
                .odInput()
                .onKeyPress(.downArrow) {
                    guard !model.voiceRequiresReopen else { return .ignored }
                    if !suggestionsOpen {
                        let initialSections = model.voiceNameSuggestionSections(query: "")
                        let initialIDs = initialSections.flatMap(\.items).map(\.id) + (canCreatePerson ? [Self.createPersonOptionID] : [])
                        guard !initialIDs.isEmpty else { return .ignored }
                        filterSuggestions = false
                        suggestionsOpen = true
                        highlightedSuggestionID = Self.nextHighlightedSuggestionID(current: nil, in: initialIDs, step: 1)
                        return .handled
                    }
                    guard !navigableIDs.isEmpty else { return .ignored }
                    highlightedSuggestionID = Self.nextHighlightedSuggestionID(current: highlightedSuggestionID, in: navigableIDs, step: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard suggestionsOpen, !navigableIDs.isEmpty else { return .ignored }
                    highlightedSuggestionID = Self.nextHighlightedSuggestionID(current: highlightedSuggestionID, in: navigableIDs, step: -1)
                    return .handled
                }

                if suggestionsOpen && !model.voiceRequiresReopen && (!sections.isEmpty || canCreatePerson) {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(sections) { section in
                                    Text(section.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(ODColors.muted)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 8)
                                        .padding(.bottom, 4)
                                    ForEach(section.items) { item in
                                        let isHighlighted = highlightedSuggestionID == item.id
                                        Button {
                                            model.selectVoiceSuggestion(item)
                                            closeSuggestions()
                                            nameFocused = true
                                        } label: {
                                            HStack(spacing: 8) {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(item.displayName)
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundStyle(ODColors.ink)
                                                        .lineLimit(1)
                                                    if let subtitle = item.subtitle {
                                                        Text(subtitle)
                                                            .font(.system(size: 11))
                                                            .foregroundStyle(ODColors.muted)
                                                            .lineLimit(1)
                                                    }
                                                }
                                                Spacer(minLength: 8)
                                                suggestionIcon(for: item)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(isHighlighted ? ODColors.selected : Color.clear,
                                                        in: RoundedRectangle(cornerRadius: 6))
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .id(item.id)
                                    }
                                }
                                if canCreatePerson {
                                    if !sections.isEmpty {
                                        Divider().padding(.vertical, 4)
                                    }
                                    let isCreateHighlighted = highlightedSuggestionID == Self.createPersonOptionID
                                    Button {
                                        model.selectVoicePerson(nil)
                                        closeSuggestions()
                                        nameFocused = true
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "plus.circle")
                                                .font(.system(size: 12))
                                                .foregroundStyle(ODColors.accent)
                                            Text("Создать человека «\(trimmedInput)»")
                                                .font(.system(size: 13))
                                                .foregroundStyle(ODColors.ink)
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(isCreateHighlighted ? ODColors.selected : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(Self.createPersonOptionID)
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 220)
                        .onChange(of: highlightedSuggestionID) { _, id in
                            if let id {
                                scrollProxy.scrollTo(id)
                            }
                        }
                    }
                    .background(ODColors.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ODColors.line))
                }

                if model.voiceIdentityActions != nil,
                   let personID = model.selectedVoice?.rows.first(where: { $0.id == draft.anchorTurnID })?.personID,
                   let person = model.voicePeople.first(where: { $0.id == personID }),
                   !model.voiceCalendarContacts.isEmpty {
                    Menu("Привязать контакт к \(person.displayName)") {
                        ForEach(model.voiceCalendarContacts, id: \.address) { contact in
                            Button(contact.address) {
                                model.confirmVoiceCalendarBinding(contact.address, personID: personID)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if !draft.inputName.allSatisfy(\.isWhitespace) || draft.isDirty {
                    Picker("Область", selection: Binding(get: { model.voiceDraft?.scope ?? .group }, set: model.setVoiceScope)) {
                        Text("Только эта реплика").tag(TranscriptNameAssignmentScope.single)
                        Text("Эта и следующие").tag(TranscriptNameAssignmentScope.remaining)
                        Text("Вся группа").tag(TranscriptNameAssignmentScope.group)
                    }.disabled(model.voiceRequiresReopen)
                    if let preview = draft.preview, preview.confirmedName != nil {
                        let protected = preview.replacedTurnIDs.count
                        if protected > 0 && draft.scope != .single {
                            Toggle("Заменить ранее назначенные имена (\(protected))", isOn: Binding(
                                get: { model.voiceDraft?.replaceManual ?? false }, set: model.setVoiceReplaceManual))
                                .toggleStyle(.checkbox)
                        }
                        if model.canConfirmVoice {
                            Text("Изменится \(preview.affectedTurnsCount) из \(preview.totalTurnsInGroup) реплик")
                                .font(.system(size: 12)).foregroundStyle(ODColors.muted)
                            DisclosureGroup("Затронутые реплики") {
                                ForEach(model.selectedVoice?.rows.filter { preview.affectedTurnIDs.contains($0.id) } ?? []) { row in
                                    Text("\(formatClock(row.start)) · \(row.text)")
                                        .font(.system(size: 12)).lineLimit(2)
                                }
                            }.font(.system(size: 12))
                        }
                    }
                    if model.canConfirmVoice {
                        Button("Применить") {
                            closeSuggestions()
                            model.confirmVoiceAssignment(draft)
                        }
                            .buttonStyle(ODButtonStyle(primary: true))
                    }
                }
                if model.isVoiceDraftDirty || model.error != nil {
                    Button("Отменить правку") {
                        closeSuggestions()
                        model.cancelVoiceInput()
                        nameFocused = true
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ODColors.accent)
                }
            }
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(ODColors.red).textSelection(.enabled) }
            if let message = model.playbackMessage { Text(message).font(.system(size: 11)).foregroundStyle(ODColors.muted) }
        }
    }

    @ViewBuilder
    private func suggestionIcon(for item: TranscriptReviewWindowModel.VoiceNameSuggestion) -> some View {
        if item.isVoiceReady {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ODColors.accent)
                .help("Голос распознан (профиль готов)")
                .accessibilityLabel("Профиль голоса готов")
        } else if item.hasSavedProfile {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12))
                .foregroundStyle(ODColors.muted)
                .help("Сохранённый человек (набираются образцы голоса)")
                .accessibilityLabel("Сохранённый человек")
        }
        if item.isCalendarAttendee {
            Image(systemName: "calendar")
                .font(.system(size: 11))
                .foregroundStyle(ODColors.muted)
                .help("Из календаря встречи")
                .accessibilityLabel("Из календаря")
        }
    }

    private var secondaryAction: some View {
        Button("Следующий голос", action: model.nextVoice)
            .buttonStyle(ODButtonStyle(compact: true))
            .disabled(model.visibleVoiceGroups.count < 2)
    }

    private func source(_ voice: TranscriptVoiceKey) -> String { TranscriptDocument.localizedSourceLabel(for: voice.sourceID) }

    private func status(_ group: TranscriptReviewWindowModel.VoiceGroup) -> String {
        if group.mixedNames { return "Разные имена" }
        if !group.fullyNamed { return "Нужно имя" }
        let origins = Set(group.rows.compactMap(\.nameOriginLabel))
        return origins.count == 1 ? origins.first ?? "Имя назначено" : "Имя назначено"
    }
}
