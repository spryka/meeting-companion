import Darwin
import Foundation

public struct VoiceProfilePerson: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var calendarBindings: [String]
    public var generation: UInt64

    public init(id: UUID = UUID(), displayName: String, calendarBindings: [String] = [], generation: UInt64 = 0) {
        self.id = id
        self.displayName = displayName
        self.calendarBindings = calendarBindings
        self.generation = generation
    }
}

public struct VoiceProfileSample: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let personID: UUID
    public let embeddingSpaceID: String
    public let embedding: [Float]
    public let recordingLocator: String
    public let recordingFingerprint: String?
    public let resultID: String
    public let turnID: String
    public let sourceID: TranscriptDocument.SourceID
    public let start: Double
    public let end: Double
    public let pcmFingerprint: String
    public let assignment: TranscriptNameAssignment
    public let policyID: String

    public init(
        id: UUID = UUID(), personID: UUID, embeddingSpaceID: String, embedding: [Float],
        recordingLocator: String, resultID: String, turnID: String, sourceID: TranscriptDocument.SourceID,
        start: Double, end: Double, pcmFingerprint: String,
        assignment: TranscriptNameAssignment, policyID: String, recordingFingerprint: String? = nil
    ) {
        self.id = id
        self.personID = personID
        self.embeddingSpaceID = embeddingSpaceID
        self.embedding = embedding
        self.recordingLocator = recordingLocator
        self.recordingFingerprint = recordingFingerprint
        self.resultID = resultID
        self.turnID = turnID
        self.sourceID = sourceID
        self.start = start
        self.end = end
        self.pcmFingerprint = pcmFingerprint
        self.assignment = assignment
        self.policyID = policyID
    }
}

public extension VoiceProfileSample {
    static let minimumWindowFrames = 3 * VoiceEmbeddingProtocol.sampleRate
    static let maximumWindowFrames = 6 * VoiceEmbeddingProtocol.sampleRate
    static let minimumActiveSamples = 3
    static let minimumActiveFrames = 12 * VoiceEmbeddingProtocol.sampleRate

    var frameCount: Int? {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        let rate = Double(VoiceEmbeddingProtocol.sampleRate)
        guard let startFrame = Int(exactly: (start * rate).rounded()),
              let endFrame = Int(exactly: (end * rate).rounded()),
              startFrame >= 0, endFrame > startFrame else { return nil }
        return endFrame - startFrame
    }

    var hasValidWindowDuration: Bool {
        frameCount.map { (Self.minimumWindowFrames...Self.maximumWindowFrames).contains($0) } == true
    }

    static func hasSufficientActiveSpeech(_ samples: [VoiceProfileSample]) -> Bool {
        guard samples.count >= minimumActiveSamples else { return false }
        var totalFrames = 0
        for sample in samples {
            guard let frames = sample.frameCount else { return false }
            let (next, overflow) = totalFrames.addingReportingOverflow(frames)
            if overflow { return true }
            totalFrames = next
        }
        return totalFrames >= minimumActiveFrames
    }
}

public struct VoiceProfileAggregate: Codable, Equatable, Sendable {
    public let personID: UUID
    public let embeddingSpaceID: String
    public let centroid: [Float]
    public let activeSampleIDs: [UUID]
    public let policyID: String

    public init(personID: UUID, embeddingSpaceID: String, centroid: [Float], activeSampleIDs: [UUID], policyID: String) {
        self.personID = personID
        self.embeddingSpaceID = embeddingSpaceID
        self.centroid = centroid
        self.activeSampleIDs = activeSampleIDs
        self.policyID = policyID
    }
}

