import Foundation

// Apple Reminders — Stage 1 (read-only). Nothing in this file can create, edit, complete or
// delete a reminder: `RemindersClient` deliberately has no write methods. Reminder content is
// held in process memory only (never SQLite, source records, the ownership journal, logs, or an
// analysis/AI input). See docs/APPLE_REMINDERS.md.

public enum RemindersAccess: String, Sendable { case notDetermined, fullAccess, denied, restricted, writeOnly }

public enum RemindersError: Error, LocalizedError, Equatable {
    case permission, unavailable
    public var errorDescription: String? {
        switch self {
        case .permission: "Reminders full access is required. Use Connections to request access, or review Reminders access in System Settings › Privacy & Security."
        case .unavailable: "Reminders could not be read. The last successful snapshot, if any, is kept and marked out of date. Try again later."
        }
    }
}

/// EventKit encodes priority as 0 (none), 1–4 (high), 5 (medium), 6–9 (low).
public enum ReminderPriority: Int, Comparable, Sendable {
    case high = 1, medium, low, none
    public init(eventKitValue: Int) {
        switch eventKitValue {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
    public var label: String {
        switch self { case .high: "High"; case .medium: "Medium"; case .low: "Low"; case .none: "None" }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A due date as Reminders stores it: either a calendar day (no time) or an instant.
public struct ReminderDue: Equatable, Sendable {
    public let date: Date
    public let hasTime: Bool
    /// Nil for floating dates, which follow the viewer's current time zone.
    public let timeZoneIdentifier: String?
    public init(date: Date, hasTime: Bool, timeZoneIdentifier: String? = nil) {
        self.date = date; self.hasTime = hasTime; self.timeZoneIdentifier = timeZoneIdentifier
    }
    /// Converts EventKit `dueDateComponents`. Date-only components resolve to the start of that day.
    public init?(components: DateComponents, fallback: Calendar = .current) {
        var calendar = components.calendar ?? fallback
        if let zone = components.timeZone { calendar.timeZone = zone }
        guard components.year != nil, components.month != nil, components.day != nil,
              let date = calendar.date(from: components) else { return nil }
        self.init(date: date, hasTime: components.hour != nil, timeZoneIdentifier: components.timeZone?.identifier)
    }
}

public struct ReminderListInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let sourceID: String
    public let sourceTitle: String
    public init(id: String, title: String, sourceID: String, sourceTitle: String) {
        self.id = id; self.title = title; self.sourceID = sourceID; self.sourceTitle = sourceTitle
    }
}

public struct ReminderItem: Identifiable, Equatable, Sendable {
    /// Stable within the device store (EventKit `calendarItemIdentifier`).
    public let id: String
    /// EventKit's cross-device identifier, retained for later write-back and duplicate linking.
    public let externalID: String?
    public let listID: String
    public let title: String
    public let notes: String?
    public let due: ReminderDue?
    public let priority: ReminderPriority
    public let isCompleted: Bool
    public let completedAt: Date?
    /// Only http(s) links are retained.
    public let url: URL?
    /// Nil whenever the public EventKit API does not expose hierarchy (it currently does not).
    public let parentID: String?
    public let isRecurring: Bool
    public let recurrenceSummary: String?
    public let lastModified: Date?

    public init(id: String, externalID: String? = nil, listID: String, title: String, notes: String? = nil,
                due: ReminderDue? = nil, priority: ReminderPriority = .none, isCompleted: Bool = false,
                completedAt: Date? = nil, url: URL? = nil, parentID: String? = nil, isRecurring: Bool = false,
                recurrenceSummary: String? = nil, lastModified: Date? = nil) {
        self.id = id; self.externalID = externalID; self.listID = listID; self.title = title
        self.notes = notes?.isEmpty == true ? nil : notes
        self.due = due; self.priority = priority; self.isCompleted = isCompleted; self.completedAt = completedAt
        if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { self.url = url }
        else { self.url = nil }
        self.parentID = parentID; self.isRecurring = isRecurring; self.recurrenceSummary = recurrenceSummary
        self.lastModified = lastModified
    }

    /// Items sharing a list and non-empty external ID are one reminder seen twice (for example,
    /// a duplicated store row). Otherwise the device identifier decides.
    var deduplicationKey: String {
        if let externalID, !externalID.isEmpty { return "ext|\(listID)|\(externalID)" }
        return "loc|\(id)"
    }
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled reminder" : trimmed
    }
}

/// Read-only access to Reminders. There are intentionally no save/complete/delete members;
/// Stage 2 write support must be a separate protocol so Stage 1 code can never obtain it.
@MainActor public protocol RemindersClient: AnyObject {
    var access: RemindersAccess { get }
    func requestAccess() async throws
    func lists() throws -> [ReminderListInfo]
    func reminders(in listIDs: [String]) async throws -> [ReminderItem]
    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any AppleCalendarChangeObservation
}

public struct RemindersSnapshot: Equatable, Sendable {
    public var lists: [ReminderListInfo]
    public var items: [ReminderItem]
    public var syncedAt: Date?
    public static let empty = RemindersSnapshot(lists: [], items: [], syncedAt: nil)
    public init(lists: [ReminderListInfo], items: [ReminderItem], syncedAt: Date?) {
        self.lists = lists; self.items = items; self.syncedAt = syncedAt
    }
    public func list(_ id: String) -> ReminderListInfo? { lists.first { $0.id == id } }
}

public enum RemindersSyncState: Equatable, Sendable {
    case notSynced
    case notAuthorized(RemindersAccess)
    case synced
    /// The last read failed; `snapshot` still holds the previous successful read.
    case failed(String)
}

public struct RemindersSyncReport: Equatable, Sendable {
    public var listCount = 0
    public var itemCount = 0
    public var duplicatesCollapsed = 0
    public var removedItems = 0
    public var removedLists = 0
    public var recurringCount = 0
}

@MainActor public final class RemindersSyncService {
    private let client: any RemindersClient
    private let now: () -> Date
    private var observation: (any AppleCalendarChangeObservation)?
    private var periodicTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isSyncing = false
    public private(set) var snapshot = RemindersSnapshot.empty
    public private(set) var state = RemindersSyncState.notSynced
    public private(set) var lastReport: RemindersSyncReport?
    /// Invoked after every state or snapshot change so a view model can publish it.
    public var onUpdate: (@MainActor () -> Void)?
    public var access: RemindersAccess { client.access }

    public init(client: any RemindersClient, now: @escaping () -> Date = Date.init) {
        self.client = client; self.now = now
    }

    /// The only place a permission prompt can originate, and only from an explicit user action.
    public func requestAccess() async throws {
        do { try await client.requestAccess() } catch { throw RemindersError.permission }
        guard client.access == .fullAccess else { throw RemindersError.permission }
    }

    /// Never prompts. Returns nil when skipped, unauthorized, failed, or already running.
    @discardableResult
    public func syncIfAuthorized() async -> RemindersSyncReport? {
        guard !isSyncing else { return nil }
        guard client.access == .fullAccess else { revoke(); return nil }
        isSyncing = true; defer { isSyncing = false }
        do {
            let lists = try client.lists()
            let listIDs = Set(lists.map(\.id))
            let fetched = try await client.reminders(in: lists.map(\.id))
            // Access can be withdrawn while a read is in flight; discard that result.
            guard client.access == .fullAccess else { revoke(); return nil }
            var report = RemindersSyncReport()
            var unique: [String: ReminderItem] = [:]
            for item in fetched where listIDs.contains(item.listID) { // reminders of a vanished list are dropped
                if let existing = unique[item.deduplicationKey] {
                    report.duplicatesCollapsed += 1
                    if Self.isPreferred(item, over: existing) { unique[item.deduplicationKey] = item }
                } else { unique[item.deduplicationKey] = item }
            }
            let items = unique.values.sorted { $0.id < $1.id }
            let previousIDs = Set(snapshot.items.map(\.id)), currentIDs = Set(items.map(\.id))
            report.removedItems = previousIDs.subtracting(currentIDs).count
            report.removedLists = Set(snapshot.lists.map(\.id)).subtracting(listIDs).count
            report.listCount = lists.count; report.itemCount = items.count
            report.recurringCount = items.filter(\.isRecurring).count
            snapshot = RemindersSnapshot(lists: lists, items: items, syncedAt: now())
            state = .synced; lastReport = report
            installObservationIfNeeded()
            onUpdate?()
            return report
        } catch {
            // Keep the last good snapshot visible but flagged; never invent or clear data on a transient failure.
            let description = (error as? RemindersError)?.localizedDescription ?? RemindersError.unavailable.localizedDescription
            state = .failed(description)
            if client.access != .fullAccess { revoke() } else { onUpdate?() }
            return nil
        }
    }

    /// Syncs immediately, then on EventKit change notifications (coalesced) and every `interval`.
    public func startMonitoring(interval: Duration = .seconds(300), debounce: Duration = .seconds(1)) {
        stopMonitoring()
        self.debounce = debounce
        periodicTask = Task { [weak self] in
            await self?.syncIfAuthorized()
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.syncIfAuthorized()
            }
        }
    }

    public func stopMonitoring() {
        periodicTask?.cancel(); periodicTask = nil
        debounceTask?.cancel(); debounceTask = nil
        observation?.cancel(); observation = nil
    }

    private var debounce: Duration = .seconds(1)

    private func installObservationIfNeeded() {
        guard observation == nil, periodicTask != nil else { return }
        observation = client.observeChanges { [weak self] in self?.scheduleCoalescedSync() }
    }

    private func scheduleCoalescedSync() {
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.syncIfAuthorized()
        }
    }

