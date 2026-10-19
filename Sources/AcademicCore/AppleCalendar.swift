import Foundation

public enum CalendarAccess: String, Sendable { case notDetermined, fullAccess, denied, restricted, writeOnly }

public enum AppleCalendarError: Error, LocalizedError, Equatable {
    case permission, unavailable, storage, invalidPlan, conflict, stalePreview, ownership, uncertainWrite, demo
    public var errorDescription: String? {
        switch self {
        case .permission: "Calendar full access is required. Use Connections to request access, or review Calendar access in System Settings."
        case .unavailable: "Calendar is unavailable or read-only. Check the account in Apple Calendar, then refresh. No automatic retry was made."
        case .storage: "Calendar ownership storage is unavailable. Writes are disabled to protect existing events."
        case .invalidPlan: "The plan contains invalid, overlapping, expired, or unsupported study sessions. Generate a new proposal."
        case .conflict: "A calendar commitment overlaps this proposal. Refresh busy times and generate a new plan."
        case .stalePreview: "The calendar or proposal changed. Review a fresh preview before approving."
        case .ownership: "A managed event was changed, moved, duplicated, or removed outside this app. It has been preserved; resolve it in Apple Calendar before retrying."
        case .uncertainWrite: "A calendar write could not be confirmed. Use Recover pending write before publishing again. If it remains unresolved, inspect Apple Calendar; do not delete the ownership file or retry blindly."
        case .demo: "Demonstration plans cannot be published to Apple Calendar."
        }
    }
}

public struct AppleCalendarSource: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// Personal-event snapshots stay in memory. Only app-owned snapshots are persisted.
public struct AppleCalendarEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var calendarID: String
    public var marker: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZone: String
    public var isBusy: Bool
    public var isSafeToModify: Bool
    public init(id: String, calendarID: String, marker: String?, title: String, start: Date, end: Date,
                timeZone: String, isBusy: Bool = true, isSafeToModify: Bool = true) {
        self.id = id; self.calendarID = calendarID; self.marker = marker; self.title = title
        self.start = start; self.end = end; self.timeZone = timeZone; self.isBusy = isBusy
        self.isSafeToModify = isSafeToModify
    }
    func sameContent(as other: Self) -> Bool {
        var lhs = self; var rhs = other; lhs.id = ""; rhs.id = ""; return lhs == rhs
    }
}

/// All calls are isolated to the main actor; test doubles never construct EKEventStore.
@MainActor public protocol AppleCalendarClient: AnyObject {
    var access: CalendarAccess { get }
    func requestAccess() async throws
    func sources() throws -> [AppleCalendarSource]
    func createCalendar(sourceID: String) throws -> String
    func validateCalendar(id: String) throws
    func events(in interval: DateInterval) throws -> [AppleCalendarEvent]
    func event(id: String) throws -> AppleCalendarEvent?
    func apply(before: AppleCalendarEvent?, after: AppleCalendarEvent?) throws -> AppleCalendarEvent?
}

public struct CalendarChange: Codable, Equatable, Sendable, Identifiable {
    public let key: String
    public let before: AppleCalendarEvent?
    public let after: AppleCalendarEvent?
    public var id: String { key }
    public var label: String { before == nil ? "Create" : after == nil ? "Cancel" : "Update" }
}

public struct CalendarPreview: Equatable, Sendable {
    public let id: UUID
    public let changes: [CalendarChange]
    public let createdAt: Date
    public let expiresAt: Date
}

public struct CalendarAuditEntry: Codable, Sendable {
    public let date: Date
    public let key: String
    public let action: String
}

public struct CalendarJournal: Codable, Sendable {
    public var calendarID: String?
    public var records: [String: AppleCalendarEvent] = [:]
    public var pending: CalendarChange?
    public var pendingIsUndo = false
    public var undoHistory: [CalendarChange] = []
    public var audit: [CalendarAuditEntry] = []
    public init() {}
}