public struct VoiceProfileLearningRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case prepared, committed, aborted, superseded, skipped, applied
    }

    public var id: UUID { event.eventID }
    public let event: TranscriptLearningEvent
    public var recordingLocator: String
    public let resultID: String
    public let previousFingerprint: String?
    public let savedFingerprint: String?
    public let catalogueGeneration: UInt64
    public let personGeneration: UInt64?
    public var stage: Stage
    public var outcome: String?
    public var extractedWindows: Int?

    public init(
        event: TranscriptLearningEvent, recordingLocator: String, resultID: String,
        previousFingerprint: String?, savedFingerprint: String?, catalogueGeneration: UInt64,
        personGeneration: UInt64?, stage: Stage
    ) {
        self.event = event
        self.recordingLocator = recordingLocator
        self.resultID = resultID
        self.previousFingerprint = previousFingerprint
        self.savedFingerprint = savedFingerprint
        self.catalogueGeneration = catalogueGeneration
        self.personGeneration = personGeneration
        self.stage = stage
    }
}

public struct VoiceProfileCatalogue: Codable, Equatable, Sendable {
    public struct SeenSamples: Codable, Equatable, Sendable {
        public var pcm: Set<String> = []
        public var assignmentWindows: Set<String> = []

        public init() {}
    }

    public private(set) var schemaVersion: Int = 1
    public fileprivate(set) var revision: UInt64 = 0
    public fileprivate(set) var instanceID: UUID?
    public var generation: UInt64 = 0
    public var people: [VoiceProfilePerson] = []
    public var samples: [VoiceProfileSample] = []
    public var aggregates: [VoiceProfileAggregate] = []
    public var learningRecords: [VoiceProfileLearningRecord]?
    public var deletedPersonIDs: Set<UUID>?
    public var seenSamples: [UUID: SeenSamples]?

    public var availableAggregates: [VoiceProfileAggregate] {
        let suspended = Set((learningRecords ?? []).compactMap { record in
            record.stage == .prepared ? record.event.previousAssignment?.assignmentID : nil
        })
        return aggregatesExcluding(assignments: suspended)
    }

    public func latestLearningUpdate(for personID: UUID) -> VoiceProfileLearningRecord? {
        guard let generation = people.first(where: { $0.id == personID })?.generation else { return nil }
        let updates = (learningRecords ?? []).filter {
            $0.event.assignment?.personID == personID && $0.personGeneration == generation
        }
        guard let latest = updates.last else { return nil }
        return updates.last(where: {
            $0.recordingLocator == latest.recordingLocator && $0.resultID == latest.resultID &&
                $0.event.editsRevision == latest.event.editsRevision && $0.stage == .committed && $0.outcome != nil
        }) ?? latest
    }

    public mutating func revokeSamples(assignments: Set<UUID>) {
        aggregates = aggregatesExcluding(assignments: assignments)
        samples.removeAll { assignments.contains($0.assignment.assignmentID) }
    }

    private func aggregatesExcluding(assignments: Set<UUID>) -> [VoiceProfileAggregate] {
        guard !assignments.isEmpty else { return aggregates }
        let retained = Dictionary(samples.compactMap { sample in
            assignments.contains(sample.assignment.assignmentID) ? nil : (sample.id, sample)
        }, uniquingKeysWith: { first, _ in first })
        return aggregates.compactMap { aggregate in
            let active = aggregate.activeSampleIDs.compactMap { retained[$0] }
            if active.count == aggregate.activeSampleIDs.count { return aggregate }
            guard VoiceProfileSample.hasSufficientActiveSpeech(active) else { return nil }
            var sums = Array(repeating: 0.0, count: 256)
            for sample in active {
                for (index, value) in sample.embedding.prefix(sums.count).enumerated() { sums[index] += Double(value) }
            }
            let norm = sums.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { return nil }
            return VoiceProfileAggregate(personID: aggregate.personID, embeddingSpaceID: aggregate.embeddingSpaceID,
                                         centroid: sums.map { Float($0 / norm) }, activeSampleIDs: active.map(\.id),
                                         policyID: aggregate.policyID)
        }
    }
}

