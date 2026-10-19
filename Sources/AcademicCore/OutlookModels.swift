import Foundation
import CryptoKit

public enum OutlookError: Error, LocalizedError, Equatable {
    case configuration, cancelled, invalidCallback, reconnect, permission, network, invalidResponse, unsafeLink, limit, attachment, review
    case http(Int)
    public var errorDescription: String? {
        switch self {
        case .configuration: "Enter a valid Microsoft Entra application (client) ID and register the documented desktop redirect URI."
        case .cancelled: "Microsoft sign-in was cancelled."
        case .invalidCallback: "The Microsoft sign-in response could not be verified. Try connecting again."
        case .reconnect: "Microsoft sign-in has expired or been revoked. Add this account again to reconnect."
        case .permission: "Microsoft denied access. Check Mail.Read consent and your university's app policy."
        case .network: "Microsoft could not be reached. Check your connection and try again."
        case .invalidResponse: "Microsoft returned an incomplete or unsupported response. No sync checkpoint was advanced."
        case .unsafeLink: "A Microsoft response contained an unexpected URL. The request was stopped."
        case .limit: "A processing limit was reached. The sync was not committed; reduce the scope or try again later."
        case .attachment: "Attachment skipped: unsupported, encrypted, suspicious, unreadable, or over the processing limit."
        case .review: "Review needs a valid date and duration, or the source has changed. Refresh the selection and try again."
        case .http(429): "Microsoft is throttling requests. Try again later."
        case .http(let code): "Microsoft request failed (HTTP \(code)). Try again later."
        }
    }
}

public func outlookDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

public struct OutlookSettings: Codable, Sendable, Equatable {
    public var clientID = ""
    public var pollingEnabled = false
    public var pollingMinutes = 15
    public var analyzeAttachments = true
    public var keywords = "tutorial,lecture,meeting,appointment,deadline,due,submit,task,commitment,cancel,reschedule"
    /// Empty means all senders; otherwise exact email addresses or domains, separated by commas.
    public var allowedSenders = ""
    public var timeZoneIdentifier = "Europe/London"
    public init() {}
    public var pollInterval: TimeInterval { TimeInterval(min(1440, max(5, pollingMinutes)) * 60) }
    public func isRelevant(subject: String, text: String, sender: String) -> Bool {
        let allowed = allowedSenders.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let address = sender.lowercased()
        guard allowed.isEmpty || allowed.contains(where: { address == $0 || address.split(separator: "@").last.map(String.init) == $0 }) else { return false }
        let content = (subject + " " + text).lowercased()
        return keywords.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains { !$0.isEmpty && content.contains($0) }
    }
}

public struct OutlookAccount: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let profileID: String
    public let clientID: String
    public var label: String
    public var address: String
    public var connected = true
    public var deltaLink: String?
    public var initialSince: Date
    public var lastSuccessfulSync: Date?
    public init(profileID: String, clientID: String, label: String, address: String, now: Date = Date()) {
        self.id = outlookDigest(clientID.lowercased() + ":" + profileID)
        self.profileID = profileID; self.clientID = clientID.lowercased(); self.label = label; self.address = address
        initialSince = now.addingTimeInterval(-30 * 86400)
    }
    public func pollingDue(settings: OutlookSettings, now: Date) -> Bool {
        connected && settings.pollingEnabled && now.timeIntervalSince(lastSuccessfulSync ?? .distantPast) >= settings.pollInterval
    }
}

public enum EmailEventKind: String, Codable, CaseIterable, Sendable {
    case tutorial, meeting, deadline, task, cancellation, reschedule
    public var advisory: Bool { self == .cancellation || self == .reschedule }
}

public struct EmailProposal: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let accountID: String
    public let messageID: String
    public let sourceID: String
    public var title: String
    public var kind: EmailEventKind
    public var date: Date?
    public var durationMinutes: Int
    public var confidence: Double
    public var evidence: String
    public var attachmentName: String?
    public var decision: ReviewDecision = .pending
    public var withdrawn = false
    public var note: String?
    public var duplicateOf: String?
    public var conflictsWith: [String] = []
    public var fingerprint: String {
        outlookDigest(kind.rawValue + ":" + title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + ":" + String(date?.timeIntervalSince1970 ?? -1))
    }
    public var canApprove: Bool { !withdrawn && (kind.advisory || date != nil) && (0...1440).contains(durationMinutes) }
}

public struct OutlookMessageRecord: Codable, Sendable, Equatable {
    public let accountID: String
    public let messageID: String
    public let revision: String
    public var removed: Bool = false
}

public struct OutlookState: Codable, Sendable, Equatable {
    public var settings = OutlookSettings()
    public var accounts: [OutlookAccount] = []
    public var proposals: [EmailProposal] = []
    public var messages: [String: OutlookMessageRecord] = [:]
    public init() {}
}

public struct OutlookSyncBatch: Sendable {
    public var account: OutlookAccount
    public var proposals: [EmailProposal]
    public var sources: [SourceRecord]
    public var messages: [String: OutlookMessageRecord]
    public var removedMessageIDs: Set<String>
    public var notices: [String]
}

/// A future notification receiver can enqueue the same account-scoped sync as polling.
/// No webhook subscription or public endpoint is created by this implementation.
public enum OutlookSyncTrigger: Sendable { case manual, polling, changeNotification(accountID: String) }
