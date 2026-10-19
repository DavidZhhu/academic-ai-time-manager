import Foundation

public struct MicrosoftProfile: Decodable, Sendable {
    public let id: String
    public let displayName: String?
    public let mail: String?
    public let userPrincipalName: String?
}

struct GraphMessage: Decodable, Sendable {
    struct Body: Decodable, Sendable { let contentType: String; let content: String }
    struct Sender: Decodable, Sendable { struct Address: Decodable, Sendable { let address: String? }; let emailAddress: Address? }
    let id: String
    let subject: String?
    let body: Body?
    let from: Sender?
    let receivedDateTime: String?
    let lastModifiedDateTime: String?
    let webLink: String?
    let hasAttachments: Bool?
    let removed: [String: String]?
    enum CodingKeys: String, CodingKey { case id, subject, body, from, receivedDateTime, lastModifiedDateTime, webLink, hasAttachments; case removed = "@removed" }
}
struct GraphPage<T: Decodable>: Decodable {
    let value: [T]
    let next: String?
    let delta: String?
    enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink"; case delta = "@odata.deltaLink" }
}
struct GraphAttachment: Decodable {
    let id: String
    let name: String
    let contentType: String?
    let size: Int
    let type: String?
    let isInline: Bool?
    enum CodingKeys: String, CodingKey { case id, name, contentType, size, isInline; case type = "@odata.type" }
}