@MainActor public protocol CalendarJournalStore {
    func load() throws -> CalendarJournal
    func save(_ journal: CalendarJournal) throws
}

/// Independent storage avoids schema/merge coupling with the Outlook integration.
@MainActor public final class FileCalendarJournalStore: CalendarJournalStore {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> CalendarJournal {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return CalendarJournal() }
            return try JSONDecoder().decode(CalendarJournal.self, from: Data(contentsOf: url))
        } catch { throw AppleCalendarError.storage }
    }
    public func save(_ journal: CalendarJournal) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(journal).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw AppleCalendarError.storage }
    }
}

@MainActor public final class AppleCalendarService {
    private let client: any AppleCalendarClient
    private let storage: any CalendarJournalStore
    private let now: () -> Date
    private var journal: CalendarJournal
    private var activePreview: CalendarPreview?
    private var previewIsUndo = false
    public var access: CalendarAccess { client.access }
    public var calendarID: String? { journal.calendarID }
    public var managedEvents: [AppleCalendarEvent] { journal.records.values.sorted { $0.start < $1.start } }
    public var hasPendingWrite: Bool { journal.pending != nil }
    public var canUndo: Bool { !journal.undoHistory.isEmpty && journal.pending == nil }

    public init(client: any AppleCalendarClient, storage: any CalendarJournalStore, now: @escaping () -> Date = Date.init) throws {
        self.client = client; self.storage = storage; self.now = now
        journal = try storage.load()
    }
    public func requestAccess() async throws { activePreview = nil; try await client.requestAccess(); try requireAccess() }
    public func sources() throws -> [AppleCalendarSource] { try requireAccess(); return try client.sources() }
    public func createCalendar(sourceID: String, approved: Bool) throws {
        guard approved else { throw AppleCalendarError.stalePreview }
        try requireAccess()
        if let id = journal.calendarID { try client.validateCalendar(id: id); return }
        let id = try client.createCalendar(sourceID: sourceID)
        var next = journal; next.calendarID = id
        try persist(next) // If storage fails, the adapter refuses to adopt a same-name calendar on retry.
    }
    public func busyIntervals(in interval: DateInterval) throws -> [DateInterval] {
        try requireAccess(); try validate(interval)
        return try client.events(in: interval).filter { $0.isBusy && $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
    }

    /// Identity is task + session ordinal, independent of the scheduler's timestamp-based IDs.
    public func preview(blocks: [ScheduledStudyBlock], timeZone: String, mode: StudyDataMode,
                        expiresAt: Date, cancelKeys: Set<String> = []) throws -> CalendarPreview {
        invalidatePreview()
        guard mode == .live else { throw AppleCalendarError.demo }
        try ready()
        guard TimeZone(identifier: timeZone) != nil, expiresAt > now(), blocks.count <= 500 else { throw AppleCalendarError.invalidPlan }
        var changes: [CalendarChange] = []; var ordinals: [String: Int] = [:]
        for block in blocks.sorted(by: { $0.startAt == $1.startAt ? $0.id < $1.id : $0.startAt < $1.startAt }) {
            let ordinal = ordinals[block.taskID, default: 0]; ordinals[block.taskID] = ordinal + 1
            let key = "\(block.taskID.utf8.count):\(block.taskID):\(ordinal)"
            guard !cancelKeys.contains(key), !block.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !block.sourceRecordIDs.isEmpty, block.startAt > now(), block.endAt > block.startAt,
                  block.startAt.timeIntervalSince(now()) < 366 * 86400,
                  block.endAt.timeIntervalSince(block.startAt) <= 86400 else { throw AppleCalendarError.invalidPlan }
            let before = try ownedEvent(key: key)
            let after = AppleCalendarEvent(id: before?.id ?? "", calendarID: journal.calendarID!,
                marker: before?.marker ?? UUID().uuidString, title: block.title, start: block.startAt,
                end: block.endAt, timeZone: timeZone)
            if before?.sameContent(as: after) != true { changes.append(CalendarChange(key: key, before: before, after: after)) }
        }
        for key in cancelKeys.sorted() {
            guard let before = try ownedEvent(key: key) else { throw AppleCalendarError.ownership }
            changes.append(CalendarChange(key: key, before: before, after: nil))
        }
        try checkConflicts(changes)
        let preview = CalendarPreview(id: UUID(), changes: changes, createdAt: now(), expiresAt: min(expiresAt, now().addingTimeInterval(300)))
        activePreview = preview; return preview
    }
    public func managedKeys() -> [String] { journal.records.keys.sorted() }
    public func event(for key: String) -> AppleCalendarEvent? { journal.records[key] }
    public func invalidatePreview() { activePreview = nil; previewIsUndo = false }

    /// Undo is another exact preview and explicit approval, never an automatic rollback.
    public func previewUndo() throws -> CalendarPreview {
        invalidatePreview(); try ready()
        guard let previous = journal.undoHistory.last else { throw AppleCalendarError.invalidPlan }
        let current = try ownedEvent(key: previous.key)
        guard (current == nil) == (previous.after == nil) else { throw AppleCalendarError.ownership }
        if let current, let expected = previous.after, !current.sameContent(as: expected) { throw AppleCalendarError.ownership }
        var restored = previous.before
        if restored != nil {
            guard restored!.start > now() else { throw AppleCalendarError.invalidPlan }
            restored!.id = current?.id ?? ""
        }
        let change = CalendarChange(key: previous.key, before: current, after: restored)
        if current == nil, try locate(before: nil, after: restored) != nil { throw AppleCalendarError.ownership }
        try checkConflicts([change])
        let preview = CalendarPreview(id: UUID(), changes: [change], createdAt: now(), expiresAt: now().addingTimeInterval(300))
        activePreview = preview; previewIsUndo = true; return preview
    }

    /// Approval binds the complete, immutable preview. No background write path exists.
    public func approve(_ preview: CalendarPreview) throws {
        guard preview == activePreview, preview.expiresAt > now() else { throw AppleCalendarError.stalePreview }
        let isUndo = previewIsUndo
        invalidatePreview()
        try ready()
        for change in preview.changes {
            guard try ownedEvent(key: change.key) == change.before else { throw AppleCalendarError.stalePreview }
            if let after = change.after, after.start <= now() { throw AppleCalendarError.stalePreview }
        }
        try checkConflicts(preview.changes)
        // Each operation has a durable write intent. Partial batches are explicit and recoverable.
        for (index, change) in preview.changes.enumerated() {
            guard preview.expiresAt > now(), change.after.map({ $0.start > now() }) ?? true else { throw AppleCalendarError.stalePreview }
            try requireAccess()
            guard try ownedEvent(key: change.key) == change.before else { throw AppleCalendarError.stalePreview }
            if change.before == nil, try locate(before: nil, after: change.after) != nil { throw AppleCalendarError.ownership }
            try checkConflicts(Array(preview.changes[index...]))
            var next = journal; next.pending = change; next.pendingIsUndo = isUndo
            next.audit.append(CalendarAuditEntry(date: now(), key: change.key, action: "approved-\(change.label.lowercased())"))
            try persist(next)
            do {
                let saved = try client.apply(before: change.before, after: change.after)
                guard (saved == nil) == (change.after == nil) else { throw AppleCalendarError.uncertainWrite }
                if let saved, let intended = change.after, !saved.sameContent(as: intended) { throw AppleCalendarError.uncertainWrite }
                next = journal; next.pending = nil; next.records[change.key] = saved
                if isUndo { next.undoHistory.removeLast() }
                else { next.undoHistory.append(CalendarChange(key: change.key, before: change.before, after: saved)) }
                next.pendingIsUndo = false
                next.audit.append(CalendarAuditEntry(date: now(), key: change.key, action: "confirmed"))
                try persist(next)
            } catch { throw AppleCalendarError.uncertainWrite }
        }
    }

    /// Read-only reconciliation after an interrupted/failed write. Never retries a mutation.
    public func recoverPendingWrite() throws {
        activePreview = nil; try requireAccess()
        guard let pending = journal.pending else { return }
        let found = try locate(before: pending.before, after: pending.after)
        var next = journal
        var applied = false
        if let after = pending.after, let found, found.sameContent(as: after) {
            next.records[pending.key] = found; applied = true
        } else if let before = pending.before, let found, found.sameContent(as: before) {
            next.records[pending.key] = found
        } else if pending.after == nil && found == nil {
            next.records[pending.key] = nil; applied = true
        } else {
            // A missing create may merely be delayed sync. Do not create a duplicate.
            throw AppleCalendarError.uncertainWrite
        }
        if applied {
            if next.pendingIsUndo { guard !next.undoHistory.isEmpty else { throw AppleCalendarError.storage }; next.undoHistory.removeLast() }
            else { next.undoHistory.append(CalendarChange(key: pending.key, before: pending.before, after: found)) }
        }
        next.pendingIsUndo = false
        next.pending = nil; next.audit.append(CalendarAuditEntry(date: now(), key: pending.key, action: "reconciled"))
        try persist(next)
    }

    private func persist(_ next: CalendarJournal) throws { try storage.save(next); journal = next }
    private func requireAccess() throws { guard client.access == .fullAccess else { throw AppleCalendarError.permission } }
    private func ready() throws {
        try requireAccess()
        guard journal.pending == nil else { throw AppleCalendarError.uncertainWrite }
        guard let id = journal.calendarID else { throw AppleCalendarError.unavailable }
        try client.validateCalendar(id: id)
    }
    private func validate(_ interval: DateInterval) throws {
        guard interval.duration > 0, interval.duration <= 366 * 86400 else { throw AppleCalendarError.invalidPlan }
    }
    private func ownedEvent(key: String) throws -> AppleCalendarEvent? {
        guard let expected = journal.records[key] else { return nil }
        guard let actual = try locate(before: expected, after: nil), actual.sameContent(as: expected), actual.isSafeToModify else {
            throw AppleCalendarError.ownership
        }
        return actual
    }
    private func locate(before: AppleCalendarEvent?, after: AppleCalendarEvent?) throws -> AppleCalendarEvent? {
        guard let sample = before ?? after, let marker = sample.marker else { throw AppleCalendarError.ownership }
        var found: [String: AppleCalendarEvent] = [:]
        for snapshot in [before, after].compactMap({ $0 }) {
            if !snapshot.id.isEmpty, let direct = try client.event(id: snapshot.id) {
                guard direct.marker == marker, direct.calendarID == journal.calendarID else { throw AppleCalendarError.ownership }
                found[direct.id] = direct
            }
            let interval = DateInterval(start: snapshot.start.addingTimeInterval(-86400), end: snapshot.end.addingTimeInterval(86400))
            for event in try client.events(in: interval) where event.marker == marker {
                guard event.calendarID == journal.calendarID else { throw AppleCalendarError.ownership }
                found[event.id] = event
            }
        }
        guard found.count <= 1 else { throw AppleCalendarError.ownership }
        return found.values.first
    }
    private func checkConflicts(_ changes: [CalendarChange]) throws {
        let removedIDs = Set(changes.compactMap { $0.before?.id })
        let proposed = changes.compactMap(\.after)
        for (index, event) in proposed.enumerated() {
            let interval = DateInterval(start: event.start, end: event.end)
            try validate(interval)
            let existing = try client.events(in: interval)
            guard !existing.contains(where: { $0.isBusy && !removedIDs.contains($0.id) && $0.start < event.end && $0.end > event.start }),
                  !proposed.prefix(index).contains(where: { $0.start < event.end && $0.end > event.start }) else {
                throw AppleCalendarError.conflict
            }
        }
    }
}
