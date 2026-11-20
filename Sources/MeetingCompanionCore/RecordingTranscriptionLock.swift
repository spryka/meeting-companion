import Darwin
import Foundation

package final class RecordingTranscriptionLock {
    private static let filename = ".transcription-attempt"
    private let descriptor: Int32

    package init(lease: RecordingDirectoryLease) throws {
        let descriptor = openat(lease.fileHandle.fileDescriptor, Self.filename,
                                O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.fileError() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = Self.fileError()
            Darwin.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit { Darwin.close(descriptor) }

    private static func fileError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
