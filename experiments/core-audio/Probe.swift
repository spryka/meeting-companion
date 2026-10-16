// Experimental only: never used by the installed application.
// shortcut: synchronous disk writes in the HAL callback; use a bounded buffer before production.
import AppKit
import AVFoundation
import CoreAudio
import Foundation

func checked(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw NSError(domain: operation, code: Int(status)) }
}

final class Probe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var tap: AudioObjectID = 0
    var device: AudioObjectID = 0
    var io: AudioDeviceIOProcID?
    let session = AVCaptureSession()
    let micQueue = DispatchQueue(label: "probe.microphone")
    let queue = DispatchQueue(label: "probe.files")
    let host: SourceAudioFile
    let remote: SourceAudioFile
    var epoch: UInt64 = 0
    var error: Error?
    var hostBuffers = 0
    var remoteBuffers = 0
    var hostPeak: Float = 0
    var remotePeak: Float = 0
    struct Timing {
        var first: Double?
        var end: Double?
        var maxGap = 0.0
        var maxOverlap = 0.0
        var frames: UInt64 = 0
        mutating func append(seconds: Double, frames: AVAudioFrameCount, rate: Double) {
            if let end {
                maxGap = max(maxGap, seconds - end)
                maxOverlap = max(maxOverlap, end - seconds)
            }
            if first == nil { first = seconds }
            end = seconds + Double(frames) / rate
            self.frames += UInt64(frames)
        }
    }
    var hostTiming = Timing()
    var remoteTiming = Timing()
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        host = try SourceAudioFile(url: directory.appendingPathComponent("host_record.wav"))
        remote = try SourceAudioFile(url: directory.appendingPathComponent("remote_record.wav"))
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
                  frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else { return }
        buffer.frameLength = buffer.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList) == noErr else { return }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        append(buffer, time: AVAudioTime.hostTime(forSeconds: seconds), microphone: true)
    }

    func append(_ buffer: AVAudioPCMBuffer, time: UInt64, microphone: Bool) {
        queue.sync {
            guard error == nil else { return }
            do {
                let seconds = AVAudioTime.seconds(forHostTime: time) - AVAudioTime.seconds(forHostTime: epoch)
                try (microphone ? host : remote).append(buffer, seconds: seconds)
                if microphone { hostTiming.append(seconds: seconds, frames: buffer.frameLength, rate: buffer.format.sampleRate) }
                else { remoteTiming.append(seconds: seconds, frames: buffer.frameLength, rate: buffer.format.sampleRate) }
                var peak: Float = 0
                if let samples = buffer.floatChannelData {
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[0][i])) }
                }
                if microphone { hostBuffers += 1; hostPeak = max(hostPeak, peak) }
                else { remoteBuffers += 1; remotePeak = max(remotePeak, peak) }
            } catch { self.error = error }
        }
    }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Meeting Companion audio-only experiment"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try checked(AudioHardwareCreateProcessTap(description, &tap), "CreateProcessTap")
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: asbd))
        try checked(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "TapFormat")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw SourceAudioError.invalidBuffer }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Companion experiment",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try checked(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "CreateAggregate")
        try checked(AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { [weak self] _, input, timestamp, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            self?.append(buffer, time: timestamp.pointee.mHostTime, microphone: false)
        }, "CreateIOProc")
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        guard let mic = devices.first(where: { $0.localizedName.contains("MacBook") }) ?? AVCaptureDevice.default(for: .audio) else { throw SourceAudioError.invalidBuffer }
        let micInput = try AVCaptureDeviceInput(device: mic)
        let micOutput = AVCaptureAudioDataOutput()
        micOutput.setSampleBufferDelegate(self, queue: micQueue)
        guard session.canAddInput(micInput), session.canAddOutput(micOutput) else { throw SourceAudioError.invalidBuffer }
        session.addInput(micInput)
        session.addOutput(micOutput)
        epoch = mach_absolute_time()
        session.startRunning()
        try checked(AudioDeviceStart(device, io), "DeviceStart")
        print("STARTED \(directory.path) system=\(format) mic=\(mic.localizedName)")
        fflush(stdout)
    }

    func stop() throws {
        if device != 0, let io { try checked(AudioDeviceStop(device, io), "DeviceStop") }
        session.stopRunning()
        micQueue.sync {}
        let duration = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: epoch)
        try queue.sync {
            try host.finish(duration: duration)
            try remote.finish(duration: duration)
            if let error { throw error }
        }
        print("FINISHED \(directory.path) duration=\(duration) hostBuffers=\(hostBuffers) remoteBuffers=\(remoteBuffers) peaks=\(hostPeak),\(remotePeak)")
        print("TIMING host=\(hostTiming) remote=\(remoteTiming)")
        fflush(stdout)
        assert(hostBuffers > 0 && remoteBuffers > 0, "Both sources must deliver audio")
        assert(hostTiming.first! >= 0 && remoteTiming.first! >= 0, "Both clocks must share the start epoch")
        assert(hostTiming.end! <= duration + 0.1 && remoteTiming.end! <= duration + 0.1, "Both clocks must share the stop epoch")
    }

    deinit {
        session.stopRunning()
        if device != 0 {
            if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
    }
}

@main struct Main {
    static func main() async {
        let log = open("/tmp/meeting-tap-probe.log", O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if log >= 0 { dup2(log, STDOUT_FILENO); dup2(log, STDERR_FILENO); close(log) }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { print("Microphone permission denied"); return }
        do {
            let probe = try Probe(directory: URL(fileURLWithPath: "/tmp/meeting-tap-" + UUID().uuidString))
            try probe.start()
            try await Task.sleep(for: .seconds(60))
            try probe.stop()
        } catch { print("PROBE FAILED: \(error)") }
    }
}
