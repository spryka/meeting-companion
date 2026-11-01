import Foundation
import MeetingCompanionCore

func main() {
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
