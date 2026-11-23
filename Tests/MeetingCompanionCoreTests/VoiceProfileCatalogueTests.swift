import Darwin
import Foundation
import Testing
@testable import MeetingCompanionCore

@Suite struct VoiceProfileCatalogueTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("VoiceProfileCatalogueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test func opensSavedPeopleWithoutTheSourceRecording() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
        let first = VoiceProfilePerson(displayName: "Анна", calendarBindings: ["Анна из продукта"])
        let second = VoiceProfilePerson(displayName: "Анна")
        var saved = VoiceProfileCatalogue()
        saved.people = [first, second]
        let bytes = try JSONEncoder().encode(saved)
        try FileManager.default.createDirectory(at: repository.directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let catalogueURL = repository.directory.appendingPathComponent("catalogue.json")
        try bytes.write(to: catalogueURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalogueURL.path)

        let reopened = try repository.load().catalogue
        #expect(reopened.people == [first, second])
        #expect(reopened.people.first?.id != reopened.people.last?.id)
        #expect(try Data(contentsOf: catalogueURL) == bytes)
    }

    @Test func updatesRevisionAndRejectsBothStaleRevisionAndSameRevisionChangedBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
        let initial = try writer.load()
        #expect(!FileManager.default.fileExists(atPath: writer.directory.path))
        let person = VoiceProfilePerson(displayName: "Илья")
        let saved = try writer.update(initial) { $0.people.append(person) }
        #expect(saved.catalogue.revision == 1)
        #expect(saved.catalogue.people == [person])
        #expect(try writer.update(saved) { _ in }.catalogue == saved.catalogue)
        #expect(throws: VoiceProfileCatalogueError.conflict) {
            try writer.update(initial) { $0.people = [] }
        }

        let url = writer.directory.appendingPathComponent("catalogue.json")
        var bytes = try Data(contentsOf: url)
        bytes.append(0x0a)
        try bytes.write(to: url)
        #expect(try writer.load().catalogue == saved.catalogue)
        #expect(throws: VoiceProfileCatalogueError.conflict) {
            try writer.update(saved) { $0.people = [] }
        }
        #expect(try Data(contentsOf: url) == bytes)

        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let models = root.appendingPathComponent("native-models", isDirectory: true)
        for sibling in [recordings, models] {
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
            try FileManager.default.removeItem(at: sibling)
        }
        #expect(try writer.load().catalogue == saved.catalogue)
    }

    @Test func rejectsSymlinksAndAnOccupiedLockWithoutOverwriting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
        let initial = try repository.load()
        let target = root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: repository.directory, withDestinationURL: target)
        #expect(throws: VoiceProfileCatalogueError.unsafePath("VoiceProfiles")) { try repository.load() }
        #expect(throws: VoiceProfileCatalogueError.unsafePath("VoiceProfiles")) {
            try repository.update(initial) { $0.people.append(.init(displayName: "Анна")) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        try FileManager.default.removeItem(at: repository.directory)

        let saved = try repository.update(initial) { $0.people.append(.init(displayName: "Анна")) }
        let lockURL = repository.directory.appendingPathComponent("catalogue.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: VoiceProfileCatalogueError.conflict) {
            try repository.update(saved) { $0.people = [] }
        }
        #expect(try repository.load().catalogue == saved.catalogue)
    }

    @Test func malformedOrFutureCatalogueIsPreserved() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
        _ = try repository.update(repository.load()) { $0.people.append(.init(displayName: "Сергей")) }
        let url = repository.directory.appendingPathComponent("catalogue.json")
        for (json, error) in [
            ("{", VoiceProfileCatalogueError.malformed),
            (#"{"schemaVersion":2}"#, .unsupportedVersion(2))
        ] {
            let bytes = Data(json.utf8)
            try bytes.write(to: url)
            #expect(throws: error) { try repository.load() }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func replacingTheDocumentCannotWriteAFutureSchema() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
        let saved = try writer.update(writer.load()) { $0.people.append(.init(displayName: "Анна")) }
        let future = try JSONDecoder().decode(VoiceProfileCatalogue.self, from: Data(
            #"{"schemaVersion":2,"revision":0,"generation":0,"people":[],"samples":[],"aggregates":[]}"#.utf8
        ))
        #expect(throws: VoiceProfileCatalogueError.unsupportedVersion(2)) {
            try writer.update(saved) { $0 = future }
        }
        #expect(try writer.load().catalogue == saved.catalogue)
    }

    @Test func replacingTheDocumentCannotReinstateAnOldCASSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
        let first = try writer.update(writer.load()) { $0.people.append(.init(displayName: "Анна")) }
        let second = try writer.update(first) { $0.people.append(.init(displayName: "Илья")) }
        var replacement = VoiceProfileCatalogue()
        replacement.people = first.catalogue.people
        let third = try writer.update(second) { $0 = replacement }
        #expect(third.catalogue.revision == 3)
        #expect(throws: VoiceProfileCatalogueError.conflict) {
            try writer.update(first) { $0.people.removeAll() }
        }
        var sameContent = VoiceProfileCatalogue()
        sameContent.people = third.catalogue.people
        #expect(try writer.update(third) { $0 = sameContent }.catalogue.revision == 3)
    }

    @Test func rejectsACLsOnDirectoryAndExistingFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
        func setACL(_ acl: String, at url: URL) throws {
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+a", acl, url.path]
            try chmod.run()
            chmod.waitUntilExit()
            try #require(chmod.terminationStatus == 0)
        }
        let initial = try writer.load()
        try FileManager.default.createDirectory(at: writer.directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try setACL("everyone allow read,search,file_inherit,directory_inherit", at: writer.directory)
        #expect(throws: VoiceProfileCatalogueError.unsafePath("VoiceProfiles")) {
            try writer.update(initial) { $0.people.append(.init(displayName: "Анна")) }
        }
        try FileManager.default.removeItem(at: writer.directory)

        let saved = try writer.update(initial) { $0.people.append(.init(displayName: "Анна")) }
        try setACL("everyone allow read", at: writer.directory.appendingPathComponent("catalogue.lock"))
        #expect(throws: VoiceProfileCatalogueError.unsafePath("catalogue.lock")) {
            try writer.update(saved) { $0.people.removeAll() }
        }
        try setACL("everyone allow read", at: writer.directory.appendingPathComponent("catalogue.json"))
        #expect(throws: VoiceProfileCatalogueError.unsafePath("catalogue.json")) { try writer.load() }
    }

    @Test func persistsEmbeddingsAndRejectsInvalidActiveProfilesAtomically() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
        let person = VoiceProfilePerson(displayName: "Анна")
        let unit = [Float(1)] + Array(repeating: Float(0), count: 255)
        let samples = (0..<13).map { index in
            VoiceProfileSample(personID: person.id, embeddingSpaceID: "we-speaker-v1", embedding: unit,
                               recordingLocator: "missing-recording-\(index / 4)", resultID: "result", turnID: "turn-\(index)",
                               sourceID: .host, start: Double(index * 6), end: Double((index + 1) * 6),
                               pcmFingerprint: "pcm-\(index)",
                               assignment: .init(personID: person.id, origin: "manual"), policyID: "policy")
        }
        func aggregate(_ active: [VoiceProfileSample], vector: [Float] = unit) -> VoiceProfileAggregate {
            VoiceProfileAggregate(personID: person.id, embeddingSpaceID: "we-speaker-v1", centroid: vector,
                                  activeSampleIDs: active.map(\.id), policyID: "policy")
        }
        let saved = try repo.update(repo.load()) {
            $0.people = [person]
            $0.samples = Array(samples.prefix(12))
            $0.aggregates = [aggregate($0.samples)]
        }
        #expect(try repo.load().catalogue == saved.catalogue)
        #expect(throws: VoiceProfileCatalogueError.malformed) {
            _ = try repo.update(saved) {
                $0.samples = samples
                $0.aggregates = [aggregate(samples)]
            }
        }
        #expect(throws: VoiceProfileCatalogueError.malformed) {
            _ = try repo.update(saved) { $0.aggregates = [aggregate($0.samples, vector: Array(repeating: 0, count: 256))] }
        }
        #expect(try repo.load().catalogue == saved.catalogue)
    }
}
