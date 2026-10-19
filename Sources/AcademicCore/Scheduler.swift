import Foundation

public struct StudyTask: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let estimatedMinutes: Int
    public let dueAt: Date
    public let priority: Int
    public let sourceRecordIDs: [String]

    public init(id: String, title: String, estimatedMinutes: Int, dueAt: Date, priority: Int = 0, sourceRecordIDs: [String] = []) {
        self.id = id; self.title = title; self.estimatedMinutes = max(0, estimatedMinutes)
        self.dueAt = dueAt; self.priority = priority; self.sourceRecordIDs = sourceRecordIDs
    }
}

public struct ScheduledStudyBlock: Equatable, Sendable, Identifiable {
    public let id: String
    public let taskID: String
    public let title: String
    public let startAt: Date
    public let endAt: Date
    public let sourceRecordIDs: [String]

    public var durationMinutes: Int { Int(endAt.timeIntervalSince(startAt) / 60) }
}

public struct UnallocatedStudyWork: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let minutes: Int
    public let dueAt: Date
}

public struct ScheduleResult: Equatable, Sendable {
    public let blocks: [ScheduledStudyBlock]
    public let unallocated: [UnallocatedStudyWork]
}

public struct AssignmentEffortEstimate: Equatable, Sendable, Identifiable {
    public let id: String
    public var estimatedMinutes: Int
    public var priority: Int
    public var confidence: Double
    public let sourceRecordIDs: [String]

    public init(id: String, estimatedMinutes: Int, priority: Int = 0, confidence: Double = 1, sourceRecordIDs: [String] = []) {
        self.id = id; self.estimatedMinutes = min(max(30, estimatedMinutes), 7 * 24 * 60)
        self.priority = min(max(0, priority), 5); self.confidence = min(max(0, confidence), 1)
        self.sourceRecordIDs = sourceRecordIDs
    }
}

/// Deterministic, editable work stages. It uses no assignment content or AI inference.
public enum StudyTaskBreakdown {
    public static func propose(for title: String, estimate: AssignmentEffortEstimate, dueAt: Date) -> [StudyTask] {
        let total = estimate.estimatedMinutes
        let first = max(5, total / 5)
        let middle = max(5, total * 3 / 5)
        let final = total - first - middle
        let stages: [(String, Int)] = [
            ("Review requirements", first),
            ("Work on assignment", middle),
            ("Review and prepare submission", final)
        ]
        return stages.enumerated().map { index, stage in
            StudyTask(id: "\(estimate.id)-stage-\(index + 1)", title: "\(stage.0): \(title)", estimatedMinutes: stage.1, dueAt: dueAt, priority: estimate.priority, sourceRecordIDs: estimate.sourceRecordIDs)
        }
    }
}

/// Builds local-calendar availability and subtracts protected rest, including rest periods crossing midnight.
public enum AvailabilityWindowBuilder {
    public static func windows(from startDate: Date, dayCount: Int, settings: AvailabilitySettings) -> [DateInterval] {
        guard dayCount > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: settings.timeZoneIdentifier) ?? .current
        let firstDay = calendar.startOfDay(for: startDate)
        var output: [DateInterval] = []
        for offset in 0..<dayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let start = calendar.date(bySettingHour: settings.studyStartHour, minute: 0, second: 0, of: day),
                  var end = calendar.date(bySettingHour: settings.studyEndHour, minute: 0, second: 0, of: day) else { continue }
            if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
            let usableStart = max(start, startDate)
            guard end > usableStart else { continue }
            let studyWindow = DateInterval(start: usableStart, end: end)
            var rests: [DateInterval] = []
            for restOffset in -1...0 {
                guard let restDay = calendar.date(byAdding: .day, value: offset + restOffset, to: firstDay),
                      let restStart = calendar.date(bySettingHour: settings.protectedRestStartHour, minute: 0, second: 0, of: restDay),
                      var restEnd = calendar.date(bySettingHour: settings.protectedRestEndHour, minute: 0, second: 0, of: restDay) else { continue }
                if restEnd <= restStart { restEnd = calendar.date(byAdding: .day, value: 1, to: restEnd) ?? restEnd }
                let clippedStart = max(restStart, studyWindow.start)
                let clippedEnd = min(restEnd, studyWindow.end)
                if clippedEnd > clippedStart { rests.append(DateInterval(start: clippedStart, end: clippedEnd)) }
            }
            var segments = [studyWindow]
            for rest in rests.sorted(by: { $0.start < $1.start }) {
                segments = segments.flatMap { segment -> [DateInterval] in
                    guard rest.start < segment.end && rest.end > segment.start else { return [segment] }
                    var remaining: [DateInterval] = []
                    if rest.start > segment.start { remaining.append(DateInterval(start: segment.start, end: rest.start)) }
                    if rest.end < segment.end { remaining.append(DateInterval(start: rest.end, end: segment.end)) }
                    return remaining
                }
            }
            output.append(contentsOf: segments.filter { $0.duration > 0 })
        }
        return output
    }
}

