import Foundation
import MeetingCompanionApplication
@testable import MeetingCompanionCore
import Testing
@testable import MeetingCompanionApp

struct VoiceDirectoryTests {
    @Test func findsNamesBindingsAndStableHomonymSubtitles() {
        let linked = VoiceProfilePerson(displayName: "Анна Лебедева",
            calendarBindings: ["anna@example.test", "second@example.test"])
        let other = VoiceProfilePerson(displayName: linked.displayName)
        let unique = VoiceProfilePerson(displayName: "Илья Соколов", calendarBindings: ["ilya@example.test"])
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [unique, other, linked]
        let directory = VoiceDirectorySnapshot(catalogue: catalogue)
        #expect(directory.rows.map(\.id) == [linked.id, other.id, unique.id])
        #expect(directory.rows.map(\.subtitle) == ["anna@example.test", "Профиль 2", nil])
        #expect(directory.rows(matching: "  АННА  ").map(\.id) == [linked.id, other.id])
        #expect(directory.rows(matching: "SECOND@").map(\.id) == [linked.id])
        #expect(directory.rows(matching: "илья@example").isEmpty)
        #expect(directory.rows(matching: "ilya@example").map(\.id) == [unique.id])
        #expect(directory.rows(matching: "профиль 2").map(\.id) == [other.id])
    }

    @Test func countsOnlyDistinctActiveMeetingsAndShowsZeroAfterReset() throws {
        let person = VoiceProfilePerson(displayName: "Анна", calendarBindings: ["anna@example.test"])
        let second = VoiceProfilePerson(displayName: "Борис")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = VoiceProfileCatalogueRepository(applicationDataDirectory: directory)
        let fingerprint = String(repeating: "a", count: 64)
        let samples = [
            sample(person.id, result: "before-retry", fingerprint: fingerprint),
            sample(person.id, result: "after-retry", fingerprint: fingerprint),
            sample(person.id, result: "legacy", fingerprint: nil),
            sample(person.id, result: "legacy", fingerprint: nil),
            sample(person.id, result: "inactive", fingerprint: nil),
            sample(second.id, result: "other", fingerprint: nil),
        ]
        let seeded = try repo.update(repo.load()) { value in
            value.people = [person, second]
            value.samples = samples
            value.aggregates = [aggregate(person.id, samples: Array(samples.prefix(4)))]
        }
        let before = try #require(VoiceDirectorySnapshot(catalogue: seeded.catalogue).rows.first { $0.id == person.id })
        #expect(before.status == .ready)
        #expect(before.meetingCount == 2)

        try VoiceLearningCoordinator(catalogue: repo).resetPerson(person.id, delete: false)
        let reset = try repo.load().catalogue
        let after = try #require(VoiceDirectorySnapshot(catalogue: reset).rows.first { $0.id == person.id })
        #expect(after.meetingCount == 0)
        #expect(after.status == .insufficientSpeech)
        #expect(after.person.calendarBindings.isEmpty)
        #expect(reset.samples.map(\.personID) == [second.id])
    }

    @Test(arguments: [
        "Лимит фрагментов этой правки достигнут.",
        "Недостаточно чистой речи.",
        "Нет новых пригодных эталонов.",
    ])
    func ordinaryHistoricalOutcomeDoesNotMarkReadyProfileAsFailed(_ outcome: String) throws {
        let person = VoiceProfilePerson(displayName: "Анна")
        var catalogue = readyCatalogue(person)
        catalogue.learningRecords = [try update(person, outcome: outcome)]
        let row = try #require(VoiceDirectorySnapshot(catalogue: catalogue).rows.first)
        #expect(row.status == .ready)
        #expect(row.failure == nil)
    }

    @Test func actualFailurePreservesExistingProfileAndCount() throws {
        let person = VoiceProfilePerson(displayName: "Анна")
        var catalogue = readyCatalogue(person)
        let reason = "Не удалось прочитать исходное аудио."
        catalogue.learningRecords = [try update(person, outcome: reason)]
        let row = try #require(VoiceDirectorySnapshot(catalogue: catalogue).rows.first)
        #expect(row.status == .failed)
        #expect(row.failure == reason)
        #expect(row.hasCompatibleProfile)
        #expect(row.meetingCount == 1)
    }

    @Test func onlyActiveLearningForThisPersonShowsUpdating() throws {
        let person = VoiceProfilePerson(displayName: "Анна")
        let other = VoiceProfilePerson(displayName: "Борис")
        var catalogue = readyCatalogue(person)
        catalogue.people.append(other)
        let pending = try update(person)
        let active = try update(other)
        catalogue.learningRecords = [pending, active]
        let rows = VoiceDirectorySnapshot(catalogue: catalogue, activeLearningEvents: [active.id]).rows
        #expect(rows.map(\.status) == [.ready, .updating])
    }

    @Test func incompatibleAggregateRequiresUpdatingAndContributesNoMeetings() throws {
        let person = VoiceProfilePerson(displayName: "Анна")
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        let old = sample(person.id, result: "legacy", fingerprint: nil, space: "old")
        catalogue.samples = [old]
        catalogue.aggregates = [aggregate(person.id, samples: [old])]
        let row = try #require(VoiceDirectorySnapshot(catalogue: catalogue).rows.first)
        #expect(row.status == .outdated)
        #expect(row.meetingCount == 0)
        #expect(!row.hasCompatibleProfile)
    }

    private func readyCatalogue(_ person: VoiceProfilePerson) -> VoiceProfileCatalogue {
        var catalogue = VoiceProfileCatalogue()
        catalogue.people = [person]
        catalogue.samples = (0..<3).map { _ in sample(person.id, result: "legacy", fingerprint: nil) }
        catalogue.aggregates = [aggregate(person.id, samples: catalogue.samples)]
        return catalogue
    }

    private func sample(_ personID: UUID, result: String, fingerprint: String?,
                        space: String = VoiceEmbeddingProtocol.embeddingSpaceID) -> VoiceProfileSample {
        .init(personID: personID, embeddingSpaceID: space, embedding: [1] + Array(repeating: 0, count: 255),
              recordingLocator: "fixture", resultID: result, turnID: "t0", sourceID: .host,
              start: 0, end: 4, pcmFingerprint: UUID().uuidString,
              assignment: .init(personID: personID, origin: "manual"), policyID: "fixture",
              recordingFingerprint: fingerprint)
    }

    private func aggregate(_ personID: UUID, samples: [VoiceProfileSample]) -> VoiceProfileAggregate {
        .init(personID: personID, embeddingSpaceID: samples[0].embeddingSpaceID, centroid: samples[0].embedding,
              activeSampleIDs: samples.map(\.id), policyID: "fixture")
    }

    private func update(_ person: VoiceProfilePerson, outcome: String? = nil) throws -> VoiceProfileLearningRecord {
        let assignment = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            TranscriptNameAssignment(personID: person.id, origin: "manual")))
        let event = try JSONDecoder().decode(TranscriptLearningEvent.self, from: JSONSerialization.data(withJSONObject: [
            "eventID": UUID().uuidString, "turnID": "t0", "editsRevision": 1, "allowsLearning": true,
            "assignment": assignment,
        ]))
        var record = VoiceProfileLearningRecord(event: event, recordingLocator: "fixture", resultID: "legacy",
            previousFingerprint: nil, savedFingerprint: nil, catalogueGeneration: 0, personGeneration: person.generation,
            stage: .committed)
        record.outcome = outcome
        return record
    }
}
