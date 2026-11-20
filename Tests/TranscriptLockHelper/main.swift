import Foundation
import MeetingCompanionCore

func main() {
    do {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--hold-transcription-workspace" {
            let temporaryDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let input = URL(fileURLWithPath: CommandLine.arguments[3])
            let workspace = try TranscriptionWorkspace(temporaryDirectory: temporaryDirectory)
            let snapshot = try workspace.snapshot(input, named: "host", lease: nil)
            FileHandle.standardOutput.write(Data((snapshot.path + "\n").utf8))
            withExtendedLifetime(workspace) { _ = readLine() }
            return
        }
        if try RecordingAudioRemoval.performWorkerRequest(Array(CommandLine.arguments.dropFirst())) { exit(0) }
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
    guard CommandLine.arguments.count >= 2 else {
        fputs("Usage: transcript-lock-helper <recording-dir>\n", stderr)
        exit(1)
    }

    let recordingURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let repo = TranscriptEditsRepository(recordingDirectory: recordingURL)

    do {
        try repo.acquireWriteLock()
    } catch {
        print("ERROR: \(error)")
        fflush(stdout)
        exit(2)
    }

    print("ACQUIRED")
    fflush(stdout)

    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "RELEASE" {
            repo.releaseWriteLock()
            print("RELEASED")
            fflush(stdout)
            exit(0)
        }
    }

    repo.releaseWriteLock()
    exit(0)
}

main()
