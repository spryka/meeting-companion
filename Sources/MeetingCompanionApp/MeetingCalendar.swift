import AppKit
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
    @Published private(set) var isLoadingCalendars = false
    @Published private(set) var suggestsCalendarSetup = false
    @Published private(set) var selectedCalendarIDs: Set<String>?
    @Published var requireCallLink: Bool {
        didSet {
            defaults.set(requireCallLink, forKey: "meetingRequireCallLink")
            refresh()
        }
    }
    private let defaults: UserDefaults
    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var reminderTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var catalogTask: Task<Void, Never>?
    private var started = false
    private var mainWindowVisible = false
    private var calendarSettingsVisible = false
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
        guard !started else { return }
        started = true
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                    self?.loadCalendarsIfVisible()
                }
            }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                    self?.loadCalendarsIfVisible()
                }
            }.store(in: &subscriptions)
        do {
            guard try await store.requestFullAccessToEvents() else {
                message = "Разреши доступ к календарю в настройках macOS для напоминаний."
                return
            }
            refresh()
            loadCalendarsIfVisible()
        } catch { message = "Календарь: " + error.localizedDescription }
    }

    func setMainWindowVisible(_ visible: Bool) {
        guard mainWindowVisible != visible else { return }
        mainWindowVisible = visible
        if visible { refresh() }
        else { suggestsCalendarSetup = false }
    }

    func setCalendarSettingsVisible(_ visible: Bool) {
        guard calendarSettingsVisible != visible else { return }
        calendarSettingsVisible = visible
        if visible { loadCalendarsIfVisible() }
        else {
            catalogTask?.cancel()
            isLoadingCalendars = false
        }
    }

    private func loadCalendarsIfVisible() {
        guard calendarSettingsVisible else { return }
        catalogTask?.cancel()
        isLoadingCalendars = true
        catalogTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            defer { self.isLoadingCalendars = false }
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                self.calendars = []
                return
            }
            self.calendars = self.store.calendars(for: .event).sorted {
                ($0.source.title, $0.title) < ($1.source.title, $1.title)
            }
        }
    }

    // Re-read the local store more often around a start; this never forces account sync.
    static func refreshDelay(events: [MeetingContext], now: Date) -> TimeInterval {
        var delay: TimeInterval = 300
        for event in events {
            let untilStart = event.start.timeIntervalSince(now)
            if untilStart > -300 && untilStart <= 300 {
                delay = min(delay, 30)
            } else if untilStart > 300 {
                delay = min(delay, untilStart - 300)
            }
        }
        return max(1, delay)
    }

    private func scheduleRefresh(now: Date) {
        guard started else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshDelay(events: events, now: now), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func checkReminders() {
        reminderTimer?.invalidate()
        let now = Date()
        if let event = events.first(where: { $0.needsReminder(now: now, handled: Set(handled.keys), requireCallLink: requireCallLink) }) {
            onMeeting?(event)
        }
        guard started, let next = events.first(where: {
            $0.start > now && !handled.keys.contains($0.id)
                && (!requireCallLink || $0.links.contains(where: MeetingContext.isCallLink))
        }) else { return }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, next.start.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkReminders() }
        }
    }

    func refresh() {
        refreshTimer?.invalidate()
        reminderTimer?.invalidate()
        let now = Date()
        defer { scheduleRefresh(now: now) }
        suggestsCalendarSetup = false
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            events = []
            calendars = []
            message = "Нет доступа к календарю; запись доступна вручную."
            return
        }
        handled = handled.filter { now.timeIntervalSince1970 - $0.value < 86400 }
        // nil preserves the default of all calendars without loading their catalog.
        let selected = selectedCalendarIDs.map { $0.compactMap { store.calendar(withIdentifier: $0) } }
        if let selected, selected.isEmpty {
            events = []
            message = "Выбери календарь в настройках Meeting Companion → Календарь."
            return
        }
        func meetings(until end: Date) -> [MeetingContext] {
            let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-300),
                                                     end: end, calendars: selected)
            return Self.visibleMeetings(store.events(matching: predicate), now: now)
        }
        events = meetings(until: now.addingTimeInterval(12 * 3600))
        message = events.isEmpty ? "В ближайшие 12 часов встреч нет." : ""
        if mainWindowVisible && events.isEmpty {
            suggestsCalendarSetup = meetings(until: now.addingTimeInterval(7 * 86400)).isEmpty
            if suggestsCalendarSetup {
                message = "В выбранных календарях нет встреч на ближайшие 7 дней. Возможно, рабочий календарь ещё не подключён к macOS."
            }
        }
        checkReminders()
    }

    static func visibleMeetings(_ events: [EKEvent], now: Date) -> [MeetingContext] {
        events.filter { event in
            !event.isAllDay && event.status != .canceled && event.endDate > now
                && event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined
        }.map(MeetingContext.init(event:)).sorted { $0.start < $1.start }
    }

    func acknowledge(_ event: MeetingContext) {
        handled[event.id] = Date().timeIntervalSince1970
        defaults.set(handled, forKey: "meetingReminders")
    }
}
