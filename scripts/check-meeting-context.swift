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
        checkMeetingSelection(store: store, calendar: event.calendar, now: now)
        precondition(meeting.needsReminder(now: now, handled: []))
        precondition(!meeting.needsReminder(now: now.addingTimeInterval(-1), handled: []))
        precondition(!meeting.needsReminder(now: now.addingTimeInterval(300), handled: []))
        precondition(!meeting.needsReminder(now: now, handled: [meeting.id]))
        precondition(!meeting.needsReminder(now: now.addingTimeInterval(3601), handled: []))
        precondition(meeting.links == ["https://telemost.yandex.ru/j/123", "https://zoom.us/j/456"])
        precondition(meeting.needsReminder(now: now, handled: [], requireCallLink: true))
        for link in ["https://company.zoom.us/j/123?pwd=test", "https://telemost.yandex.ru/j/123",
                     "https://telemost.360.yandex.ru/j/123",
                     "https://meet.google.com/abc-defg-hij", "https://teams.microsoft.com/l/meetup-join/123",
                     "https://teams.live.com/meet/123", "https://company.webex.com/meet/person",
                     "https://meet.jit.si/room", "https://jazz.sber.ru/room"] {
            precondition(MeetingContext.isCallLink(link), link)
        }
        for link in ["https://docs.google.com/document/d/123", "https://zoom.us/",
                     "https://zoom.us/pricing", "https://zoom.us.evil.example/j/123",
                     "https://telemost.360.yandex.ru/", "https://telemost.360.yandex.ru.evil.example/j/123",
                     "mailto:person@zoom.us", "https://telemost.yandex.ru/", "https://example.com/agenda"] {
            precondition(!MeetingContext.isCallLink(link), link)
        }
        event.url = URL(string: "https://docs.google.com/document/d/123")
        event.notes = "Ссылка на видеовстречу: https://telemost.360.yandex.ru/j/123"
        let telemost360 = MeetingContext(event: event)
        precondition(telemost360.needsReminder(now: now.addingTimeInterval(114), handled: [], requireCallLink: true),
                     "A Telemost 360 meeting must trigger a reminder with the call-link filter enabled")
        event.notes = "Очная встреча"
        let inPerson = MeetingContext(event: event)
        precondition(inPerson.needsReminder(now: now, handled: []))
        precondition(!inPerson.needsReminder(now: now, handled: [], requireCallLink: true))
        let later = EKEvent(eventStore: store)
        later.calendar = event.calendar
        later.title = "Later this week"
        later.startDate = now.addingTimeInterval(2 * 86400)
        later.endDate = later.startDate.addingTimeInterval(3600)
        let ended = EKEvent(eventStore: store)
        ended.calendar = event.calendar
        ended.startDate = now.addingTimeInterval(-3600)
        ended.endDate = now
        let allDay = EKEvent(eventStore: store)
        allDay.calendar = event.calendar
        allDay.startDate = now
        allDay.endDate = now.addingTimeInterval(86400)
        allDay.isAllDay = true
        let visible = MeetingCalendar.visibleMeetings([later, ended, allDay, event], now: now)
        precondition(visible.map(\.summary) == ["Meeting", "Later this week"])
        precondition(!visible[1].needsReminder(now: now, handled: []))
        precondition(MeetingCalendar.visibleMeetings([ended, allDay], now: now).isEmpty)
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
        print("Meeting selection transitions, reminders, call links, persistence and context checks passed")
    }

    @MainActor
    static func checkMeetingSelection(store: EKEventStore, calendar: EKCalendar, now: Date) {
        func context(_ title: String, start: Double, end: Double) -> MeetingContext {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = title
            event.startDate = now.addingTimeInterval(start)
            event.endDate = now.addingTimeInterval(end)
            return MeetingContext(event: event)
        }
        let first = context("First", start: 0, end: 60)
        let next = context("Next", start: 120, end: 180)
        let overlap = context("Overlap", start: 30, end: 150)
        let events = [first, next]
        var selection = MeetingSelection()
        selection.refresh(events: events, now: now)
        precondition(selection.meeting == first)
        selection.refresh(events: events, now: now.addingTimeInterval(60))
        precondition(selection.meeting == nil, "An ended meeting must clear before the next starts")
        selection.refresh(events: events, now: now.addingTimeInterval(120))
        precondition(selection.meeting == next)

        selection.select(first)
        selection.refresh(events: events, now: now.addingTimeInterval(120))
        precondition(selection.meeting == next, "An expired manual selection must not stick")
        selection.select(next)
        selection.refresh(events: events, now: now)
        precondition(selection.meeting == next, "Preserve a manually chosen future meeting")
        let updated = context("Updated title", start: 120, end: 240)
        precondition(updated.id == next.id)
        selection.refresh(events: [first, updated], now: now)
        precondition(selection.meeting == updated, "Use the latest context for the selected event")
        selection.refresh(events: [first], now: now)
        precondition(selection.meeting == first, "Removed selections return to automatic selection")
        selection.select(nil)
        selection.refresh(events: events, now: now.addingTimeInterval(120))
        precondition(selection.meeting == nil, "Respect an explicit recording without a meeting")

        var ambiguous = MeetingSelection()
        ambiguous.refresh(events: events + [overlap], now: now.addingTimeInterval(30))
        precondition(ambiguous.meeting == MeetingSelection.orderedCurrent(events: events + [overlap], now: now.addingTimeInterval(30)).first, "Default to the first current event in stable order")
        ambiguous.select(first)
        ambiguous.refresh(events: events + [overlap], now: now.addingTimeInterval(30))
        precondition(ambiguous.meeting == first, "Respect a manual choice among concurrent meetings")
        precondition(MeetingSelection.nextBoundary(events: events, now: now) == now.addingTimeInterval(60))
        precondition(MeetingSelection.nextBoundary(events: events, now: now.addingTimeInterval(60)) == next.start)
        precondition(MeetingSelection.nextBoundary(events: events, now: next.end) == nil)
    }
}
