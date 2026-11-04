import Foundation

enum CommunityProviders {
    static let kr36 = JSONSourceProvider(
        descriptor: descriptor("36kr", "36氪", .blog, "https://www.36kr.com/", version: "36kr-2026.1"),
        endpoints: [Endpoint(
            board: board("36kr", "hot", "人气榜"),
            url: URL(string: "https://gateway.36kr.com/api/mis/nav/home/nav/rank/hot")!,
            method: "POST",
            body: Data("{\"partner_id\":\"wap\",\"param\":{\"siteId\":1,\"platformId\":2}}".utf8),
            headers: ["Content-Type": "application/json"]
        ) { data, _, selected in
            let rows = try JSONValues.array((try JSONValues.object(data)["data"] as? [String: Any])?["hotRankList"], path: "data.hotRankList")
            return rows.enumerated().compactMap { offset, row in
                guard let material = row["templateMaterial"] as? [String: Any], let title = JSONValues.string(material["widgetTitle"]), let nativeID = JSONValues.string(row["itemId"]) else { return nil }
                return item(selected, nativeID: nativeID, title: title, url: URL(string: "https://www.36kr.com/p/\(nativeID)")!, author: JSONValues.string(material["authorName"]), rank: offset + 1, metric: JSONValues.double(material["statCollect"]), metricLabel: "收藏")
            }
        }]
    )

    static let juejin = JSONSourceProvider(
        descriptor: descriptor("juejin", "掘金", .community, "https://juejin.cn/hot/articles", version: "juejin-2026.1"),
        endpoints: [Endpoint(board: board("juejin", "hot", "文章热榜"), url: URL(string: "https://api.juejin.cn/content_api/v1/content/article_rank?category_id=1&type=hot")!) { data, _, selected in
            let rows = try JSONValues.array(try JSONValues.object(data)["data"], path: "data")
            return rows.enumerated().compactMap { offset, row in
                guard let content = row["content"] as? [String: Any], let title = JSONValues.string(content["title"]), let nativeID = JSONValues.string(content["content_id"]) else { return nil }
                return item(selected, nativeID: nativeID, title: title, url: URL(string: "https://juejin.cn/post/\(nativeID)")!, author: JSONValues.string((row["author"] as? [String: Any])?["name"]), rank: offset + 1, metric: JSONValues.double((row["content_counter"] as? [String: Any])?["hot_rank"]), metricLabel: "热度")
            }
        }]
    )

    static let tieba = JSONSourceProvider(
        descriptor: descriptor("tieba", "百度贴吧", .community, "https://tieba.baidu.com/hottopic/browse/topicList", version: "tieba-2026.1"),
        endpoints: [Endpoint(board: board("tieba", "hot", "热议榜"), url: URL(string: "https://tieba.baidu.com/hottopic/browse/topicList")!, headers: ["Accept": "application/json,text/plain,*/*"]) { data, _, selected in
            let topic = ((try JSONValues.object(data)["data"] as? [String: Any])?["bang_topic"] as? [String: Any])
            let rows = try JSONValues.array(topic?["topic_list"], path: "data.bang_topic.topic_list")
            return rows.enumerated().compactMap { offset, row in
                guard let title = JSONValues.string(row["topic_name"]), let link = JSONValues.string(row["topic_url"]).flatMap({ URL(string: $0) }) else { return nil }
                return item(selected, nativeID: JSONValues.string(row["topic_id"]), title: title, url: link, summary: JSONValues.string(row["topic_desc"]), rank: offset + 1, metric: JSONValues.double(row["discuss_num"]), metricLabel: "讨论")
            }
        }]
    )

    static let hupu = JSONSourceProvider(
        descriptor: descriptor("hupu", "虎扑", .community, "https://bbs.hupu.com/all-gambia", version: "hupu-2026.1"),
        endpoints: [Endpoint(board: board("hupu", "hot", "步行街热帖"), url: URL(string: "https://m.hupu.com/api/v2/bbs/topicThreads?topicId=1&page=1")!) { data, _, selected in
            let rows = try JSONValues.array((try JSONValues.object(data)["data"] as? [String: Any])?["topicThreads"], path: "data.topicThreads")
            return rows.enumerated().compactMap { offset, row in
                guard let title = JSONValues.string(row["title"]), let nativeID = JSONValues.string(row["tid"]) else { return nil }
                return item(selected, nativeID: nativeID, title: title, url: URL(string: "https://bbs.hupu.com/\(nativeID).html")!, author: JSONValues.string(row["username"]), rank: offset + 1, metric: JSONValues.double(row["replies"]), metricLabel: "回复")
            }
        }]
    )
}
