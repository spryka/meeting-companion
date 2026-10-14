import Foundation
@main struct Check {
    static func main() async throws {
        let folder = Transcription.scriptsDirectory
        precondition(folder.path.contains(".app/Contents/Resources/transcription"))
        print("Bundled scripts: " + folder.path)
        let result = try await Transcription.checkDependencies()
        print(result.output)
        precondition(result.succeeded, "Bundled model check failed")
        if CommandLine.arguments.count > 1 {
            let recording = URL(fileURLWithPath: CommandLine.arguments[1])
            let transcript = try await Transcription.run(recording: recording)
            let text = try String(contentsOf: transcript, encoding: .utf8)
            precondition(text.contains("[00:") && text.contains("Host attribution"))
            print("Bundled transcription passed: " + transcript.path)
        }
    }
}
