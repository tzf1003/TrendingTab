import XCTest
@testable import TrendingTabIntelligence
@testable import TrendingTabNetworking

private actor SearchTransport: HTTPTransport {
    let response: HTTPResponse
    var request: HTTPRequest?
    init(status: Int = 200, json: String) {
        response = HTTPResponse(statusCode: status, data: Data(json.utf8), headers: [:], finalURL: URL(string: "https://example.com")!)
    }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        self.request = request
        return response
    }
}

final class ResearchSearchTests: XCTestCase, @unchecked Sendable {
    func testWebSearchBuildsTimeFiltersAndEncodesScopedQuery() throws {
        for (range, google, bing) in [("day", "d", "ez1"), ("week", "w", "ez2"), ("month", "m", "ez3"), ("year", "y", "ez4")] {
            let request = ResearchSearchRequest(query: "人工智能 & 新闻?", timeRange: range, domain: "Example.COM")
            for (engine, filter, value) in [(ResearchWebSearch.Engine.google, "tbs", "qdr:\(google)"), (.bing, "filters", "ex1:\"\(bing)\"")] {
                let destination = try ResearchWebSearch.destination(engine: engine, request: request)
                let items = try XCTUnwrap(URLComponents(url: destination.url, resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "人工智能 & 新闻? site:example.com")
                XCTAssertEqual(items.first(where: { $0.name == filter })?.value, value)
                XCTAssertTrue(destination.timeFilterRequested)
            }
            let baidu = try ResearchWebSearch.destination(engine: .baidu, request: request)
            let items = try XCTUnwrap(URLComponents(url: baidu.url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first(where: { $0.name == "wd" })?.value, "人工智能 & 新闻? site:example.com")
            XCTAssertFalse(baidu.timeFilterRequested)
        }
        for engine in [ResearchWebSearch.Engine.baidu, .bing, .google] {
            let destination = try ResearchWebSearch.destination(engine: engine, request: .init(query: "测试"))
            XCTAssertFalse(destination.timeFilterRequested)
            XCTAssertEqual(URLComponents(url: destination.url, resolvingAgainstBaseURL: false)?.queryItems?.count, 1)
        }
    }

    func testBraveSearchUsesScopedQueryAndNormalizesResults() async throws {
        let transport = SearchTransport(json: #"{"web":{"results":[{"title":"报道","url":"https://example.com/story","description":"摘要","page_age":"2026-11-01"}]}}"#)
        let service = ResearchSearchService(transport: transport)
        let credential = "example" + "-credential"
        let results = try await service.search(provider: .brave, credential: credential, request: .init(query: "热点", timeRange: "week", domain: "example.com"))
        XCTAssertEqual(results.first?.published, "2026-11-01")
        XCTAssertEqual(results.first?.snippet, "摘要")
        let recorded = await transport.request
        let request = try XCTUnwrap(recorded)
        let query = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "q" })?.value, "热点 site:example.com")
        XCTAssertEqual(query.first(where: { $0.name == "freshness" })?.value, "pw")
        XCTAssertEqual(request.headers["X-Subscription-Token"], credential)
    }

    func testTavilyBodyAndHTTPFailure() async throws {
        let transport = SearchTransport(json: #"{"results":[{"title":"报道","url":"https://example.com","content":"摘要","published_date":"2026-11-01"}]}"#)
        let service = ResearchSearchService(transport: transport)
        let credential = "example" + "-credential"
        let results = try await service.search(provider: .tavily, credential: credential, request: .init(query: "热点", timeRange: "day", domain: "example.com"))
        XCTAssertEqual(results.first?.published, "2026-11-01")
        let recorded = await transport.request
        let request = try XCTUnwrap(recorded)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(credential)")
        XCTAssertEqual(body["time_range"] as? String, "day")
        XCTAssertEqual(body["include_domains"] as? [String], ["example.com"])
        XCTAssertEqual(body["include_published_date"] as? Bool, true)
        let failure = ResearchSearchService(transport: SearchTransport(status: 429, json: "{}"))
        do {
            _ = try await failure.search(provider: .tavily, credential: credential, request: .init(query: "热点"))
            XCTFail("限流必须显示为错误")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("429"))
        }
        XCTAssertNil(ResearchSearchRequest(query: "x", domain: "example.com/path").domain)
    }
}
