import Darwin
import Foundation

/// The CLI owns a shared lock from capture through publication. Retention requires exclusive access.
public final class RecordingDirectoryLock: Sendable {
    let descriptor: Int32
    public init(folder: URL, exclusive: Bool) throws {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        descriptor = fd
    }
    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    // Anchor every lookup at the locked folder; links cannot redirect removal outside it.
    func removeFile(_ file: URL, from folder: URL) throws {
        let components = file.pathComponents.dropFirst(folder.pathComponents.count)
        guard let name = components.last, file.pathComponents.starts(with: folder.pathComponents) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var parent = dup(descriptor)
        guard parent >= 0 else { throw posixError() }
        defer { close(parent) }
        for part in components.dropLast() {
            let next = openat(parent, part, O_DIRECTORY | O_NOFOLLOW | O_RDONLY | O_CLOEXEC)
            guard next >= 0 else { throw posixError() }
            close(parent)
            parent = next
        }
        var fileInfo = stat()
        guard fstatat(parent, name, &fileInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
        guard fileInfo.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileWriteInvalidFileName) }
        guard unlinkat(parent, name, 0) == 0 else { throw posixError() }
    }

    func removeMeeting(_ target: RecordingTrashTarget) throws {
        try withVerifiedParent(of: target) { _ in
            // Recursive removal stays on the opened inode, even if its name is replaced.
            guard removefileat(descriptor, ".", nil, UInt32(REMOVEFILE_RECURSIVE | REMOVEFILE_KEEP_PARENT)) == 0 else { throw posixError() }
        }
        try withVerifiedParent(of: target) { parent in
            guard unlinkat(parent, target.folder.lastPathComponent, AT_REMOVEDIR) == 0 else { throw posixError() }
        }
    }

    func withVerifiedParent(of target: RecordingTrashTarget, _ operation: (Int32) throws -> Void) throws {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var parent = open(target.root.path, flags)
        guard parent >= 0 else { throw posixError() }
        defer { close(parent) }
        var root = stat(), named = stat()
        guard fstat(parent, &root) == 0, root.st_dev == target.rootDevice, root.st_ino == target.rootInode,
              target.folder.pathComponents.starts(with: target.root.pathComponents) else { throw CocoaError(.fileWriteInvalidFileName) }
        for part in target.folder.deletingLastPathComponent().pathComponents.dropFirst(target.root.pathComponents.count) {
            let next = openat(parent, part, flags)
            guard next >= 0 else { throw posixError() }
            close(parent)
            parent = next
        }
        guard fstatat(parent, target.folder.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              target.device == named.st_dev, target.inode == named.st_ino else { throw CocoaError(.fileWriteInvalidFileName) }
        try operation(parent)
    }

    deinit { close(descriptor) }
}
