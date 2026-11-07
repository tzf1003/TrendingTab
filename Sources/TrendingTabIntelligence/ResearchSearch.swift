import Foundation
import TrendingTabNetworking

public enum ResearchSearchProvider: String, CaseIterable, Sendable {
    case web, brave, tavily
}

public enum ResearchSearchTopic: String, Sendable {
    case general, news
}

public struct ResearchSearchResult: Decodable, Sendable {
    public let title: String
    public let url: String
    public let snippet: String
    public let published: String?

    public init(title: String, url: String, snippet: String, published: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.published = published
    }
}

public struct ResearchSearchRequest: Sendable {
    public let query: String
    public let timeRange: String?
    public let domain: String?
    public let topic: ResearchSearchTopic

    public init(query: String, timeRange: String? = nil, domain: String? = nil, topic: ResearchSearchTopic = .general) {
        self.query = query
        self.topic = topic
        self.timeRange = ["day", "week", "month", "year"].contains(timeRange ?? "") ? timeRange : nil
        let domain = domain?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.domain = domain.range(of: #"^(?=.{1,253}$)[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil ? domain : nil
    }
}

/// Constructs browser search URLs without exposing search-engine details to the agent.
public enum ResearchWebSearch {
    public enum Engine: String, Sendable { case baidu, bing, google }
    public struct Destination: Sendable {
        public let url: URL
        public let timeFilterRequested: Bool
    }

    public enum SearchURLError: LocalizedError {
        case invalidURL
        public var errorDescription: String? { "无法生成搜索地址，请调整搜索内容。" }
    }

    public static func destination(engine: Engine, request: ResearchSearchRequest) throws -> Destination {
        let base: String
        switch engine {
        case .baidu: base = "https://www.baidu.com/s"
        case .bing: base = "https://www.bing.com/search"
        case .google: base = "https://www.google.com/search"
        }
        var components = URLComponents(string: base)!
        let query = request.domain.map { "\(request.query) site:\($0)" } ?? request.query
        components.queryItems = [URLQueryItem(name: engine == .baidu ? "wd" : "q", value: query)]
        var applied = false
        if let range = request.timeRange {
            switch engine {
            case .google:
                if let value = ["day": "d", "week": "w", "month": "m", "year": "y"][range] {
                    components.queryItems?.append(URLQueryItem(name: "tbs", value: "qdr:\(value)"))
                    applied = true
                }
            case .bing:
                if let value = ["day": "ez1", "week": "ez2", "month": "ez3", "year": "ez4"][range] {
                    components.queryItems?.append(URLQueryItem(name: "filters", value: "ex1:\"\(value)\""))
                    applied = true
                }
            case .baidu: break
            }
        }
        guard let url = components.url else { throw SearchURLError.invalidURL }
        return Destination(url: url, timeFilterRequested: applied)
    }
}

/// Search API requests use an isolated, anonymous session and never share WebKit cookies.
public struct ResearchSearchService: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = AnonymousSearchTransport()) { self.transport = transport }

    public func search(provider: ResearchSearchProvider, credential: String, request: ResearchSearchRequest) async throws -> [ResearchSearchResult] {
        guard provider != .web, !credential.isEmpty else { throw SearchError.configuration }
        let response: HTTPResponse
        switch provider {
        case .brave:
            let index = request.topic == .news ? "news" : "web"
            var components = URLComponents(string: "https://api.search.brave.com/res/v1/\(index)/search")!
            let query = request.domain.map { "\(request.query) site:\($0)" } ?? request.query
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "10")]
            let freshness = ["day": "pd", "week": "pw", "month": "pm", "year": "py"]
            if let value = request.timeRange.flatMap({ freshness[$0] }) { components.queryItems?.append(URLQueryItem(name: "freshness", value: value)) }
            guard let url = components.url else { throw SearchError.invalidQuery }
            response = try await transport.send(HTTPRequest(url: url, headers: ["Accept": "application/json", "X-Subscription-Token": credential], includeConditionalHeaders: false))
        case .tavily:
            var body: [String: Any] = ["query": request.query, "max_results": 10, "topic": request.topic.rawValue,
                                       "include_raw_content": false, "include_published_date": true]
            if let range = request.timeRange { body["time_range"] = range }
            if let domain = request.domain { body["include_domains"] = [domain] }
            response = try await transport.send(HTTPRequest(url: URL(string: "https://api.tavily.com/search")!, method: "POST", headers: ["Authorization": "Bearer \(credential)", "Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: body), includeConditionalHeaders: false))
        case .web: throw SearchError.configuration
        }
        guard (200...299).contains(response.statusCode) else { throw SearchError.http(response.statusCode) }
        do {
            switch provider {
            case .brave:
                let payload = try JSONDecoder().decode(BraveResponse.self, from: response.data)
                let results: [BraveResponse.Result]
                if let available = request.topic == .news ? payload.results : payload.web?.results {
                    results = available
                } else if request.topic == .general && payload.type == "search" {
                    // Brave may omit result groups that have no available data.
                    results = []
                } else {
                    throw SearchError.invalidResponse
                }
                return results.map { ResearchSearchResult(title: $0.title, url: $0.url, snippet: $0.description ?? "", published: $0.pageAge ?? $0.age) }
            case .tavily:
                let payload = try JSONDecoder().decode(TavilyResponse.self, from: response.data)
                return payload.results.map { ResearchSearchResult(title: $0.title, url: $0.url, snippet: $0.content ?? "", published: $0.publishedDate) }
            case .web: throw SearchError.configuration
            }
        } catch { throw SearchError.invalidResponse }
    }

    public enum SearchError: LocalizedError {
        case configuration, invalidQuery, http(Int), invalidResponse
        public var errorDescription: String? {
            switch self {
            case .configuration: "请先配置搜索服务的 API Key。"
            case .invalidQuery: "无法生成搜索地址，请调整搜索内容。"
            case .http(let status): "搜索服务返回 HTTP \(status)，请检查配置或稍后重试。"
            case .invalidResponse: "搜索服务返回的数据无法解析。"
            }
        }
    }

    private struct BraveResponse: Decodable {
        struct Container: Decodable { let results: [Result] }
        struct Result: Decodable {
            let title, url: String
            let description, age, pageAge: String?
            enum CodingKeys: String, CodingKey { case title, url, description, age; case pageAge = "page_age" }
        }
        let web: Container?
        let results: [Result]?
        let type: String?
    }
    private struct TavilyResponse: Decodable {
        struct Result: Decodable {
            let title, url: String
            let content, publishedDate: String?
            enum CodingKeys: String, CodingKey { case title, url, content; case publishedDate = "published_date" }
        }
        let results: [Result]
    }
}

public struct AnonymousSearchTransport: HTTPTransport {
    public init() {}
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        // Search credentials must never be forwarded to a redirected host.
        let session = URLSession(configuration: configuration, delegate: RejectSearchRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        let (data, raw) = try await session.data(for: urlRequest)
        guard let response = raw as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HTTPResponse(statusCode: response.statusCode, data: data, headers: [:], finalURL: response.url ?? request.url)
    }
}

private final class RejectSearchRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