    /// Permission revoked or never granted: drop all reminder content from memory.
    private func revoke() {
        snapshot = .empty
        state = .notAuthorized(client.access)
        lastReport = nil
        observation?.cancel(); observation = nil
        onUpdate?()
    }

    private static func isPreferred(_ candidate: ReminderItem, over existing: ReminderItem) -> Bool {
        switch (candidate.lastModified, existing.lastModified) {
        case let (a?, b?) where a != b: return a > b
        case (_?, nil): return true
        case (nil, _?): return false
        default: return candidate.id < existing.id // deterministic tie-break
        }
    }
}

// MARK: - Presentation

public struct ReminderNode: Identifiable, Equatable, Sendable {
    public let item: ReminderItem
    public let children: [ReminderNode]
    public var id: String { item.id }
}

/// A due-date marker for Day/Week/Month. It is not an event: it has no duration and is never
/// passed to the Timeline projection, the scheduler, or busy-time checks.
public struct ReminderDueMarker: Identifiable, Equatable, Sendable {
    public let id: String
    public let reminderID: String
    public let title: String
    public let date: Date
    public let hasTime: Bool
    public let listTitle: String
    public let priority: ReminderPriority
    public let isCompleted: Bool
}

public enum RemindersPresentation {
    public static let upcomingHorizonDays = 14

