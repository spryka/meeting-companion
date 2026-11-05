import Foundation
import Darwin
import MeetingCompanionCore
import MeetingTranscriptionPipeline

nonisolated(unsafe) var interrupted: sig_atomic_t = 0

func checkCancel() throws {
    if interrupted != 0 {
        throw PipelineError("cancelled")
    }
}

func printHelp() {
    let help = """
    Usage: MeetingTranscriptionWorker [options] <recording_path_or_dir>
           MeetingTranscriptionWorker <model_root> <host.wav> <remote.wav> <output_dir> [options]

    Modes:
      --recording --offline   Process recording using platform directory contract
      --check, --availability Check local availability of required model weights and assets
      --prepare               Verify or link verified models into app-owned model directory
      --help, -h              Show this help message

    Options:
      --model-root <path>     Directory containing model subdirectories (gigaam, nemotron, vad, parakeet)
      --source-root <path>    Source directory with verified models for initial preparation
      --parakeet              Enable Parakeet phonetic cascade
      --echo-cancel           Enable WebRTC AEC3 echo cancellation on microphone
      --result-id <id>        Explicit resultID for the transcript version
    """
    print(help)
}

func emitProgress(_ event: PipelineProgressEvent) {
    let line = event.formatStdoutLine() + "\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

do {
    signal(SIGINT) { _ in interrupted = 1 }
    signal(SIGTERM) { _ in interrupted = 1 }

    let rawArgs = Array(CommandLine.arguments.dropFirst())

    if rawArgs.isEmpty || rawArgs.contains("--help") || rawArgs.contains("-h") {
        printHelp()
        exit(0)
    }

    var modelRoot = ModelAssets.defaultModelRoot()
    var sourceRoot: URL? = {
        if let env = ProcessInfo.processInfo.environment["MEETING_COMPANION_SOURCE_MODELS"], !env.isEmpty {
            return URL(fileURLWithPath: env).resolvingSymlinksInPath().standardizedFileURL
        }
        return nil
    }()

    var parakeet = false
    var echoCancel = false
    var checkOnly = false
    var prepareOnly = false
    var explicitResultID: String? = nil
    var positional: [String] = []

    var idx = 0
    while idx < rawArgs.count {
        let arg = rawArgs[idx]
        switch arg {
        case "--recording", "--offline":
            // Standard mode flags passed by platform runner
            idx += 1
        case "--parakeet":
            parakeet = true
            idx += 1
        case "--echo-cancel":
            echoCancel = true
            idx += 1
        case "--check", "--availability":
            checkOnly = true
            idx += 1
        case "--prepare":
            prepareOnly = true
            idx += 1
        case "--model-root":
            guard idx + 1 < rawArgs.count else {
                FileHandle.standardError.write(Data("Error: --model-root requires a directory path value\n".utf8))
                exit(2)
            }
            modelRoot = URL(fileURLWithPath: rawArgs[idx + 1]).resolvingSymlinksInPath().standardizedFileURL
            idx += 2
        case "--source-root":
            guard idx + 1 < rawArgs.count else {
                FileHandle.standardError.write(Data("Error: --source-root requires a directory path value\n".utf8))
                exit(2)
            }
            sourceRoot = URL(fileURLWithPath: rawArgs[idx + 1]).resolvingSymlinksInPath().standardizedFileURL
            idx += 2
        case "--result-id":
            guard idx + 1 < rawArgs.count else {
                FileHandle.standardError.write(Data("Error: --result-id requires an identifier value\n".utf8))
                exit(2)
            }
            explicitResultID = rawArgs[idx + 1]
            idx += 2
        default:
            if arg.hasPrefix("-") {
                FileHandle.standardError.write(Data("Error: Unknown option '\(arg)'\n".utf8))
                printHelp()
                exit(2)
            }
            positional.append(arg)
            idx += 1
        }
    }

    if prepareOnly {
        do {
            try ModelAssets.prepare(
                modelRoot: modelRoot,
                sourceRoot: sourceRoot,
                parakeet: parakeet,
                allowDownload: true,
                isCancelled: { interrupted != 0 },
                onProgress: { msg in
                    fputs("\(msg)\n", stdout)
                    fflush(stdout)
                }
            )
            print("Models prepared and verified in \(modelRoot.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Error preparing models: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    if checkOnly {
        let (ready, missing) = ModelAssets.checkAvailability(modelRoot: modelRoot, parakeet: parakeet, onProgress: { message in
            fputs("\(message)\n", stdout)
            fflush(stdout)
        })
        if ready {
            print("All required models are present in \(modelRoot.path)")
            exit(0)
        } else {
            let msg = "Missing required model files in \(modelRoot.path): " + missing.joined(separator: ", ") + "\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(1)
        }
    }

    if positional.count == 4 {
        // Direct 4-argument invocation: <model_root> <host.wav> <remote.wav> <output_dir>
        let customModelRoot = URL(fileURLWithPath: positional[0]).resolvingSymlinksInPath().standardizedFileURL
        let hostURL = URL(fileURLWithPath: positional[1]).resolvingSymlinksInPath().standardizedFileURL
        let remoteURL = URL(fileURLWithPath: positional[2]).resolvingSymlinksInPath().standardizedFileURL
        let outputDir = URL(fileURLWithPath: positional[3]).resolvingSymlinksInPath().standardizedFileURL

        guard hostURL != remoteURL else {
            FileHandle.standardError.write(Data("Error: Host and remote audio paths must differ\n".utf8))
            exit(1)
        }
        guard FileManager.default.fileExists(atPath: hostURL.path) else {
            FileHandle.standardError.write(Data("Error: Missing host audio: \(hostURL.path)\n".utf8))
            exit(1)
        }
        guard FileManager.default.fileExists(atPath: remoteURL.path) else {
            FileHandle.standardError.write(Data("Error: Missing remote audio: \(remoteURL.path)\n".utf8))
            exit(1)
        }

        let customRunner = PipelineRunner(
            modelRoot: customModelRoot,
            parakeetEnabled: parakeet,
            echoCancelEnabled: echoCancel
        )

        let stem = hostURL.deletingPathExtension().lastPathComponent
        let sources = RecordingSources(
            recordingDirectory: outputDir,
            stem: stem,
            hostWAV: hostURL,
            remoteWAV: remoteURL,
            hostRelPath: "raw/\(stem).host_record.wav",
            remoteRelPath: "raw/\(stem).remote_record.wav"
        )

        let resultID = explicitResultID ?? ("res_" + UUID().uuidString.prefix(8).lowercased())
        let res = try customRunner.run(
            sources: sources,
            resultID: resultID,
            checkCancel: checkCancel,
            onProgress: emitProgress
        )

        let publisher = TranscriptPublisher(recordingDirectory: outputDir)
        let publishedURL = try publisher.publish(
            document: res.document,
            audioMixURL: res.audioMixURL,
            aecAudioURL: res.aecAudioURL,
            correctionJournalData: res.correctionJournalData,
            recordingStem: stem,
            hostAudioRelPath: sources.hostRelPath,
            remoteAudioRelPath: sources.remoteRelPath,
            checkCancel: checkCancel,
            onWarning: { emitProgress(PipelineProgressEvent(stage: .warning, completed: 0, total: 1, warning: $0)) }
        )
        print("Success: Published transcript to \(publishedURL.path)")
        exit(0)
    }

    guard let recordingArg = positional.first else {
        FileHandle.standardError.write(Data("Error: No recording path specified.\n".utf8))
        printHelp()
        exit(1)
    }

    // Resolve recording sources deterministically matching app contract
    let sources = try RecordingSourceResolver.resolve(recordingPath: recordingArg)
    let runner = PipelineRunner(
        modelRoot: modelRoot,
        parakeetEnabled: parakeet,
        echoCancelEnabled: echoCancel
    )
    let resultID = explicitResultID ?? ("res_" + UUID().uuidString.prefix(8).lowercased())

    let pipelineResult = try runner.run(
        sources: sources,
        resultID: resultID,
        checkCancel: checkCancel,
        onProgress: emitProgress
    )

    let publisher = TranscriptPublisher(recordingDirectory: sources.recordingDirectory)
    let publishedURL = try publisher.publish(
        document: pipelineResult.document,
        audioMixURL: pipelineResult.audioMixURL,
        aecAudioURL: pipelineResult.aecAudioURL,
        correctionJournalData: pipelineResult.correctionJournalData,
        recordingStem: sources.stem,
        hostAudioRelPath: sources.hostRelPath,
        remoteAudioRelPath: sources.remoteRelPath,
            checkCancel: checkCancel,
            onWarning: { emitProgress(PipelineProgressEvent(stage: .warning, completed: 0, total: 1, warning: $0)) }
    )

    print("Success: Published transcript version \(resultID) to \(publishedURL.path)")
    exit(0)

} catch {
    if interrupted != 0 {
        FileHandle.standardError.write(Data("Process cancelled by user.\n".utf8))
        exit(130)
    } else {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
