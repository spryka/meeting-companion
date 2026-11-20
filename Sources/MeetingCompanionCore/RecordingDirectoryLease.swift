import Darwin
import Foundation

public final class RecordingDirectoryLease: Sendable {
    package let directory: URL
    private let descriptor: Int32

    public convenience init(_ directory: URL, exclusive: Bool = false) throws {
        try self.init(directory, exclusive: exclusive, wait: false)
    }

    package init(_ directory: URL, exclusive: Bool, wait: Bool) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let lock = (exclusive ? LOCK_EX : LOCK_SH) | (wait ? 0 : LOCK_NB)
        guard flock(descriptor, lock) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw error
        }
        self.directory = directory
        self.descriptor = descriptor
    }

    package var fileHandle: FileHandle { FileHandle(fileDescriptor: descriptor, closeOnDealloc: false) }

    package func openDirectory() throws -> RecordingAudioDirectory {
        try RecordingAudioDirectory(directory, parent: descriptor, name: ".")
    }

    package func validateLocation() throws {
        var opened = stat()
        var current = stat()
        guard fstat(descriptor, &opened) == 0, lstat(directory.path, &current) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                NSLocalizedDescriptionKey: "Папка записи изменилась во время обработки"
            ])
        }
    }

    deinit { Darwin.close(descriptor) }
}
