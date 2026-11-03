import Foundation
import MeetingCompanionCore
import MeetingCompanionPlatform
import MeetingCompanionApplication

@available(macOS 15.0, *)
@main
struct MeetingCompanionCLI {
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

            let historyRepo = RecordingHistoryRepository()
            let sessionService = RecordingSessionService(historyRepo: historyRepo)
            let processingService = ProcessingService(
                transcriptionRunner: CLITranscriptionRunner(),
                audioExporter: CLIAudioExporter(),
                historyRepository: historyRepo
            )

            let outputURL = try RecordingPaths.makeOutputURL(outputDirectory: options.outputDirectory, outputKind: options.outputKind)
            let recorder = try await Recorder(
                outputURL: outputURL,
                outputKind: options.outputKind,
                microphoneDeviceID: options.microphoneDeviceID
            )
            let controller = CLIAudioCaptureController(recorder: recorder)

            print("Recording to: \(outputURL.path)")
            print("Capturing: system audio + microphone")
            print(options.duration == nil ? "Press Enter to stop." : "Will stop after \(formatDuration(options.duration!)).")

            _ = try await sessionService.start(controller: controller, outputURL: outputURL)

            if let duration = options.duration {
                try await Task.sleep(for: .seconds(duration))
            } else {
                _ = readLine()
            }

            let stopResult = try await sessionService.stop()
            if stopResult.wasCancelledShort {
                print("Recording was under short threshold; cancelled.")
                return
            }

            print("Recording finished: \(formatDuration(stopResult.duration))")
            print("Saved: \(stopResult.outputURL.path) (\(formatBytes(fileSize(at: stopResult.outputURL))))")
            for warning in stopResult.warnings { fputs("Warning: " + warning + "\n", stderr) }
            print("Transcribing locally...")

            let (stream, continuation) = AsyncStream<ProcessingService.Event>.makeStream()
            await processingService.addEventHandler { event in
                continuation.yield(event)
            }
            await processingService.enqueue(
                recordingURL: stopResult.outputURL,
                settings: ProcessingJobSettings(parakeet: false, echoCancellation: false),
                stoppedCapture: stopResult.stoppedCapture
            )

            var transcriptURL: URL?
            var processingError: String?
            for await event in stream {
                switch event {
                case .completed(_, let url, let warning):
                    transcriptURL = url
                    if let warning {
                        fputs("Warning: " + warning + "\n", stderr)
                    }
                    continuation.finish()
                case .failed(_, let error, let warning):
                    processingError = error
                    if let warning {
                        fputs("Warning: " + warning + "\n", stderr)
                    }
                    continuation.finish()
                case .cancelled(_, let warning):
                    if let warning { fputs("Warning: " + warning + "\n", stderr) }
                    processingError = "Cancelled"
                    continuation.finish()
                case .persistenceWarning(_, let warning):
                    fputs("Warning: " + warning + "\n", stderr)
                default:
                    break
                }
            }

            if let transcriptURL {
                print("Transcript: " + transcriptURL.path)
            } else {
                fputs("\(processingError ?? "Transcription failed")\n", stderr)
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
            case "--list-microphones":
                listMicrophones = true
            case "--monitor-levels":
                monitorLevels = true
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidOption("--output-dir requires a path")
                }
                outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--format":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidOption("--format requires m4a or mp4")
                }
                switch arguments[index] {
                case "m4a":
                    outputKind = .m4a
                case "mp4":
                    outputKind = .mp4
                default:
                    throw CLIError.invalidOption("Unsupported format: \(arguments[index])")
                }
            case "--duration":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidOption("--duration requires seconds")
                }
                guard let parsed = Double(arguments[index]), parsed > 0 else {
                    throw CLIError.invalidOption("Duration must be a positive number of seconds")
                }
                duration = parsed
            case "--microphone":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidOption("--microphone requires an ID")
                }
                microphoneDeviceID = arguments[index]
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                throw CLIError.unknownOption(argument)
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
}

enum CLIError: LocalizedError {
    case invalidOption(String)
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case .invalidOption(let message):
            return message
        case .unknownOption(let option):
            return "Unknown option: \(option)"
        }
    }
}

private func printMicrophones() {
    let devices = Microphones.available()
    if devices.isEmpty {
        print("No microphone devices found.")
        return
    }

    print("Available microphone devices:")
    for device in devices {
        print("  \(device.id)\t\(device.name)")
    }
}

private func monitorLevels(options: Options) async throws {
    let monitor = try await AudioLevelMonitor(
        microphoneDeviceID: options.microphoneDeviceID
    ) { mic, system in
        print(String(format: "mic: %4.0f%%  sys: %4.0f%%", mic * 100, system * 100), terminator: "\r")
        fflush(stdout)
    }

    print("Monitoring audio levels. Press Enter to stop.")
    try await monitor.start()
    _ = readLine()
    try? await monitor.stop()
    print("")
}

private func printUsage() {
    let text = """
    meeting-companion: dual-channel meeting audio recorder + native MLX transcription

    USAGE:
      meeting-companion [options]

    OPTIONS:
      --duration <seconds>      Stop automatically after the given duration
      --output-dir <path>       Directory for output files (default: ~/Documents/Recordings)
      --format <m4a|mp4>        Audio container format (default: m4a)
      --microphone <id>         Specific microphone device ID
      --list-microphones        List available microphone input devices and exit
      --monitor-levels          Continuously print input levels without recording
      -h, --help                Show this help message
    """
    print(text)
}
