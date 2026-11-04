import Foundation
import TrendingTabCore
import TrendingTabNetworking

enum NewsAndVideoProviders {
    static let netease = JSONSourceProvider(
        descriptor: descriptor("netease-news", "网易新闻", .news, "https://news.163.com/", version: "netease-2026.1"),
        endpoints: [Endpoint(board: board("netease-news", "hot", "热点榜"), url: URL(string: "https://m.163.com/fe/api/hot/news/flow")!) { data, _, selected in
            let rows = try JSONValues.array((try JSONValues.object(data)["data"] as? [String: Any])?["list"], path: "data.list")
            return rows.enumerated().compactMap { offset, row in
                guard let title = JSONValues.string(row["title"]), let nativeID = JSONValues.string(row["docid"]) else { return nil }
                return item(selected, nativeID: nativeID, title: title, url: URL(string: "https://www.163.com/dy/article/\(nativeID).html")!, author: JSONValues.string(row["source"]), rank: offset + 1)
            }
        }]
    )

    static let thepaper = JSONSourceProvider(
        descriptor: descriptor("thepaper", "澎湃新闻", .news, "https://www.thepaper.cn/", version: "thepaper-2026.1"),
        endpoints: [Endpoint(board: board("thepaper", "hot", "热榜"), url: URL(string: "https://cache.thepaper.cn/contentapi/wwwIndex/rightSidebar")!) { data, _, selected in
            let rows = try JSONValues.array((try JSONValues.object(data)["data"] as? [String: Any])?["hotNews"], path: "data.hotNews")
            return rows.enumerated().compactMap { offset, row in
                guard let title = JSONValues.string(row["name"]), let nativeID = JSONValues.string(row["contId"]) else { return nil }
                return item(selected, nativeID: nativeID, title: title, url: URL(string: "https://www.thepaper.cn/newsDetail_forward_\(nativeID)")!, rank: offset + 1, metric: JSONValues.double(row["praiseTimes"]), metricLabel: "互动")
            }
        }]
    )

    static let qqNews = JSONSourceProvider(
        descriptor: descriptor("qq-news", "腾讯新闻", .news, "https://news.qq.com/", version: "qq-news-2026.1"),
        endpoints: [Endpoint(board: board("qq-news", "hot", "热点榜"), url: URL(string: "https://r.inews.qq.com/gw/event/hot_ranking_list?page_size=50")!) { data, _, selected in
            let lists = try JSONValues.array(try JSONValues.object(data)["idlist"], path: "idlist")
            let rows = try JSONValues.array(lists.first?["newslist"], path: "idlist[0].newslist").dropFirst()
            return rows.enumerated().compactMap { offset, row in
                guard let title = JSONValues.string(row["title"]), let nativeID = JSONValues.string(row["id"]) else { return nil }
                let hot = (row["hotEvent"] as? [String: Any])?["hotScore"]
                return item(selected, nativeID: nativeID, title: title, url: URL(string: "https://new.qq.com/rain/a/\(nativeID)")!, summary: JSONValues.string(row["abstract"]), author: JSONValues.string(row["source"]), rank: offset + 1, metric: JSONValues.double(hot), metricLabel: "热度")
            }
        }]
    )

    static let bilibili = BilibiliSourceProvider()
}

struct BilibiliSourceProvider: SourceProvider {
    var descriptor: SourceDescriptor {
        TrendingTabSources.descriptor("bilibili", "哔哩哔哩", .video, "https://www.bilibili.com/v/popular/rank/all", version: "bilibili-2026.2")
    }
    func boards() async throws -> [BoardDescriptor] { [board("bilibili", "hot", "全站排行")] }

    func fetch(board: String, context: FetchContext) async throws -> FetchResult {
        let primary = URL(string: "https://api.bilibili.com/x/web-interface/ranking/v2?rid=0&type=all")!
        let fallback = URL(string: "https://api.bilibili.com/x/web-interface/ranking?rid=0&type=all")!
        let selected = BoardDescriptor(id: board, sourceID: descriptor.id, title: "全站排行")
        var lastError: Error = SourceFailure.schemaChanged("缺少 data.list")
        for url in [primary, fallback] {
            do {
                let response = try await context.transport.send(HTTPRequest(url: url, headers: ["Referer": "https://www.bilibili.com/ranking/all"]))
                if let failure = HTTPMapping.failure(for: response) { throw failure }
                let items = try Self.parse(response.data, board: selected)
                if !items.isEmpty {
                    return FetchResult(sourceID: descriptor.id, boardID: board, fetchedAt: context.now, parserVersion: descriptor.parserVersion, items: items, etag: response.etag, lastModified: response.lastModified)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func parse(_ data: Data, board: BoardDescriptor) throws -> [NormalizedItem] {
        let rows = try JSONValues.array((try JSONValues.object(data)["data"] as? [String: Any])?["list"], path: "data.list")
        return rows.enumerated().compactMap { offset, row in
            guard let title = JSONValues.string(row["title"]), let nativeID = JSONValues.string(row["bvid"]) else { return nil }
            let owner = (row["owner"] as? [String: Any])?["name"] ?? row["author"]
            let views = (row["stat"] as? [String: Any])?["view"] ?? row["video_review"]
            return item(board, nativeID: nativeID, title: title, url: URL(string: "https://www.bilibili.com/video/\(nativeID)")!, summary: JSONValues.string(row["desc"]), author: JSONValues.string(owner), rank: offset + 1, metric: JSONValues.double(views), metricLabel: "播放")
        }
    }
}
