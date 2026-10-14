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

    func needsReminder(now: Date, handled: Set<String>) -> Bool {
        start <= now && now.timeIntervalSince(start) < 300 && end > now && !handled.contains(id)
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
    @Published var message = ""
    private let store = EKEventStore()
    private var timer: Timer?
    private var handled = UserDefaults.standard.dictionary(forKey: "meetingReminders") as? [String: Double] ?? [:]
    var onMeeting: ((MeetingContext) -> Void)?

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
            message = "Нет доступа к календарю; запись доступна вручную."
            return
        }
        message = ""
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        let now = Date()
        handled = handled.filter { now.timeIntervalSince1970 - $0.value < 86400 }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-300),
                                                 end: now.addingTimeInterval(12 * 3600), calendars: nil)
        events = store.events(matching: predicate).filter { event in
            !event.isAllDay && event.status != .canceled && event.endDate > now
                && event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined
        }.map(MeetingContext.init(event:)).sorted { $0.start < $1.start }
        if let event = events.first(where: { $0.needsReminder(now: now, handled: Set(handled.keys)) }) {
            onMeeting?(event)
        }
    }

    func acknowledge(_ event: MeetingContext) {
        handled[event.id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(handled, forKey: "meetingReminders")
    }
}
