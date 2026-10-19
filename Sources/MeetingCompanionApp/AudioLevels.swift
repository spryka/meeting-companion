import Combine
import Foundation

@MainActor
final class AudioLevels: ObservableObject {
    private(set) var mic = 0.0
    private(set) var system = 0.0
    private var pendingMic = 0.0
    private var pendingSystem = 0.0
    private var lastMic = Date.distantPast
    private var lastSystem = Date.distantPast
    private var timer: Timer?

    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        reset()
        if active {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.flush() }
            }
        }
    }

    func receive(mic: Double, system: Double, now: Date = Date()) {
        if mic.isFinite { pendingMic = mic; lastMic = now }
        if system.isFinite { pendingSystem = system; lastSystem = now }
    }

    func flush(now: Date = Date()) {
        let nextMic = Self.step(now.timeIntervalSince(lastMic) < 0.6 ? pendingMic : 0)
        let nextSystem = Self.step(now.timeIntervalSince(lastSystem) < 0.6 ? pendingSystem : 0)
        guard nextMic != mic || nextSystem != system else { return }
        objectWillChange.send()
        mic = nextMic
        system = nextSystem
    }

    func reset() {
        pendingMic = 0
        pendingSystem = 0
        lastMic = .distantPast
        lastSystem = .distantPast
        flush()
    }

    private static func step(_ value: Double) -> Double {
        (min(max(value, 0), 1) * 10).rounded() / 10
    }
}

// A level hint, not a speech classifier; never changes recording state itself.
struct MutedMicrophoneActivity {
    private var aboveSince: Date?
    private var lastLoud = Date.distantPast
    private(set) var detected = false

    mutating func receive(_ level: Double, muted: Bool, now: Date = Date()) -> Bool {
        guard muted, level.isFinite else { self = Self(); return false }
        if level >= 0.12 {
            if aboveSince == nil { aboveSince = now }
            if now.timeIntervalSince(aboveSince!) >= 0.6 { detected = true }
            lastLoud = now
        } else {
            aboveSince = nil
            if now.timeIntervalSince(lastLoud) >= 2 { detected = false }
        }
        return detected
    }
}
