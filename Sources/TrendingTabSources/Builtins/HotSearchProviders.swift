import Foundation

enum HotSearchProviders {
    static let weibo = JSONSourceProvider(
        descriptor: descriptor("weibo", "微博", .hotSearch, "https://s.weibo.com/top/summary/", version: "weibo-2026.1"),
        endpoints: [Endpoint(board: board("weibo", "hot", "热搜榜"), url: URL(string: "https://weibo.com/ajax/side/hotSearch")!, headers: ["Referer": "https://weibo.com/"]) { data, _, selected in
            let root = try JSONValues.object(data)
            let realtime = try JSONValues.array((root["data"] as? [String: Any])?["realtime"], path: "data.realtime")
            return realtime.enumerated().compactMap { offset, row in
                guard let title = JSONValues.string(row["word"] ?? row["word_scheme"]) else { return nil }
                let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
                return item(selected, nativeID: JSONValues.string(row["mid"] ?? row["word_scheme"]), title: title, url: URL(string: "https://s.weibo.com/weibo?q=\(encoded)")!, summary: JSONValues.string(row["word_scheme"]), rank: offset + 1, metric: JSONValues.double(row["num"]), metricLabel: "热度")
            }
        }]
    )

    static let douyin = JSONSourceProvider(
        descriptor: descriptor("douyin", "抖音", .hotSearch, "https://www.douyin.com/hot", version: "douyin-2026.1"),
        endpoints: [Endpoint(board: board("douyin", "hot", "热点榜"), url: URL(string: "https://www.douyin.com/aweme/v1/web/hot/search/list/?device_platform=webapp&aid=6383&channel=channel_pc_web&detail_list=1")!, headers: ["Referer": "https://www.douyin.com/"]) { data, _, selected in
            let root = try JSONValues.object(data)
            let words = try JSONValues.array((root["data"] as? [String: Any])?["word_list"], path: "data.word_list")
            return words.enumerated().compactMap { offset, row in
                guard let title = JSONValues.string(row["word"]), let nativeID = JSONValues.string(row["sentence_id"]) else { return nil }
                return item(selected, nativeID: nativeID, title: title, url: URL(string: "https://www.douyin.com/hot/\(nativeID)")!, rank: offset + 1, metric: JSONValues.double(row["hot_value"]), metricLabel: "热度")
            }
        }]
    )

    static let zhihu = JSONSourceProvider(
        descriptor: descriptor("zhihu", "知乎", .hotSearch, "https://www.zhihu.com/hot", version: "zhihu-2026.1"),
        endpoints: [Endpoint(board: board("zhihu", "hot", "热榜"), url: URL(string: "https://api.zhihu.com/topstory/hot-lists/total?limit=50")!, headers: ["Referer": "https://www.zhihu.com/hot"]) { data, _, selected in
            let rows = try JSONValues.array(try JSONValues.object(data)["data"], path: "data")
            return rows.enumerated().compactMap { offset, row in
                guard let target = row["target"] as? [String: Any], let title = JSONValues.string(target["title"]) else { return nil }
                let question = JSONValues.string(target["url"])?.split(separator: "/").last.map(String.init)
                let link = URL(string: "https://www.zhihu.com/question/\(question ?? "")")!
                let hotText = JSONValues.string(row["detail_text"])
                return item(selected, nativeID: JSONValues.string(target["id"]) ?? question, title: title, url: link, summary: JSONValues.string(target["excerpt"]), rank: offset + 1, metric: JSONValues.double(hotText), metricLabel: hotText)
            }
        }]
    )

    static let toutiao = JSONSourceProvider(
        descriptor: descriptor("toutiao", "今日头条", .hotSearch, "https://www.toutiao.com/", version: "toutiao-2026.1"),
        endpoints: [Endpoint(board: board("toutiao", "hot", "热榜"), url: URL(string: "https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc")!) { data, _, selected in
            let rows = try JSONValues.array(try JSONValues.object(data)["data"], path: "data")
            return rows.enumerated().compactMap { offset, row in
                guard let title = JSONValues.string(row["Title"]), let nativeID = JSONValues.string(row["ClusterIdStr"]) else { return nil }
                return item(selected, nativeID: nativeID, title: title, url: URL(string: "https://www.toutiao.com/trending/\(nativeID)/")!, rank: offset + 1, metric: JSONValues.double(row["HotValue"]), metricLabel: "热度")
            }
        }]
    )
}
