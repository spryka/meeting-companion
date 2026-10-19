import Combine
import Foundation

@main struct Check {
    @MainActor static func main() {
        var hint = MutedMicrophoneActivity()
        let epoch = Date()
        precondition(!hint.receive(0.4, muted: true, now: epoch))
        precondition(hint.receive(0.4, muted: true, now: epoch.addingTimeInterval(0.7)))
        precondition(hint.receive(0, muted: true, now: epoch.addingTimeInterval(1)))
        precondition(!hint.receive(0, muted: true, now: epoch.addingTimeInterval(3)))
        precondition(!hint.receive(1, muted: false, now: epoch.addingTimeInterval(4)))
        precondition(!hint.receive(1, muted: true, now: epoch.addingTimeInterval(5)))
        precondition(!hint.receive(0, muted: true, now: epoch.addingTimeInterval(5.2)))
        precondition(!hint.receive(1, muted: true, now: epoch.addingTimeInterval(5.8)))
        let levels = AudioLevels()
        let now = Date()
        var updates = 0
        let observer = levels.objectWillChange.sink { updates += 1 }
        levels.receive(mic: 0.32, system: .nan, now: now)
        levels.receive(mic: .nan, system: 0.87, now: now)
        precondition(updates == 0)
        levels.flush(now: now)
        precondition(levels.mic == 0.3 && levels.system == 0.9 && updates == 1)
        levels.receive(mic: 0.31, system: 0.88, now: now)
        levels.flush(now: now)
        precondition(updates == 1, "Equal steps must not redraw")
        levels.flush(now: now.addingTimeInterval(1))
        precondition(levels.mic == 0 && levels.system == 0 && updates == 2)
        levels.receive(mic: 2, system: -1, now: now)
        levels.flush(now: now)
        precondition(levels.mic == 1 && levels.system == 0)
        levels.setActive(false)
        precondition(levels.mic == 0 && levels.system == 0)
        withExtendedLifetime(observer) {}
        print("Audio levels: batching, quantization, unchanged values, silence, bounds and reset passed")
    }
}
