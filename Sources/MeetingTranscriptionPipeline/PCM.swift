import Foundation
import AVFoundation
import CryptoKit

public struct PipelineAudioError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ text: String) { description = text }
}

public final class PCMReader: @unchecked Sendable {
    public let file: AVAudioFile
    public let count: Int
    public let block: Int
    private let buffer: AVAudioPCMBuffer
    public private(set) var maxReadFrames = 0
    public private(set) var decodedFrames = 0
    public private(set) var bufferCapacity = 0

    public init(_ url: URL, block: Int, limit: Int = Int.max) throws {
        guard block > 0, block <= Int(UInt32.max), limit >= 0 else {
            throw PipelineAudioError("invalid reader bounds")
        }
        file = try AVAudioFile(forReading: url)
        let f = file.fileFormat.streamDescription.pointee
        guard url.pathExtension.lowercased() == "wav", f.mSampleRate == 16000,
              f.mChannelsPerFrame == 1, f.mFormatID == kAudioFormatLinearPCM,
              f.mBitsPerChannel == 16, f.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              file.processingFormat.commonFormat == .pcmFormatFloat32 else {
            throw PipelineAudioError("input must be 16 kHz mono PCM16 WAV; no implicit resampling")
        }
        self.block = block
        count = min(Int(file.length), limit)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(1, min(block, count)))) else {
            throw PipelineAudioError("cannot allocate PCM buffer")
        }
        buffer = pcm
        bufferCapacity = Int(pcm.frameCapacity)
    }

    public func next() throws -> [Float]? {
        let n = min(block, count - decodedFrames)
        if n == 0 { return nil }
        maxReadFrames = max(maxReadFrames, n)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(n))
        guard buffer.frameLength == n, let p = buffer.floatChannelData?[0] else {
            throw PipelineAudioError("unexpected PCM EOF")
        }
        decodedFrames += n
        return Array(UnsafeBufferPointer(start: p, count: n))
    }
}

public func streamingSHA(_ url: URL) throws -> String {
    let f = try FileHandle(forReadingFrom: url)
    defer { try? f.close() }
    var hash = SHA256()
    while try autoreleasepool(invoking: { () throws -> Bool in
        guard let data = try f.read(upToCount: 1_048_576), !data.isEmpty else { return false }
        hash.update(data: data)
        return true
    }) {}
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

public struct FeedFrames: Sendable {
    public init() {}
    public private(set) var tail: [Float] = []
    public private(set) var maxBuffered = 0
    public private(set) var samples = 0
    public private(set) var finished = false

    public mutating func append(_ input: [Float], emit: ([Float]) throws -> Void) throws {
        guard !finished else { throw PipelineAudioError("feed after EOF") }
        samples += input.count
        let block = tail + input
        maxBuffered = max(maxBuffered, block.count)
        let n = block.count / 512 * 512
        for i in stride(from: 0, to: n, by: 512) {
            try emit(Array(block[i..<i+512]))
        }
        tail = Array(block[n...])
    }

    public mutating func finish(emit: ([Float]) throws -> Void) throws {
        guard !finished else { throw PipelineAudioError("duplicate EOF") }
        finished = true
        if !tail.isEmpty {
            try emit(tail + Array(repeating: 0, count: 512 - tail.count))
            tail = []
        }
    }
}
