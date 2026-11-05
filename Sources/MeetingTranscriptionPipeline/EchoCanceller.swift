import Foundation
import AVFoundation
import MeetingCompanionCore

public struct EchoCancelResult: Sendable {
    public let audioURL: URL
    public let outcome: TranscriptDocument.AECOutcome
    public let warnings: [TranscriptDocument.Warning]

    public init(audioURL: URL, outcome: TranscriptDocument.AECOutcome, warnings: [TranscriptDocument.Warning]) {
        self.audioURL = audioURL
        self.outcome = outcome
        self.warnings = warnings
    }
}

public struct EchoCanceller: Sendable {
    public init() {}

    /// Locates the bundled or built meeting-aec executable.
    public static func locateExecutable() -> URL? {
        if let env = ProcessInfo.processInfo.environment["MEETING_AEC_PATH"], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        let appURL = Bundle.main.bundleURL
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("transcription/aec/meeting-aec"),
            Bundle.main.resourceURL?.appendingPathComponent("aec/meeting-aec"),
            appURL.appendingPathComponent("Contents/Resources/transcription/aec/meeting-aec"),
            appURL.appendingPathComponent("Contents/Resources/aec/meeting-aec"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("meeting-aec"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("aec/meeting-aec"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/aec/meeting-aec")
        ]

        for candidate in candidates {
            if let candidate, FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Finds the byte offset of the data chunk in a standard RIFF/WAVE file.
    public static func findWavDataOffset(url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 12), magic.count == 12,
              String(decoding: magic[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: magic[8..<12], as: UTF8.self) == "WAVE" else {
            return nil
        }

        while let header = try? handle.read(upToCount: 8), header.count == 8 {
            let chunkID = String(decoding: header[0..<4], as: UTF8.self)
            let chunkSize = header[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }
            if chunkID == "data" {
                let offset = (try? handle.offset()) ?? 0
                return Int(offset)
            }
            let paddedSize = (UInt64(chunkSize) + 1) & ~1
            guard let current = try? handle.offset() else { return nil }
            try? handle.seek(toOffset: current + paddedSize)
        }
        return nil
    }

    /// Performs echo cancellation if requested.
    /// If reference audio is completely silent, preserves microphone bit-for-bit without DSP.
    /// If meeting-aec fails or is missing, falls back to original host mic with an explicit warning.
    public static func process(
        host: URL,
        remote: URL,
        destination: URL,
        requested: Bool,
        executableURL: URL? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> EchoCancelResult {
        guard requested else {
            return EchoCancelResult(audioURL: host, outcome: .disabled, warnings: [])
        }

        let hostFile: AVAudioFile
        let remoteFile: AVAudioFile
        do {
            hostFile = try AVAudioFile(forReading: host)
            remoteFile = try AVAudioFile(forReading: remote)
        } catch {
            return EchoCancelResult(
                audioURL: host,
                outcome: .failed,
                warnings: [TranscriptDocument.Warning(
                    code: "aec_fallback",
                    sourceID: .host,
                    message: "AEC3: не удалось открыть входные файлы: \(error.localizedDescription); откат к исходному микрофону"
                )]
            )
        }

        let hostFormat = hostFile.fileFormat
        let remoteFormat = remoteFile.fileFormat

        guard hostFormat.sampleRate == 16000, remoteFormat.sampleRate == 16000,
              hostFormat.channelCount == 1, remoteFormat.channelCount == 1 else {
            return EchoCancelResult(
                audioURL: host,
                outcome: .failed,
                warnings: [TranscriptDocument.Warning(
                    code: "aec_fallback",
                    sourceID: .host,
                    message: "AEC3: входные дорожки должны быть 16 кГц моно (host: \(Int(hostFormat.sampleRate))Hz \(hostFormat.channelCount)ch, remote: \(Int(remoteFormat.sampleRate))Hz \(remoteFormat.channelCount)ch); откат к исходному микрофону"
                )]
            )
        }

        let hostFrames = Int(hostFile.length)
        let remoteFrames = Int(remoteFile.length)

        guard hostFrames == remoteFrames else {
            return EchoCancelResult(
                audioURL: host,
                outcome: .failed,
                warnings: [TranscriptDocument.Warning(
                    code: "aec_fallback",
                    sourceID: .host,
                    message: "AEC3: не совпадают длительности дорожек (host=\(hostFrames), remote=\(remoteFrames)); откат к исходному микрофону"
                )]
            )
        }

        guard let hostOffset = findWavDataOffset(url: host),
              let remoteOffset = findWavDataOffset(url: remote) else {
            return EchoCancelResult(
                audioURL: host,
                outcome: .failed,
                warnings: [TranscriptDocument.Warning(
                    code: "aec_fallback",
                    sourceID: .host,
                    message: "AEC3: не удалось определить смещение PCM в WAV; откат к исходному микрофону"
                )]
            )
        }

        // Format-aware bounded silence detection.
        // Decoding, read, or buffer allocation failures must NOT be classified as known silence.
        var isRemoteKnownSilent = false
        let bufferCapacity: AVAudioFrameCount = 32000
        if let buffer = AVAudioPCMBuffer(pcmFormat: remoteFile.processingFormat, frameCapacity: bufferCapacity) {
            remoteFile.framePosition = 0
            var allFramesChecked = 0
            var foundNonZero = false
            let totalFrames = Int(remoteFile.length)

            while remoteFile.framePosition < remoteFile.length {
                let toRead = min(bufferCapacity, AVAudioFrameCount(remoteFile.length - remoteFile.framePosition))
                do {
                    try remoteFile.read(into: buffer, frameCount: toRead)
                } catch {
                    // Read failure: cannot determine silence
                    break
                }
                let framesRead = Int(buffer.frameLength)
                guard framesRead > 0 else { break }

                if let floatChannels = buffer.floatChannelData {
                    let channel0 = floatChannels[0]
                    for i in 0..<framesRead {
                        if channel0[i] != 0.0 {
                            foundNonZero = true
                            break
                        }
                    }
                } else if let int16Channels = buffer.int16ChannelData {
                    let channel0 = int16Channels[0]
                    for i in 0..<framesRead {
                        if channel0[i] != 0 {
                            foundNonZero = true
                            break
                        }
                    }
                } else {
                    // Unsupported channel data format: cannot determine silence
                    break
                }

                if foundNonZero { break }
                allFramesChecked += framesRead
            }

            if !foundNonZero && allFramesChecked == totalFrames && totalFrames > 0 {
                isRemoteKnownSilent = true
            }
        }

        if isRemoteKnownSilent {
            onProgress?(hostFrames, hostFrames)
            return EchoCancelResult(audioURL: host, outcome: .applied, warnings: [])
        }

        guard let executable = executableURL ?? locateExecutable() else {
            return EchoCancelResult(
                audioURL: host,
                outcome: .failed,
                warnings: [TranscriptDocument.Warning(
                    code: "aec_fallback",
                    sourceID: .host,
                    message: "AEC3: исполняемый файл meeting-aec не найден; откат к исходному микрофону"
                )]
            )
        }

        let tempID = UUID().uuidString
        let tempDir = destination.deletingLastPathComponent()
        let tempAEC = tempDir.appendingPathComponent(".aec-\(tempID).wav")
        defer { try? FileManager.default.removeItem(at: tempAEC) }

        FileManager.default.createFile(atPath: tempAEC.path, contents: nil)
        guard let outFile = try? FileHandle(forWritingTo: tempAEC) else {
            return EchoCancelResult(
                audioURL: host,
                outcome: .failed,
                warnings: [TranscriptDocument.Warning(
                    code: "aec_fallback",
                    sourceID: .host,
                    message: "AEC3: не удалось создать временный файл; откат к исходному микрофону"
                )]
            )
        }

        // Write WAV header
        var wavHeader = Data()
        wavHeader.append(contentsOf: [UInt8]("RIFF".utf8))
        let riffSize = UInt32(36 + hostFrames * 2)
        withUnsafeBytes(of: riffSize) { wavHeader.append(contentsOf: $0) }
        wavHeader.append(contentsOf: [UInt8]("WAVEfmt ".utf8))
        let subchunk1Size = UInt32(16)
        withUnsafeBytes(of: subchunk1Size) { wavHeader.append(contentsOf: $0) }
        let audioFormat = UInt16(1) // PCM
        withUnsafeBytes(of: audioFormat) { wavHeader.append(contentsOf: $0) }
        let numChannels = UInt16(1) // Mono
        withUnsafeBytes(of: numChannels) { wavHeader.append(contentsOf: $0) }
        let sampleRateVal = UInt32(16000)
        withUnsafeBytes(of: sampleRateVal) { wavHeader.append(contentsOf: $0) }
        let byteRate = UInt32(32000) // 16000 * 1 * 2
        withUnsafeBytes(of: byteRate) { wavHeader.append(contentsOf: $0) }
        let blockAlign = UInt16(2)
        withUnsafeBytes(of: blockAlign) { wavHeader.append(contentsOf: $0) }
        let bitsPerSampleVal = UInt16(16)
        withUnsafeBytes(of: bitsPerSampleVal) { wavHeader.append(contentsOf: $0) }
        wavHeader.append(contentsOf: [UInt8]("data".utf8))
        let dataSizeBytes = UInt32(hostFrames * 2)
        withUnsafeBytes(of: dataSizeBytes) { wavHeader.append(contentsOf: $0) }

        try? outFile.write(contentsOf: wavHeader)

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            host.path,
            remote.path,
            String(hostOffset),
            String(remoteOffset),
            String(hostFrames)
        ]
        process.standardOutput = outFile
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()

            let errHandle = errPipe.fileHandleForReading
            var errTail = ""
            var pending = Data()

            while true {
                let chunk = errHandle.availableData
                guard !chunk.isEmpty else { break }
                pending.append(chunk)

                while let newlineIdx = pending.firstIndex(of: 10) {
                    let lineData = pending[..<newlineIdx]
                    pending = pending.suffix(from: pending.index(after: newlineIdx))
                    let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.hasPrefix("AEC_PROGRESS ") {
                        let parts = line.split(separator: " ")
                        if parts.count == 3, let done = Int(parts[1]), let total = Int(parts[2]) {
                            onProgress?(done, total)
                        }
                    } else if !line.isEmpty {
                        errTail += line + "\n"
                        if errTail.count > 2000 { errTail = String(errTail.suffix(2000)) }
                    }
                }
            }

            process.waitUntilExit()
            try? outFile.close()

            guard process.terminationStatus == 0 else {
                return EchoCancelResult(
                    audioURL: host,
                    outcome: .failed,
                    warnings: [TranscriptDocument.Warning(
                        code: "aec_fallback",
                        sourceID: .host,
                        message: "AEC3: сбой процесса meeting-aec (код \(process.terminationStatus)): \(errTail.trimmingCharacters(in: .whitespacesAndNewlines)); откат к исходному микрофону"
                    )]
                )
            }

            let aecFile = try AVAudioFile(forReading: tempAEC)
            guard Int(aecFile.length) == hostFrames else {
                return EchoCancelResult(
                    audioURL: host,
                    outcome: .failed,
                    warnings: [TranscriptDocument.Warning(
                        code: "aec_fallback",
                        sourceID: .host,
                        message: "AEC3: число обработанных фреймов (\(aecFile.length)) не равно исходным (\(hostFrames)); откат к исходному микрофону"
                    )]
                )
            }

            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempAEC, to: destination)

            return EchoCancelResult(audioURL: destination, outcome: .applied, warnings: [])
        } catch {
            try? outFile.close()
            return EchoCancelResult(
                audioURL: host,
                outcome: .failed,
                warnings: [TranscriptDocument.Warning(
                    code: "aec_fallback",
                    sourceID: .host,
                    message: "AEC3: исключение при запуске (\(error.localizedDescription)); откат к исходному микрофону"
                )]
            )
        }
    }
}
