import Foundation

public enum EmailReviewRules {
    public static func annotated(_ proposals: [EmailProposal], existing: [AcademicItem]) -> [EmailProposal] {
        var seen: [String: String] = [:]
        return proposals.sorted { $0.id < $1.id }.map { value in
            var p = value; p.duplicateOf = nil; p.conflictsWith = []
            guard !p.withdrawn else { return p }
            if let duplicate = seen[p.fingerprint] { p.duplicateOf = duplicate }
            else { seen[p.fingerprint] = p.id }
            if let date = p.date {
                let end = date.addingTimeInterval(TimeInterval(max(1, p.durationMinutes) * 60))
                p.conflictsWith = existing.filter {
                    ($0.title.lowercased() == p.title.lowercased() && $0.startsAt != date) ||
                    ($0.isProtected && $0.kind != .deadline && p.kind != .deadline && p.kind != .task && $0.startsAt < end && $0.endsAt > date && !$0.sourceRecordIDs.contains(p.sourceID))
                }.map(\.id)
                p.conflictsWith += proposals.filter {
                    guard $0.id != p.id, !$0.withdrawn else { return false }
                    if $0.title.lowercased() == p.title.lowercased() && ($0.date != p.date || $0.durationMinutes != p.durationMinutes) { return true }
                    guard let other = $0.date, $0.fingerprint != p.fingerprint,
                          ![EmailEventKind.deadline, .task, .cancellation, .reschedule].contains($0.kind),
                          ![EmailEventKind.deadline, .task, .cancellation, .reschedule].contains(p.kind) else { return false }
                    return other < end && other.addingTimeInterval(TimeInterval(max(1, $0.durationMinutes) * 60)) > date
                }.map(\.id)
            }
            return p
        }
    }
}