/// Deterministic scheduling over concrete local-availability windows. It never edits a calendar.
public enum StudyScheduler {
    public static func makePlan(
        tasks: [StudyTask],
        availableWindows: [DateInterval],
        fixedEvents: [DateInterval],
        sessionMinutes: Int = 60,
        breakMinutes: Int = 10
    ) -> ScheduleResult {
        guard sessionMinutes > 0 else {
            return ScheduleResult(blocks: [], unallocated: tasks.filter { $0.estimatedMinutes > 0 }.map {
                UnallocatedStudyWork(id: $0.id, title: $0.title, minutes: $0.estimatedMinutes, dueAt: $0.dueAt)
            })
        }

        let sortedTasks = tasks.sorted {
            if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.id < $1.id
        }
        var blocks: [ScheduledStudyBlock] = []
        var unallocated: [UnallocatedStudyWork] = []

        for task in sortedTasks where task.estimatedMinutes > 0 {
            var remaining = task.estimatedMinutes
            while remaining > 0 {
                let requested = min(remaining, sessionMinutes)
                let requiredBreak = TimeInterval(max(0, breakMinutes) * 60)
                let occupied = fixedEvents + blocks.map { DateInterval(start: $0.startAt, end: $0.endAt.addingTimeInterval(requiredBreak)) }
                guard let start = firstFreeStart(duration: requested, dueAt: task.dueAt, windows: availableWindows, occupied: occupied) else {
                    unallocated.append(UnallocatedStudyWork(id: task.id, title: task.title, minutes: remaining, dueAt: task.dueAt))
                    break
                }
                let end = start.addingTimeInterval(TimeInterval(requested * 60))
                blocks.append(ScheduledStudyBlock(id: "\(task.id)-\(Int(start.timeIntervalSince1970))", taskID: task.id, title: task.title, startAt: start, endAt: end, sourceRecordIDs: task.sourceRecordIDs))
                remaining -= requested
            }
        }
        return ScheduleResult(blocks: blocks.sorted { $0.startAt < $1.startAt }, unallocated: unallocated)
    }

    private static func firstFreeStart(duration: Int, dueAt: Date, windows: [DateInterval], occupied: [DateInterval]) -> Date? {
        let required = TimeInterval(duration * 60)
        for window in windows.sorted(by: { $0.start < $1.start }) {
            let upperBound = min(window.end, dueAt)
            guard upperBound.timeIntervalSince(window.start) >= required else { continue }
            var candidate = window.start
            let overlaps = occupied.filter { $0.start < upperBound && $0.end > candidate }.sorted { $0.start < $1.start }
            for interval in overlaps {
                if interval.start.timeIntervalSince(candidate) >= required { return candidate }
                if interval.end > candidate { candidate = interval.end }
                if upperBound.timeIntervalSince(candidate) < required { break }
            }
            if upperBound.timeIntervalSince(candidate) >= required { return candidate }
        }
        return nil
    }
}
