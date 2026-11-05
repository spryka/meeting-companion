import Foundation
import MeetingCompanionCore
import MeetingCompanionApplication
import MeetingCompanionPlatform

/// App/Platform adapter implementing TranscriptionRunnerProtocol using Platform Transcription runner.
public final class PlatformTranscriptionRunner: TranscriptionRunnerProtocol, Sendable {
    public init() {}

    public func checkDependencies(availability: Bool, parakeet: Bool) async throws -> Bool {
        let result = try await Transcription.checkDependencies(
            availability: availability,
            parakeet: parakeet
        )
        return result.succeeded
    }

    public func checkDependenciesWithOutput(
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

    public func run(
        recording: URL,
        parakeet: Bool,
        echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> URL {
        return try await Transcription.run(
            recording: recording,
            parakeet: parakeet,
            echoCancellation: echoCancellation,
            onProgress: onProgress
        )
    }
}

/// App/Platform adapter implementing AudioExporterProtocol using Platform exportMixedAudio.
public final class PlatformAudioExporter: AudioExporterProtocol, Sendable {
    public init() {}

    public func exportMixedAudio(from inputs: [URL], to output: URL) async throws {
        try await MeetingCompanionPlatform.exportMixedAudio(from: inputs, to: output)
    }
}

/// App/Platform adapter implementing AudioCaptureControllerProtocol using Recorder.
public final class PlatformAudioCaptureController: AudioCaptureControllerProtocol, @unchecked Sendable {
    private let recorder: Recorder

    public init(recorder: Recorder) {
        self.recorder = recorder
    }

    public func startCapture() async throws {
        try await recorder.start()
    }

    public func stopCapture() async throws -> AudioCaptureStopResult {
        let stopped = try await recorder.stopCapture()
        return AudioCaptureStopResult(
            duration: stopped.duration,
            outputURL: stopped.outputURL,
            warnings: [],
            stoppedCapture: stopped
        )
    }

    public func setMicrophoneMuted(_ muted: Bool) {
        recorder.setMicrophoneMuted(muted)
    }

    public func currentMicrophoneState() -> MicrophoneRecordingState {
        recorder.microphoneState()
    }
}
