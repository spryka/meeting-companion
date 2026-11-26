import Foundation
import MeetingCompanionCore

struct VoicePersonNames {
    let sortedPeople: [VoiceProfilePerson]
    let peopleByKey: [String: [VoiceProfilePerson]]

    init(_ people: [VoiceProfilePerson]) {
        sortedPeople = people.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if $0.calendarBindings.isEmpty != $1.calendarBindings.isEmpty { return !$0.calendarBindings.isEmpty }
            return $0.id.uuidString < $1.id.uuidString
        }
        peopleByKey = Dictionary(grouping: sortedPeople) {
            TranscriptSpeakerAssignmentService.nameComparisonKey($0.displayName)
        }
    }

    func homonyms(of person: VoiceProfilePerson) -> [VoiceProfilePerson] {
        peopleByKey[TranscriptSpeakerAssignmentService.nameComparisonKey(person.displayName)] ?? []
    }

    func subtitle(for person: VoiceProfilePerson) -> String? {
        if let contact = person.calendarBindings.first, !contact.isEmpty { return contact }
        let group = homonyms(of: person)
        guard group.count > 1, let index = group.firstIndex(where: { $0.id == person.id }) else { return nil }
        return "Профиль \(index + 1)"
    }
}

struct VoiceDirectorySnapshot: Sendable {
    struct Row: Identifiable, Sendable {
        let person: VoiceProfilePerson
        let subtitle: String?
        let meetingCount: Int
        let status: Status
        let failure: String?
        let hasCompatibleProfile: Bool
        var id: UUID { person.id }
    }

    enum Status: String, Sendable {
        case ready = "Готов"
        case insufficientSpeech = "Недостаточно речи"
        case updating = "Обновляется"
        case failed = "Не удалось обновить"
        case outdated = "Нужно обновить профиль"
    }

    let rows: [Row]

    init(catalogue: VoiceProfileCatalogue, activeLearningEvents: Set<UUID> = []) {
        let names = VoicePersonNames(catalogue.people)
        let aggregates = Dictionary(uniqueKeysWithValues: catalogue.availableAggregates.map { ($0.personID, $0) })
        let samplesByPerson = Dictionary(grouping: catalogue.samples, by: \.personID)
        let activeByPerson = Dictionary(grouping: (catalogue.learningRecords ?? []).filter {
            activeLearningEvents.contains($0.id) && $0.stage == .committed && $0.outcome == nil &&
                $0.catalogueGeneration == catalogue.generation
        }, by: { $0.event.assignment?.personID })
        rows = names.sortedPeople.map { person in
            let aggregate = aggregates[person.id]
            let ready = aggregate?.embeddingSpaceID == VoiceEmbeddingProtocol.embeddingSpaceID
            let activeSamples = Set(ready ? (aggregate?.activeSampleIDs ?? []) : [])
            let meetings = (samplesByPerson[person.id] ?? []).filter { activeSamples.contains($0.id) }.map {
                // This is the same meeting identity used by VoiceProfileUpdatePolicy.
                $0.recordingFingerprint ?? $0.resultID
            }
            let update = catalogue.latestLearningUpdate(for: person.id)
            let failure = Self.failure(in: update)
            let updating = activeByPerson[person.id]?.contains { $0.personGeneration == person.generation } == true
            let status: Status
            if updating {
                status = .updating
            } else if failure != nil {
                status = .failed
            } else if ready {
                status = .ready
            } else {
                status = aggregate == nil ? .insufficientSpeech : .outdated
            }
            return Row(person: person, subtitle: names.homonyms(of: person).count > 1 ? names.subtitle(for: person) : nil,
                       meetingCount: Set(meetings).count, status: status, failure: failure, hasCompatibleProfile: ready)
        }
    }

    func rows(matching search: String) -> [Row] {
        let key = TranscriptSpeakerAssignmentService.nameComparisonKey
        let query = key(search)
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            key(row.person.displayName).contains(query) ||
                row.person.calendarBindings.contains { key($0).contains(query) } ||
                row.subtitle.map { key($0).contains(query) } == true
        }
    }

    private static func failure(in update: VoiceProfileLearningRecord?) -> String? {
        guard let update, update.stage == .committed, let outcome = update.outcome else { return nil }
        switch outcome {
        case "Лимит фрагментов этой правки достигнут.", "Недостаточно чистой речи.", "Нет новых пригодных эталонов.":
            return nil
        default:
            return outcome
        }
    }
}
