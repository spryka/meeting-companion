import EventKit
import Foundation

@main
struct MeetingChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.calendar.title = "Work"
        event.title = "Interview"
        event.startDate = now
        event.endDate = now.addingTimeInterval(3600)
        event.notes = "Agenda: architecture https://telemost.yandex.ru/j/123"
        event.url = URL(string: "https://zoom.us/j/456")
        let meeting = MeetingContext(event: event)
        precondition(meeting.needsReminder(now: now, handled: []))
        precondition(!meeting.needsReminder(now: now.addingTimeInterval(-1), handled: []))
        precondition(!meeting.needsReminder(now: now.addingTimeInterval(300), handled: []))
        precondition(!meeting.needsReminder(now: now, handled: [meeting.id]))
        precondition(!meeting.needsReminder(now: now.addingTimeInterval(3601), handled: []))
        precondition(meeting.links == ["https://telemost.yandex.ru/j/123", "https://zoom.us/j/456"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("test.m4a")
        try meeting.save(beside: audio)
        let path = folder.appendingPathComponent("test.context.json")
        let original = try Data(contentsOf: path)
        let json = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        precondition(json["host"] as? String == NSFullUserName())
        precondition(json["timezone"] as? String == TimeZone.current.identifier)
        precondition(json["summary"] as? String == "Interview")
        precondition(json["agenda"] as? String == event.notes)
        precondition(json["start"] as? String != nil)
        do { try meeting.save(beside: audio); preconditionFailure("Context overwritten") } catch {}
        let unchanged = try Data(contentsOf: path)
        precondition(unchanged == original)
        print("Meeting reminder timing, links and context checks passed")
    }
}
