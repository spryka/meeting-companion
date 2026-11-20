import Darwin
import Foundation

package final class TranscriptionWorkspace {
    private static let rootName = "MeetingCompanion-transcription-workspaces"
    private let lease: RecordingDirectoryLease
    package var directory: URL { lease.directory }

    package init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
        let root = try Self.lockRoot(in: temporaryDirectory)
        defer { withExtendedLifetime(root) {} }
        Self.removeAbandoned(in: root)

        let name = UUID().uuidString
        let directory = root.directory.appendingPathComponent(name, isDirectory: true)
        try root.validateLocation()
        guard mkdirat(root.fileHandle.fileDescriptor, name, 0o700) == 0 else {
            throw RecordingAudioDirectory.fileError()
        }
        lease = try Self.lockPrivateDirectory(directory)
    }

    deinit { try? Self.remove(lease) }

    package static func removeAbandoned(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        guard let root = try? lockRoot(in: temporaryDirectory) else { return }
        removeAbandoned(in: root)
    }

    private static func lockRoot(in temporaryDirectory: URL) throws -> RecordingDirectoryLease {
        let root = temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST {
            throw RecordingAudioDirectory.fileError()
        }
        return try lockPrivateDirectory(root, wait: true)
    }

    private static func lockPrivateDirectory(_ directory: URL, wait: Bool = false) throws -> RecordingDirectoryLease {
        let lease = try RecordingDirectoryLease(directory, exclusive: true, wait: wait)
        var status = stat()
        guard fstat(lease.fileHandle.fileDescriptor, &status) == 0,
              status.st_uid == geteuid(), status.st_mode & 0o777 == 0o700 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try lease.validateLocation()
        return lease
    }

    private static func removeAbandoned(in root: RecordingDirectoryLease) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.directory.path) else { return }
        for name in names where UUID(uuidString: name) != nil {
            guard (try? root.validateLocation()) != nil else { return }
            let directory = root.directory.appendingPathComponent(name, isDirectory: true)
            guard let lease = try? lockPrivateDirectory(directory) else { continue }
            try? remove(lease)
        }
    }

    private static func remove(_ lease: RecordingDirectoryLease) throws {
        defer { withExtendedLifetime(lease) {} }
        try lease.validateLocation()
        try FileManager.default.removeItem(at: lease.directory)
    }

    package func snapshot(_ source: URL, named name: String, lease: RecordingDirectoryLease?) throws -> URL {
        let sourceDirectory = source.deletingLastPathComponent()
        let root = try lease?.openDirectory() ?? RecordingAudioDirectory(sourceDirectory)
        let parent = try root.directory(at: sourceDirectory)
        let input = try parent.openInput(source.lastPathComponent)
        defer { try? input.close() }

        let target = directory.appendingPathComponent(name).appendingPathExtension(source.pathExtension)
        if fclonefileat(input.fileDescriptor, AT_FDCWD, target.path, UInt32(CLONE_NOOWNERCOPY)) != 0 {
            let output = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw RecordingAudioDirectory.fileError() }
            defer { Darwin.close(output) }
            guard fcopyfile(input.fileDescriptor, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                throw RecordingAudioDirectory.fileError()
            }
        }
        return target
    }
}
