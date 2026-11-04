import Foundation
import TrendingTabCore
import TrendingTabNetworking

struct Endpoint {
    var board: BoardDescriptor
    var url: URL
    var method: String = "GET"
    var body: Data? = nil
    var headers: [String: String] = [:]
    var parser: @Sendable (Data, FetchContext, BoardDescriptor) throws -> [NormalizedItem]
}

struct JSONSourceProvider: SourceProvider {
    var descriptor: SourceDescriptor
    var endpoints: [Endpoint]

    func boards() async throws -> [BoardDescriptor] { endpoints.map(\.board) }

    func fetch(board: String, context: FetchContext) async throws -> FetchResult {
        guard let endpoint = endpoints.first(where: { $0.board.id == board }) else {
            throw ProviderError.unknownBoard(board)
        }
        var headers = endpoint.headers
        if endpoint.method == "GET" {
            headers.merge(context.cache.headers(for: endpoint.board.id)) { current, _ in current }
        }
        let response = try await context.transport.send(HTTPRequest(
            url: endpoint.url,
            method: endpoint.method,
            headers: headers,
            body: endpoint.body
        ))
        if let failure = HTTPMapping.failure(for: response) { throw failure }
        if response.statusCode == 304 {
            return FetchResult(sourceID: descriptor.id, boardID: board, fetchedAt: context.now, parserVersion: descriptor.parserVersion, items: [])
        }
        context.cache.store(key: endpoint.board.id, response: response)
        let items = try endpoint.parser(response.data, context, endpoint.board)
        return FetchResult(
            sourceID: descriptor.id,
            boardID: board,
            fetchedAt: context.now,
            parserVersion: descriptor.parserVersion,
            items: items,
            etag: response.etag,
            lastModified: response.lastModified
        )
    }
}

func descriptor(_ id: String, _ title: String, _ category: SourceCategory, _ homepage: String, version: String, attribution: String? = "请求格式参考 DailyHotApi（MIT）") -> SourceDescriptor {
    SourceDescriptor(id: id, title: title, category: category, homepage: URL(string: homepage)!, parserVersion: version, attribution: attribution)
}

func board(_ source: String, _ suffix: String = "hot", _ title: String, _ kind: String = "hot") -> BoardDescriptor {
    BoardDescriptor(id: "\(source).\(suffix)", sourceID: source, title: title, kind: kind)
}

func item(_ board: BoardDescriptor, nativeID: String?, title: String, url: URL, summary: String? = nil, author: String? = nil, publishedAt: Date? = nil, rank: Int, metric: Double? = nil, metricLabel: String? = nil) -> NormalizedItem {
    NormalizedItem(sourceID: board.sourceID, boardID: board.id, nativeID: nativeID, title: title, url: url, summary: summary, author: author, publishedAt: publishedAt, rank: rank, rawMetric: metric, metricLabel: metricLabel)
}
