import Foundation

public enum UnifiedTimelineSource: String, Equatable, Sendable {
    case canvas, outlook, demonstration, appleCalendar, managedCalendar, unknown

    public var label: String {
        switch self {
        case .canvas: "Oxford Canvas"
        case .outlook: "Approved Outlook event"
        case .demonstration: "Demonstration data"
        case .appleCalendar: "Apple Calendar"
        case .managedCalendar: "Academic AI Time Manager calendar"
        case .unknown: "Unknown source"
        }
    }
}

/// Display-only values for Day, Week, and Month. Apple Calendar values are transient and are
/// intentionally kept outside SQLite/source records.
public struct UnifiedTimelineEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let timeZone: String
    public let kind: AcademicItemKind
    public let verification: VerificationState
    public let source: UnifiedTimelineSource
    public let isProtected: Bool
    public let isAllDay: Bool
    public let sourceRecordIDs: [String]

    public init(id: String, title: String, start: Date, end: Date, timeZone: String,
                kind: AcademicItemKind, verification: VerificationState, source: UnifiedTimelineSource,
                isProtected: Bool, isAllDay: Bool = false, sourceRecordIDs: [String] = []) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.timeZone = timeZone
        self.kind = kind; self.verification = verification; self.source = source
        self.isProtected = isProtected; self.isAllDay = isAllDay; self.sourceRecordIDs = sourceRecordIDs
    }

    /// Deadline instants need a non-empty interval when they are placed in a date range.
    public var displayEnd: Date { end > start ? end : start.addingTimeInterval(1) }
}

public enum UnifiedTimeline {
    public static func events(academicItems: [AcademicItem], sources: [SourceRecord],
                              calendarEvents: [AppleCalendarTimelineEvent]) -> [UnifiedTimelineEvent] {
        let providers = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.provider) })
        let academic = academicItems.map { item in
            UnifiedTimelineEvent(id: "academic:\(item.id)", title: item.title, start: item.startsAt, end: item.endsAt,
                timeZone: item.timeZoneIdentifier, kind: item.kind, verification: item.verification,
                source: source(for: item, providers: providers), isProtected: item.isProtected,
                sourceRecordIDs: item.sourceRecordIDs)
        }
        let academicKeys = Set(academic.map { duplicateKey(title: $0.title, start: $0.start, end: $0.end) })
        let calendar = calendarEvents.compactMap { event -> UnifiedTimelineEvent? in
            // A busy personal Calendar event that exactly mirrors an imported event stays a single
            // Timeline row. Its transient title hash is used only for this in-memory comparison.
            if event.source == .personal,
               academicKeys.contains(duplicateKey(titleHash: event.titleHash, start: event.start, end: event.end)) {
                return nil
            }
            return UnifiedTimelineEvent(id: event.id, title: event.title, start: event.start, end: event.end,
                timeZone: event.timeZone, kind: event.source == .managed ? .studyBlock : .classSession,
                verification: .verified, source: event.source == .managed ? .managedCalendar : .appleCalendar,
                isProtected: true, isAllDay: event.isAllDay)
        }
        return (academic + calendar).sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
    }

    private static func source(for item: AcademicItem, providers: [String: String]) -> UnifiedTimelineSource {
        let values = item.sourceRecordIDs.compactMap { providers[$0] }
        if values.contains("Canvas") { return .canvas }
        if values.contains("Outlook") { return .outlook }
        if values.contains(where: { $0 == "Canvas (sample)" || $0 == "Outlook (sample)" }) { return .demonstration }
        return .unknown
    }

    private static func duplicateKey(title: String, start: Date, end: Date) -> String {
        duplicateKey(titleHash: normalized(title).hashValue, start: start, end: end)
    }

    private static func duplicateKey(titleHash: Int, start: Date, end: Date) -> String {
        "\(titleHash)|\(start.timeIntervalSinceReferenceDate)|\(end.timeIntervalSinceReferenceDate)"
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
