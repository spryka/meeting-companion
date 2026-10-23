@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum AudioCaptureBackend: String, CaseIterable, Sendable {
    case screenCaptureKit
    case coreAudioTap
}

typealias AudioSink = @Sendable (AVAudioPCMBuffer, CMTime, Bool) -> Void

protocol AudioCapture: AnyObject, Sendable {
    func start() async throws
    func stop() async throws
}

func makeAudioCapture(backend: AudioCaptureBackend, microphoneID: String?,
    sink: @escaping AudioSink) async throws -> any AudioCapture {
    switch backend {
    case .screenCaptureKit:
        return try await ScreenAudioCapture(microphoneID: microphoneID, sink: sink)
    case .coreAudioTap:
        return TapAudioCapture(microphoneID: microphoneID, sink: sink)
    }
}

func pcmBuffer(from sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
    guard CMSampleBufferDataIsReady(sample), let description = CMSampleBufferGetFormatDescription(sample),
          CMSampleBufferGetNumSamples(sample) > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
              frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else { throw SourceAudioError.invalidBuffer }
    buffer.frameLength = buffer.frameCapacity
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(buffer.frameLength),
        into: buffer.mutableAudioBufferList) == noErr else { throw SourceAudioError.invalidBuffer }
    return buffer
}

struct CaptureLoss: Codable, Sendable {
    let microphone: Bool
    let timestamp: Double
    let duration: Double
}

struct CaptureFailure: Error, LocalizedError, Sendable {
    let report: CaptureReport
    var errorDescription: String? { report.warning }
}

struct MicrophoneRecoveryEvent: Codable, Sendable {
    let timestamp: Double
    let reason: String
}

struct CaptureReport: Codable, Sendable {
    var droppedBuffers = 0
    // Sum of source durations: simultaneous losses on two channels count twice.
    var droppedSourceSeconds = 0.0
    var losses: [CaptureLoss] = []
    var failure: String?
    var exportFailure: String?
    var microphoneRecoveryEvents: [MicrophoneRecoveryEvent]?
    var microphoneRecoveries: Int?
    var microphoneMissing: Bool?
    var warning: String? {
        var messages: [String] = []
        if droppedBuffers > 0 {
            messages.append(String(format: "Пропущено аудиобуферов: %d (%.3f с суммарно по дорожкам).", droppedBuffers, droppedSourceSeconds))
        }
        if let failure { messages.append("Сбой захвата: " + failure) }
        if microphoneMissing == true {
            messages.append("Во время записи переставали поступать данные микрофона; часть речи могла не сохраниться.")
        }
        if let count = microphoneRecoveries, count > 0 {
            messages.append("Попыток восстановления микрофона: \(count). В эти моменты возможны пропуски речи.")
        }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
}

// All file/conversion work runs on this queue; HAL callbacks only copy bounded input.
final class AudioDelivery: @unchecked Sendable {
    let queue = DispatchQueue(label: "local.meeting-companion.audio-delivery")
    private let slots: DispatchSemaphore
    private let lock = NSLock()
    private var report = CaptureReport()
    private let sink: AudioSink

    init(capacity: Int = 256, sink: @escaping AudioSink) {
        // Absorb short disk/scheduler stalls without allowing an unbounded queue.
        slots = DispatchSemaphore(value: capacity)
        self.sink = sink
    }

    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if report.failure == nil { report.failure = error.localizedDescription }
    }

    func noteMicrophoneRecovery(reason: String) {
        lock.lock(); defer { lock.unlock() }
        report.microphoneRecoveries = (report.microphoneRecoveries ?? 0) + 1
        if (report.microphoneRecoveryEvents?.count ?? 0) < 128 {
            if report.microphoneRecoveryEvents == nil { report.microphoneRecoveryEvents = [] }
            report.microphoneRecoveryEvents?.append(MicrophoneRecoveryEvent(
                timestamp: CMClockGetTime(CMClockGetHostTimeClock()).seconds, reason: reason))
        }
    }

    func submit(_ buffer: AVAudioPCMBuffer, time: CMTime, microphone: Bool) {
        guard slots.wait(timeout: .now()) == .success else {
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            lock.lock()
            report.droppedBuffers += 1
            report.droppedSourceSeconds += seconds
            // Bound diagnostics even if the disk remains blocked for hours.
            if report.losses.count < 1024 {
                report.losses.append(CaptureLoss(microphone: microphone, timestamp: time.seconds, duration: seconds))
            }
            lock.unlock()
            return
        }
        queue.async { [self] in
            defer { slots.signal() }
            sink(buffer, time, microphone)
        }
    }

    func drain() throws {
        queue.sync {}
        lock.lock(); defer { lock.unlock() }
        if report.warning != nil { throw CaptureFailure(report: report) }
    }
}

