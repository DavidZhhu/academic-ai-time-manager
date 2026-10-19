import Foundation

public protocol CanvasTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class CanvasRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionCanvasTransport: CanvasTransport {
    private static let session = URLSession(configuration: .ephemeral, delegate: CanvasRedirectBlocker(), delegateQueue: nil)
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CanvasImportError.invalidResponse }
        return (data, response)
    }
}

public struct CanvasCourse: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let timeZone: String?
    enum CodingKeys: String, CodingKey { case id, name, timeZone = "time_zone" }
    public init(id: Int, name: String, timeZone: String? = nil) { self.id = id; self.name = name; self.timeZone = timeZone }
}

public struct CanvasAssignment: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let dueAt: Date?
    public let htmlURL: URL?
    public let submission: CanvasSubmissionEvidence?

    enum CodingKeys: String, CodingKey { case id, name, dueAt = "due_at", htmlURL = "html_url", submission }

    public init(id: Int, name: String, dueAt: Date?, htmlURL: URL?, submission: CanvasSubmissionEvidence? = nil) {
        self.id = id; self.name = name; self.dueAt = dueAt; self.htmlURL = htmlURL; self.submission = submission
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        dueAt = try values.decodeIfPresent(Date.self, forKey: .dueAt)
        htmlURL = try values.decodeIfPresent(URL.self, forKey: .htmlURL)
        // Optional/unsupported evidence must never turn into an inferred completion or break the import.
        submission = try? values.decodeIfPresent(CanvasSubmissionEvidence.self, forKey: .submission)
    }
}

public struct CanvasCalendarEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let title: String
    public let startAt: Date
    public let endAt: Date?
    public let htmlURL: URL?
    public let contextName: String?
    public let contextCode: String?
    enum CodingKeys: String, CodingKey {
        case id, title, startAt = "start_at", endAt = "end_at", htmlURL = "html_url", contextName = "context_name", contextCode = "context_code"
    }
}

public enum CanvasImportError: Error, LocalizedError, Equatable {
    case invalidBaseURL
    case invalidResponse
    case unsafePaginationURL
    case httpStatus(Int)
    case paginationLimit
    case networkFailure

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Canvas base URL must use HTTPS and contain a host."
        case .invalidResponse: "Canvas returned an invalid response."
        case .unsafePaginationURL: "Canvas pagination link left the configured HTTPS origin."
        case .httpStatus(401): "Oxford Canvas rejected the saved token. Reconnect the account and test the connection."
        case .httpStatus(403): "Oxford Canvas denied access to this read-only data. Check the token permissions and course access."
        case .httpStatus(429): "Oxford Canvas is rate limiting requests. Wait a little and try syncing again."
        case .httpStatus(let code) where code >= 500: "Oxford Canvas is temporarily unavailable (HTTP \(code)). Try again later."
        case .httpStatus(let code): "Canvas could not return the requested data (HTTP \(code)). Check access and try again."
        case .paginationLimit: "Canvas pagination exceeded the safety limit."
        case .networkFailure: "Could not reach Oxford Canvas. Check your internet connection and try again."
        }
    }
}

public struct CanvasImportResult: Equatable, Sendable {
    public let sourceRecords: [SourceRecord]
    public let academicItems: [AcademicItem]
}

/// Read-only Canvas importer. It never persists or prints the supplied access token.
public struct CanvasImporter: Sendable {
    private let baseURL: URL
    private let accessToken: String
    private let transport: any CanvasTransport
    private let maxPages: Int
    private let maxAttempts: Int
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(baseURL: URL, accessToken: String, transport: any CanvasTransport = URLSessionCanvasTransport(), maxPages: Int = 100, maxAttempts: Int = 3, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil else { throw CanvasImportError.invalidBaseURL }
        self.baseURL = baseURL; self.accessToken = accessToken; self.transport = transport
        self.maxPages = max(1, maxPages); self.maxAttempts = max(1, maxAttempts); self.sleep = sleep
    }

