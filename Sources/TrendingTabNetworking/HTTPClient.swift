import Foundation
import TrendingTabCore

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var data: Data
    public var headers: [String: String]
    public var finalURL: URL

    public init(statusCode: Int, data: Data, headers: [String: String], finalURL: URL) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
        self.finalURL = finalURL
    }

    public var text: String { String(data: data, encoding: .utf8) ?? "" }
    public var etag: String? { headers.first { $0.key.lowercased() == "etag" }?.value }
    public var lastModified: String? { headers.first { $0.key.lowercased() == "last-modified" }?.value }
    public var retryAfter: TimeInterval? {
        headers.first { $0.key.lowercased() == "retry-after" }.flatMap { TimeInterval($0.value) }
    }
}

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public var includeConditionalHeaders: Bool

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 15, includeConditionalHeaders: Bool = true) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.includeConditionalHeaders = includeConditionalHeaders
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        request.headers.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
        if urlRequest.value(forHTTPHeaderField: "User-Agent") == nil {
            urlRequest.setValue("TrendingTab/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw SourceFailure.network("响应类型无效")
        }
        let headers = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let name = key as? String, let text = value as? String else { return nil }
            return (name, text)
        })
        return HTTPResponse(statusCode: http.statusCode, data: data, headers: headers, finalURL: http.url ?? request.url)
    }
}

public actor RequestGate {
    private let globalLimit: Int
    private let hostLimit: Int
    private var globalInFlight = 0
    private var hostInFlight: [String: Int] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(globalLimit: Int = 4, hostLimit: Int = 1) {
        self.globalLimit = globalLimit
        self.hostLimit = hostLimit
    }

    public func acquire(host: String) async {
        while globalInFlight >= globalLimit || (hostInFlight[host] ?? 0) >= hostLimit {
            await withCheckedContinuation { waiters.append($0) }
        }
        globalInFlight += 1
        hostInFlight[host, default: 0] += 1
    }

    public func release(host: String) {
        globalInFlight = max(0, globalInFlight - 1)
        hostInFlight[host] = max(0, (hostInFlight[host] ?? 1) - 1)
        let next = waiters
        waiters.removeAll()
        next.forEach { $0.resume() }
    }
}

public final class ConditionalCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: (etag: String?, modified: String?)] = [:]

    public init() {}

    public func headers(for key: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key] else { return [:] }
        var headers: [String: String] = [:]
        if let etag = value.etag { headers["If-None-Match"] = etag }
        if let modified = value.modified { headers["If-Modified-Since"] = modified }
        return headers
    }

    public func store(key: String, response: HTTPResponse) {
        lock.lock()
        values[key] = (response.etag, response.lastModified)
        lock.unlock()
    }
}

public enum HTTPMapping {
    public static func failure(for response: HTTPResponse) -> SourceFailure? {
        switch response.statusCode {
        case 200...299: nil
        case 304: nil
        case 401: .unauthorized
        case 403: .forbidden
        case 429: .rateLimited(retryAfter: response.retryAfter)
        default: .network("HTTP \(response.statusCode)")
        }
    }
}
