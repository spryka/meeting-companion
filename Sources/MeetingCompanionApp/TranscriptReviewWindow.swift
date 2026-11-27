import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if !TRANSCRIPT_WINDOW_HARNESS
import MeetingCompanionCore
import MeetingCompanionPlatform
#endif

@MainActor
struct VoiceIdentityEditActions {
    let people: () -> [VoiceProfilePerson]
    let selectPerson: (UUID?, String) throws -> TranscriptPersonSelection
    let confirmCalendarBinding: (UUID, String, TranscriptDocument) throws -> Void
    let isEnabled: () -> Bool
    let learningFailure: (URL) -> String?
    var resolveTypedPerson: ((String) throws -> TranscriptVoicePersonIntent?)? = nil
    var readyPersonIDs: (() -> Set<UUID>)? = nil
}

@MainActor
final class TranscriptReviewWindowManager: ObservableObject {
    let coordinator: TranscriptWindowCoordinator
    private let isProcessing: @Sendable (URL) async -> Bool
    private let transportFactory: @MainActor () -> any TranscriptPlaybackTransport
    var voiceIdentityActions: VoiceIdentityEditActions?
    @Published private(set) var current: TranscriptReviewWindowModel?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published var externalModal = false {
        didSet { if externalModal { current?.invalidateQueuedPlaybackSeek() } }
    }
    var settingsInput: @MainActor () -> Bool = { false }
    var trashInput: @MainActor () -> Bool = { false }
    var nativeInput: @MainActor () -> Bool = { false }
    var retentionInProgress: @MainActor (URL) -> Bool = { _ in false }
    @Published var savedRevision = 0
    @Published private(set) var commandNotice: String?
    private var generation = 0
    private var opening: Task<TranscriptReviewWindowModel, Error>?
    private var openingURL: URL?
    var hasForeignInput: Bool { trashInput() || externalModal || current?.currentDraftIdentity != nil }
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
         learningCommitObserver: TranscriptEditsRepository.LearningCommitObserver? = nil,
         transportFactory: @escaping @MainActor () -> any TranscriptPlaybackTransport = { TranscriptAVPlayerTransport() }) {
        self.isProcessing = isProcessing
        self.coordinator = TranscriptWindowCoordinator(learningCommitObserver: learningCommitObserver)
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
        try await open(recordingURL: recordingURL, title: title, ownTrashModal: { false })
    }

    func prepareForTrash(_ recording: URL, ownsModal: @MainActor () -> Bool) async -> Bool {
        guard ownsModal(), !settingsInput(), !nativeInput(), !externalModal, current?.currentDraftIdentity == nil else { return false }
        generation += 1
        let expected = generation
        _ = try? await opening?.value
        guard expected == generation, ownsModal(), !settingsInput(), !nativeInput(), !externalModal,
              current?.currentDraftIdentity == nil else { return false }
        opening = nil; openingURL = nil; loading = false
        if current?.state.id == RecordingEntry.canonicalURL(recording) { closeLoadedSession() }
        return true
    }

    func reopenAfterFailedTrash(recordingURL: URL, title: String, ownsModal: @escaping @MainActor () -> Bool) async throws -> TranscriptReviewWindowModel {
        try await open(recordingURL: recordingURL, title: title, ownTrashModal: ownsModal)
    }

    private func open(recordingURL: URL, title: String, ownTrashModal: @escaping @MainActor () -> Bool) async throws -> TranscriptReviewWindowModel {
        func admitted() -> Bool {
            guard !retentionInProgress(RecordingEntry.canonicalURL(recordingURL)) else { return false }
            if ownTrashModal(), trashInput(), !settingsInput(), !nativeInput(), !externalModal, current?.currentDraftIdentity == nil { return true }
            return admitNavigation()
        }
        let key = RecordingEntry.canonicalURL(recordingURL)
        guard !retentionInProgress(key) else { throw TranscriptEditsError.conflict("Выполняется автоочистка записи.") }
        guard admitted() else { throw TranscriptEditsError.conflict("Сохраните или отмените ввод.") }
        if openingURL == key, let opening { return try await opening.value }
        generation += 1
        let expected = generation
        let reusesCurrent = current.map { $0.state.id == key && !$0.state.isClosed } ?? false
        loading = !reusesCurrent
        defer {
            if expected == generation { loading = false; opening = nil; openingURL = nil }
        }
        guard !(await isProcessing(key)) else { throw TranscriptWindowError.readOnlyLegacy("Идёт обработка; откройте текст после её завершения.") }
        guard expected == generation else { throw TranscriptWindowError.closed }
        guard admitted() else { throw TranscriptEditsError.conflict("Сохраните или отмените ввод.") }
        if let current, current.state.id == key, !current.state.isClosed { return current }
        loading = true
        let previous = opening
        failure = nil; openingURL = key
        let task = Task { [self] in
            _ = try? await previous?.value
            guard expected == generation, admitted() else { throw TranscriptWindowError.closed }
            closeLoadedSession()
            let state = try await coordinator.openWindow(for: key).state
            do {
                let model = try await TranscriptReviewWindowModel(state: state, transportFactory: transportFactory)
                model.inputBlocked = { [weak self] in
                    guard let self else { return true }
                    return self.settingsInput() || self.trashInput() || self.externalModal
                }
                let processing = await isProcessing(key)
                guard expected == generation, admitted(), !state.isClosed, !processing else {
                    model.close(); throw TranscriptWindowError.closed
                }
                model.onSaved = { [weak self] in self?.savedRevision += 1 }
                model.onStaleVoiceSession = { [weak self, weak model] in
                    guard let self, let model, self.current === model else { return }
                    self.closeCurrent()
                    self.failure = "Расшифровка изменилась. Выберите запись снова."
                }
                model.voiceIdentityActions = voiceIdentityActions
                current = model
                return model
            } catch { state.close(); throw error }
        }
        opening = task
        do {
            let model = try await task.value
            return model
        } catch {
            if expected == generation { failure = error.localizedDescription }
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
    var voiceIdentityActions: VoiceIdentityEditActions?
    struct Row: Identifiable, Sendable {
        let id: String
        let start: Double
        let end: Double
        let originalName: String
        let name: String
        let text: String
        let editText: String
        let speakerID: String
        let sourceID: TranscriptDocument.SourceID
        let localID: Int
        let hasManualName: Bool
        let hasSavedName: Bool
        let nameOrigin: String?
        let personID: UUID?
        let voiceRefusal: TranscriptVoiceRefusal?
        var nameOriginLabel: String? {
            guard hasSavedName else { return nil }
            switch nameOrigin {
            case "automaticVoiceMatch", "derivedVoiceMatch": return "Автоимя"
            case "manual": return "Вручную"
            default: return "Имя сохранено"
            }
        }

        init(
            id: String,
            start: Double,
            name: String,
            text: String,
            speakerID: String = "",
            sourceID: TranscriptDocument.SourceID = .host,
            localID: Int = 1,
            hasManualName: Bool = false,
            hasSavedName: Bool? = nil,
            editText: String? = nil,
            end: Double = 0,
            originalName: String? = nil,
            nameOrigin: String? = nil,
            personID: UUID? = nil,
            voiceRefusal: TranscriptVoiceRefusal? = nil
        ) {
            self.id = id
            self.start = start
            self.end = end
            self.originalName = originalName ?? name
            self.name = name
            self.text = text
            self.editText = editText ?? text
            self.speakerID = speakerID
            self.sourceID = sourceID
            self.localID = localID
            self.hasManualName = hasManualName
            self.hasSavedName = hasSavedName ?? hasManualName
            self.nameOrigin = nameOrigin
            self.personID = personID
            self.voiceRefusal = voiceRefusal
        }
    }

    static func continuationTurnIDs(in rows: [Row]) -> Set<String> {
        Set(zip(rows, rows.dropFirst()).compactMap { previous, row in
            guard previous.hasSavedName, row.hasSavedName, previous.name == row.name,
                  previous.personID == row.personID, previous.nameOrigin == row.nameOrigin,
                  previous.speakerID == row.speakerID, previous.sourceID == row.sourceID else {
                return nil
            }
            return row.id
        })
    }

    enum SpeakerAssignmentScope: String, CaseIterable, Identifiable, Sendable {
        case thisTurn = "Только эта реплика"
        case allVoiceGroup = "Реплики этого голоса отсюда до конца"
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
        var replaceManual = false
        var pendingConfirmation: GroupConfirmationPayload?
        var preview: TranscriptBulkAssignmentPreview?
        let targetResultID: String
        let calendarAttendees: [String]
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
    var onStaleVoiceSession: (() -> Void)?
    @Published private(set) var voiceLearningNotice: String?
    @Published private(set) var voiceLearningConfirmedTurnID: String?
    struct VoiceGroup: Identifiable {
        let id: TranscriptVoiceKey
        let rows: [Row]
        let title: String
        let fullyNamed: Bool
        let mixedNames: Bool
        var originalName: String { rows[0].originalName }
    }
    var voiceGroups: [VoiceGroup] {
        var order: [TranscriptVoiceKey] = []
        var grouped: [TranscriptVoiceKey: [Row]] = [:]
        for row in rows {
            let key = TranscriptVoiceKey(sourceID: row.sourceID, localID: row.localID)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(row)
        }
        return order.map { key in
            let members = grouped[key]!
            let named = members.filter(\.hasSavedName)
            let names = Set(named.map(\.name))
            let mixed = Set(named.compactMap(\.personID)).count > 1 ||
                (names.count > 1 && Set(names.map(TranscriptSpeakerAssignmentService.nameComparisonKey)).count > 1)
            let fullyNamed = members.allSatisfy(\.hasSavedName)
            return VoiceGroup(id: key, rows: members,
                title: fullyNamed && !mixed ? members[0].name : members[0].originalName,
                fullyNamed: fullyNamed, mixedNames: mixed)
        }
    }
    var availableCalendarNames: [String] {
        let assigned = Set(rows.filter(\.hasSavedName).map { TranscriptSpeakerAssignmentService.nameComparisonKey($0.name) })
        return Self.uniqueParticipantNames(calendarAttendees, excluding: assigned)
    }

    var savedMeetingNames: [String] {
        Self.uniqueParticipantNames(rows.filter { $0.hasSavedName && ($0.nameOrigin == nil || $0.nameOrigin == "manual") }.map(\.name))
    }

    private static func uniqueParticipantNames(_ names: [String], excluding excluded: Set<String> = []) -> [String] {
        var seen = excluded
        return names.filter {
            let key = TranscriptSpeakerAssignmentService.nameComparisonKey($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    struct VoiceAssignmentDraft: Equatable {
        let id: UUID
        let resultID: String
        let voice: TranscriptVoiceKey
        let anchorTurnID: String
        let initialName: String
        var inputName: String
        var scope: TranscriptNameAssignmentScope
        var person: TranscriptPersonSelection = .asEntered
        var requiresExplicitPerson = false
        var replaceManual: Bool = false
        var scopeSelected = false
        var preview: TranscriptBulkAssignmentPreview?

        var isDirty: Bool {
            !inputName.utf8.elementsEqual(initialName.utf8) || person != .asEntered || requiresExplicitPerson || replaceManual
        }
    }
    @Published private(set) var voiceReviewVisible = false
    @Published private(set) var voiceReviewComplete = false
    @Published private(set) var selectedVoiceID: TranscriptVoiceKey?
    @Published private(set) var voiceDraft: VoiceAssignmentDraft?
    private var parkedVoiceDrafts: [String: VoiceAssignmentDraft] = [:]
    private var parkedVoiceInput: VoiceAssignmentDraft? {
        rows.lazy.compactMap { self.parkedVoiceDrafts[$0.id] }.first(where: \.isDirty)
    }
    var hasParkedVoiceInput: Bool { parkedVoiceDrafts.values.contains(where: \.isDirty) }
    private var lastVoiceTurnID: String?
    @Published private(set) var reviewedVoices: Set<TranscriptVoiceKey> = []
    var selectedVoice: VoiceGroup? { voiceGroups.first { $0.id == selectedVoiceID } }
    var reviewedVoiceCount: Int { voiceGroups.filter { $0.fullyNamed || reviewedVoices.contains($0.id) }.count }
    var voiceChangesCount: Int {
        guard let preview = voiceDraft?.preview, preview.confirmedName != nil else { return 0 }
        return preview.affectedTurnsCount
    }
    @Published private(set) var voiceRequiresReopen = false
    @Published private(set) var voiceListRequested = false
    @Published private(set) var showOnlyUnrecognizedVoices = false
    struct VoiceNameSuggestion: Identifiable, Equatable {
        enum Kind: Equatable {
            case meetingParticipant
            case savedVoice
        }

        enum Selection: Equatable {
            case existingPerson(VoiceProfilePerson)
            case plainName(String)
        }

        let id: String
        let displayName: String
        let subtitle: String?
        let kind: Kind
        let selection: Selection
        let isCalendarAttendee: Bool
        let isVoiceReady: Bool
        var searchAliases: Set<String> = []
        var requiresExplicitPerson = false

        var hasSavedProfile: Bool {
            if case .existingPerson = selection { return true }
            return false
        }
    }

    struct VoiceNameSuggestionSection: Identifiable, Equatable {
        let id: String
        let title: String
        let items: [VoiceNameSuggestion]
    }

    @Published private(set) var voicePeople: [VoiceProfilePerson] = []
    @Published private(set) var voiceReadyPersonIDs: Set<UUID> = []
    @Published private(set) var voiceSelectionRevision: Int = 0
    var matchingVoicePeople: [VoiceProfilePerson] {
        let key = TranscriptSpeakerAssignmentService.nameComparisonKey
        let query = key(voiceDraft?.inputName ?? "")
        guard !query.isEmpty else { return voicePeople }
        return voicePeople.filter { person in
            key(person.displayName).contains(query) || person.calendarBindings.contains { key($0).contains(query) }
        }
    }

    func voiceNameSuggestionSections(query: String) -> [VoiceNameSuggestionSection] {
        let key = TranscriptSpeakerAssignmentService.nameComparisonKey
        let names = VoicePersonNames(voicePeople)
        let sortedPeople = names.sortedPeople
        let peopleByID = Dictionary(uniqueKeysWithValues: sortedPeople.map { ($0.id, $0) })
        let peopleByKey = names.peopleByKey

        let contactsByName = Dictionary(grouping: voiceCalendarContacts.indices) {
            key(voiceCalendarContacts[$0].displayName)
        }
        let contactsByAddress = Dictionary(grouping: voiceCalendarContacts.indices) {
            voiceCalendarContacts[$0].address
        }
        let peopleByAddress = Dictionary(grouping: sortedPeople.flatMap { person in
            Set(person.calendarBindings).map { ($0, person) }
        }, by: { $0.0 })
        let uniquelyNamedPeople = peopleByKey.compactMapValues { $0.count == 1 ? $0.first : nil }

        var matchedContacts = Set<Int>()
        var contactIndices = Array<Int?>(repeating: nil, count: calendarAttendees.count)
        func takeContact(_ indices: [Int]) -> Int? {
            indices.first { matchedContacts.insert($0).inserted }
        }
        // Reserve exact matches before any display name can consume those contacts.
        for (position, name) in calendarAttendees.enumerated() {
            guard let url = URL(string: name),
                  let address = TranscriptDocument.CalendarParticipant(displayName: nil, contactURL: url)?.address,
                  let indices = contactsByAddress[address] else { continue }
            contactIndices[position] = takeContact(indices) ?? indices.first
        }
        for (position, name) in calendarAttendees.enumerated() where contactIndices[position] == nil {
            contactIndices[position] = takeContact(contactsByName[key(name)] ?? [])
        }
        let invitations = zip(calendarAttendees, contactIndices).map { name, index in
            (name: name, contact: index.map { voiceCalendarContacts[$0] })
        } + voiceCalendarContacts.indices.compactMap { index in
            matchedContacts.contains(index) ? nil : (voiceCalendarContacts[index].displayName, voiceCalendarContacts[index])
        }
        let invitationsByName = Dictionary(grouping: invitations) { key($0.contact?.displayName ?? $0.name) }
        let calendarNameKeys = Set(invitationsByName.keys)
        let manualRows = rows.filter { $0.hasSavedName && ($0.nameOrigin == nil || $0.nameOrigin == "manual") }
        let unlinkedManualNames = Set(manualRows.compactMap { row in
            row.personID.flatMap { peopleByID[$0] } == nil ? key(row.name) : nil
        })
        let blockedNameFallback = Set(calendarNameKeys.filter {
            !voiceCalendarContacts.isEmpty && uniquelyNamedPeople[$0]?.calendarBindings.isEmpty == false
        })
        let resolvedInvitations = invitations.map { invitation -> (name: String, contact: TranscriptDocument.CalendarParticipant?, person: VoiceProfilePerson?) in
            let contact = invitation.contact
            var person: VoiceProfilePerson?
            if let contact, contactsByAddress[contact.address]?.count == 1 {
                let owners = peopleByAddress[contact.address] ?? []
                let nameKey = key(contact.displayName)
                if owners.count == 1 {
                    person = owners.first?.1
                } else if owners.isEmpty, invitationsByName[nameKey]?.count == 1,
                          !unlinkedManualNames.contains(nameKey),
                          let candidate = uniquelyNamedPeople[nameKey], candidate.calendarBindings.isEmpty {
                    person = candidate
                }
            }
            return (invitation.name, contact, person)
        }
        var addressedNameKeys = Set<String>()
        for invitation in resolvedInvitations {
            guard let contact = invitation.contact else { continue }
            addressedNameKeys.insert(key(invitation.name))
            addressedNameKeys.insert(key(contact.displayName))
            if let person = invitation.person { addressedNameKeys.insert(key(person.displayName)) }
        }

        var meetingIndices: [String: Int] = [:]
        var meetingItems: [VoiceNameSuggestion] = []
        func appendParticipant(_ name: String, person: VoiceProfilePerson?, isCalendar: Bool,
                               contact: TranscriptDocument.CalendarParticipant? = nil, requiresExplicitPerson: Bool = false) {
            let shownName = (contact?.displayName ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
            let nameKey = key(shownName)
            guard person != nil || !nameKey.isEmpty else { return }
            let id: String
            if let person { id = "person-\(person.id.uuidString)" }
            else if let contact { id = "calendar-\(contact.address)" }
            else { id = "\(requiresExplicitPerson && !isCalendar ? "manual" : "name")-\(nameKey)" }

            var searchAliases = Set([key(name), nameKey])
            if let contact { searchAliases.insert(key(contact.address)) }
            if let index = meetingIndices[id] {
                meetingItems[index].searchAliases.formUnion(searchAliases)
                return
            }
            meetingIndices[id] = meetingItems.count
            meetingItems.append(.init(
                id: id, displayName: person?.displayName ?? shownName,
                subtitle: person.flatMap(names.subtitle(for:)) ?? contact?.address,
                kind: .meetingParticipant, selection: person.map(VoiceNameSuggestion.Selection.existingPerson) ?? .plainName(shownName),
                isCalendarAttendee: isCalendar, isVoiceReady: person.map { voiceReadyPersonIDs.contains($0.id) } ?? false,
                searchAliases: searchAliases, requiresExplicitPerson: requiresExplicitPerson
            ))
        }
        for invitation in resolvedInvitations {
            if let contact = invitation.contact {
                let nameKey = key(contact.displayName)
                let ambiguous = invitation.person == nil &&
                    (invitationsByName[nameKey, default: []].count > 1 || peopleByKey[nameKey] != nil ||
                     unlinkedManualNames.contains(nameKey))
                appendParticipant(invitation.name, person: invitation.person, isCalendar: true,
                                  contact: contact, requiresExplicitPerson: ambiguous)
            } else {
                let nameKey = key(invitation.name)
                let ambiguous = addressedNameKeys.contains(nameKey) || blockedNameFallback.contains(nameKey)
                appendParticipant(invitation.name, person: ambiguous ? nil : uniquelyNamedPeople[nameKey],
                                  isCalendar: true, requiresExplicitPerson: ambiguous)
            }
        }

        let linkedManualNames = Set(manualRows.compactMap { row in
            row.personID.flatMap { peopleByID[$0] }.map { _ in key(row.name) }
        })
        for row in manualRows {
            let nameKey = key(row.name)
            if let person = row.personID.flatMap({ peopleByID[$0] }) {
                appendParticipant(row.name, person: person, isCalendar: false)
            } else if addressedNameKeys.contains(nameKey) {
                appendParticipant(row.name, person: nil, isCalendar: false, requiresExplicitPerson: true)
            } else if !linkedManualNames.contains(nameKey) {
                let person = blockedNameFallback.contains(nameKey) ? nil : uniquelyNamedPeople[nameKey]
                if person != nil || !calendarNameKeys.contains(nameKey) {
                    appendParticipant(row.name, person: person, isCalendar: false)
                }
            }
        }

        let savedItems: [VoiceNameSuggestion] = sortedPeople
            .filter { meetingIndices["person-\($0.id.uuidString)"] == nil }
            .map { person in
                VoiceNameSuggestion(
                    id: "person-\(person.id.uuidString)",
                    displayName: person.displayName,
                    subtitle: names.subtitle(for: person),
                    kind: .savedVoice,
                    selection: .existingPerson(person),
                    isCalendarAttendee: false,
                    isVoiceReady: voiceReadyPersonIDs.contains(person.id)
                )
            }

        let queryKey = key(query)
        func matchesQuery(_ item: VoiceNameSuggestion) -> Bool {
            guard !queryKey.isEmpty else { return true }
            if key(item.displayName).contains(queryKey) { return true }
            if item.searchAliases.contains(where: { $0.contains(queryKey) }) { return true }
            if let sub = item.subtitle, key(sub).contains(queryKey) { return true }
            if case .existingPerson(let person) = item.selection {
                return person.calendarBindings.contains { key($0).contains(queryKey) }
            }
            return false
        }

        let filteredMeeting = meetingItems.filter(matchesQuery)
        let filteredSaved = savedItems.filter(matchesQuery)
        var sections: [VoiceNameSuggestionSection] = []
        if !filteredMeeting.isEmpty {
            sections.append(.init(id: "meeting", title: "Участники встречи", items: filteredMeeting))
        }
        if !filteredSaved.isEmpty {
            sections.append(.init(id: "saved", title: "Сохранённые голоса", items: filteredSaved))
        }
        return sections
    }

    func selectVoiceSuggestion(_ suggestion: VoiceNameSuggestion) {
        switch suggestion.selection {
        case .existingPerson(let person):
            selectVoicePerson(person)
        case .plainName(let name):
            updateVoiceName(name, requiresExplicitPerson: suggestion.requiresExplicitPerson)
        }
    }

    func refreshVoiceIdentityState() {
        guard voiceReviewVisible else { return }
        voicePeople = voiceIdentityActions?.people() ?? []
        voiceReadyPersonIDs = voiceIdentityActions?.readyPersonIDs?() ?? []
    }

    private func showVoiceReview() {
        voiceReviewVisible = true
        refreshVoiceIdentityState()
        let document = try? TranscriptResultStorage(recordingURL: state.recordingURL).currentDocument()
        voiceCalendarContacts = document?.context?.calendarParticipants ?? []
    }
    @Published private(set) var voiceCalendarContacts: [TranscriptDocument.CalendarParticipant] = []
    var visibleVoiceGroups: [VoiceGroup] { showOnlyUnrecognizedVoices ? voiceGroups.filter { !$0.fullyNamed } : voiceGroups }
    var voiceListVisible: Bool { voiceListRequested }
    var isVoiceDraftDirty: Bool { voiceDraft?.isDirty == true || voiceRequiresReopen }
    var canConfirmVoice: Bool {
        !voiceRequiresReopen && (voiceDraft?.preview?.affectedTurnsCount ?? 0) > 0 && voiceDraft?.preview?.confirmedName != nil
    }
    var canConfirmSavedVoiceName: Bool {
        guard !voiceRequiresReopen, let draft = voiceDraft, draft.preview?.confirmedName != nil, !draft.isDirty,
              voiceIdentityActions?.isEnabled() == true, voiceIdentityActions?.resolveTypedPerson != nil,
              let row = rows.first(where: { $0.id == draft.anchorTurnID }), row.hasSavedName, row.personID == nil else { return false }
        return row.nameOrigin == nil || row.nameOrigin == "manual"
    }
    func requestVoiceList() -> Bool {
        guard !inputBlocked(), !isClosed, !state.isClosed, voiceReviewVisible else { return false }
        beginEditing()
        voiceListRequested = true
        return true
    }

    private func requireCurrentReview() throws -> TranscriptReviewSession {
        guard !isClosed, !state.isClosed, !state.isReadOnly, let session = state.session,
              !session.isClosed, session.activeResultID == currentResultID,
              try TranscriptResultStorage(recordingURL: state.recordingURL).currentDocument()?.resultID == currentResultID else {
            throw TranscriptEditsError.conflict("Текущий результат изменился. Отмените ввод и заново откройте запись.")
        }
        return session
    }

    func openVoiceReview(anchorTurnID: String? = nil) {
        guard !inputBlocked(), activeDraft == nil, activeTextDraft == nil else { rejectConflictingAction(); return }
        do { _ = try requireCurrentReview() }
        catch {
            guard hasUnsavedChanges else { self.error = error.localizedDescription; return }
            voiceRequiresReopen = true
            beginEditing()
            voiceReviewVisible = true
            let parked = anchorTurnID.flatMap { parkedVoiceDrafts[$0] }
                ?? parkedVoiceInput
            if let parked { selectVoice(parked.voice, anchorTurnID: parked.anchorTurnID, scope: parked.scope) }
            self.error = error.localizedDescription
            return
        }
        guard !voiceGroups.isEmpty else { return }
        beginEditing()
        showVoiceReview()
        if let anchorTurnID, let row = rows.first(where: { $0.id == anchorTurnID }) {
            showOnlyUnrecognizedVoices = false
            selectVoice(.init(sourceID: row.sourceID, localID: row.localID), anchorTurnID: anchorTurnID, scope: .single)
            return
        }
        if hasParkedVoiceInput, let parked = parkedVoiceInput {
            if !visibleVoiceGroups.contains(where: { $0.id == parked.voice }) { showOnlyUnrecognizedVoices = false }
            selectVoice(parked.voice, anchorTurnID: parked.anchorTurnID, scope: parked.scope)
            return
        }
        guard let chosen = visibleVoiceGroups.first(where: { $0.id == selectedVoiceID })?.id
            ?? visibleVoiceGroups.first(where: { !$0.fullyNamed })?.id ?? visibleVoiceGroups.first?.id else {
            voiceReviewComplete = true
            return
        }
        selectVoice(chosen, anchorTurnID: lastVoiceTurnID)
    }

    func setUnrecognizedVoiceFilter(_ filtered: Bool) {
        guard !inputBlocked() else { return }
        showOnlyUnrecognizedVoices = filtered
        if let selectedVoiceID, visibleVoiceGroups.contains(where: { $0.id == selectedVoiceID }) {
            if voiceDraft == nil { selectVoice(selectedVoiceID, anchorTurnID: lastVoiceTurnID) }
            else { voiceReviewComplete = false }
        } else if let first = visibleVoiceGroups.first {
            selectVoice(first.id)
        } else {
            voiceReviewComplete = true
            parkVoiceDraft()
            voiceDraft = nil
        }
    }

    func selectVoice(_ voice: TranscriptVoiceKey, anchorTurnID: String? = nil, scope: TranscriptNameAssignmentScope = .group) {
        guard !inputBlocked(), !isClosed, !state.isClosed, voiceReviewVisible else { return }
        guard let group = voiceGroups.first(where: { $0.id == voice }), let resultID = currentResultID,
              let anchor = group.rows.first(where: { $0.id == anchorTurnID })
                ?? (showOnlyUnrecognizedVoices ? group.rows.first(where: { !$0.hasSavedName }) : nil)
                ?? group.rows.first else { return }
        beginEditing()
        parkVoiceDraft()
        selectedVoiceID = voice
        lastVoiceTurnID = anchor.id
        voiceListRequested = false
        voiceReviewComplete = false
        let initial = anchor.hasSavedName ? anchor.name : ""
        voiceDraft = parkedVoiceDrafts.removeValue(forKey: anchor.id) ?? VoiceAssignmentDraft(id: UUID(), resultID: resultID, voice: voice,
            anchorTurnID: anchor.id, initialName: initial, inputName: initial, scope: scope)
        error = nil
        refreshVoicePreview()
        voiceSelectionRevision &+= 1
    }

    private func parkVoiceDraft() {
        guard let draft = voiceDraft, draft.isDirty || draft.scopeSelected else { return }
        parkedVoiceDrafts[draft.anchorTurnID] = draft
    }

    private func refreshVoicePreview() {
        guard var draft = voiceDraft, !voiceRequiresReopen else { return }
        do {
            let session = try requireCurrentReview()
            if !draft.inputName.allSatisfy(\.isWhitespace) {
                draft.preview = try session.previewAssignment(
                    anchorTurnID: draft.anchorTurnID, scope: draft.scope, displayName: draft.inputName, person: draft.person,
                    replaceManuallyAssigned: draft.replaceManual
                )
            } else {
                draft.preview = try session.previewGroupAssignment(voice: draft.voice, replaceManuallyAssigned: draft.replaceManual)
            }
            voiceDraft = draft
        } catch {
            draft.preview = nil
            voiceDraft = draft
            voiceRequiresReopen = true
            self.error = error.localizedDescription
        }
    }

    func updateVoiceName(_ name: String, requiresExplicitPerson: Bool = false) {
        guard !inputBlocked(), !voiceRequiresReopen, var draft = voiceDraft else { return }
        draft.inputName = name
        draft.person = .asEntered
        draft.requiresExplicitPerson = requiresExplicitPerson
        voiceListRequested = false
        voiceDraft = draft
        error = nil
        refreshVoicePreview()
    }

    func setVoiceScope(_ scope: TranscriptNameAssignmentScope) {
        guard !inputBlocked(), !voiceRequiresReopen, var draft = voiceDraft else { return }
        draft.scope = scope
        draft.scopeSelected = true
        if scope == .single { draft.replaceManual = false }
        voiceDraft = draft
        refreshVoicePreview()
    }

    func selectVoicePerson(_ person: VoiceProfilePerson?) {
        guard !inputBlocked(), !voiceRequiresReopen, var draft = voiceDraft, let actions = voiceIdentityActions else { return }
        let name = (person?.displayName ?? draft.inputName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            draft.person = try actions.selectPerson(person?.id, name)
            if draft.person != .asEntered { draft.requiresExplicitPerson = false }
            draft.inputName = name
            voiceListRequested = false
            voiceDraft = draft
            error = nil
            refreshVoicePreview()
        } catch { self.error = error.localizedDescription }
    }

    func confirmVoiceCalendarBinding(_ address: String, personID: UUID) {
        guard !inputBlocked(), let actions = voiceIdentityActions,
              let anchor = voiceDraft?.anchorTurnID,
              rows.first(where: { $0.id == anchor })?.personID == personID else { return }
        do {
            _ = try requireCurrentReview()
            guard let document = try TranscriptResultStorage(recordingURL: state.recordingURL).currentDocument(),
                  document.resultID == currentResultID else { return }
            try actions.confirmCalendarBinding(personID, address, document)
            voicePeople = actions.people()
            voiceReadyPersonIDs = actions.readyPersonIDs?() ?? []
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func setVoiceReplaceManual(_ replace: Bool) {
        guard !inputBlocked(), !voiceRequiresReopen, var draft = voiceDraft else { return }
        draft.replaceManual = replace
        voiceListRequested = false
        voiceDraft = draft
        error = nil
        refreshVoicePreview()
    }

    func confirmVoiceAssignment(_ confirmation: VoiceAssignmentDraft, confirmSavedName: Bool = false) {
        guard !inputBlocked(), voiceReviewVisible, !isClosed, !state.isClosed else { return }
        guard !voiceRequiresReopen, let draft = voiceDraft, draft == confirmation,
              draft.inputName.utf8.elementsEqual(confirmation.inputName.utf8),
              draft.resultID == currentResultID, draft.voice == selectedVoiceID,
              var preview = draft.preview, !draft.inputName.allSatisfy(\.isWhitespace) else {
            error = "Подтверждение группы устарело или не совпадает с текущим состоянием."
            return
        }
        guard confirmSavedName ? canConfirmSavedVoiceName : canConfirmVoice else { return }
        do {
            let session = try requireCurrentReview()
            let learn = voiceIdentityActions?.isEnabled() == true
            if learn && draft.requiresExplicitPerson {
                error = "Выберите профиль этого человека или нажмите «Создать человека»."
                return
            }
            var typedPerson: TranscriptVoicePersonIntent?
            var learningFailure: String?
            if confirmSavedName {
                guard let resolve = voiceIdentityActions?.resolveTypedPerson else { return }
                guard let person = try resolve(draft.inputName) else {
                    setVoiceScope(.single)
                    error = "Есть несколько людей с этим именем. Выберите человека из списка и нажмите «Применить»."
                    return
                }
                let single = try session.previewAssignment(anchorTurnID: draft.anchorTurnID, scope: .single,
                    displayName: draft.inputName, person: .confirmed(person))
                guard single.revision == preview.revision, single.snapshotOverrides == preview.snapshotOverrides else {
                    throw TranscriptEditsError.conflict("Назначение изменилось. Отмените ввод и заново откройте запись.")
                }
                preview = single
            } else if learn, preview.canResolveTypedPerson,
               TranscriptSpeakerAssignmentService.nameComparisonKey(draft.inputName) !=
                TranscriptSpeakerAssignmentService.nameComparisonKey(draft.initialName),
               let resolve = voiceIdentityActions?.resolveTypedPerson {
                do { typedPerson = try resolve(draft.inputName) }
                catch { learningFailure = error.localizedDescription }
                if typedPerson == nil, learningFailure == nil {
                    error = "Есть несколько людей с этим именем. Выберите человека из списка."
                    return
                }
            }
            let saved = try session.assignSpeakerName(preview: preview, displayName: draft.inputName,
                                                      learnVoice: learn, typedPerson: typedPerson)
            rows = try Self.loadRows(resultID: draft.resultID, session: session)
            reviewedVoices.insert(draft.voice)
            voiceDraft = nil
            error = nil
            let failure = learningFailure ?? voiceIdentityActions?.learningFailure(session.recordingDirectory)
            voiceLearningNotice = failure
            voiceLearningConfirmedTurnID = nil
            if confirmSavedName, failure == nil, saved.pendingLearningEvents?.contains(where: {
                $0.allowsLearning && $0.turnID == draft.anchorTurnID && $0.editsRevision == saved.revision
            }) == true {
                voiceLearningConfirmedTurnID = draft.anchorTurnID
            }
            onSaved?()
            refreshVoiceIdentityState()
            if visibleVoiceGroups.contains(where: { $0.id == draft.voice }) {
                selectVoice(draft.voice, anchorTurnID: draft.anchorTurnID, scope: draft.scope)
            } else if let first = visibleVoiceGroups.first {
                selectVoice(first.id)
            } else {
                voiceReviewComplete = true
            }
        } catch {
            if let editsError = error as? TranscriptEditsError, case .conflict = editsError { voiceRequiresReopen = true }
            self.error = (confirmSavedName ? "Не удалось подтвердить имя: " : "Ошибка назначения имени: ") + error.localizedDescription
        }
    }

    func nextVoice() {
        guard !inputBlocked(), voiceReviewVisible, !isClosed, !state.isClosed else { return }
        let groups = visibleVoiceGroups
        guard groups.count > 1, let index = groups.firstIndex(where: { $0.id == selectedVoiceID }) else { return }
        selectVoice(groups[(index + 1) % groups.count].id)
    }

    func cancelVoiceInput() {
        guard !inputBlocked(), voiceReviewVisible else { return }
        let requiresReopen = voiceRequiresReopen
        let draft = voiceDraft
        voiceDraft = nil
        voiceRequiresReopen = false
        error = nil
        if requiresReopen {
            close(); state.close()
            onStaleVoiceSession?()
        } else if let selectedVoiceID {
            selectVoice(selectedVoiceID, anchorTurnID: draft?.anchorTurnID, scope: draft?.scope ?? .group)
        }
    }

    func returnToTranscript(turnID: String? = nil) {
        guard !inputBlocked(), !isClosed, !state.isClosed else { return }
        guard !voiceRequiresReopen else { rejectConflictingAction(); return }
        beginEditing()
        let target = turnID ?? voiceDraft?.anchorTurnID
        parkVoiceDraft()
        voiceReviewVisible = false
        voiceDraft = nil
        error = nil
        if let turnID = target, rows.contains(where: { $0.id == turnID }) {
            turnNavigation = TurnNavigation(id: UUID(), turnID: turnID, seek: nil)
            turnNavigationSettled = true
        }
    }

    func openDraftVoiceReview() {
        guard !inputBlocked(), !isClosed, !state.isClosed, let draft = activeDraft,
              draft.targetResultID == currentResultID else { return }
        do { _ = try requireCurrentReview() }
        catch { self.error = error.localizedDescription; return }
        activeDraft = nil
        showVoiceReview()
        selectVoice(TranscriptVoiceKey(sourceID: draft.sourceID, localID: draft.localID),
                    anchorTurnID: draft.turnID, scope: draft.scope == .thisTurn ? .single : .remaining)
        updateVoiceName(draft.inputName)
    }
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
        case voice
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
        if isVoiceDraftDirty || parkedVoiceDrafts.values.contains(where: \.isDirty) {
            return .voice
        } else if let textDraft = activeTextDraft {
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
        isTextDraftDirty || isNameDraftDirty || isVoiceDraftDirty || parkedVoiceDrafts.values.contains(where: \.isDirty)
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

    func userScrollPhaseChanged(_ phase: ScrollPhase) {
        guard !inputBlocked() else { return }
        switch phase {
        case .tracking, .interacting, .decelerating:
            endTurnNavigationGesture()
            if let target = turnNavigation { cancelTurnNavigation(target) }
            follow.manualScroll()
        case .idle, .animating: break
        @unknown default: break
        }
    }

    func beginEditing() {
        invalidateQueuedPlaybackSeek()
        follow.beginEditing()
        playback.cancelSegment()
        fragmentTurnID = nil
    }
    func returnToPlayback() { if !inputBlocked() { setFollow(true) } }
    func setFollow(_ follow: Bool) {
        guard !isClosed else { return }
        if follow {
            endTurnNavigationGesture()
            if let target = turnNavigation { cancelTurnNavigation(target) }
            self.follow.returnToPlayback()
        } else {
            self.follow.manualScroll()
        }
    }
    var playbackEnabled: Bool { playbackState == .ready || playbackState == .playing }
    @Published private(set) var fragmentTurnID: String?
    private var fragmentRequestID: UUID?
    func playVoiceTurn(_ turnID: String) async {
        guard !inputBlocked(), !isClosed, !state.isClosed, voiceReviewVisible,
              let row = selectedVoice?.rows.first(where: { $0.id == turnID }),
              row.start.isFinite, row.end.isFinite, row.start >= 0, row.start < playbackDuration,
              row.end > row.start, playbackEnabled else { return }
        if fragmentTurnID == turnID, playback.segment != nil { playback.toggle(); return }
        let voice = selectedVoiceID, result = currentResultID
        let requestID = UUID()
        fragmentRequestID = requestID
        await playback.playSegment(start: row.start, end: row.end)
        guard fragmentRequestID == requestID, !inputBlocked(), !isClosed, !state.isClosed,
              voiceReviewVisible, selectedVoiceID == voice,
              currentResultID == result, playback.segment == row.start...min(row.end, playbackDuration) else { return }
        fragmentTurnID = turnID
    }
    @Published private(set) var playbackMessage: String? = "Для старого TXT или недоступного результата воспроизведение не поддерживается."
    private var playback: TranscriptPlaybackController
    private let transportFactory: @MainActor () -> any TranscriptPlaybackTransport
    private var preparation: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var index: TranscriptIntervalIndex?
    private var isClosed = false
    struct PlaybackSeekRequest {
        let id: UUID
        let position: Double
    }
    private var pendingPlaybackSeek: PlaybackSeekRequest?
    private var executingPlaybackSeek: UUID?
    var playbackSeekPosition: Double { pendingPlaybackSeek?.position ?? playbackPosition }
    struct TurnNavigation {
        let id: UUID
        let turnID: String
        let seek: PlaybackSeekRequest?
    }
    @Published private(set) var turnNavigation: TurnNavigation?
    private var turnNavigationSettled = false
    private var turnNavigationKeyHeld = false
    var highlightedTurnID: String? { turnNavigation?.turnID ?? activeTurnIDs.first }

    func beginTurnNavigationGesture() { turnNavigationKeyHeld = true }

    func endTurnNavigationGesture() {
        turnNavigationKeyHeld = false
        releaseTurnNavigationToPlayback()
    }

    private func releaseTurnNavigationToPlayback() {
        if !turnNavigationKeyHeld, turnNavigationSettled, pendingPlaybackSeek == nil, playbackState == .playing {
            turnNavigation = nil
        }
    }

    func requestTurnNavigation(by direction: Int) -> TurnNavigation? {
        let anchor = turnNavigation.flatMap { target in rows.firstIndex { $0.id == target.turnID } }
            ?? rows.lastIndex { $0.start <= playbackSeekPosition }
        let next = anchor.map { $0 + direction } ?? 0
        guard rows.indices.contains(next) else { return nil }
        return requestTurnNavigation(to: rows[next].id)
    }

    func requestTurnNavigation(to turnID: String) -> TurnNavigation? {
        guard !isClosed, !state.isClosed, !inputBlocked(), currentDraftIdentity == nil,
              let row = rows.first(where: { $0.id == turnID }) else { return nil }
        let seek = playbackEnabled ? requestPlaybackSeek(to: row.start) : nil
        let target = TurnNavigation(id: seek?.id ?? UUID(), turnID: row.id, seek: seek)
        turnNavigationSettled = false
        turnNavigation = target
        return target
    }

    func cancelTurnNavigation(_ target: TurnNavigation) {
        if turnNavigation?.id == target.id { turnNavigation = nil }
        if let seek = target.seek { cancelPlaybackSeek(seek) }
    }

    func performTurnNavigation(_ target: TurnNavigation) async {
        guard turnNavigation?.id == target.id, !isClosed, !state.isClosed,
              !inputBlocked(), currentDraftIdentity == nil else { cancelTurnNavigation(target); return }
        guard let seek = target.seek else {
            turnNavigationSettled = true
            releaseTurnNavigationToPlayback()
            return
        }
        let succeeded = await performPlaybackSeek(seek)
        guard turnNavigation?.id == target.id else { return }
        if !succeeded { cancelTurnNavigation(target) }
        else {
            turnNavigationSettled = true
            releaseTurnNavigationToPlayback()
        }
    }

    func togglePlayback() {
        guard !isClosed, !inputBlocked() else { return }
        playback.toggle()
    }

    func seekPlayback(to seconds: Double) async {
        guard let request = requestPlaybackSeek(to: seconds) else { return }
        await performPlaybackSeek(request)
    }

    func requestPlaybackSeek(to seconds: Double) -> PlaybackSeekRequest? {
        guard !isClosed, !state.isClosed, !inputBlocked(), currentDraftIdentity == nil,
              playbackEnabled, seconds.isFinite else { return nil }
        let request = PlaybackSeekRequest(id: UUID(), position: min(playbackDuration, max(0, seconds)))
        turnNavigation = nil
        pendingPlaybackSeek = request
        return request
    }

    func cancelPlaybackSeek(_ request: PlaybackSeekRequest) {
        if pendingPlaybackSeek?.id == request.id, executingPlaybackSeek != request.id { pendingPlaybackSeek = nil }
    }

    func invalidateQueuedPlaybackSeek() {
        if voiceReviewVisible { fragmentRequestID = nil; playback.cancelSegment(); fragmentTurnID = nil }
        endTurnNavigationGesture()
        if let request = pendingPlaybackSeek, executingPlaybackSeek != request.id {
            pendingPlaybackSeek = nil
            if turnNavigation?.id == request.id { turnNavigation = nil }
        }
        if let target = turnNavigation, !turnNavigationSettled, executingPlaybackSeek != target.id {
            turnNavigation = nil
        }
    }

    @discardableResult
    func performPlaybackSeek(_ request: PlaybackSeekRequest) async -> Bool {
        guard !isClosed, !state.isClosed, !inputBlocked(), currentDraftIdentity == nil,
              playbackEnabled, pendingPlaybackSeek?.id == request.id,
              executingPlaybackSeek != request.id else { cancelPlaybackSeek(request); return false }
        executingPlaybackSeek = request.id
        defer {
            if pendingPlaybackSeek?.id == request.id { pendingPlaybackSeek = nil }
            if executingPlaybackSeek == request.id { executingPlaybackSeek = nil }
        }
        let succeeded = await playback.seek(to: request.position)
        return succeeded && !isClosed && playbackEnabled
    }

    func setPlaybackRate(_ rate: Float) {
        guard !isClosed, !inputBlocked() else { return }
        playback.setPlaybackRate(rate)
        playbackRate = playback.playbackRate
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        fragmentRequestID = nil
        turnNavigationKeyHeld = false
        turnNavigation = nil
        pendingPlaybackSeek = nil
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
        voiceDraft = nil
        parkedVoiceDrafts.removeAll()
        voiceReviewVisible = false
        activeExportRequest = nil
    }

    private func preparePlayback(resultID: String) {
        guard !isClosed, !state.isClosed else { return }
        turnNavigationKeyHeld = false
        turnNavigation = nil
        pendingPlaybackSeek = nil
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
        if playback.segment == nil { fragmentTurnID = nil }
        let wasPlayable = playbackEnabled
        playbackState = playback.state
        playbackPosition = playback.position
        playbackDuration = playback.duration
        playbackRate = playback.playbackRate
        if !wasPlayable, playbackEnabled, pendingPlaybackSeek == nil, !turnNavigationKeyHeld { turnNavigation = nil }
        releaseTurnNavigationToPlayback()
        switch playback.state {
        case .unavailable:
            playbackMessage = "Аудио текущего результата не подготовлено. Текст и сохранённые правки доступны; другая дорожка не подставляется."
        case .failed:
            playbackMessage = "Не удалось воспроизвести аудио текущего результата: файл отсутствует, повреждён или недоступен. Текст и сохранённые правки доступны; другая дорожка не подставляется."
        case .ready, .playing: playbackMessage = nil
        case .loading: playbackMessage = "Загрузка аудио текущего результата…"
        case .idle, .closed: break
        }
        activeTurnIDs = index?.readingFocusTurnID(at: playback.position).map { [$0] } ?? []
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
        let presentation = TranscriptTextPresentation(document: document, overrides: edits.overrides)
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
                text: presentation.readingText[turn.id] ?? "",
                speakerID: turn.speakerID,
                sourceID: sourceID,
                localID: localID,
                hasManualName: override?.protectsNameFromBulkReplacement == true,
                hasSavedName: override?.displayName != nil,
                editText: presentation.editableText[turn.id] ?? "",
                end: turn.end,
                originalName: "Speaker \(displayNumber)",
                nameOrigin: override?.assignment?.origin,
                personID: override?.assignment?.personID,
                voiceRefusal: override?.voiceRefusal
            )
        }
    }

    nonisolated private static func loadCalendarAttendees(resultID: String, storage: ReviewStorage) -> [String] {
        guard let doc = try? TranscriptDocument.load(from: storage.editsRepository.resultURL(for: resultID),
                                                     recordingDirectory: storage.recordingDirectory) else {
            return []
        }
        return doc.context?.attendees ?? []
    }

    nonisolated private static func loadContextAttendees(resultID: String, storage: ReviewStorage) -> [String]? {
        guard let doc = try? TranscriptDocument.load(from: storage.editsRepository.resultURL(for: resultID),
                                                     recordingDirectory: storage.recordingDirectory) else {
            return nil
        }
        guard let attendees = doc.context?.attendees, !attendees.isEmpty else { return nil }
        return attendees
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

    nonisolated private static func loadIndex(resultID: String, storage: ReviewStorage) throws -> TranscriptIntervalIndex {
        let document = try TranscriptDocument.load(from: storage.editsRepository.resultURL(for: resultID), recordingDirectory: storage.recordingDirectory)
        guard document.resultID == resultID else { throw TranscriptStorageError.currentResultUnavailable(resultID) }
        return TranscriptIntervalIndex(document: document)
    }

    func openSpeakerAssignment(for turnID: String) {
        guard !inputBlocked(), !voiceReviewVisible else { return }
        guard !isClosed, !state.isClosed, !state.isReadOnly, state.session != nil, let resultID = currentResultID else { return }
        guard activeTextDraft == nil, activeDraft == nil else {
            self.error = "Завершите или отмените редактирование текста перед назначением имени."
            return
        }
        guard let row = rows.first(where: { $0.id == turnID }) else { return }
        beginEditing()
        let initial = row.hasSavedName ? row.name : ""
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
            calendarAttendees: availableCalendarNames
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
        if scope == .thisTurn { draft.replaceManual = false }
        draft.pendingConfirmation = nil
        draft.preview = nil
        activeDraft = draft
        error = nil
        saveSpeakerAssignment(draftID: draft.id)
    }

    func setDraftReplaceManual(_ replace: Bool, draftID: UUID) {
        guard var draft = activeDraft, draft.id == draftID, draft.scope == .allVoiceGroup else { return }
        draft.replaceManual = replace
        draft.pendingConfirmation = nil
        draft.preview = nil
        activeDraft = draft
        saveSpeakerAssignment(draftID: draftID)
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

        do {
            let preview = try session.previewAssignment(
                anchorTurnID: draft.turnID, scope: draft.scope == .thisTurn ? .single : .remaining,
                displayName: draft.inputName, replaceManuallyAssigned: draft.replaceManual
            )
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
        } catch {
            self.error = error.localizedDescription
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
              currentConfirmation.id == confirmation.id,
              let preview = currentConfirmation.preview else {
            self.error = "Подтверждение группы устарело или не совпадает с текущим состоянием."
            return
        }

        do {
            _ = try requireCurrentReview()
            _ = try session.assignSpeakerName(preview: preview, displayName: confirmation.confirmedName)
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
        guard !inputBlocked(), !voiceReviewVisible else { return }
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
            initialText: row.editText,
            text: row.editText,
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
    var keyboardNavigationVisible = true
    private var narrow: Bool { workspaceWidth <= 767 }
    private var compact: Bool { workspaceWidth <= 1023 }
    @State private var scrollPosition: String?
    @FocusState private var countFocused: Bool
    @FocusState private var focusedControl: TranscriptControl?
    @AccessibilityFocusState(for: .voiceOver) private var accessibilityControl: TranscriptControl?
    @State private var hoveredTurnID: String?
    @State private var hoveringTranscriptHelp = false
    @State private var showingTranscriptHelp = false
    @State private var editorTrigger: TranscriptControl?
    @State private var pendingRowFocus: TranscriptControl?

    private enum TranscriptControl: Hashable {
        case help
        case timecode(String)
        case speaker(String)
        case text(String)

        var turnID: String? {
            switch self {
            case .help: nil
            case let .timecode(id), let .speaker(id), let .text(id): id
            }
        }
    }
#if !TRANSCRIPT_WINDOW_HARNESS
    @StateObject private var transcriptNavigation = WorkspaceNavigationView(.transcript)
#endif

    var body: some View {
        VStack(spacing: 0) {
            if model.hasParkedVoiceInput {
                HStack(spacing: 8) {
                    Text("Есть несохранённая правка имени").font(.system(size: 12)).foregroundStyle(ODColors.ink)
                    Spacer(minLength: 4)
                    Button("Вернуться к правке") { model.openVoiceReview() }
                        .buttonStyle(ODButtonStyle(compact: true))
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(ODColors.toolbar)
            }
            ZStack {
                transcriptContent
                    .opacity(model.voiceReviewVisible ? 0 : 1)
                    .allowsHitTesting(!model.voiceReviewVisible)
                    .disabled(model.voiceReviewVisible)
                    .accessibilityHidden(model.voiceReviewVisible)
                if model.voiceReviewVisible {
                    SpeakerReviewView(model: model, title: title, transcriptReturnTurnID: editorTrigger?.turnID) {
                        editorTrigger = nil
                    }
                }
            }
            playerFooter
        }
        .onChange(of: ObjectIdentifier(model)) { resetTranscriptInteraction() }
        .onChange(of: model.currentResultID) { resetTranscriptInteraction() }
        .onChange(of: model.voiceReviewVisible) { _, visible in
            if !visible && !restoreEditorFocus() {
                countFocused = model.turnNavigation == nil
#if !TRANSCRIPT_WINDOW_HARNESS
                if model.turnNavigation != nil { transcriptNavigation.focus() }
#endif
            }
        }
        .sheet(isPresented: Binding(get: { model.activeDraft != nil || model.activeTextDraft != nil }, set: { _ in }),
               onDismiss: { restoreEditorFocus() }) {
            editingSheet.interactiveDismissDisabled()
        }
    }

    private var transcriptContent: some View {
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
                            transcriptTurns()
                        }
                    }
                    .padding(.horizontal, narrow ? 16 : compact ? 24 : 48)
                    .padding(.top, narrow ? 28 : compact ? 32 : workspaceWidth >= 1392 ? 48 : 40)
                    .padding(.bottom, compact ? (narrow ? 28 : 32) : 48)
                    .frame(maxWidth: 840)
                    .frame(maxWidth: .infinity, alignment: .top)
#if !TRANSCRIPT_WINDOW_HARNESS
                    .background(WorkspaceNavigationFocus(surface: transcriptNavigation, visible: keyboardNavigationVisible && !model.voiceReviewVisible, onVerticalKey: { direction in
                        if model.legacyText == nil {
                            (transcriptNavigation.window as? WorkspaceWindow)?.navigateTranscriptTurn(by: direction)
                            return
                        }
                        guard let scroll = transcriptNavigation.enclosingScrollView else { return }
                        model.userScrollPhaseChanged(.interacting)
                        let clip = scroll.contentView
                        let step = CGFloat(direction) * scroll.verticalLineScroll * (scroll.documentView?.isFlipped == true ? 1 : -1)
                        clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: step)).origin)
                        scroll.reflectScrolledClipView(clip)
                    }))
#endif
                }
                .scrollPosition(id: $scrollPosition, anchor: .top)
#if !TRANSCRIPT_WINDOW_HARNESS
                .contentShape(Rectangle())
                .onTapGesture { transcriptNavigation.focus() }
#endif
                .onScrollPhaseChange { _, phase in model.userScrollPhaseChanged(phase) }
                .onChange(of: model.follow.request) { _, _ in
                    guard model.turnNavigation == nil, model.follow.isFollowing, let target = model.follow.targetID else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
                .onChange(of: model.turnNavigation?.id) { _, _ in
                    if let target = model.turnNavigation?.turnID {
                        proxy.scrollTo(target, anchor: .center)
                    } else if model.follow.isFollowing, let target = model.follow.targetID {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }

        }
        .background(ODColors.surface)
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
                    speakerCountEntry
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let entryDate { Text(entryDate.formatted(date: .long, time: .shortened)) }
                if let duration = entryDuration, duration > 0 { Text(Self.clock(seconds: duration)) }
                if !model.rows.isEmpty { speakerCountEntry }
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
                .disclosureGroupStyle(FullWidthDisclosureStyle())
                .padding(12)
                .background(ODColors.warningBg, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8).padding(.bottom, 0)
            }

            Rectangle()
                .fill(ODColors.line)
                .frame(height: 1)
                .padding(.top, 28)
                .padding(.bottom, 24)

            HStack(spacing: 8) {
                Text("Транскрипт")
                    .font(.system(size: 14, weight: .semibold))
                    .odLineBox(size: 14, height: 18.9)
                    .foregroundColor(ODColors.ink)
                    .accessibilityAddTraits(.isHeader)
                transcriptHelp
            }
            .padding(.bottom, 24)
        }
    }

    private var speakerCountEntry: some View {
        Button(action: { model.openVoiceReview() }) {
            HStack(spacing: 6) {
                ODIconView(.people, size: 14, color: ODColors.accent)
                Text("\(model.voiceGroups.count) говорящих")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(ODColors.accent)
        .focused($countFocused)
        .disabled(model.state.isReadOnly || model.state.isClosed)
        .help(model.state.isReadOnly ? "Разбор имён недоступен в режиме чтения." : "Назначить имена говорящим")
        .accessibilityLabel("\(model.voiceGroups.count) говорящих. Назначить имена")
    }

    private var canEditTurns: Bool {
        !model.state.isReadOnly && !model.state.isClosed && model.currentResultID != nil
    }

    private var transcriptHelp: some View {
        Button {
            showingTranscriptHelp = true
        } label: {
            Text("?")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(lineWidth: 1))
                .foregroundStyle(hoveringTranscriptHelp ? ODColors.ink : ODColors.muted)
                .frame(width: narrow ? 44 : 32, height: narrow ? 44 : 32)
                .background(hoveringTranscriptHelp ? ODColors.hover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onHover { hoveringTranscriptHelp = $0 }
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .help)
        .accessibilityFocused($accessibilityControl, equals: .help)
        .accessibilityLabel("Справка по транскрипту")
        .popover(isPresented: $showingTranscriptHelp, arrowEdge: .bottom) {
            Text("Подведите курсор к реплике. Карандаш открывает правку текста. Чтобы изменить говорящего, нажмите на имя или значок людей.")
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(width: 300, alignment: .leading)
                .onExitCommand { showingTranscriptHelp = false }
        }
        .onChange(of: showingTranscriptHelp) { wasShown, isShown in
            if wasShown && !isShown {
                focusedControl = .help
                accessibilityControl = .help
            }
        }
    }

    private func transcriptTurns() -> some View {
        let continuationIDs = TranscriptReviewWindowModel.continuationTurnIDs(in: model.rows)
        return LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(model.rows) { row in
                transcriptTurn(row, continuesSpeaker: continuationIDs.contains(row.id))
                    .id(row.id)
                    .task(id: pendingRowFocus?.turnID == row.id ? pendingRowFocus : nil) {
                        guard let pendingRowFocus, pendingRowFocus.turnID == row.id else { return }
                        focusedControl = pendingRowFocus
                        accessibilityControl = pendingRowFocus
                        self.pendingRowFocus = nil
                    }
            }
        }
        .scrollTargetLayout()
    }

    private func transcriptTurn(_ row: TranscriptReviewWindowModel.Row, continuesSpeaker: Bool) -> some View {
        let timecode = Self.clock(seconds: row.start)
        let showActions = hoveredTurnID == row.id || focusedControl?.turnID == row.id ||
            accessibilityControl?.turnID == row.id
        return HStack(alignment: .top, spacing: narrow ? 8 : 16) {
            Button {
#if TRANSCRIPT_WINDOW_HARNESS
                if let target = model.requestTurnNavigation(to: row.id) {
                    Task { await model.performTurnNavigation(target) }
                }
#else
                transcriptNavigation.focus()
                (transcriptNavigation.window as? WorkspaceWindow)?.navigateTranscriptTurn(to: row.id)
#endif
            } label: {
                Text(timecode)
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundColor(model.highlightedTurnID == row.id ? ODColors.accent : ODColors.muted)
                    .frame(width: narrow ? 44 : 48, height: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.playbackEnabled)
            .focused($focusedControl, equals: .timecode(row.id))
            .accessibilityFocused($accessibilityControl, equals: .timecode(row.id))
            .accessibilityLabel("Перейти к " + timecode)

            if continuesSpeaker {
                HStack(alignment: .top, spacing: 8) {
                    turnText(row, announceSpeaker: true)
                    if canEditTurns {
                        HStack(spacing: 4) {
                            let label = "Изменить говорящего в \(timecode)"
                            turnAction(.people, control: .speaker(row.id), label: label,
                                       value: speakerDescription(row), visible: showActions) {
                                openSpeakerEditor(row.id)
                            }
                            textAction(row.id, timecode: timecode, visible: showActions)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(row.sourceID == .host ? ODColors.accent : ODColors.muted)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        speakerCaption(row, timecode: timecode)
                        Spacer(minLength: 0)
                        if canEditTurns {
                            textAction(row.id, timecode: timecode, visible: showActions)
                        }
                    }
                    .frame(minHeight: 28)
                    turnText(row, announceSpeaker: false)
                }
            }
        }
        .padding(.horizontal, narrow ? 8 : 12)
        .padding(.vertical, continuesSpeaker ? 8 : narrow ? 12 : 16)
        .background(
            model.highlightedTurnID == row.id
                ? ODColors.surface.mix(with: ODColors.selected, by: 0.65)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(Rectangle())
        .onHover { hovered in
            if hovered { hoveredTurnID = row.id }
            else if hoveredTurnID == row.id { hoveredTurnID = nil }
        }
        .onDisappear {
            if hoveredTurnID == row.id { hoveredTurnID = nil }
        }
    }

    private func turnText(_ row: TranscriptReviewWindowModel.Row, announceSpeaker: Bool) -> some View {
        Text(row.text)
            .font(.system(size: 16))
            .odLineBox(size: 16, height: 28)
            .foregroundStyle(ODColors.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityLabel(announceSpeaker ? "\(row.name). \(row.text)" : row.text)
    }

    private func speakerOrigin(_ row: TranscriptReviewWindowModel.Row) -> (icon: ODIcon, label: String)? {
        guard row.hasSavedName else { return nil }
        switch row.nameOrigin {
        case "automaticVoiceMatch", "derivedVoiceMatch": return (.speakerAutomatic, "Определено автоматически")
        case "manual": return (.speakerManual, "Назначено вручную")
        default: return nil
        }
    }

    private func speakerDescription(_ row: TranscriptReviewWindowModel.Row) -> String {
        if let origin = speakerOrigin(row) { return "\(row.name). \(origin.label)" }
        return row.name
    }

    @ViewBuilder
    private func speakerCaption(_ row: TranscriptReviewWindowModel.Row, timecode: String) -> some View {
        let origin = speakerOrigin(row)
        let caption = HStack(spacing: 8) {
            Text(row.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ODColors.ink)
            if let origin {
                ODIconView(origin.icon, size: 14, color: ODColors.muted)
                    .accessibilityHidden(true)
            } else if !row.hasSavedName && canEditTurns {
                Text("· Назначить имя")
                    .font(.system(size: 13))
                    .foregroundStyle(ODColors.muted)
            }
        }
        if canEditTurns {
            let title = row.hasSavedName ? "Изменить говорящего" : "Назначить имя"
            Button { openSpeakerEditor(row.id) } label: {
                caption
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ODColors.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ODColors.line))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .speaker(row.id))
            .accessibilityFocused($accessibilityControl, equals: .speaker(row.id))
            .accessibilityLabel("\(title) в \(timecode)")
            .accessibilityValue(speakerDescription(row))
            .help(origin.map { "\(title). \($0.label)" } ?? title)
        } else {
            caption
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(speakerDescription(row))
                .help(origin?.label ?? row.name)
        }
    }

    private func textAction(_ turnID: String, timecode: String, visible: Bool) -> some View {
        turnAction(.edit, control: .text(turnID), label: "Исправить текст в \(timecode)", visible: visible) {
            model.openTextEditing(for: turnID)
            if model.activeTextDraft?.turnID == turnID { editorTrigger = .text(turnID) }
        }
    }

    private func turnAction(_ icon: ODIcon, control: TranscriptControl, label: String, value: String = "",
                            visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // The native control stays in the key-view and accessibility loops.
            ODIconView(icon, size: 16, color: ODColors.muted)
                .opacity(visible ? 1 : 0)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(visible)
        .focused($focusedControl, equals: control)
        .accessibilityFocused($accessibilityControl, equals: control)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .help(label)
    }

    private func openSpeakerEditor(_ turnID: String) {
        model.openVoiceReview(anchorTurnID: turnID)
        if model.voiceReviewVisible { editorTrigger = .speaker(turnID) }
    }

    @discardableResult
    private func restoreEditorFocus() -> Bool {
        guard let trigger = editorTrigger else { return false }
        editorTrigger = nil
        guard canEditTurns, model.rows.contains(where: { $0.id == trigger.turnID }) else {
            focusedControl = .help
            accessibilityControl = .help
            return true
        }
        pendingRowFocus = trigger
        return true
    }

    private func resetTranscriptInteraction() {
        hoveredTurnID = nil
        editorTrigger = nil
        pendingRowFocus = nil
        focusedControl = nil
        accessibilityControl = nil
        showingTranscriptHelp = false
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
            onSeek: { target in
                if let request = model.requestPlaybackSeek(to: target) {
                    Task { await model.performPlaybackSeek(request) }
                }
            })
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
        ODDialog(title: model.activeTextDraft != nil ? "Исправить реплику" : "Сменить спикера",
                 width: min(500, max(300, workspaceWidth - 32)),
                 maxContentHeight: max(200, (NSScreen.main?.visibleFrame.height ?? 900) - 200), close: {
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
                    Text("\(Self.clock(seconds: row.start)) · \(row.originalName) · \(TranscriptDocument.localizedSourceLabel(for: draft.sourceID))")
                        .font(.system(size: 13))
                        .foregroundColor(ODColors.muted)
                    Text(row.text).font(.system(size: 14)).foregroundStyle(ODColors.ink)
                        .lineLimit(4).textSelection(.enabled)
                }

                Text(draft.calendarAttendees.isEmpty ? "Нет свободных подсказок из календаря. Введите имя вручную." : "Подсказки из календаря")
                    .font(.system(size: 13))
                    .foregroundStyle(ODColors.muted)

                let suggestions = draft.calendarAttendees
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
                    if draft.scope == .allVoiceGroup, let preview = confirmation.preview, !preview.replacedTurnIDs.isEmpty {
                        Toggle("Заменить ранее назначенные имена (\(preview.replacedTurnIDs.count))", isOn: Binding(
                            get: { model.activeDraft?.replaceManual ?? false },
                            set: { model.setDraftReplaceManual($0, draftID: draft.id) }
                        ))
                        .toggleStyle(.checkbox)
                    }
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

                let voice = TranscriptVoiceKey(sourceID: draft.sourceID, localID: draft.localID)
                let count = model.voiceGroups.first { $0.id == voice }?.rows.count ?? 0
                Button("Прослушать все реплики этого голоса (\(count)) →", action: model.openDraftVoiceReview)
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(ODColors.accent)
                    .padding(.vertical, 8)

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
}
