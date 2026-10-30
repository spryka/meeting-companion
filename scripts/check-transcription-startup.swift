import Foundation
import AppKit

// Compile alongside app sources without AppMain's @main into an isolated test bundle.
@main struct StartupCheck {
    @MainActor static func main() async throws {
        precondition(Bundle.main.bundleIdentifier == "local.meeting-companion-upgrade-check",
                     "Run inside an isolated test bundle, never the installed app")
        let available = CommandLine.arguments.contains("--available")
        let folder = Bundle.main.resourceURL!.appendingPathComponent("transcription")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let runner = folder.appendingPathComponent("run.sh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "$(dirname "$0")/invocations"
        printf '%s\\n' '\(available ? "OK: current models" : "ERROR: vad: модели нет в кэше. Скачайте её в настройках.")'
        exit \(available ? 0 : 1)

        """.write(to: runner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        let recordings = folder.appendingPathComponent("empty-recordings")
        UserDefaults.standard.setVolatileDomain([
            "transcriptionPrepared": true, "improveTechnicalTerms": true,
            "recordingsDirectory": recordings.path
        ], forName: UserDefaults.argumentDomain)
        let model = RecorderViewModel()
        precondition(!model.transcriptionReady, "Saved readiness must not bypass model validation")
        for _ in 0..<100 {
            if !model.diagnosticRunning && model.diagnosticReport.contains("Транскрибация готова.") { break }
            if !model.diagnosticRunning && model.diagnosticReport.contains("Нажмите «Скачать модели»") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(!model.diagnosticRunning && model.transcriptionReady == available)
        let arguments = try String(contentsOf: folder.appendingPathComponent("invocations"), encoding: .utf8)
        precondition(arguments == "--availability\n--parakeet\n", "Startup must only check availability offline")
        precondition(available || model.diagnosticReport.contains("Нажмите «Скачать модели»"))
        print(available ? "Current models: ready" : "Saved ready + missing current models: download required")
        exit(0)
    }
}
