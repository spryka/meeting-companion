import Foundation

struct RecordingOvertime {
    let deadline: Date
    let hasMeeting: Bool
    private(set) var postponedUntil: Date?

    init(start: Date, meetingEnd: Date?) {
        deadline = meetingEnd ?? start.addingTimeInterval(3600)
        hasMeeting = meetingEnd != nil
    }

    func needsReminder(at now: Date) -> Bool {
        now >= deadline && now >= (postponedUntil ?? deadline)
    }

    mutating func postpone(at now: Date) {
        postponedUntil = now.addingTimeInterval(15 * 60)
    }
}
