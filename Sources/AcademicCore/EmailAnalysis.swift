import Foundation

public struct EmailAnalysisInput: Sendable {
    public let accountID: String
    public let messageID: String
    public let sourceID: String
    public let subject: String
    public let text: String
    public let attachmentName: String?
    public let timeZoneIdentifier: String
}

public protocol EmailAnalysisProvider: Sendable {
    var transmitsOffDevice: Bool { get }
    func analyze(_ input: EmailAnalysisInput) async throws -> [EmailProposal]
}

/// Local deterministic extraction. Imported text is data; it cannot change rules or invoke tools.
public struct LocalEmailAnalysisProvider: EmailAnalysisProvider {
    public var transmitsOffDevice: Bool { false }
    public init() {}
    public func analyze(_ input: EmailAnalysisInput) async throws -> [EmailProposal] {
        let text = String(input.text.prefix(50_000))
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var result: [EmailProposal] = []
        for line in lines.prefix(500) {
            let context = (input.subject + " " + line).lowercased()
            guard let kind = Self.kind(context) else { continue }
            let date = Self.explicitDate(line, timeZone: input.timeZoneIdentifier) ?? Self.explicitDate(input.subject, timeZone: input.timeZoneIdentifier)
            // Without a date, retain one reviewable commitment rather than inventing a time.
            if date == nil && result.contains(where: { $0.date == nil && $0.kind == kind }) { continue }
            let evidence = String(line.prefix(1000))
            let title = String(input.subject.prefix(250))
            let identity = input.sourceID + ":" + (input.attachmentName ?? "body") + ":" + kind.rawValue + ":" + evidence
            result.append(EmailProposal(id: "outlook-review-" + outlookDigest(identity), accountID: input.accountID,
                messageID: input.messageID, sourceID: input.sourceID, title: title.isEmpty ? "Email commitment" : title,
                kind: kind, date: date, durationMinutes: kind == .deadline || kind == .task ? 0 : 60,
                confidence: date == nil ? 0.35 : 0.75, evidence: evidence, attachmentName: input.attachmentName,
                note: kind.advisory ? "Advisory only: approval records review; update any existing commitment separately."
                    : date == nil ? "Date or time is unclear. Set it before approving. Relative dates require your review."
                    : "Check the extracted date and default duration before approving."))
            if result.count >= 30 { break }
        }
        return result
    }
    private static func kind(_ value: String) -> EmailEventKind? {
        if value.contains("cancel") { return .cancellation }
        if value.contains("reschedul") || value.contains("postpon") || value.contains("moved to") { return .reschedule }
        if value.contains("deadline") || value.contains("due") || value.contains("submit") { return .deadline }
        if value.contains("tutorial") { return .tutorial }
        if value.contains("meeting") || value.contains("appointment") || value.contains("lecture") { return .meeting }
        if value.contains("task") || value.contains("commitment") || value.contains("please complete") { return .task }
        return nil
    }
    public static func explicitDate(_ text: String, timeZone: String) -> Date? {
        let patterns: [(String, [String])] = [
            (#"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\b"#, []),
            (#"\b\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}\b"#, ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm"]),
            (#"\b\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}\b"#, ["d/M/yyyy H:mm"]),
            (#"\b\d{1,2} [A-Za-z]+ \d{4}(?: at)? \d{1,2}:\d{2}\b"#, ["d MMMM yyyy 'at' H:mm", "d MMMM yyyy H:mm", "d MMM yyyy H:mm"])
        ]
        for (pattern, formats) in patterns {
            guard let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let value = String(text[match])
            if formats.isEmpty { return MicrosoftGraphClient.date(value) }
            for format in formats {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB")
                formatter.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(identifier: "Europe/London")!
                formatter.dateFormat = format; formatter.isLenient = false
                if let date = formatter.date(from: value) { return date }
            }
        }
        return nil
    }
    public static func plainText(_ body: String, isHTML: Bool) -> String {
        guard isHTML else { return String(body.prefix(50_000)) }
        var value = String(body.prefix(100_000))
        value = value.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)<(?:br\s*/?|/p|/div|/li)>"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\"")] { value = value.replacingOccurrences(of: entity, with: character) }
        return String(value.prefix(50_000))
    }
}

public enum EmailAnalysisValidator {
    public static func validate(_ proposals: [EmailProposal], input: EmailAnalysisInput) throws {
        guard proposals.count <= 30, Set(proposals.map(\.id)).count == proposals.count else { throw OutlookError.invalidResponse }
        for p in proposals {
            guard p.accountID == input.accountID, p.messageID == input.messageID, p.sourceID == input.sourceID,
                  p.confidence.isFinite, (0...1).contains(p.confidence), !p.title.isEmpty, p.title.count <= 250,
                  !p.evidence.isEmpty, p.evidence.count <= 1000, input.text.contains(p.evidence),
                  p.decision == .pending, !p.withdrawn, (0...1440).contains(p.durationMinutes) else { throw OutlookError.invalidResponse }
        }
    }
}
