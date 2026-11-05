import Foundation
import MeetingCompanionCore
import MeetingCompanionApplication
import MeetingCompanionPlatform

final class CLITranscriptionRunner: TranscriptionRunnerProtocol, Sendable {
    func checkDependencies(availability: Bool, parakeet: Bool) async throws -> Bool {
        let result = try await Transcription.checkDependencies(availability: availability, parakeet: parakeet)
        return result.succeeded
    }

    func checkDependenciesWithOutput(
        prepare: Bool,
        availability: Bool,
        parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> (output: String, succeeded: Bool) {
        try await Transcription.checkDependencies(
            prepare: prepare,
            availability: availability,
            parakeet: parakeet,
            onOutput: onOutput
        )
    }

    func run(
        recording: URL,
        parakeet: Bool,
        echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> URL {
        try await Transcription.run(
            recording: recording,
            parakeet: parakeet,
            echoCancellation: echoCancellation,
            onProgress: onProgress
        )
    }
}

final class CLIAudioExporter: AudioExporterProtocol, Sendable {
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws {
        try await MeetingCompanionPlatform.exportMixedAudio(from: inputs, to: output)
    }
}

final class CLIAudioCaptureController: AudioCaptureControllerProtocol, @unchecked Sendable {
    private let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func startCapture() async throws {
        try await recorder.start()
    }

    func stopCapture() async throws -> AudioCaptureStopResult {
        let stopped = try await recorder.stopCapture()
        return AudioCaptureStopResult(
            duration: stopped.duration,
            outputURL: stopped.outputURL,
            warnings: [],
            stoppedCapture: stopped
        )
    }

    func setMicrophoneMuted(_ muted: Bool) {
        recorder.setMicrophoneMuted(muted)
    }

    func currentMicrophoneState() -> MicrophoneRecordingState {
        .receiving
    }
}
