import Combine
import EventKit
import Foundation

struct MeetingContext: Encodable, Identifiable, Hashable {
    let id: String
    let calendar: String
    let summary: String
    let start: Date
    let end: Date
    let agenda: String
    let links: [String]
    let attendees: [String]
    let host = NSFullUserName()
    let timezone = TimeZone.current.identifier

    init(event: EKEvent) {
        id = (event.calendar.calendarIdentifier + ":" + (event.eventIdentifier ?? "") + ":" + String(event.startDate.timeIntervalSince1970))
        calendar = event.calendar.title
        summary = event.title ?? "Встреча"
        start = event.startDate
        end = event.endDate
        agenda = event.notes ?? ""
        attendees = (event.attendees ?? []).map { $0.name ?? $0.url.absoluteString }
        links = Self.links(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n"))
    }

    static func links(in text: String) -> [String] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return Array(Set((detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [])
            .compactMap { $0.url?.absoluteString })).sorted()
    }

    static func isCallLink(_ link: String) -> Bool {
        guard let url = URL(string: link), let host = url.host?.lowercased(),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let path = url.path.lowercased()
        func domain(_ name: String) -> Bool { host == name || host.hasSuffix("." + name) }
        if domain("zoom.us") || domain("zoom.com") {
            return ["/j/", "/my/", "/s/"].contains { path.hasPrefix($0) && path.count > $0.count }
        }
        if host == "telemost.yandex.ru" || host == "telemost.yandex.com" {
            return path.hasPrefix("/j/") && path.count > 3
        }
        if host == "meet.google.com" { return path != "" && path != "/" }
        if host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.cloud.microsoft" {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")
        }
        if domain("webex.com") {
            return path.hasPrefix("/meet/") || path.hasPrefix("/join/") || path.hasSuffix("/j.php")
        }
        if host == "meet.jit.si" || host == "jazz.sber.ru" { return path != "" && path != "/" }
        return false
    }

    func needsReminder(now: Date, handled: Set<String>, requireCallLink: Bool = false) -> Bool {
        start <= now && now.timeIntervalSince(start) < 300 && end > now && !handled.contains(id)
            && (!requireCallLink || links.contains(where: Self.isCallLink))
    }

    func save(beside recording: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: recording.deletingPathExtension().appendingPathExtension("context.json"), options: [.withoutOverwriting])
    }
}

@MainActor
final class MeetingCalendar: ObservableObject {
    @Published var events: [MeetingContext] = []
    @Published var calendars: [EKCalendar] = []
    @Published var message = ""
    @Published private(set) var selectedCalendarIDs: Set<String>?
    @Published var requireCallLink: Bool {
        didSet {
            defaults.set(requireCallLink, forKey: "meetingRequireCallLink")
            refresh()
        }
    }
    private let defaults: UserDefaults
    private let store = EKEventStore()
    private var timer: Timer?
    private var handled: [String: Double]
    var onMeeting: ((MeetingContext) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedCalendarIDs = defaults.stringArray(forKey: "meetingCalendarIDs").map { Set($0) }
        requireCallLink = defaults.object(forKey: "meetingRequireCallLink") as? Bool ?? true
        handled = defaults.dictionary(forKey: "meetingReminders") as? [String: Double] ?? [:]
    }

    func isSelected(_ calendar: EKCalendar) -> Bool {
        selectedCalendarIDs?.contains(calendar.calendarIdentifier) ?? true
    }

    func select(_ calendar: EKCalendar, enabled: Bool) {
        var ids = selectedCalendarIDs ?? Set(calendars.map(\.calendarIdentifier))
        if enabled { ids.insert(calendar.calendarIdentifier) }
        else { ids.remove(calendar.calendarIdentifier) }
        selectedCalendarIDs = ids
        defaults.set(Array(ids).sorted(), forKey: "meetingCalendarIDs")
        refresh()
    }

    func start() async {
        do {
            guard try await store.requestFullAccessToEvents() else {
                message = "Разреши доступ к календарю в настройках macOS для напоминаний."
                return
            }
            refresh()
        } catch { message = "Календарь: " + error.localizedDescription }
    }

    func refresh() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            events = []
            calendars = []
            message = "Нет доступа к календарю; запись доступна вручную."
            return
        }
        message = ""
        calendars = store.calendars(for: .event).sorted {
            ($0.source.title, $0.title) < ($1.source.title, $1.title)
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        let now = Date()
        handled = handled.filter { now.timeIntervalSince1970 - $0.value < 86400 }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-300),
                                                 end: now.addingTimeInterval(12 * 3600), calendars: calendars.filter(isSelected))
        events = calendars.contains(where: isSelected) ? store.events(matching: predicate).filter { event in
            !event.isAllDay && event.status != .canceled && event.endDate > now
                && event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined
        }.map(MeetingContext.init(event:)).sorted { $0.start < $1.start } : []
        if let event = events.first(where: { $0.needsReminder(now: now, handled: Set(handled.keys), requireCallLink: requireCallLink) }) {
            onMeeting?(event)
        }
    }

    func acknowledge(_ event: MeetingContext) {
        handled[event.id] = Date().timeIntervalSince1970
        defaults.set(handled, forKey: "meetingReminders")
    }
}
