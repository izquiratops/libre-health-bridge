import Foundation

public enum CloudError: Error, LocalizedError, Equatable, Sendable {
    case network, invalidResponse, invalidCredentials, termsRequired, rateLimited
    case rateLimitedUntil(Date)
    case http(Int), api(Int), regionalRedirect, missingConnection, wrongPatient

    public var errorDescription: String? {
        switch self {
        case .network: "error.cloud.network"
        case .invalidResponse: "error.cloud.invalidResponse"
        case .invalidCredentials: "error.cloud.invalidCredentials"
        case .termsRequired: "error.cloud.termsRequired"
        case .rateLimited, .rateLimitedUntil: "error.cloud.rateLimited"
        case .http: "error.cloud.http"
        case .api: "error.cloud.api"
        case .regionalRedirect: "error.cloud.regionalRedirect"
        case .missingConnection: "error.cloud.missingConnection"
        case .wrongPatient: "error.cloud.wrongPatient"
        }
    }
}

public struct HTTPResult: Sendable {
    public let status: Int
    public let data: Data
    public let retryAfter: Date?
    public init(status: Int, data: Data, retryAfter: Date? = nil) {
        self.status = status; self.data = data; self.retryAfter = retryAfter
    }
}

public protocol CloudTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor URLSessionTransport: CloudTransport {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
        let retryAfter: Date?
        if let header = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(header), seconds >= 0, seconds.isFinite {
                retryAfter = Date().addingTimeInterval(seconds)
            } else {
                let format = DateFormatter()
                format.locale = Locale(identifier: "en_US_POSIX")
                format.timeZone = TimeZone(secondsFromGMT: 0)
                format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                retryAfter = format.date(from: header)
            }
        } else { retryAfter = nil }
        return HTTPResult(status: response.statusCode, data: data, retryAfter: retryAfter)
    }
}

public actor LibreCloudClient {
    private let credentials: Credentials
    private let transport: any CloudTransport
    private var host = "api.libreview.io"
    private var token: String?
    private var accountID: String?

    public init(credentials: Credentials, transport: any CloudTransport = URLSessionTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    private struct Envelope<T: Decodable>: Decodable {
        let status: Int
        let data: T?
    }
    private struct Status: Decodable { let status: Int }
    private struct Login: Decodable {
        struct User: Decodable { let id: String }
        struct Ticket: Decodable { let token: String }
        let redirect: Bool?
        let region: String?
        let user: User?
        let authTicket: Ticket?
    }

    private func request<T: Decodable>(_ path: [String], body: Data? = nil,
                                       authenticated: Bool = false, as type: T.Type) async throws -> T {
        var url = URL(string: "https://\(host)")!
        for component in path { url.appendPathComponent(component) }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("llu.android", forHTTPHeaderField: "product")
        request.setValue("4.16.0", forHTTPHeaderField: "version")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated, let token, let accountID {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(accountID, forHTTPHeaderField: "account-id")
        }
        let response: HTTPResult
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { try Task.checkCancellation(); throw CloudError.network }
        try Task.checkCancellation()
        if response.status == 429 {
            if let until = response.retryAfter { throw CloudError.rateLimitedUntil(until) }
            throw CloudError.rateLimited
        }
        guard (200..<300).contains(response.status) else { throw CloudError.http(response.status) }
        // Decode status before payload: an error payload need not match the success schema.
        let status: Int
        do { status = try JSONDecoder().decode(Status.self, from: response.data).status }
        catch { throw CloudError.invalidResponse }
        switch status {
        case 0: break
        case 2: throw CloudError.invalidCredentials
        case 4: throw CloudError.termsRequired
        default: throw CloudError.api(status)
        }
        do {
            guard let data = try JSONDecoder().decode(Envelope<T>.self, from: response.data).data else {
                throw CloudError.invalidResponse
            }
            return data
        } catch { throw CloudError.invalidResponse }
    }

    public func login() async throws {
        token = nil
        accountID = nil
        var visited: Set<String> = []
        for _ in 0..<4 {
            guard visited.insert(host).inserted else { throw CloudError.regionalRedirect }
            let data = try await request(["llu", "auth", "login"],
                                         body: JSONEncoder().encode(credentials), as: Login.self)
            if data.redirect == true {
                guard let region = data.region,
                      region.range(of: #"^[a-z]{2,8}$"#, options: .regularExpression) != nil
                else { throw CloudError.regionalRedirect }
                host = "api-\(region).libreview.io"
                continue
            }
            guard let token = data.authTicket?.token, !token.isEmpty,
                  let userID = data.user?.id, !userID.isEmpty
            else { throw CloudError.invalidResponse }
            self.token = token
            accountID = sha256(userID)
            return
        }
        throw CloudError.regionalRedirect
    }

    private func get<T: Decodable>(_ path: [String], as type: T.Type) async throws -> T {
        if token == nil { try await login() }
        do { return try await request(path, authenticated: true, as: type) }
        catch CloudError.http(401) {
            try await login()
            return try await request(path, authenticated: true, as: type)
        }
    }

    public func connections() async throws -> [Connection] {
        let result = try await get(["llu", "connections"], as: [Connection].self)
        // IDs come from this endpoint and later become a single URL path component.
        guard result.allSatisfy({ !$0.patientId.isEmpty && $0.patientId.count <= 128 &&
            $0.patientId.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil }),
              Set(result.map(\.patientId)).count == result.count
        else { throw CloudError.invalidResponse }
        return result
    }

    public func snapshot(for connection: Connection, now: Date? = nil) async throws -> CloudSnapshot {
        let graph = try await get(["llu", "connections", connection.patientId, "graph"], as: Graph.self)
        if let id = graph.connection?.patientId, id != connection.patientId { throw CloudError.wrongPatient }
        let candidates = [connection.glucoseMeasurement, graph.connection?.glucoseMeasurement].compactMap { $0 }
        // Prefer the newer of the two latest-reading endpoints, not the list order.
        let latest = candidates.reduce(nil as RawMeasurement?) { previous, candidate in
            guard let previous else { return candidate }
            let previousDate = TimestampParser.parse(previous.factoryTimestamp) ?? .distantPast
            let candidateDate = TimestampParser.parse(candidate.factoryTimestamp) ?? .distantPast
            // The graph request happens later, so it wins equal-timestamp corrections.
            return candidateDate >= previousDate ? candidate : previous
        }
        let fetchedAt = now ?? Date()
        return CloudSnapshot(patientID: connection.patientId, fetchedAt: fetchedAt,
                             historyCount: graph.graphData.count,
                             preview: latest.map { MeasurementPreview(raw: $0, now: fetchedAt) },
                             batch: ReadingNormalizer.normalize(history: graph.graphData, latest: latest,
                                                                patientID: connection.patientId, now: fetchedAt))
    }
}