    public func fetchAssignments(retrievedAt: Date = Date()) async throws -> CanvasImportResult {
        var courseComponents = URLComponents(url: baseURL.appendingPathComponent("api/v1/courses"), resolvingAgainstBaseURL: false)!
        courseComponents.queryItems = [URLQueryItem(name: "enrollment_state[]", value: "active"), URLQueryItem(name: "per_page", value: "100")]
        let coursesURL = courseComponents.url!
        let courses: [CanvasCourse] = try await fetchPages(startingAt: coursesURL)
        var records: [SourceRecord] = []
        var items: [AcademicItem] = []
        var seenRecords = Set<String>()
        for course in courses {
            let courseID = "canvas-course-\(course.id)"
            if seenRecords.insert(courseID).inserted {
                records.append(SourceRecord(id: courseID, provider: "Canvas", externalID: "course-\(course.id)", retrievedAt: retrievedAt, displayTitle: course.name))
            }
            var assignmentComponents = URLComponents(url: baseURL.appendingPathComponent("api/v1/courses/\(course.id)/assignments"), resolvingAgainstBaseURL: false)!
            assignmentComponents.queryItems = [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "include[]", value: "submission")]
            let assignmentsURL = assignmentComponents.url!
            let assignments: [CanvasAssignment] = try await fetchPages(startingAt: assignmentsURL)
            for assignment in assignments {
                let externalID = "course-\(course.id)-assignment-\(assignment.id)"
                let sourceID = "canvas-\(externalID)"
                if seenRecords.insert(sourceID).inserted {
                    records.append(SourceRecord(id: sourceID, provider: "Canvas", externalID: externalID, retrievedAt: retrievedAt,
                        sourceURI: assignment.htmlURL?.absoluteString, displayTitle: "\(course.name): \(assignment.name)",
                        assignmentDetails: ImportedAssignmentDetails(dueAt: assignment.dueAt, submission: assignment.submission)))
                }
                if let dueAt = assignment.dueAt {
                    items.append(AcademicItem(id: sourceID, title: "\(course.name): \(assignment.name)", startsAt: dueAt, endsAt: dueAt, timeZoneIdentifier: validTimeZone(course.timeZone), kind: .deadline, verification: .verified, sourceRecordIDs: [sourceID], isProtected: true))
                }
            }
        }
        let eventWindow = CalendarEventWindow(around: retrievedAt)
        for group in stride(from: 0, to: courses.count, by: 10) {
            let contexts = courses[group..<min(group + 10, courses.count)].map { "course_\($0.id)" }
            var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/calendar_events"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "type", value: "event"), URLQueryItem(name: "start_date", value: eventWindow.start),
                URLQueryItem(name: "end_date", value: eventWindow.end), URLQueryItem(name: "per_page", value: "100")
            ] + contexts.map { URLQueryItem(name: "context_codes[]", value: $0) }
            let events: [CanvasCalendarEvent] = try await fetchPages(startingAt: components.url!)
            for event in events {
                let externalID = "calendar-event-\(event.id)"
                let sourceID = "canvas-\(externalID)"
                if seenRecords.insert(sourceID).inserted {
                    records.append(SourceRecord(id: sourceID, provider: "Canvas", externalID: externalID, retrievedAt: retrievedAt, sourceURI: event.htmlURL?.absoluteString))
                    let courseName = event.contextName.map { "\($0): " } ?? ""
                    items.append(AcademicItem(id: sourceID, title: "\(courseName)\(event.title)", startsAt: event.startAt, endsAt: max(event.startAt, event.endAt ?? event.startAt), timeZoneIdentifier: eventTimeZone(courses: courses, contextCode: event.contextCode), kind: .classSession, verification: .verified, sourceRecordIDs: [sourceID], isProtected: true))
                }
            }
        }
        return CanvasImportResult(sourceRecords: records, academicItems: items)
    }

    private func validTimeZone(_ identifier: String?) -> String {
        guard let identifier, TimeZone(identifier: identifier) != nil else { return "UTC" }
        return identifier
    }

    private func eventTimeZone(courses: [CanvasCourse], contextCode: String?) -> String {
        if let contextCode, let id = Int(contextCode.split(separator: "_").last ?? ""), let zone = courses.first(where: { $0.id == id })?.timeZone {
            return validTimeZone(zone)
        }
        return "UTC"
    }

    private struct CalendarEventWindow {
        let start: String
        let end: String
        init(around date: Date) {
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
            start = formatter.string(from: date.addingTimeInterval(-30 * 24 * 60 * 60))
            end = formatter.string(from: date.addingTimeInterval(365 * 24 * 60 * 60))
        }
    }

    private func fetchPages<T: Decodable>(startingAt url: URL) async throws -> [T] {
        var next: URL? = url
        var pageCount = 0
        var values: [T] = []
        while let pageURL = next {
            guard pageCount < maxPages else { throw CanvasImportError.paginationLimit }
            guard sameOrigin(pageURL) else { throw CanvasImportError.unsafePaginationURL }
            pageCount += 1
            let (data, response) = try await request(pageURL)
            values.append(contentsOf: try Self.decoder.decode([T].self, from: data))
            next = Self.nextLink(response.value(forHTTPHeaderField: "Link"))
        }
        return values
    }

    private func request(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<maxAttempts {
            let (data, response): (Data, HTTPURLResponse)
            do { (data, response) = try await transport.send(request) }
            catch {
                if attempt + 1 < maxAttempts {
                    try await sleep(.seconds(1 << min(attempt, 5)))
                    continue
                }
                throw CanvasImportError.networkFailure
            }
            if (200..<300).contains(response.statusCode) { return (data, response) }
            if (response.statusCode == 429 || (500..<600).contains(response.statusCode)), attempt + 1 < maxAttempts {
                let exponent = min(attempt, 5)
                try await sleep(.seconds(1 << exponent))
                continue
            }
            throw CanvasImportError.httpStatus(response.statusCode)
        }
        throw CanvasImportError.invalidResponse
    }

    private func sameOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == baseURL.host?.lowercased() && url.port == baseURL.port
    }

    private static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let segment = part.trimmingCharacters(in: .whitespaces)
            guard segment.contains("rel=\"next\"") || segment.contains("rel=next"),
                  let open = segment.firstIndex(of: "<"), let close = segment[segment.index(after: open)...].firstIndex(of: ">") else { continue }
            return URL(string: String(segment[segment.index(after: open)..<close]))
        }
        return nil
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let value = try container.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try container.singleValueContainer(), debugDescription: "Invalid Canvas timestamp")
        }
        return decoder
    }
}