public enum VoiceProfileCatalogueError: LocalizedError, Equatable {
    case conflict
    case unsafePath(String)
    case malformed
    case unsupportedVersion(Int)
    case io(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .conflict: "Каталог голосов уже изменён или занят."
        case .unsafePath(let name): "Небезопасный путь каталога голосов: \(name)."
        case .malformed: "Каталог голосов повреждён."
        case .unsupportedVersion(let version): "Версия каталога голосов \(version) не поддерживается."
        case .io(let operation, let code): "Ошибка каталога голосов при операции \(operation) (\(code))."
        }
    }
}

public struct VoiceProfileCatalogueRepository: Sendable {
    private static let catalogueName = "catalogue.json"
    private static let maxBytes = 64 * 1024 * 1024
    public let directory: URL

    public struct Snapshot: Sendable {
        public let catalogue: VoiceProfileCatalogue
        public var sizeInBytes: Int { bytes?.count ?? 0 }
        fileprivate let bytes: Data?
        fileprivate let directory: URL
    }

    public init(applicationDataDirectory: URL) {
        self.directory = applicationDataDirectory.standardizedFileURL.appendingPathComponent("VoiceProfiles", isDirectory: true)
    }

    public func load() throws -> Snapshot {
        guard let descriptor = try openDirectory(create: false) else {
            return Snapshot(catalogue: VoiceProfileCatalogue(), bytes: nil, directory: directory)
        }
        defer { close(descriptor) }
        let bytes = try readCatalogue(in: descriptor)
        return Snapshot(catalogue: try bytes.map(decode) ?? VoiceProfileCatalogue(), bytes: bytes, directory: directory)
    }

    public func update(_ expected: Snapshot, _ change: (inout VoiceProfileCatalogue) throws -> Void) throws -> Snapshot {
        guard expected.directory == directory else { throw VoiceProfileCatalogueError.conflict }

        guard let descriptor = try openDirectory(create: true) else {
            throw VoiceProfileCatalogueError.io("open catalogue directory", ENOENT)
        }
        defer { close(descriptor) }
        let lock = try acquireCatalogueLock(in: descriptor, writing: true)
        defer { close(lock) }
        guard try readCatalogue(in: descriptor) == expected.bytes else {
            throw VoiceProfileCatalogueError.conflict
        }
        var catalogue = expected.catalogue
        try change(&catalogue)
        catalogue.revision = expected.catalogue.revision
        catalogue.instanceID = expected.catalogue.instanceID ?? UUID()
        try validate(catalogue)
        if catalogue == expected.catalogue { return expected }
        guard catalogue.revision < UInt64.max else { throw VoiceProfileCatalogueError.malformed }
        catalogue.revision += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(catalogue)
        guard bytes.count <= Self.maxBytes else { throw VoiceProfileCatalogueError.malformed }

        let staged = "catalogue-\(UUID().uuidString).tmp"
        let file = openat(descriptor, staged, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw VoiceProfileCatalogueError.io("stage catalogue", errno) }
        defer {
            close(file)
            unlinkat(descriptor, staged, 0)
        }
        guard hasNoExtendedACL(file) else { throw VoiceProfileCatalogueError.unsafePath(staged) }
        try FileHandle(fileDescriptor: file, closeOnDealloc: false).write(contentsOf: bytes)
        guard fsync(file) == 0 else { throw VoiceProfileCatalogueError.io("sync catalogue", errno) }

        var opened = stat(), visible = stat()
        guard fstat(descriptor, &opened) == 0, lstat(directory.path, &visible) == 0,
              opened.st_dev == visible.st_dev, opened.st_ino == visible.st_ino,
              try readCatalogue(in: descriptor) == expected.bytes else {
            throw VoiceProfileCatalogueError.conflict
        }
        let result = expected.bytes == nil
            ? renameatx_np(descriptor, staged, descriptor, Self.catalogueName, UInt32(RENAME_EXCL))
            : renameat(descriptor, staged, descriptor, Self.catalogueName)
        guard result == 0 else {
            let code = errno
            if code == EEXIST { throw VoiceProfileCatalogueError.conflict }
            throw VoiceProfileCatalogueError.io("replace catalogue", code)
        }
        return Snapshot(catalogue: catalogue, bytes: bytes, directory: directory)
    }

