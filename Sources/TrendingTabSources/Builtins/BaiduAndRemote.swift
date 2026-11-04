import Foundation
import SwiftSoup
import TrendingTabCore
import TrendingTabNetworking

public struct BaiduSourceProvider: SourceProvider {
    public let descriptor = SourceDescriptor(id: "baidu", title: "百度", category: .hotSearch, homepage: URL(string: "https://top.baidu.com/board")!, parserVersion: "baidu-2026.1", attribution: "页面解析参考 DailyHotApi（MIT）")

    public init() {}
    public func boards() async throws -> [BoardDescriptor] { [BoardDescriptor(id: "baidu.realtime", sourceID: "baidu", title: "热搜", kind: "hot")] }

    public func fetch(board: String, context: FetchContext) async throws -> FetchResult {
        let response = try await context.transport.send(HTTPRequest(url: URL(string: "https://top.baidu.com/board?tab=realtime")!, headers: context.cache.headers(for: board)))
        if let failure = HTTPMapping.failure(for: response) { throw failure }
        context.cache.store(key: board, response: response)
        let selected = BoardDescriptor(id: board, sourceID: descriptor.id, title: "热搜", kind: "hot")
        let items = try Self.parse(response.data, board: selected)
        return FetchResult(sourceID: descriptor.id, boardID: board, fetchedAt: context.now, parserVersion: descriptor.parserVersion, items: items, etag: response.etag, lastModified: response.lastModified)
    }

    public static func parse(_ data: Data, board: BoardDescriptor) throws -> [NormalizedItem] {
        let html = String(data: data, encoding: .utf8) ?? ""
        if let range = html.range(of: "<!--s-data:"), let end = html[range.upperBound...].range(of: "-->") {
            let json = String(html[range.upperBound..<end.lowerBound])
            if let root = try? JSONValues.object(Data(json.utf8)) {
                let cards = ((root["data"] as? [String: Any])?["cards"] as? [[String: Any]]) ?? (root["cards"] as? [[String: Any]]) ?? []
                let content = (cards.first?["content"] as? [[String: Any]]) ?? []
                let rows = (content.first?["content"] as? [[String: Any]]) ?? content
                let parsed = rows.enumerated().compactMap { offset, row -> NormalizedItem? in
                    guard let title = JSONValues.string(row["word"] ?? row["title"]) else { return nil }
                    let query = JSONValues.string(row["query"]) ?? title
                    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                    return item(board, nativeID: JSONValues.string(row["index"]) ?? "\(offset + 1)", title: title, url: URL(string: "https://www.baidu.com/s?wd=\(encoded)")!, summary: JSONValues.string(row["desc"]), rank: offset + 1, metric: JSONValues.double(row["hotScore"] ?? row["hotTag"]), metricLabel: "热度")
                }
                if !parsed.isEmpty { return parsed }
            }
        }
        let document = try SwiftSoup.parse(html)
        let titles = try document.select(".c-single-text-ellipsis, .title_dIF3B").array()
        return titles.enumerated().compactMap { offset, element in
            guard let title = try? element.text().trimmedNonEmpty() else { return nil }
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
            return item(board, nativeID: "\(offset + 1)", title: title, url: URL(string: "https://www.baidu.com/s?wd=\(encoded)")!, rank: offset + 1)
        }
    }
}

public struct RemoteSourceProvider: SourceProvider {
    public var remoteSourceID: String
    public var descriptor: SourceDescriptor

    public init(remoteSourceID: String, descriptor: SourceDescriptor) {
        self.remoteSourceID = remoteSourceID
        self.descriptor = descriptor
    }

    public func boards() async throws -> [BoardDescriptor] {
        [BoardDescriptor(id: "\(descriptor.id).remote", sourceID: descriptor.id, title: descriptor.title)]
    }

    public func fetch(board: String, context: FetchContext) async throws -> FetchResult {
        guard let base = context.remoteBaseURL else { throw SourceFailure.configurationRequired("请配置自建服务地址") }
        let url = base.appendingPathComponent("v1/sources/\(remoteSourceID)/boards/\(board)/items")
        var headers = ["Accept": "application/json"]
        if let credential = context.remoteCredential { headers["Authorization"] = "Bearer \(credential)" }
        let response = try await context.transport.send(HTTPRequest(url: url, headers: headers))
        if let failure = HTTPMapping.failure(for: response) { throw failure }
        let payload = try TrendingJSON.value(RemoteBoardPayload.self, from: response.data)
        guard payload.schemaVersion == 1 else { throw SourceFailure.schemaChanged("不支持协议版本 \(payload.schemaVersion)") }
        return FetchResult(sourceID: descriptor.id, boardID: board, fetchedAt: payload.fetchedAt, parserVersion: "remote-v\(payload.schemaVersion)", items: payload.items)
    }
}

public struct RemoteBoardPayload: Codable, Sendable {
    public var schemaVersion: Int
    public var sourceID: String
    public var boardID: String
    public var fetchedAt: Date
    public var items: [NormalizedItem]
    public var status: String
}
