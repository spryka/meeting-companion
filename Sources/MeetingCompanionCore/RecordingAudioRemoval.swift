import Darwin
import Foundation

package struct RecordingAudioRemoval: Codable {
    package static let workerArgument = "--remove-retained-audio"
    // The kernel checks the resolved path at write time, including for inherited directory descriptors.
    private static let profile = """
    (version 1)(allow default)(deny file-write*)(allow file-write* (subpath (param "RECORDING")))
    """

    package struct File: Codable {
        package let directory: [String]
        package let parent: RecordingAudioDirectory.Identity
        package let name: String
        package let identity: RecordingAudioDirectory.Identity
        package let modifiedAt: Date

        package init(directory: [String], parent: RecordingAudioDirectory.Identity, name: String,
                     identity: RecordingAudioDirectory.Identity, modifiedAt: Date) {
            self.directory = directory
            self.parent = parent
            self.name = name
            self.identity = identity
            self.modifiedAt = modifiedAt
        }
    }

    package let folder: URL
    package let files: [File]

    package init(folder: URL, files: [File]) {
        self.folder = folder
        self.files = files
    }

    package func run(worker: URL, lease: RecordingDirectoryLease, scope: String) throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let descriptor = Darwin.open(input.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RecordingAudioDirectory.fileError() }
        defer { _ = unlink(input.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: JSONEncoder().encode(self))
        try handle.close()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", Self.profile, "-D", "RECORDING=" + scope, worker.path, Self.workerArgument, input.path]
        process.standardInput = lease.fileHandle
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)])
        }
    }

    package static func performWorkerRequest(_ arguments: [String]) throws -> Bool {
        guard arguments.first == workerArgument else { return false }
        guard arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let input = URL(fileURLWithPath: arguments[1])
        let removal = try JSONDecoder().decode(Self.self, from: Data(contentsOf: input))
        try removal.perform()
        return true
    }

    private func perform() throws {
        let folder = try RecordingAudioDirectory(folder)
        var lease = stat()
        guard fstat(STDIN_FILENO, &lease) == 0, lease.st_mode & S_IFMT == S_IFDIR,
              lease.st_dev == folder.identity.device, lease.st_ino == folder.identity.inode,
              flock(STDIN_FILENO, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        try folder.child("raw")?.markRetention()

        var firstFailure: (any Error)?
        for file in files {
            do {
                let directory = try file.directory.reduce(folder) { directory, name in
                    guard let child = try directory.child(name) else { throw CocoaError(.fileNoSuchFile) }
                    return child
                }
                guard directory.identity == file.parent else { throw CocoaError(.fileWriteInvalidFileName) }
                try folder.validateLocation()
                try directory.removeAudio(file)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }
}

package final class RecordingAudioDirectory {
    package struct Identity: Codable, Equatable {
        let device: dev_t
        let inode: ino_t
    }

    package let url: URL
    package let identity: Identity
    private let descriptor: Int32
    private static let quarantinePrefix = ".audio-retention."

    package init(_ url: URL, parent: Int32 = AT_FDCWD, name: String? = nil) throws {
        self.url = url
        let descriptor = openat(parent, name ?? url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.fileError() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let error = Self.fileError()
            Darwin.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
        identity = Identity(device: status.st_dev, inode: status.st_ino)
    }

    deinit { Darwin.close(descriptor) }

    package func child(_ name: String) throws -> RecordingAudioDirectory? {
        guard Self.validName(name) else { throw CocoaError(.fileReadInvalidFileName) }
        do {
            return try RecordingAudioDirectory(url.appendingPathComponent(name), parent: descriptor, name: name)
        } catch let error as POSIXError where error.code == .ENOENT || error.code == .ENOTDIR || error.code == .ELOOP {
            return nil
        }
    }

    package func directory(at target: URL) throws -> RecordingAudioDirectory {
        let base = url.pathComponents
        let path = target.pathComponents
        guard path.starts(with: base) else { throw CocoaError(.fileReadInvalidFileName) }
        return try path.dropFirst(base.count).reduce(self) { directory, name in
            guard let child = try directory.child(name) else { throw CocoaError(.fileNoSuchFile) }
            return child
        }
    }

    package func createDirectory(_ name: String) throws {
        guard Self.validName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        guard mkdirat(descriptor, name, 0o777) == 0 else { throw Self.fileError() }
    }

    package func rename(_ source: String, to target: String) throws {
        guard Self.validName(source), Self.validName(target) else { throw CocoaError(.fileWriteInvalidFileName) }
        guard renameatx_np(descriptor, source, descriptor, target, UInt32(RENAME_EXCL)) == 0 else { throw Self.fileError() }
    }

    package func writeAtomically(_ data: Data, named name: String) throws {
        guard Self.validName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        var previous = stat()
        if fstatat(descriptor, name, &previous, AT_SYMLINK_NOFOLLOW) == 0, previous.st_mode & S_IFMT == S_IFLNK {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let temporary = ".transcript-export-" + UUID().uuidString
        let output = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard output >= 0 else { throw Self.fileError() }
        defer { _ = unlinkat(descriptor, temporary, 0) }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw Self.fileError() }
    }

    package func validateLocation() throws {
        var current = stat()
        guard lstat(url.path, &current) == 0, identity == Identity(device: current.st_dev, inode: current.st_ino),
              url.resolvingSymlinksInPath() == url.standardizedFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
    }

    package func names() throws -> [String] {
        try validateLocation()
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    package func openInput(_ name: String) throws -> FileHandle {
        guard Self.validName(name) else { throw CocoaError(.fileReadInvalidFileName) }
        let input = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw Self.fileError() }
        var status = stat()
        guard fstat(input, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(input)
            throw CocoaError(.fileReadInvalidFileName)
        }
        return FileHandle(fileDescriptor: input, closeOnDealloc: true)
    }

    package func fileIdentity(_ name: String) -> Identity? {
        fileState(name)?.identity
    }

    private func fileState(_ name: String) -> (identity: Identity, modifiedAt: Date)? {
        var status = stat()
        guard Self.validName(name), fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
              status.st_mode & S_IFMT == S_IFREG else { return nil }
        let time = status.st_mtimespec
        return (Identity(device: status.st_dev, inode: status.st_ino),
                Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000))
    }

    package static func originalName(_ name: String, device: dev_t, inode: ino_t) -> String {
        let prefix = quarantinePrefix + "\(device).\(inode)."
        guard name.hasPrefix(prefix) else { return name }
        let suffix = name.dropFirst(prefix.count)
        guard suffix.dropFirst(36).first == ".", UUID(uuidString: String(suffix.prefix(36))) != nil else { return name }
        return String(suffix.dropFirst(37))
    }

    package static func quarantineName(for name: String, identity: Identity) -> String {
        quarantinePrefix + "\(identity.device).\(identity.inode).\(UUID().uuidString)." + name
    }

    package func audioFiles(in folder: URL, matching predicate: (String) -> Bool) throws -> [RecordingAudioRemoval.File] {
        let relative = Array(url.pathComponents.dropFirst(folder.pathComponents.count))
        return try names().compactMap { name in
            guard let file = fileState(name) else { return nil }
            guard predicate(Self.originalName(name, device: file.identity.device, inode: file.identity.inode)) else { return nil }
            return RecordingAudioRemoval.File(directory: relative, parent: identity, name: name,
                                              identity: file.identity, modifiedAt: file.modifiedAt)
        }
    }

    fileprivate func markRetention() throws {
        try validateLocation()
        let mark = openat(descriptor, RecordingPaths.audioRetentionMarker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if mark >= 0 {
            Darwin.close(mark)
        } else if errno != EEXIST || fileIdentity(RecordingPaths.audioRetentionMarker) == nil {
            throw Self.fileError()
        }
    }

    fileprivate func removeAudio(_ file: RecordingAudioRemoval.File) throws {
        try validateLocation()
        let name = file.name, identity = file.identity
        guard let current = fileState(name), current.identity == identity, current.modifiedAt == file.modifiedAt else { return }
        let original = Self.originalName(name, device: identity.device, inode: identity.inode)
        let quarantined = Self.quarantineName(for: original, identity: identity)
        // Use a fresh unpublished name for every attempt, including recovery.
        guard renameatx_np(descriptor, name, descriptor, quarantined, UInt32(RENAME_EXCL)) == 0 else { throw Self.fileError() }
        guard let moved = fileState(quarantined), moved.identity == identity, moved.modifiedAt == file.modifiedAt else {
            _ = renameatx_np(descriptor, quarantined, descriptor, name, UInt32(RENAME_EXCL))
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard unlinkat(descriptor, quarantined, 0) == 0 || errno == ENOENT else {
            let error = Self.fileError()
            _ = renameatx_np(descriptor, quarantined, descriptor, name, UInt32(RENAME_EXCL))
            throw error
        }
    }

    static func fileError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
