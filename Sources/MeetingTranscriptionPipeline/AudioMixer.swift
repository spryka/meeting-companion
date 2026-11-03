import Foundation
import AVFoundation

public enum AudioMixerError: LocalizedError, Sendable {
    case invalidSource(String)
    case destinationExists(String)
    case destinationIsSource
    case durationMismatch(hostFrames: Int, remoteFrames: Int)
    case encodingFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let path):
            return "Некорректный исходный аудиофайл для микширования: \(path)"
        case .destinationExists(let path):
            return "Файл микса уже существует: \(path)"
        case .destinationIsSource:
            return "Целевой файл микса совпадает с одним из исходных файлов"
        case .durationMismatch(let host, let remote):
            return "Длительности дорожек не совпадают (host: \(host), remote: \(remote) фреймов)"
        case .encodingFailed(let detail):
            return "Сбой сжатия AAC через afconvert: \(detail)"
        case .verificationFailed(let detail):
            return "Сбой проверки декодирования микса: \(detail)"
        }
    }
}

public struct AudioMixer: Sendable {
    public static let sampleRate: Double = 16000
    public static let blockFrames: AVAudioFrameCount = 65536

    /// Validates an audio file via AVAudioFile and returns its total frame count.
    public static func inspectWAV(_ url: URL) throws -> Int {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioMixerError.invalidSource("Не удалось открыть WAV: \(error.localizedDescription) (\(url.path))")
        }

        let format = file.processingFormat
        guard format.sampleRate == sampleRate, format.channelCount == 1 else {
            throw AudioMixerError.invalidSource("Требуется 16 kHz mono WAV, получено: rate=\(format.sampleRate), ch=\(format.channelCount) в \(url.path)")
        }

        let frames = Int(file.length)
        guard frames > 0 else {
            throw AudioMixerError.invalidSource("Пустой аудиофайл: \(url.path)")
        }
        return frames
    }

    /// Prepares an immutable AAC mix from host and remote mono 16kHz WAVs.
    /// Streams in blocks using AVAudioFile, avoids loading entire audio files into memory,
    /// and verifies the encoded mix duration.
    public static func prepareMix(host: URL, remote: URL, destination: URL) throws {
        let hostStandard = host.resolvingSymlinksInPath().standardizedFileURL
        let remoteStandard = remote.resolvingSymlinksInPath().standardizedFileURL
        let destStandard = destination.resolvingSymlinksInPath().standardizedFileURL

        if destStandard == hostStandard || destStandard == remoteStandard {
            throw AudioMixerError.destinationIsSource
        }
        if FileManager.default.fileExists(atPath: destStandard.path) {
            throw AudioMixerError.destinationExists(destStandard.path)
        }

        let hostFile = try AVAudioFile(forReading: hostStandard)
        let remoteFile = try AVAudioFile(forReading: remoteStandard)

        let hostFrames = Int(hostFile.length)
        let remoteFrames = Int(remoteFile.length)

        guard hostFrames == remoteFrames else {
            throw AudioMixerError.durationMismatch(hostFrames: hostFrames, remoteFrames: remoteFrames)
        }
        let totalFrames = hostFrames

        let destDir = destStandard.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let tempID = UUID().uuidString
        let tempMixedWAV = destDir.appendingPathComponent(".mix-temp-\(tempID).wav")
        let tempEncodedM4A = destDir.appendingPathComponent(".mix-temp-\(tempID).m4a")
        let tempDecodedWAV = destDir.appendingPathComponent(".mix-temp-dec-\(tempID).wav")

        defer {
            try? FileManager.default.removeItem(at: tempMixedWAV)
            try? FileManager.default.removeItem(at: tempEncodedM4A)
            try? FileManager.default.removeItem(at: tempDecodedWAV)
        }

        // Stream-mix channels into temporary 16kHz 16-bit WAV file and finalize header
        try {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let mixedFile = try AVAudioFile(forWriting: tempMixedWAV, settings: settings)

            let format = hostFile.processingFormat
            guard let hostBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
                  let remoteBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
                  let mixedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
                throw AudioMixerError.encodingFailed("Не удалось выделить буферы аудио")
            }

            hostFile.framePosition = 0
            remoteFile.framePosition = 0

            while hostFile.framePosition < hostFile.length {
                let framesLeft = AVAudioFrameCount(hostFile.length - hostFile.framePosition)
                let toRead = min(blockFrames, framesLeft)

                try hostFile.read(into: hostBuffer, frameCount: toRead)
                try remoteFile.read(into: remoteBuffer, frameCount: toRead)

                let readCount = Int(hostBuffer.frameLength)
                guard readCount > 0,
                      let hostPtr = hostBuffer.floatChannelData?[0],
                      let remotePtr = remoteBuffer.floatChannelData?[0],
                      let mixedPtr = mixedBuffer.floatChannelData?[0] else {
                    break
                }

                for i in 0..<readCount {
                    mixedPtr[i] = (hostPtr[i] + remotePtr[i]) * 0.5
                }

                mixedBuffer.frameLength = AVAudioFrameCount(readCount)
                try mixedFile.write(from: mixedBuffer)
            }
        }()

        // Encode via /usr/bin/afconvert
        let encodeProcess = Process()
        encodeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        encodeProcess.arguments = [
            tempMixedWAV.path,
            tempEncodedM4A.path,
            "-f", "m4af",
            "-d", "aac",
            "-b", "32000",
            "-q", "127"
        ]
        let encodeErrPipe = Pipe()
        encodeProcess.standardError = encodeErrPipe
        try encodeProcess.run()
        encodeProcess.waitUntilExit()

        guard encodeProcess.terminationStatus == 0 else {
            let errData = encodeErrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(decoding: errData, as: UTF8.self)
            throw AudioMixerError.encodingFailed("Код \(encodeProcess.terminationStatus): \(errText)")
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tempEncodedM4A.path),
              let size = attrs[.size] as? UInt64, size > 0 else {
            throw AudioMixerError.encodingFailed("afconvert создал пустой файл M4A")
        }

        // Verify decoded duration matches source frames (within 1023 AAC padding frames)
        let decodeProcess = Process()
        decodeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        decodeProcess.arguments = [
            tempEncodedM4A.path,
            tempDecodedWAV.path,
            "-f", "WAVE",
            "-d", "LEI16@16000"
        ]
        let decodeErrPipe = Pipe()
        decodeProcess.standardError = decodeErrPipe
        try decodeProcess.run()
        decodeProcess.waitUntilExit()

        guard decodeProcess.terminationStatus == 0 else {
            let errData = decodeErrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(decoding: errData, as: UTF8.self)
            throw AudioMixerError.verificationFailed("Не удалось декодировать M4A для проверки: \(errText)")
        }

        let decodedFile = try AVAudioFile(forReading: tempDecodedWAV)
        let decodedFrames = Int(decodedFile.length)
        guard decodedFrames >= totalFrames && decodedFrames <= totalFrames + 1023 else {
            throw AudioMixerError.verificationFailed("Длительность декодированного микса (\(decodedFrames)) не соответствует источнику (\(totalFrames))")
        }

        // Move to destination
        if FileManager.default.fileExists(atPath: destStandard.path) {
            throw AudioMixerError.destinationExists(destStandard.path)
        }
        try FileManager.default.moveItem(at: tempEncodedM4A, to: destStandard)
    }
}
