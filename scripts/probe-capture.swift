// Standalone capture comparison; never writes audio or changes the default device.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw NSError(domain: "CaptureProbe", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(operation): \(status)"])
    }
}

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func textProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var key = address(selector), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    try check(AudioObjectGetPropertyData(device, &key, 0, nil, &size, &value), "Read device text")
    guard let value else { throw NSError(domain: "CaptureProbe", code: 1) }
    return value.takeRetainedValue() as String
}

private func inputDevices() throws -> [(AudioObjectID, String, String)] {
    var key = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    try check(AudioObjectGetPropertyDataSize(system, &key, 0, nil, &size), "List device size")
    var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(system, &key, 0, nil, &size, &devices), "List devices")
    return try devices.compactMap { device in
        var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var bytes: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes), "Input streams")
        guard bytes > 0 else { return nil }
        return (device, try textProperty(device, kAudioDevicePropertyDeviceUID),
                try textProperty(device, kAudioObjectPropertyName))
    }
}

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var units: Int64 = 0
    func receive(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        buffers += 1; units += Int64(count)
    }
    var snapshot: (Int, Int64) {
        lock.lock(); defer { lock.unlock() }
        return (buffers, units)
    }
}

private final class Microphone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let counts: Counts
    private let queue = DispatchQueue(label: "capture-probe.microphone")
    init(counts: Counts) { self.counts = counts }
    func start(uid: String) throws {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
        guard let device = devices.first(where: { $0.uniqueID == uid }) else {
            throw NSError(domain: "CaptureProbe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "AVCapture microphone UID not found: \(uid)"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "CaptureProbe", code: 3)
        }
        session.addInput(input); session.addOutput(output)
        session.startRunning()
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if CMSampleBufferDataIsReady(sample) { counts.receive(CMSampleBufferGetNumSamples(sample)) }
    }
    func stop() { session.stopRunning(); queue.sync {} }
}

private final class HardwareInput {
    private var device: AudioObjectID = 0
    private var tap: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var aggregate = false

    func start(mode: String, inputDevice: AudioObjectID, counts: Counts) throws {
        if mode == "tap" {
            var pid = ProcessInfo.processInfo.processIdentifier, process: AudioObjectID = 0
            var key = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key,
                UInt32(MemoryLayout.size(ofValue: pid)), &pid, &size, &process), "Find process")
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: process == 0 ? [] : [process])
            description.name = "Meeting Companion Capture Probe"
            description.isPrivate = true; description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create tap")
            let properties: [String: Any] = [
                kAudioAggregateDeviceNameKey: description.name,
                kAudioAggregateDeviceUIDKey: "capture-probe." + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                 kAudioSubTapDriftCompensationKey: true]]]
            try check(AudioHardwareCreateAggregateDevice(properties as CFDictionary, &device), "Create aggregate")
            aggregate = true
        } else { device = inputDevice }
        // No copying, conversion, playback or files: only validate that input is delivered.
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            counts.receive(buffers.reduce(0) { $0 + ($1.mData == nil ? 0 : Int($1.mDataByteSize)) })
        }, "Create IOProc")
        try check(AudioDeviceStart(device, io), "Start input")
    }
    func stop() {
        if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
        io = nil
        if aggregate && device != 0 { AudioHardwareDestroyAggregateDevice(device) }
        device = 0; aggregate = false
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stop() }
}

@main
private struct CaptureProbe {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--self-check"] {
                let counts = Counts()
                counts.receive(0); counts.receive(100); counts.receive(20)
                precondition(counts.snapshot == (2, 120))
                HardwareInput().stop()
                print("Capture probe counters and unused hardware cleanup passed; no audio opened")
                return
            }
            if args == ["--list"] {
                for (_, uid, name) in try inputDevices() { print("\(uid)\t\(name)") }
                return
            }
            guard args.count == 3, ["avcapture", "tap", "hal"].contains(args[0]),
                  let seconds = Int(args[1]), (5...60).contains(seconds) else {
                throw NSError(domain: "CaptureProbe", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "Usage: --list | --self-check | avcapture|tap|hal SECONDS(5...60) MICROPHONE_UID"])
            }
            let mode = args[0], uid = args[2]
            guard let input = try inputDevices().first(where: { $0.1 == uid }) else {
                throw NSError(domain: "CaptureProbe", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Input device not found: \(uid)"])
            }
            if mode != "tap", !(await AVCaptureDevice.requestAccess(for: .audio)) {
                throw NSError(domain: "CaptureProbe", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
            }
            let counts = Counts(), microphone = Microphone(counts: counts), hardware = HardwareInput()
            defer { microphone.stop(); hardware.stop() }
            print("START mode=\(mode) seconds=\(seconds) input=\(input.2) pid=\(ProcessInfo.processInfo.processIdentifier)")
            fflush(stdout)
            if mode == "avcapture" { try microphone.start(uid: uid) }
            else { try hardware.start(mode: mode, inputDevice: input.0, counts: counts) }
            if mode != "tap" {
                print("MicMode preferred=\(AVCaptureDevice.preferredMicrophoneMode.rawValue) active=\(AVCaptureDevice.activeMicrophoneMode.rawValue)")
            }
            fflush(stdout)
            try await Task.sleep(for: .seconds(seconds))
            microphone.stop(); hardware.stop()
            let (buffers, units) = counts.snapshot
            guard buffers > 0 else {
                throw NSError(domain: "CaptureProbe", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "No input buffers; this run is invalid"])
            }
            print("STOP mode=\(mode) buffers=\(buffers) \(mode == "avcapture" ? "frames" : "bytes")=\(units)")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
