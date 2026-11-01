import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import MeetingCompanionCore

@Suite final class TranscriptEditsLockTests {
    private var cleanup: [URL] = []
    private var runningProcesses: [Process] = []

    deinit {
        for process in runningProcesses {
            reapProcess(process, timeoutSeconds: 1.0)
        }
        for url in cleanup {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("transcription/fixtures/transcript-document")

    private func fixture(_ name: String) -> URL {
        fixtures.appendingPathComponent(name + ".json")
    }

    private func temporaryDirectory(_ prefix: String = "TranscriptEditsLockTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            prefix + "-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        return directory
    }

    private func createSyntheticRecording(
        in root: URL,
        resultID: String = "res_valid_parakeet_off"
    ) throws -> (resultURL: URL, audioURLs: [URL], versionDir: URL) {
        let versionDir = root
            .appendingPathComponent("raw")
            .appendingPathComponent("transcripts")
            .appendingPathComponent(resultID)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let resultURL = versionDir.appendingPathComponent("result.json")
        let fixtureData = try Data(contentsOf: fixture("valid_parakeet_off"))
        try fixtureData.write(to: resultURL)

        let rawDir = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

        let hostAudio = rawDir.appendingPathComponent("meeting.host_record.wav")
        let remoteAudio = rawDir.appendingPathComponent("meeting.remote_record.wav")
        let mixAudio = versionDir.appendingPathComponent("mix.m4a")

        let hostBytes = Data("SYNTHETIC_PCM_AUDIO_HOST_16KHZ".utf8)
        let remoteBytes = Data("SYNTHETIC_PCM_AUDIO_REMOTE_16KHZ".utf8)
        let mixBytes = Data("SYNTHETIC_M4A_MIX_AUDIO_PAYLOAD".utf8)

        try hostBytes.write(to: hostAudio)
        try remoteBytes.write(to: remoteAudio)
        try mixBytes.write(to: mixAudio)

        _ = try TranscriptDocument.load(from: resultURL, recordingDirectory: root)
        return (resultURL, [hostAudio, remoteAudio, mixAudio], versionDir)
    }

    private func findHelperBinary() throws -> URL {
        struct HelperNotFoundError: LocalizedError {
            let searched: String
            var errorDescription: String? { "TranscriptLockHelper binary not found in current test image output directory (searched: \(searched))" }
        }

        #if canImport(Darwin)
        var info = Dl_info()
        guard dladdr(unsafeBitCast(TranscriptEditsLockTests.self, to: UnsafeRawPointer.self), &info) != 0,
              let fname = info.dli_fname else {
            throw HelperNotFoundError(searched: "dladdr could not identify current test image")
        }
        let imageURL = URL(fileURLWithPath: String(cString: fname))
        var outputDirectory = imageURL.deletingLastPathComponent()
        // SwiftPM puts the image either directly in products or in an XCTest bundle.
        if outputDirectory.lastPathComponent == "MacOS",
           outputDirectory.deletingLastPathComponent().lastPathComponent == "Contents",
           outputDirectory.deletingLastPathComponent().deletingLastPathComponent().pathExtension == "xctest" {
            outputDirectory = outputDirectory.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
        }
        let candidate = outputDirectory.appendingPathComponent("TranscriptLockHelper")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw HelperNotFoundError(searched: candidate.path)
        }
        print("TranscriptLockHelper selected: \(candidate.path) (test image: \(imageURL.path))")
        return candidate
        #else
        throw HelperNotFoundError(searched: "current test image lookup requires Darwin")
        #endif
    }

    private func launchHelper(recordingDirectory: URL) throws -> (process: Process, stdin: Pipe, stdout: Pipe) {
        let helperBinary = try findHelperBinary()
        let process = Process()
        process.executableURL = helperBinary
        process.arguments = [recordingDirectory.path]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        runningProcesses.append(process)
        return (process, stdinPipe, stdoutPipe)
    }

    private func readLineWithTimeout(from handle: FileHandle, timeoutSeconds: Double = 5.0) throws -> String? {
        #if canImport(Darwin)
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var buffer = Data()
        let startNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let timeoutNanos = UInt64(timeoutSeconds * 1_000_000_000)

        while true {
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: 0..<(newlineIndex + 1))
                return String(data: lineData, encoding: .utf8)
            }

            let nowNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let elapsedNanos = nowNanos - startNanos
            if elapsedNanos >= timeoutNanos {
                break
            }

            let remainingMs = Int32((timeoutNanos - elapsedNanos) / 1_000_000)
            var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pollFd, 1, max(1, remainingMs))

            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                break
            } else if pollResult == 0 {
                break
            }

            if (pollFd.revents & Int16(POLLIN)) != 0 {
                var chunk = [UInt8](repeating: 0, count: 1024)
                let bytesRead = read(fd, &chunk, chunk.count)
                if bytesRead > 0 {
                    buffer.append(contentsOf: chunk[0..<bytesRead])
                } else if bytesRead == 0 {
                    break
                } else {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                        continue
                    }
                    break
                }
            } else if (pollFd.revents & (Int16(POLLHUP) | Int16(POLLERR))) != 0 {
                var chunk = [UInt8](repeating: 0, count: 1024)
                let bytesRead = read(fd, &chunk, chunk.count)
                if bytesRead > 0 {
                    buffer.append(contentsOf: chunk[0..<bytesRead])
                }
                break
            }
        }

        if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.subdata(in: 0..<(newlineIndex + 1))
            return String(data: lineData, encoding: .utf8)
        }
        if !buffer.isEmpty {
            return String(data: buffer, encoding: .utf8)
        }
        return nil
        #else
        return nil
        #endif
    }

    private func reapProcess(_ process: Process, timeoutSeconds: Double = 3.0) {
        guard process.isRunning else { return }
        process.terminate() // SIGTERM
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        #if canImport(Darwin)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning && Date() < killDeadline {
                usleep(50_000)
            }
        }
        #endif
        #expect(!process.isRunning, "Process \(process.processIdentifier) must not survive")
    }

    struct ProcessExitTimeoutError: LocalizedError {
        let pid: pid_t
        var errorDescription: String? { "Process \(pid) did not exit within timeout" }
    }

    private func waitForProcessExit(_ process: Process, timeoutSeconds: Double = 3.0) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        guard !process.isRunning else {
            reapProcess(process, timeoutSeconds: 2.0)
            throw ProcessExitTimeoutError(pid: process.processIdentifier)
        }
    }

    @Test func testLockRejectsSecondProcessAndReleasesOnExplicitClose() throws {
        let rootA = try temporaryDirectory("recordingA")
        let rootB = try temporaryDirectory("recordingB")
        _ = try createSyntheticRecording(in: rootA)
        _ = try createSyntheticRecording(in: rootB)

        let repoA = TranscriptEditsRepository(recordingDirectory: rootA)
        let repoB = TranscriptEditsRepository(recordingDirectory: rootB)
        #expect(repoA.lockURL() == rootA.appendingPathComponent(".transcript-editor.lock"))
        #expect(repoB.lockURL() == rootB.appendingPathComponent(".transcript-editor.lock"))

        // Launch child process to acquire lock on recording A
        let (childProcess, childStdin, childStdout) = try launchHelper(recordingDirectory: rootA)
        let handshake = try readLineWithTimeout(from: childStdout.fileHandleForReading, timeoutSeconds: 5.0)

        // If prerequisite lock acquisition failed in skeleton, map honest runtime prerequisite error
        guard handshake == "ACQUIRED\n" else {
            if let text = handshake, text.contains("notImplemented") {
                throw TranscriptEditsError.notImplemented
            }
            #expect(handshake == "ACQUIRED\n")
            return
        }

        // Child process owns the lock on recording A and is verified alive
        #expect(childProcess.isRunning)

        // 1. Per-recording isolation: distinct recording B must acquire and release successfully
        #expect(throws: Never.self) {
            try repoB.acquireWriteLock()
        }
        repoB.releaseWriteLock()

        // 2. Second process attempting to acquire lock on recording A is denied
        #expect {
            try repoA.acquireWriteLock()
        } throws: { error in
            guard case .lockDenied = error as? TranscriptEditsError else {
                return false
            }
            return true
        }

        // 3. Explicit release: send command to child
        childStdin.fileHandleForWriting.write(Data("RELEASE\n".utf8))
        let releaseAck = try readLineWithTimeout(from: childStdout.fileHandleForReading, timeoutSeconds: 5.0)
        #expect(releaseAck == "RELEASED\n")
        try waitForProcessExit(childProcess, timeoutSeconds: 3.0)
        #expect(childProcess.terminationReason == .exit)
        #expect(childProcess.terminationStatus == 0)

        // 4. Fresh repository instance can now acquire lock on recording A
        let freshRepoA = TranscriptEditsRepository(recordingDirectory: rootA)
        try freshRepoA.acquireWriteLock()
        freshRepoA.releaseWriteLock()
    }

    @Test func testLockRejectsSecondProcessAndReleasesOnProcessDeath() throws {
        let rootA = try temporaryDirectory("recordingA")
        let rootB = try temporaryDirectory("recordingB")
        _ = try createSyntheticRecording(in: rootA)
        _ = try createSyntheticRecording(in: rootB)

        let repoA = TranscriptEditsRepository(recordingDirectory: rootA)
        let repoB = TranscriptEditsRepository(recordingDirectory: rootB)
        #expect(repoA.lockURL() == rootA.appendingPathComponent(".transcript-editor.lock"))
        #expect(repoB.lockURL() == rootB.appendingPathComponent(".transcript-editor.lock"))

        // Launch child process to acquire lock on recording A; keep stdin open to avoid EOF release
        let (childProcess, childStdin, childStdout) = try launchHelper(recordingDirectory: rootA)
        let handshake = try readLineWithTimeout(from: childStdout.fileHandleForReading, timeoutSeconds: 5.0)

        guard handshake == "ACQUIRED\n" else {
            if let text = handshake, text.contains("notImplemented") {
                throw TranscriptEditsError.notImplemented
            }
            #expect(handshake == "ACQUIRED\n")
            return
        }

        // Verified child owner is running
        #expect(childProcess.isRunning)

        // 1. Per-recording isolation: distinct recording B must acquire and release successfully
        #expect(throws: Never.self) {
            try repoB.acquireWriteLock()
        }
        repoB.releaseWriteLock()

        // 2. Second process attempting to acquire lock on recording A is denied
        #expect {
            try repoA.acquireWriteLock()
        } throws: { error in
            guard case .lockDenied = error as? TranscriptEditsError else {
                return false
            }
            return true
        }

        // Keep stdin handle alive until crash
        _ = childStdin

        // 3. Crash scenario: forcefully kill child with SIGKILL (not graceful terminate)
        #if canImport(Darwin)
        let pid = childProcess.processIdentifier
        let killRes = kill(pid, SIGKILL)
        guard killRes == 0 else {
            struct KillFailedError: LocalizedError {
                let code: Int32
                var errorDescription: String? { "kill(SIGKILL) failed with errno \(code)" }
            }
            throw KillFailedError(code: errno)
        }
        #else
        childProcess.terminate()
        #endif
        try waitForProcessExit(childProcess, timeoutSeconds: 3.0)
        #expect(childProcess.terminationReason == .uncaughtSignal)
        #expect(childProcess.terminationStatus == SIGKILL)

        // 4. OS lock must be released on process death; fresh repository instance acquires lock
        let freshRepoA = TranscriptEditsRepository(recordingDirectory: rootA)
        try freshRepoA.acquireWriteLock()
        freshRepoA.releaseWriteLock()
    }

    @Test func testRepeatedAcquireOnSameRepoIsIdempotent() throws {
        let root = try temporaryDirectory("recordingIdempotent")
        _ = try createSyntheticRecording(in: root)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        try repo.acquireWriteLock()
        // Repeated acquire on the same repository instance must be idempotent and not throw or deadlock
        try repo.acquireWriteLock()
        repo.releaseWriteLock()
    }

    @Test func testSeparateRepoInSameProcessIsDeniedWhileOtherHoldsLock() throws {
        let rootA = try temporaryDirectory("recordingSameProcessA")
        let rootB = try temporaryDirectory("recordingSameProcessB")
        _ = try createSyntheticRecording(in: rootA)
        _ = try createSyntheticRecording(in: rootB)

        let repoA1 = TranscriptEditsRepository(recordingDirectory: rootA)
        let repoA2 = TranscriptEditsRepository(recordingDirectory: rootA)
        let repoB = TranscriptEditsRepository(recordingDirectory: rootB)

        try repoA1.acquireWriteLock()

        // Second repository instance on same recording A in same process is denied
        #expect {
            try repoA2.acquireWriteLock()
        } throws: { error in
            guard case .lockDenied = error as? TranscriptEditsError else { return false }
            return true
        }

        // Distinct recording B can be acquired and released without issue
        try repoB.acquireWriteLock()
        repoB.releaseWriteLock()

        // After repoA1 releases, repoA2 can acquire
        repoA1.releaseWriteLock()
        try repoA2.acquireWriteLock()
        repoA2.releaseWriteLock()
    }

    @Test func testDeinitReleasesLock() throws {
        let root = try temporaryDirectory("recordingDeinit")
        _ = try createSyntheticRecording(in: root)

        do {
            let repoTemp = TranscriptEditsRepository(recordingDirectory: root)
            try repoTemp.acquireWriteLock()
        }

        // repoTemp has been deallocated; its deinit must release the lock FD
        let repoNext = TranscriptEditsRepository(recordingDirectory: root)
        try repoNext.acquireWriteLock()
        repoNext.releaseWriteLock()
    }

    @Test func testLockFileSymlinkIsRejectedWithoutOpening() throws {
        let root = try temporaryDirectory("recordingSymlinkLock")
        let outsideDir = try temporaryDirectory("outsideLock")
        _ = try createSyntheticRecording(in: root)

        let lockFile = root.appendingPathComponent(".transcript-editor.lock")
        let outsideTarget = outsideDir.appendingPathComponent("malicious.lock")
        try Data("outside".utf8).write(to: outsideTarget)
        try FileManager.default.createSymbolicLink(at: lockFile, withDestinationURL: outsideTarget)

        let repo = TranscriptEditsRepository(recordingDirectory: root)
        #expect {
            try repo.acquireWriteLock()
        } throws: { error in
            guard case .malformed = error as? TranscriptEditsError else {
                guard case .lockDenied = error as? TranscriptEditsError else { return false }
                return true
            }
            return true
        }
    }
}
