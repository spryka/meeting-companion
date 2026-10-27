import Foundation

@main struct Check {
    static func main() {
        let start = Date(timeIntervalSince1970: 1000)
        var manual = RecordingOvertime(start: start, meetingEnd: nil)
        precondition(!manual.hasMeeting)
        precondition(!manual.needsReminder(at: start.addingTimeInterval(3599)))
        precondition(manual.needsReminder(at: start.addingTimeInterval(3600)))
        let now = start.addingTimeInterval(4000)
        manual.postpone(at: now)
        precondition(!manual.needsReminder(at: now.addingTimeInterval(899)))
        precondition(manual.needsReminder(at: now.addingTimeInterval(900)))
        let end = start.addingTimeInterval(120)
        let meeting = RecordingOvertime(start: start, meetingEnd: end)
        precondition(meeting.hasMeeting)
        precondition(!meeting.needsReminder(at: end.addingTimeInterval(-1)))
        precondition(meeting.needsReminder(at: end))
        let next = RecordingOvertime(start: now, meetingEnd: nil)
        precondition(!next.needsReminder(at: now))
        precondition(RecordingOvertime(start: start, meetingEnd: start.addingTimeInterval(-1)).needsReminder(at: start))
        print("Recording overtime: calendar end, one-hour threshold, snooze and new recording passed")
    }
}