    /// Incomplete, dated reminders: overdue first, then those due within the horizon.
    public static func upcoming(_ items: [ReminderItem], now: Date, horizonDays: Int = upcomingHorizonDays,
                                calendar: Calendar = .current) -> (overdue: [ReminderItem], upcoming: [ReminderItem]) {
        let horizon = calendar.date(byAdding: .day, value: horizonDays, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(Double(horizonDays) * 86400)
        let open = items.filter { !$0.isCompleted && $0.due != nil }.sorted(by: dueOrder)
        let overdue = open.filter { isOverdue($0, now: now, calendar: calendar) }
        let upcoming = open.filter { !isOverdue($0, now: now, calendar: calendar) && $0.due!.date < horizon }
        return (overdue, upcoming)
    }

    /// A date-only reminder is overdue only after its day has ended.
    public static func isOverdue(_ item: ReminderItem, now: Date, calendar: Calendar = .current) -> Bool {
        guard !item.isCompleted, let due = item.due else { return false }
        if due.hasTime { return due.date < now }
        return calendar.startOfDay(for: due.date) < calendar.startOfDay(for: now)
    }

    /// Top-level reminders with subtasks nested when a parent is present in the same list.
    /// A missing parent makes the child top-level instead of hiding it.
    public static func tree(_ items: [ReminderItem], listID: String? = nil) -> [ReminderNode] {
        let scoped = items.filter { listID == nil || $0.listID == listID }
        let ids = Set(scoped.map(\.id))
        let byParent = Dictionary(grouping: scoped.filter { $0.parentID != nil && ids.contains($0.parentID!) && $0.parentID != $0.id },
                                  by: { $0.parentID! })
        var visited = Set<String>()
        func node(_ item: ReminderItem) -> ReminderNode {
            visited.insert(item.id)
            let children = (byParent[item.id] ?? []).filter { !visited.contains($0.id) }.sorted(by: listOrder).map(node)
            return ReminderNode(item: item, children: children)
        }
        let roots = scoped.filter { $0.parentID == nil || !ids.contains($0.parentID!) || $0.parentID == $0.id }.sorted(by: listOrder)
        var result = roots.map(node)
        // Parent cycles have no root; surface the unvisited members rather than losing them.
        for item in scoped.sorted(by: listOrder) where !visited.contains(item.id) { result.append(node(item)) }
        return result
    }

    public static func markers(items: [ReminderItem], lists: [ReminderListInfo], in interval: DateInterval) -> [ReminderDueMarker] {
        let titles = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.title) })
        return items.compactMap { item -> ReminderDueMarker? in
            guard let due = item.due, due.date >= interval.start, due.date < interval.end else { return nil }
            return ReminderDueMarker(id: "reminder-due:\(item.id)", reminderID: item.id, title: item.displayTitle,
                date: due.date, hasTime: due.hasTime, listTitle: titles[item.listID] ?? "Reminders",
                priority: item.priority, isCompleted: item.isCompleted)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }

    public static func markers(_ markers: [ReminderDueMarker], on day: Date, calendar: Calendar = .current) -> [ReminderDueMarker] {
        markers.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    public static func dueDescription(_ item: ReminderItem, now: Date, calendar: Calendar = .current) -> String {
        guard let due = item.due else { return "No due date" }
        let text = due.hasTime ? due.date.formatted(date: .abbreviated, time: .shortened)
                               : due.date.formatted(date: .abbreviated, time: .omitted)
        return isOverdue(item, now: now, calendar: calendar) ? "Overdue · \(text)" : "Due \(text)"
    }

    public static func openCount(_ items: [ReminderItem], listID: String? = nil) -> Int {
        items.filter { !$0.isCompleted && (listID == nil || $0.listID == listID) }.count
    }

    private static func dueOrder(_ a: ReminderItem, _ b: ReminderItem) -> Bool {
        let (x, y) = (a.due!.date, b.due!.date)
        return x == y ? (a.priority == b.priority ? a.id < b.id : a.priority < b.priority) : x < y
    }

    /// Open items first, then due date (undated last), priority, title.
    private static func listOrder(_ a: ReminderItem, _ b: ReminderItem) -> Bool {
        if a.isCompleted != b.isCompleted { return !a.isCompleted }
        switch (a.due?.date, b.due?.date) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        if a.priority != b.priority { return a.priority < b.priority }
        return a.title == b.title ? a.id < b.id : a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}