public struct MicrosoftGraphClient: Sendable {
    let transport: any CanvasTransport
    let token: @Sendable (Bool) async throws -> String
    let sleep: @Sendable (TimeInterval) async throws -> Void
    public init(transport: any CanvasTransport = MicrosoftHTTPTransport(), token: @escaping @Sendable (Bool) async throws -> String,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.transport = transport; self.token = token; self.sleep = sleep
    }
    public static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    public static func safeURL(_ string: String, path: String? = nil) throws -> URL {
        guard let url = URL(string: string), url.scheme == "https", url.host == "graph.microsoft.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil,
              (url.path == "/v1.0/me" || url.path.hasPrefix("/v1.0/me/")), path == nil || url.path == path else { throw OutlookError.unsafeLink }
        return url
    }
    static func component(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    func get(_ url: URL) async throws -> Data {
        _ = try Self.safeURL(url.absoluteString)
        var refreshed = false; var forceNextRefresh = false; var attempts = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url); request.httpMethod = "GET"
            request.setValue("Bearer \(try await token(forceNextRefresh))", forHTTPHeaderField: "Authorization")
            forceNextRefresh = false
            request.setValue("IdType=\"ImmutableId\", outlook.body-content-type=\"text\", odata.maxpagesize=50", forHTTPHeaderField: "Prefer")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            let data: Data; let response: HTTPURLResponse
            do { (data, response) = try await transport.send(request) }
            catch is CancellationError { throw CancellationError() }
            catch let error as OutlookError { throw error }
            catch {
                guard attempts < 2 else { throw OutlookError.network }
                attempts += 1; try await sleep(TimeInterval(attempts)); continue
            }
            if response.statusCode == 401 {
                guard !refreshed else { throw OutlookError.reconnect }
                refreshed = true; forceNextRefresh = true; continue
            }
            if response.statusCode == 403 { throw OutlookError.permission }
            if response.statusCode == 429 || (500...599).contains(response.statusCode) {
                guard attempts < 2 else { throw OutlookError.http(response.statusCode) }
                attempts += 1
                let header = response.value(forHTTPHeaderField: "Retry-After")
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                let delay = header.flatMap(Double.init) ?? header.flatMap { formatter.date(from: $0)?.timeIntervalSinceNow } ?? TimeInterval(attempts * 2)
                // Never retry earlier than a long server-requested delay; let the next poll retry.
                guard delay <= 60 else { throw OutlookError.http(response.statusCode) }
                try await sleep(max(1, delay)); continue
            }
            guard response.statusCode == 200 else { throw OutlookError.http(response.statusCode) }
            guard data.count <= 8_000_000 else { throw OutlookError.limit }
            return data
        }
    }
    public func profile() async throws -> MicrosoftProfile {
        let data = try await get(Self.safeURL("https://graph.microsoft.com/v1.0/me?$select=id,displayName,mail,userPrincipalName"))
        guard let profile = try? JSONDecoder().decode(MicrosoftProfile.self, from: data), !profile.id.isEmpty else { throw OutlookError.invalidResponse }
        return profile
    }
    public func synchronize(account: OutlookAccount, previous: OutlookState, now: Date = Date(),
                            provider: any EmailAnalysisProvider = LocalEmailAnalysisProvider(),
                            extractor: any EmailAttachmentExtracting = SafeAttachmentExtractor()) async throws -> OutlookSyncBatch {
        guard !provider.transmitsOffDevice else { throw OutlookError.permission }
        // Check the credential's subject before importing into an account's namespace.
        guard try await profile().id == account.profileID else { throw OutlookError.reconnect }
        var initial = account
        if initial.deltaLink == nil { initial.initialSince = now.addingTimeInterval(-30 * 86400) }
        do { return try await readDelta(account: initial, previous: previous, now: now, provider: provider, extractor: extractor) }
        catch OutlookError.http(410) {
            var reset = account; reset.deltaLink = nil; reset.initialSince = now.addingTimeInterval(-30 * 86400)
            var batch = try await readDelta(account: reset, previous: previous, now: now, provider: provider, extractor: extractor)
            batch.notices.append("The mailbox checkpoint expired; refreshed the last 30 days without removing previously reviewed events.")
            return batch
        }
    }
    private func readDelta(account: OutlookAccount, previous: OutlookState, now: Date,
                           provider: any EmailAnalysisProvider, extractor: any EmailAttachmentExtracting) async throws -> OutlookSyncBatch {
        let path = "/v1.0/me/mailFolders/inbox/messages/delta"
        var components = URLComponents(string: "https://graph.microsoft.com" + path)!
        components.queryItems = [URLQueryItem(name: "$filter", value: "receivedDateTime ge " + ISO8601DateFormatter().string(from: account.initialSince)),
            URLQueryItem(name: "$select", value: "id,subject,body,from,receivedDateTime,lastModifiedDateTime,webLink,hasAttachments")]
        var url = try Self.safeURL(account.deltaLink ?? components.url!.absoluteString, path: path)
        var seen = Set<String>(); var messages: [String: GraphMessage] = [:]; var totalBytes = 0
        var checkpoint: String?
        for _ in 0..<200 {
            guard seen.insert(url.absoluteString).inserted else { throw OutlookError.limit }
            let data = try await get(url); totalBytes += data.count
            guard totalBytes <= 30_000_000 else { throw OutlookError.limit }
            guard let page = try? JSONDecoder().decode(GraphPage<GraphMessage>.self, from: data) else { throw OutlookError.invalidResponse }
            for message in page.value { messages[message.id] = message }
            guard messages.count < 5000 else { throw OutlookError.limit }
            if let next = page.next { url = try Self.safeURL(next, path: path) }
            else {
                guard let delta = page.delta else { throw OutlookError.invalidResponse }
                _ = try Self.safeURL(delta, path: path); checkpoint = delta; break
            }
        }
        guard let checkpoint else { throw OutlookError.limit }
        var batch = OutlookSyncBatch(account: account, proposals: [], sources: [], messages: [:], removedMessageIDs: [], notices: [])
        var attachmentBudget = 20_000_000
        for message in messages.values.sorted(by: { $0.id < $1.id }) {
            let sourceID = "outlook-" + outlookDigest(account.id + ":" + message.id)
            if message.removed != nil {
                batch.removedMessageIDs.insert(message.id)
                batch.messages[sourceID] = OutlookMessageRecord(accountID: account.id, messageID: message.id, revision: "removed", removed: true)
                continue
            }
            // A partial delta change is hydrated rather than erasing prior analysis.
            let complete: GraphMessage
            if message.subject == nil || message.receivedDateTime == nil || message.body == nil {
                let data = try await get(Self.safeURL("https://graph.microsoft.com/v1.0/me/messages/" + Self.component(message.id) + "?$select=id,subject,body,from,receivedDateTime,lastModifiedDateTime,webLink,hasAttachments"))
                guard let value = try? JSONDecoder().decode(GraphMessage.self, from: data) else { throw OutlookError.invalidResponse }
                complete = value
            } else { complete = message }
            guard complete.id == message.id, let received = complete.receivedDateTime.flatMap(Self.date), let body = complete.body else { throw OutlookError.invalidResponse }
            guard received >= account.initialSince else { continue }
            let subject = complete.subject ?? "Email commitment"
            let text = LocalEmailAnalysisProvider.plainText(body.content, isHTML: body.contentType.lowercased() == "html")
            let revision = outlookDigest(subject + text + String(complete.hasAttachments ?? false) + (complete.lastModifiedDateTime ?? "") + String(previous.settings.analyzeAttachments) + previous.settings.keywords + previous.settings.allowedSenders + previous.settings.timeZoneIdentifier)
            if previous.messages[sourceID]?.revision == revision { continue }
            batch.messages[sourceID] = OutlookMessageRecord(accountID: account.id, messageID: message.id, revision: revision)
            let sender = complete.from?.emailAddress?.address ?? ""
            guard previous.settings.isRelevant(subject: subject, text: text, sender: sender) else { continue }
            let webLink = complete.webLink.flatMap { URL(string: $0) }.flatMap { url -> String? in
                guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, ["outlook.office.com", "outlook.office365.com", "outlook.live.com"].contains(url.host ?? "") else { return nil }
                return url.absoluteString
            }
            batch.sources.append(SourceRecord(id: sourceID, provider: "Outlook", externalID: account.id + ":" + message.id,
                retrievedAt: now, sourceURI: webLink, displayTitle: account.address + " · " + subject))
            func analyze(_ text: String, attachment: String? = nil) async throws -> [EmailProposal] {
                let input = EmailAnalysisInput(accountID: account.id, messageID: message.id, sourceID: sourceID,
                    subject: subject, text: text, attachmentName: attachment, timeZoneIdentifier: previous.settings.timeZoneIdentifier)
                let proposals = try await provider.analyze(input)
                try EmailAnalysisValidator.validate(proposals, input: input)
                return proposals
            }
            batch.proposals += try await analyze(text.isEmpty ? subject : text)
            if complete.hasAttachments == true && previous.settings.analyzeAttachments {
                let path = "/v1.0/me/messages/" + Self.component(message.id) + "/attachments"
                var next: URL? = try Self.safeURL("https://graph.microsoft.com" + path + "?$select=id,name,contentType,size,isInline")
                var visited = Set<String>(); var processed = 0
                while let pageURL = next {
                    guard visited.count < 10, visited.insert(pageURL.absoluteString).inserted else { throw OutlookError.limit }
                    let data = try await get(pageURL)
                    guard let page = try? JSONDecoder().decode(GraphPage<GraphAttachment>.self, from: data) else { throw OutlookError.invalidResponse }
                    for attachment in page.value {
                        guard attachment.type == "#microsoft.graph.fileAttachment", attachment.isInline != true,
                              SafeAttachmentExtractor.supports(name: attachment.name, contentType: attachment.contentType ?? "", size: attachment.size),
                              processed < 3, attachment.size <= attachmentBudget else {
                            batch.notices.append("An attachment was skipped by type, safety, or size limits."); continue
                        }
                        processed += 1; attachmentBudget -= attachment.size
                        let raw = try await get(Self.safeURL("https://graph.microsoft.com" + path + "/" + Self.component(attachment.id) + "/$value"))
                        guard raw.count <= SafeAttachmentExtractor.maxBytes, raw.count <= attachment.size else { throw OutlookError.limit }
                        do {
                            let extracted = try extractor.extract(data: raw, name: attachment.name, contentType: attachment.contentType ?? "")
                            batch.proposals += try await analyze(extracted, attachment: attachment.name)
                        } catch OutlookError.attachment { batch.notices.append("An attachment could not be safely extracted; review it outside the planner if needed.") }
                    }
                    next = try page.next.map { try Self.safeURL($0, path: URL(string: "https://graph.microsoft.com" + path)!.path) }
                }
            }
        }
        batch.account.deltaLink = checkpoint; batch.account.lastSuccessfulSync = now
        batch.notices = Array(Set(batch.notices)).sorted()
        return batch
    }
}
