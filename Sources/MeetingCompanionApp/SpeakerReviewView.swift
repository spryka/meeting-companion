import SwiftUI
import MeetingCompanionCore

struct SpeakerReviewView: View {
    @ObservedObject var model: TranscriptReviewWindowModel
    @State private var detailHeaderHeight: CGFloat = 0
    @State private var assignmentHeight: CGFloat = 0
    @FocusState private var headingFocused: Bool
    @FocusState private var focusedVoice: TranscriptVoiceKey?
    @AccessibilityFocusState private var accessibleHeading: Bool

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width <= 640
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) { heading; Spacer(minLength: 0); progress }
                    VStack(alignment: .leading, spacing: 8) { heading; progress }
                }
                .padding(geometry.size.width <= 760 ? 16 : 24)
                Divider()
                if model.voiceReviewComplete {
                    completion
                } else if compact {
                    if model.voiceListVisible { voiceList }
                    else { detail(compact: true) }
                } else {
                    HStack(spacing: 0) {
                        voiceList.frame(width: geometry.size.width <= 820 ? 180 : 212)
                        Divider()
                        detail(compact: false)
                    }
                }
                Divider()
                Text("Календарь предлагает имена; голос выбираете вы")
                    .font(.system(size: 11)).foregroundStyle(ODColors.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(10)
            }
            .background(ODColors.surface)
        }
        .onAppear { focusHeading() }
        .onChange(of: model.selectedVoiceID) { _, _ in focusHeading() }
        .onChange(of: model.voiceReviewComplete) { _, _ in focusHeading() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Назначить имена")
                .font(.system(size: 25, weight: .semibold)).tracking(-0.6)
                .foregroundStyle(ODColors.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Прослушайте голос и укажите, кому он принадлежит")
                .font(.system(size: 13)).foregroundStyle(ODColors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progress: some View {
        Text("Разобрано \(model.reviewedVoiceCount) из \(model.voiceGroups.count)")
            .font(.system(size: 13)).foregroundStyle(ODColors.muted)
            .fixedSize().accessibilityLabel("Разобрано \(model.reviewedVoiceCount) из \(model.voiceGroups.count) говорящих")
    }

    private var voiceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ГОВОРЯЩИЕ · \(model.voiceGroups.count)")
                .font(.system(size: 12)).foregroundStyle(ODColors.muted).padding(.horizontal, 16).padding(.top, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(model.voiceGroups.enumerated()), id: \.element.id) { index, group in
                            Button {
                                model.selectVoice(group.id)
                                if model.selectedVoiceID == group.id, !model.isVoiceDraftDirty { focusHeading() }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                        .foregroundStyle(model.selectedVoiceID == group.id ? ODColors.accent : ODColors.muted)
                                        .frame(width: 32, height: 32)
                                        .background(ODColors.surface, in: Circle())
                                        .overlay(Circle().stroke(model.selectedVoiceID == group.id ? ODColors.accent : ODColors.line))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(group.title).font(.system(size: 14, weight: .semibold))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text("\(source(group.id)) · \(group.rows.count) реплик").font(.system(size: 11)).foregroundStyle(ODColors.muted)
                                        Text(status(group)).font(.system(size: 11))
                                            .foregroundStyle(group.fullyNamed ? ODColors.green : ODColors.muted)
                                        if let first = group.rows.first, first.start >= 3600 {
                                            Text("Первый раз в " + formatClock(first.start))
                                                .font(.system(size: 11)).foregroundStyle(ODColors.muted)
                                        }
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
            }
        }
        .background(ODColors.sidebar)
    }

    private func detail(compact: Bool) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    detailHeader(compact: compact)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailHeaderHeight = $0 }
                    turns(padding: compact ? 16 : 24)
                        .frame(height: max(120, geometry.size.height - detailHeaderHeight - assignmentHeight))
                    assignment(padding: compact ? 16 : 24, stackActions: geometry.size.width <= 760)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { assignmentHeight = $0 }
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailHeader(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if compact {
                Button("‹ Все говорящие") {
                    if model.requestVoiceList() {
                        focusedVoice = model.selectedVoiceID
                    }
                }
                .buttonStyle(.plain).foregroundStyle(ODColors.accent).font(.system(size: 13))
                .padding(.vertical, 6)
            }
            if let group = model.selectedVoice {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(.system(size: 24, weight: .semibold)).tracking(-0.4)
                            .fixedSize(horizontal: false, vertical: true)
                            .focusable().focused($headingFocused).accessibilityFocused($accessibleHeading)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(group.originalName) · \(source(group.id))")
                            .font(.system(size: 12)).foregroundStyle(ODColors.muted)
                    }
                    Spacer(minLength: 0)
                    let step = (model.voiceGroups.firstIndex { $0.id == group.id } ?? 0) + 1
                    Text("\(step) / \(model.voiceGroups.count)").font(.system(size: 13)).foregroundStyle(ODColors.muted).fixedSize()
                }
                Text("Все реплики этого голоса за встречу — от первой до последней.")
                    .font(.system(size: 13)).foregroundStyle(ODColors.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 16 : 24)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func turns(padding: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(model.selectedVoice?.rows.count ?? 0) реплик · по времени встречи")
                .font(.system(size: 12)).foregroundStyle(ODColors.muted).padding(.horizontal, padding).padding(.top, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.selectedVoice?.rows ?? []) { row in
                        VStack(alignment: .leading, spacing: 10) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { fragmentButton(row); Text(row.name).font(.system(size: 12)).foregroundStyle(ODColors.muted); Spacer(minLength: 0); contextLink(row) }
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { fragmentButton(row); Spacer(); contextLink(row) }
                                    Text(row.name).font(.system(size: 12)).foregroundStyle(ODColors.muted)
                                }
                            }
                            Text(row.text).font(.system(size: 16)).lineSpacing(5)
                                .foregroundStyle(ODColors.ink).textSelection(.enabled)
                            if model.fragmentTurnID == row.id {
                                let duration = min(row.end, model.playbackDuration) - row.start
                                let elapsed = min(duration, max(0, model.playbackPosition - row.start))
                                let elapsedText = formatClock(elapsed.rounded(.down))
                                let durationText = formatClock(duration.rounded(.down))
                                HStack(spacing: 8) {
                                    ProgressView(value: elapsed, total: max(0.001, duration))
                                        .progressViewStyle(FragmentProgressStyle())
                                        .frame(width: 120)
                                        .accessibilityLabel("Прослушивание фрагмента")
                                        .accessibilityValue("\(elapsedText) из \(durationText)")
                                    Text("\(elapsedText) / \(durationText)")
                                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(ODColors.muted)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                        .background(model.fragmentTurnID == row.id ? ODColors.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }.padding(.horizontal, padding)
            }.id(model.selectedVoiceID)
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
        Button("В транскрипте") { model.returnToTranscript(turnID: row.id) }
            .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(ODColors.muted)
            .help(model.isVoiceDraftDirty ? "Сначала сохраните или отмените ввод имени." : "Показать реплику в полном тексте")
    }

    private func assignment(padding: CGFloat, stackActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let draft = model.voiceDraft {
                HStack(spacing: 8) {
                    Text("Кто это?").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    if !model.availableCalendarNames.isEmpty {
                        Text("Подсказки из календаря").font(.system(size: 12)).foregroundStyle(ODColors.muted)
                    }
                }
                if model.availableCalendarNames.isEmpty {
                    Text("Нет свободных подсказок из календаря. Введите имя вручную.")
                        .font(.system(size: 12)).foregroundStyle(ODColors.muted)
                } else {
                    ODWrappingChips {
                        ForEach(model.availableCalendarNames, id: \.self) { name in
                            Button(name) { model.updateVoiceName(name) }.buttonStyle(ODButtonStyle(compact: true))
                        }
                    }
                }
                TextField("Выберите имя или введите своё", text: Binding(get: { model.voiceDraft?.inputName ?? "" }, set: model.updateVoiceName))
                    .odInput().accessibilityLabel("Кто это? Имя говорящего")
                    .disabled(model.voiceRequiresReopen)
                    .onSubmit { if model.canConfirmVoice, let draft = model.voiceDraft { model.confirmVoiceAssignment(draft) } }
                let manual = model.selectedVoice?.rows.filter(\.hasManualName).count ?? 0
                if manual > 0 {
                    Toggle("Заменить ранее назначенные имена (\(manual))", isOn: Binding(get: { model.voiceDraft?.replaceManual ?? false }, set: model.setVoiceReplaceManual))
                        .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(ODColors.muted)
                        .disabled(model.voiceRequiresReopen)
                }
                Text(draft.inputName.isEmpty
                     ? "Выбрана группа: \(model.selectedVoice?.rows.count ?? 0) реплик."
                     : "Изменится \(model.voiceChangesCount) из \(model.selectedVoice?.rows.count ?? 0) реплик."
                        + (manual > 0 && !draft.replaceManual ? " Ранее назначенные имена сохранятся." : ""))
                    .font(.system(size: 12)).foregroundStyle(ODColors.muted)
                if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(ODColors.red).textSelection(.enabled) }
                if let message = model.playbackMessage { Text(message).font(.system(size: 11)).foregroundStyle(ODColors.muted) }
                if stackActions { VStack(spacing: 12) { assignAction; secondaryAction } }
                else { HStack(spacing: 12) { secondaryAction; Spacer(minLength: 0); assignAction } }
                if model.isVoiceDraftDirty || model.error != nil {
                    Button(model.voiceRequiresReopen ? "Отменить ввод и закрыть сеанс" : "Отменить ввод", action: model.cancelVoiceInput)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ODColors.accent)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(padding)
        .background(ODColors.toolbar).overlay(alignment: .top) { Divider() }
    }

    private var assignAction: some View {
        Button { if let draft = model.voiceDraft { model.confirmVoiceAssignment(draft) } } label: {
            Text(model.voiceDraft?.replaceManual == true ? "Заменить и перейти к следующему →" : "Назначить и перейти к следующему →")
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
        }
        .buttonStyle(ODButtonStyle(primary: true)).disabled(!model.canConfirmVoice)
    }

    private var secondaryAction: some View {
        let group = model.selectedVoice
        let reviewed = group.map { $0.fullyNamed || model.reviewedVoices.contains($0.id) } ?? false
        return Button(reviewed ? "Следующий" : "Пропустить", action: model.skipVoice)
            .buttonStyle(.plain).font(.system(size: 14, weight: .medium))
            .disabled(model.isVoiceDraftDirty)
            .help(model.isVoiceDraftDirty ? "Сначала сохраните или отмените ввод имени." : "Перейти без записи")
    }

    private var completion: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Все голоса просмотрены").font(.system(size: 13)).foregroundStyle(ODColors.muted)
                Text("Разбор завершён").font(.system(size: 28, weight: .semibold))
                    .focusable().focused($headingFocused).accessibilityFocused($accessibleHeading).accessibilityAddTraits(.isHeader)
                Text("Проверено \(model.voiceGroups.count - model.skippedVoices.count) голосов, пропущено \(model.skippedVoices.count). Вы можете вернуться к любому голосу и изменить имя.")
                    .font(.system(size: 14)).foregroundStyle(ODColors.muted)
                ViewThatFits(in: .horizontal) {
                    HStack { returnButton; listButton }
                    VStack(alignment: .leading) { returnButton; listButton }
                }
            }.padding(32).frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
        }
        }
    }

    private var returnButton: some View { Button("Вернуться к транскрипту") { model.returnToTranscript() }.buttonStyle(ODButtonStyle(primary: true)) }
    private var listButton: some View {
        Button("Посмотреть список") {
            if let selected = model.selectedVoiceID { model.selectVoice(selected) }
            _ = model.requestVoiceList()
        }.buttonStyle(.plain).padding(8)
    }
    private func source(_ voice: TranscriptVoiceKey) -> String { TranscriptDocument.localizedSourceLabel(for: voice.sourceID) }
    private func status(_ group: TranscriptReviewWindowModel.VoiceGroup) -> String {
        if model.skippedVoices.contains(group.id) { return "Пропущен" }
        if group.fullyNamed || model.reviewedVoices.contains(group.id) { return group.mixedNames ? "Разные имена" : "Имя назначено" }
        return "Не назначен"
    }
    private func focusHeading() { headingFocused = true; accessibleHeading = true }
}
