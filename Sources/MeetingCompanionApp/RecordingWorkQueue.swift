import Foundation

// One export/transcription job at a time; microphone capture never enters this queue.
@MainActor
final class RecordingWorkQueue {
    private var pending: [@MainActor () async -> Void] = []
    private var worker: Task<Void, Never>?
    var isRunning: Bool { worker != nil }

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        pending.append(operation)
        guard worker == nil else { return }
        worker = Task { [self] in
            while !pending.isEmpty {
                let next = pending.removeFirst()
                await next()
            }
            worker = nil
        }
    }
}
