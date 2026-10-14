import Foundation
import InterviewRecorderCore

@available(macOS 15.0, *)
@main
struct InterviewRecorderCLI {
    static func main() async {
        do {
            let options = try Options.parse(CommandLine.arguments)
            if options.listMicrophones {
                printMicrophones()
                return
            }
            if options.monitorLevels {
                try await monitorLevels(options: options)
                return
            }

            let outputURL = try RecordingPaths.makeOutputURL(outputDirectory: options.outputDirectory, outputKind: options.outputKind)
            let recorder = try await Recorder(
                outputURL: outputURL,
                outputKind: options.outputKind,
                microphoneDeviceID: options.microphoneDeviceID
            )

            print("Recording to: \(outputURL.path)")
            print("Capturing: system audio + microphone")
            print(options.duration == nil ? "Press Enter to stop." : "Will stop after \(formatDuration(options.duration!)).")

            try await recorder.start()

            if let duration = options.duration {
                try await Task.sleep(for: .seconds(duration))
            } else {
                _ = readLine()
            }

            let result = try await recorder.stop()
            print("Recording finished: \(formatDuration(result.duration))")
            print("Saved: \(result.outputURL.path) (\(formatBytes(result.fileSize)))")
            print("Transcribing locally...")
            do {
                let transcript = try await Transcription.run(recording: result.outputURL)
                print("Transcript: " + transcript.path)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            fputs(permissionHint, stderr)
            exit(1)
        }
    }
}

struct Options {
    var outputDirectory: URL
    var outputKind: OutputKind
    var duration: TimeInterval?
    var microphoneDeviceID: String?
    var listMicrophones = false
    var monitorLevels = false

    static func parse(_ arguments: [String]) throws -> Options {
        var outputDirectory = RecordingPaths.defaultOutputDirectory
        var outputKind = OutputKind.m4a
        var duration: TimeInterval?
        var microphoneDeviceID: String?
        var listMicrophones = false
        var monitorLevels = false

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                print(Self.usage)
                exit(0)
            case "--output-dir":
                index += 1
                guard index < arguments.count else { throw RecorderError.missingValue(argument) }
                outputDirectory = URL(fileURLWithPath: NSString(string: arguments[index]).expandingTildeInPath)
            case "--duration":
                index += 1
                guard index < arguments.count else { throw RecorderError.missingValue(argument) }
                guard let value = TimeInterval(arguments[index]), value > 0 else {
                    throw RecorderError.invalidValue(argument, arguments[index])
                }
                duration = value
            case "--microphone-id":
                index += 1
                guard index < arguments.count else { throw RecorderError.missingValue(argument) }
                microphoneDeviceID = arguments[index]
            case "--list-microphones":
                listMicrophones = true
            case "--monitor-levels":
                monitorLevels = true
            case "--type":
                index += 1
                guard index < arguments.count else { throw RecorderError.missingValue(argument) }
                switch arguments[index].lowercased() {
                case "m4a":
                    outputKind = .m4a
                case "mp4":
                    outputKind = .mp4
                default:
                    throw RecorderError.invalidValue(argument, arguments[index])
                }
            default:
                throw RecorderError.unknownArgument(argument)
            }

            index += 1
        }

        return Options(
            outputDirectory: outputDirectory,
            outputKind: outputKind,
            duration: duration,
            microphoneDeviceID: microphoneDeviceID,
            listMicrophones: listMicrophones,
            monitorLevels: monitorLevels
        )
    }

    static let usage = """
    Usage:
      meeting-companion [--output-dir DIR] [--duration SECONDS] [--type m4a|mp4] [--microphone-id ID]
      meeting-companion --list-microphones
      meeting-companion --monitor-levels [--duration SECONDS] [--microphone-id ID]

    Defaults:
      --output-dir ~/Downloads/Interviews
      --type m4a

    The utility records system audio and the default microphone until Enter is pressed.
    """
}

@available(macOS 15.0, *)
func monitorLevels(options: Options) async throws {
    let state = LevelState()
    let duration = options.duration ?? 10
    let monitor = try await AudioLevelMonitor(microphoneDeviceID: options.microphoneDeviceID) { mic, system in
        Task {
            await state.update(mic: mic, system: system)
        }
    }

    print("Monitoring levels for \(formatDuration(duration))...")
    print("Play system audio and speak into the selected microphone.")
    try await monitor.start()

    let ticks = max(1, Int(duration / 0.5))
    for _ in 0..<ticks {
        try await Task.sleep(for: .milliseconds(500))
        let snapshot = await state.snapshotAndDecay()
        print("mic=\(snapshot.mic) system=\(snapshot.system)")
    }

    try await monitor.stop()
}

actor LevelState {
    private var micLevel = 0.0
    private var systemLevel = 0.0

    func update(mic: Double, system: Double) {
        if mic.isFinite {
            micLevel = mic
        }
        if system.isFinite {
            systemLevel = system
        }
    }

    func snapshotAndDecay() -> (mic: String, system: String) {
        let snapshot = (
            mic: String(format: "%.3f", micLevel),
            system: String(format: "%.3f", systemLevel)
        )
        micLevel *= 0.86
        systemLevel *= 0.86
        return snapshot
    }
}

func printMicrophones() {
    let microphones = Microphones.available()
    if microphones.isEmpty {
        print("No microphones found.")
        return
    }

    for microphone in microphones {
        print("\(microphone.id)\t\(microphone.name)")
    }
}