    /// Fence a commit based on a persisted catalogue without changing catalogue metadata.
    public func withVerifiedSnapshot<T>(_ expected: Snapshot, _ body: () throws -> T) throws -> T {
        guard expected.directory == directory, expected.bytes != nil,
              let descriptor = try openDirectory(create: false) else {
            throw VoiceProfileCatalogueError.conflict
        }
        defer { close(descriptor) }
        let lock = try acquireCatalogueLock(in: descriptor, writing: false)
        defer { close(lock) }
        guard try readCatalogue(in: descriptor) == expected.bytes else {
            throw VoiceProfileCatalogueError.conflict
        }
        return try body()
    }

    private func acquireCatalogueLock(in descriptor: Int32, writing: Bool) throws -> Int32 {
        let flags = writing ? O_RDWR | O_CREAT : O_RDONLY
        guard let lock = try openPrivateFile("catalogue.lock", in: descriptor, flags: flags) else {
            throw VoiceProfileCatalogueError.io("open catalogue lock", ENOENT)
        }
        let mode = writing ? LOCK_EX : LOCK_SH
        guard flock(lock, mode | LOCK_NB) == 0 else {
            let code = errno
            close(lock)
            if code == EWOULDBLOCK { throw VoiceProfileCatalogueError.conflict }
            throw VoiceProfileCatalogueError.io("lock catalogue", code)
        }
        return lock
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        let parent = directory.deletingLastPathComponent()
        guard directory.isFileURL, parent.path == parent.resolvingSymlinksInPath().path else {
            throw VoiceProfileCatalogueError.unsafePath("Application Support")
        }
        if create {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let parentDescriptor = open(parent.path, flags)
        guard parentDescriptor >= 0 else { return try missingOrUnsafe("Application Support", errno) }
        defer { close(parentDescriptor) }
        if create, mkdirat(parentDescriptor, directory.lastPathComponent, 0o700) != 0, errno != EEXIST {
            throw VoiceProfileCatalogueError.io("create catalogue directory", errno)
        }
        let descriptor = openat(parentDescriptor, directory.lastPathComponent, flags)
        guard descriptor >= 0 else { return try missingOrUnsafe(directory.lastPathComponent, errno) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0,
              hasNoExtendedACL(descriptor) else {
            close(descriptor)
            throw VoiceProfileCatalogueError.unsafePath(directory.lastPathComponent)
        }
        return descriptor
    }

    private func openPrivateFile(_ name: String, in directory: Int32, flags: Int32) throws -> Int32? {
        let descriptor = openat(directory, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { return try missingOrUnsafe(name, errno) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1, metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0,
              hasNoExtendedACL(descriptor) else {
            close(descriptor)
            throw VoiceProfileCatalogueError.unsafePath(name)
        }
        return descriptor
    }

    private func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }

    private func missingOrUnsafe(_ component: String, _ code: Int32) throws -> Int32? {
        switch code {
        case ENOENT: return nil
        case ELOOP, ENOTDIR: throw VoiceProfileCatalogueError.unsafePath(component)
        default: throw VoiceProfileCatalogueError.io("open \(component)", code)
        }
    }

    private func readCatalogue(in directory: Int32) throws -> Data? {
        guard let descriptor = try openPrivateFile(Self.catalogueName, in: directory, flags: O_RDONLY) else { return nil }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw VoiceProfileCatalogueError.io("read catalogue metadata", errno) }
        guard (0...Int64(Self.maxBytes)).contains(metadata.st_size) else { throw VoiceProfileCatalogueError.malformed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let expectedSize = Int(metadata.st_size)
        let data = try handle.read(upToCount: expectedSize + 1) ?? Data()
        guard data.count == expectedSize else { throw VoiceProfileCatalogueError.conflict }
        return data
    }

    private struct Header: Decodable { let schemaVersion: Int }

    private func decode(_ data: Data) throws -> VoiceProfileCatalogue {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw VoiceProfileCatalogueError.malformed
        }
        guard header.schemaVersion == 1 else { throw VoiceProfileCatalogueError.unsupportedVersion(header.schemaVersion) }
        guard let catalogue = try? decoder.decode(VoiceProfileCatalogue.self, from: data) else {
            throw VoiceProfileCatalogueError.malformed
        }
        try validate(catalogue)
        return catalogue
    }

    private func validate(_ catalogue: VoiceProfileCatalogue) throws {
        guard catalogue.schemaVersion == 1 else {
            throw VoiceProfileCatalogueError.unsupportedVersion(catalogue.schemaVersion)
        }
        let learningRecords = catalogue.learningRecords ?? []
        guard Set(learningRecords.map(\.id)).count == learningRecords.count,
              learningRecords.allSatisfy({ !$0.recordingLocator.isEmpty && !$0.resultID.isEmpty &&
                  !$0.event.turnID.isEmpty && $0.event.editsRevision > 0 &&
                  (0...4).contains($0.extractedWindows ?? 0) }) else {
            throw VoiceProfileCatalogueError.malformed
        }
        let people = Set(catalogue.people.map(\.id))
        guard people.count == catalogue.people.count,
              people.isDisjoint(with: catalogue.deletedPersonIDs ?? []),
              (catalogue.seenSamples?.keys.allSatisfy(people.contains) ?? true),
              catalogue.people.allSatisfy({ !$0.displayName.allSatisfy(\.isWhitespace) }) else {
            throw VoiceProfileCatalogueError.malformed
        }
        let sampleIDs = Set(catalogue.samples.map(\.id))
        guard sampleIDs.count == catalogue.samples.count,
              catalogue.samples.allSatisfy({ sample in
                  people.contains(sample.personID) && sample.assignment.personID == sample.personID &&
                  sample.assignment.canContributeVoiceSamples && sample.assignment.version > 0 &&
                  sample.start.isFinite && sample.end.isFinite && sample.start >= 0 && sample.end > sample.start &&
                  !sample.recordingLocator.isEmpty && !sample.resultID.isEmpty && !sample.turnID.isEmpty &&
                  sample.recordingFingerprint.map(VoiceAudioQuality.isFingerprint) != false &&
                  !sample.pcmFingerprint.isEmpty && !sample.embeddingSpaceID.isEmpty && !sample.policyID.isEmpty &&
                  isUnitEmbedding(sample.embedding)
              }) else {
            throw VoiceProfileCatalogueError.malformed
        }
        let samples = Dictionary(uniqueKeysWithValues: catalogue.samples.map { ($0.id, $0) })
        guard Set(catalogue.aggregates.map(\.personID)).count == catalogue.aggregates.count,
              catalogue.aggregates.allSatisfy({ profile in
                  let active = Set(profile.activeSampleIDs)
                  return people.contains(profile.personID) && (1...12).contains(active.count) &&
                      active.count == profile.activeSampleIDs.count && !profile.policyID.isEmpty &&
                      isUnitEmbedding(profile.centroid) && active.allSatisfy { id in
                          samples[id]?.personID == profile.personID && samples[id]?.embeddingSpaceID == profile.embeddingSpaceID
                      }
              }) else {
            throw VoiceProfileCatalogueError.malformed
        }
    }

    private func isUnitEmbedding(_ values: [Float]) -> Bool {
        guard values.count == 256, values.allSatisfy(\.isFinite) else { return false }
        let normSquared = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        return abs(normSquared - 1) <= 0.01
    }
}