private final class ScreenAudioCapture: NSObject, AudioCapture, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let delivery: AudioDelivery
    private let queue = DispatchQueue(label: "local.meeting-companion.sck-audio")

    init(microphoneID: String?, sink: @escaping AudioSink) async throws {
        delivery = AudioDelivery(sink: sink)
        super.init()
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw RecorderError.noDisplay }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphoneID
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        self.stream = stream
    }

    func start() async throws { try await stream?.startCapture() }

    func stop() async throws {
        let stream = stream
        self.stream = nil
        do { try await stream?.stopCapture() }
        catch { delivery.fail(error) }
        queue.sync {}
        try delivery.drain()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        do { delivery.submit(try pcmBuffer(from: sample), time: CMSampleBufferGetPresentationTimeStamp(sample), microphone: type == .microphone) }
        catch { delivery.fail(error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { delivery.fail(error) }
}

private final class TapAudioCapture: NSObject, AudioCapture, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let microphoneID: String?
    private let delivery: AudioDelivery
    private let microphone = AVCaptureSession()
    private let micQueue = DispatchQueue(label: "local.meeting-companion.tap-microphone")
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var observer: NSObjectProtocol?

    init(microphoneID: String?, sink: @escaping AudioSink) {
        self.microphoneID = microphoneID
        delivery = AudioDelivery(sink: sink)
        super.init()
    }

    func start() async throws {
        if !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw NSError(domain: "AudioCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Нет доступа к микрофону."])
        }
        do { try configureAndStart() }
        catch { cleanup(); throw error }
    }

    private func configureAndStart() throws {
        var pid = ProcessInfo.processInfo.processIdentifier
        var processID: AudioObjectID = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout.size(ofValue: processID))
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout.size(ofValue: pid)), &pid, &size, &processID), "FindProcess")
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processID == 0 ? [] : [processID])
        description.name = "Meeting Companion"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "CreateProcessTap")
        address.mSelector = kAudioTapPropertyFormat
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout.size(ofValue: asbd))
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "TapFormat")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw SourceAudioError.invalidBuffer }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Companion",
            kAudioAggregateDeviceUIDKey: "local.meeting-companion." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                             kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "CreateAggregateDevice")
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { [weak self] _, input, timestamp, _, _ in
            guard let self else { return }
            guard let borrowed = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: borrowed.frameLength) else {
                delivery.fail(SourceAudioError.invalidBuffer); return
            }
            copy.frameLength = borrowed.frameLength
            let source = UnsafeMutableAudioBufferListPointer(borrowed.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (from, to) in zip(source, target) {
                guard let fromData = from.mData, let toData = to.mData, from.mDataByteSize <= to.mDataByteSize else {
                    delivery.fail(SourceAudioError.invalidBuffer); return
                }
                memcpy(toData, fromData, Int(from.mDataByteSize))
            }
            let time = CMTime(seconds: AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime), preferredTimescale: 1_000_000_000)
            delivery.submit(copy, time: time, microphone: false)
        }, "CreateIOProc")
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        guard let mic = microphoneID.flatMap({ id in devices.first { $0.uniqueID == id } }) ?? (microphoneID == nil ? AVCaptureDevice.default(for: .audio) : nil) else {
            throw NSError(domain: "AudioCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Выбранный микрофон недоступен."])
        }
        let input = try AVCaptureDeviceInput(device: mic)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: micQueue)
        guard microphone.canAddInput(input), microphone.canAddOutput(output) else { throw SourceAudioError.invalidBuffer }
        microphone.addInput(input)
        microphone.addOutput(output)
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: microphone, queue: nil) { [weak self] note in
            self?.delivery.fail(note.userInfo?[AVCaptureSessionErrorKey] as? Error ?? SourceAudioError.invalidBuffer)
        }
        microphone.startRunning()
        try check(AudioDeviceStart(device, io), "StartAudioDevice")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        do { delivery.submit(try pcmBuffer(from: sample), time: CMSampleBufferGetPresentationTimeStamp(sample), microphone: true) }
        catch { delivery.fail(error) }
    }

    func stop() async throws {
        cleanup()
        try delivery.drain()
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw NSError(domain: "CoreAudioTap", code: Int(status), userInfo: [NSLocalizedDescriptionKey:
                "Core Audio Tap: \(operation), ошибка \(status). Проверьте доступ к системному звуку или выберите ScreenCaptureKit."])
        }
    }

    private func cleanup() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if device != 0, let io {
            let status = AudioDeviceStop(device, io)
            if status != noErr { delivery.fail(NSError(domain: "AudioDeviceStop", code: Int(status))) }
            AudioDeviceDestroyIOProcID(device, io)
        }
        io = nil
        microphone.stopRunning()
        micQueue.sync {}
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }

    deinit { cleanup() }
}
