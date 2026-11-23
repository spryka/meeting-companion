import SwiftUI
import MeetingCompanionCore

struct VoiceSettingsView: View {
    @ObservedObject var model: RecorderViewModel
    @State private var catalogue: VoiceProfileCatalogue?
    @State private var catalogueBytes = 0
    @State private var selection: UUID?
    @State private var narrowDetail = false
    @State private var search = ""
    @State private var error: String?
    @State private var confirmation: Removal?
    private var modelReady: Bool { model.voiceModelStatus == .ready }

    private enum Removal: Identifiable {
        case samples(UUID), person(UUID), catalogue
        var id: String {
            switch self {
            case .samples(let id): "samples-\(id)"
            case .person(let id): "person-\(id)"
            case .catalogue: "catalogue"
            }
        }
        var title: String {
            switch self {
            case .samples: "Сбросить обучение?"
            case .person: "Удалить человека?"
            case .catalogue: "Удалить базу голосов?"
            }
        }
        var action: String {
            switch self {
            case .samples: "Сбросить обучение"
            case .person: "Удалить человека"
            case .catalogue: "Удалить базу голосов"
            }
        }
        var message: String {
            switch self {
            case .samples: "Эталоны и календарные привязки этого человека будут удалены. Карточка и имена в записях сохранятся."
            case .person: "Карточка, привязки и эталоны этого человека будут удалены. Имена в записях сохранятся."
            case .catalogue: "Все люди, привязки и эталоны будут удалены. Записи и расшифровки сохранятся."
            }
        }
    }

    private var people: [VoiceProfilePerson] {
        (catalogue?.people ?? []).filter { person in
            search.isEmpty || person.displayName.localizedCaseInsensitiveContains(search) ||
                person.calendarBindings.contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if $0.calendarBindings.isEmpty != $1.calendarBindings.isEmpty { return !$0.calendarBindings.isEmpty }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Запоминать голоса", isOn: $model.voiceIdentityEnabled).toggleStyle(.switch)
            if !model.automaticVoiceNamesAvailable {
                Text("Автоимена станут доступны после калибровки.")
                    .font(.system(size: 12)).foregroundStyle(ODColors.muted)
            }
            HStack {
                Text(model.voiceModelStatus.title)
                Spacer()
                if !modelReady {
                    Button("Подготовить модель") { model.checkVoiceModel(prepare: true) }
                        .disabled(model.preventsSettingsOperation)
                }
            }.padding(12).background(ODColors.toolbar, in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled) }
            profileBrowser
        }
        .task { model.checkVoiceModel(prepare: false) }
        .task(id: [model.voiceJobs, model.voiceCatalogueUpdate]) { await reload() }
        .alert(item: $confirmation) { removal in
            Alert(title: Text(removal.title), message: Text(removal.message),
                  primaryButton: .destructive(Text(removal.action)) {
                    Task { await remove(removal) }
                  }, secondaryButton: .cancel(Text("Отмена")))
        }
    }

    private var profileBrowser: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    list.frame(minWidth: 235, maxWidth: 300)
                    detail.frame(minWidth: 290, maxWidth: .infinity, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if narrowDetail, selection != nil {
                        Button("К списку голосов") { narrowDetail = false }
                        detail
                    } else {
                        list
                    }
                }
            }
            if catalogue?.people.isEmpty == false {
                Text("На диске: \(ByteCountFormatter.string(fromByteCount: Int64(catalogueBytes), countStyle: .file))")
                    .font(.system(size: 12)).foregroundStyle(ODColors.muted)
                Button("Удалить базу голосов", role: .destructive) { confirmation = .catalogue }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Найти человека", text: $search).textFieldStyle(.roundedBorder)
            if catalogue != nil && people.isEmpty {
                Text(search.isEmpty ? "Голосовых профилей пока нет" : "Никого не найдено")
                    .font(.system(size: 12)).foregroundStyle(ODColors.muted)
            }
            ForEach(people) { person in
                Button {
                    selection = person.id
                    narrowDetail = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.displayName).fontWeight(.medium)
                        if let contact = person.calendarBindings.first {
                            Text(contact).font(.system(size: 12)).foregroundStyle(ODColors.muted)
                        }
                        Text(status(for: person.id)).font(.system(size: 12)).foregroundStyle(ODColors.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(selection == person.id ? ODColors.selected : ODColors.toolbar, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == person.id ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let person = catalogue?.people.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 9) {
                Text(person.displayName).font(.system(size: 17, weight: .semibold))
                Text(status(for: person.id)).font(.system(size: 12)).foregroundStyle(ODColors.muted)
                if !person.calendarBindings.isEmpty {
                    Text(person.calendarBindings.joined(separator: ", ")).font(.system(size: 12)).textSelection(.enabled)
                }
                if let record = latestUpdate(for: person.id), let outcome = record.outcome {
                    if record.stage == .committed && isReady(person.id) {
                        Text("Ранее сохранённый профиль доступен").font(.system(size: 12)).foregroundStyle(ODColors.muted)
                    }
                    Text(outcome).font(.system(size: 12)).foregroundStyle(ODColors.muted).textSelection(.enabled)
                }
                Button("Сбросить обучение") { confirmation = .samples(person.id) }
                Button("Удалить человека", role: .destructive) { confirmation = .person(person.id) }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(ODColors.toolbar, in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text("Выберите человека").font(.system(size: 12)).foregroundStyle(ODColors.muted)
        }
    }

    private func status(for id: UUID) -> String {
        if let record = latestUpdate(for: id), record.stage == .committed {
            if record.outcome != nil { return "Не удалось обновить" }
            if model.voiceJobs > 0 { return "Обновляется" }
        }
        if let aggregate = catalogue?.availableAggregates.first(where: { $0.personID == id }) {
            if aggregate.embeddingSpaceID != VoiceEmbeddingProtocol.embeddingSpaceID { return "Нужно обновить профиль" }
            return "Готов"
        }
        return "Недостаточно речи"
    }

    private func isReady(_ id: UUID) -> Bool {
        catalogue?.availableAggregates.contains { $0.personID == id && $0.embeddingSpaceID == VoiceEmbeddingProtocol.embeddingSpaceID } == true
    }

    private func latestUpdate(for id: UUID) -> VoiceProfileLearningRecord? {
        catalogue?.latestLearningUpdate(for: id)
    }

    private func reload() async {
        let repo = model.voiceLearning.catalogue
        do {
            let result = try await Task.detached { try repo.load() }.value
            guard !Task.isCancelled else { return }
            catalogue = result.catalogue
            catalogueBytes = result.sizeInBytes
            if selection == nil || !result.catalogue.people.contains(where: { $0.id == selection }) {
                selection = people.first?.id
                narrowDetail = false
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func remove(_ removal: Removal) async {
        let coordinator = model.voiceLearning
        do {
            try await Task.detached {
                switch removal {
                case .samples(let person): try coordinator.resetPerson(person, delete: false)
                case .person(let person): try coordinator.resetPerson(person, delete: true)
                case .catalogue: try coordinator.deleteCatalogue()
                }
            }.value
            error = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
