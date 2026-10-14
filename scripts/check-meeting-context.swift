import EventKit
import Foundation

@main
struct MeetingChecks {
    @MainActor
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.calendar.title = "Work"
        event.title = "Meeting"
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
        precondition(meeting.needsReminder(now: now, handled: [], requireCallLink: true))
        for link in ["https://company.zoom.us/j/123?pwd=test", "https://telemost.yandex.ru/j/123",
                     "https://meet.google.com/abc-defg-hij", "https://teams.microsoft.com/l/meetup-join/123",
                     "https://teams.live.com/meet/123", "https://company.webex.com/meet/person",
                     "https://meet.jit.si/room", "https://jazz.sber.ru/room"] {
            precondition(MeetingContext.isCallLink(link), link)
        }
        for link in ["https://docs.google.com/document/d/123", "https://zoom.us/",
                     "https://zoom.us/pricing", "https://zoom.us.evil.example/j/123",
                     "mailto:person@zoom.us", "https://telemost.yandex.ru/", "https://example.com/agenda"] {
            precondition(!MeetingContext.isCallLink(link), link)
        }
        event.url = URL(string: "https://docs.google.com/document/d/123")
        event.notes = "Очная встреча"
        let inPerson = MeetingContext(event: event)
        precondition(inPerson.needsReminder(now: now, handled: []))
        precondition(!inPerson.needsReminder(now: now, handled: [], requireCallLink: true))
        event.notes = meeting.agenda
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
        precondition(json["summary"] as? String == "Meeting")
        precondition(json["agenda"] as? String == event.notes)
        precondition(json["start"] as? String != nil)
        do { try meeting.save(beside: audio); preconditionFailure("Context overwritten") } catch {}
        let unchanged = try Data(contentsOf: path)
        precondition(unchanged == original)
        let suite = "meeting-checks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = MeetingCalendar(defaults: defaults)
        let other = EKCalendar(for: .event, eventStore: store)
        calendar.calendars = [event.calendar, other]
        precondition(calendar.requireCallLink)
        precondition(calendar.isSelected(event.calendar) && calendar.isSelected(other))
        calendar.select(other, enabled: false)
        precondition(calendar.isSelected(event.calendar) && !calendar.isSelected(other))
        calendar.requireCallLink = false
        let restored = MeetingCalendar(defaults: defaults)
        precondition(restored.isSelected(event.calendar) && !restored.isSelected(other))
        precondition(!restored.requireCallLink)
        restored.select(event.calendar, enabled: false)
        let empty = MeetingCalendar(defaults: defaults)
        precondition(!empty.isSelected(event.calendar) && !empty.isSelected(other))
        precondition(empty.events.isEmpty)
        empty.select(other, enabled: true)
        precondition(empty.isSelected(other) && !empty.isSelected(event.calendar))
        print("Meeting reminder timing, call links, calendar selection, persistence and context checks passed")
    }
}
