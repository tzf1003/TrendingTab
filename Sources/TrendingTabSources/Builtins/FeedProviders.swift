import Foundation
import TrendingTabCore
import TrendingTabNetworking

public struct FeedSource: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var category: SourceCategory
    public var feedURL: URL
    public var homepage: URL
    public var encoding: String
    public var configured: Bool

    public init(id: String, title: String, category: SourceCategory, feedURL: URL, homepage: URL, encoding: String = "utf-8", configured: Bool = true) {
        self.id = id
        self.title = title
        self.category = category
        self.feedURL = feedURL
        self.homepage = homepage
        self.encoding = encoding
        self.configured = configured
    }
}

public struct RSSSourceProvider: SourceProvider {
    public var feed: FeedSource
    public var descriptor: SourceDescriptor {
        SourceDescriptor(
            id: feed.id,
            title: feed.title,
            category: feed.category,
            homepage: feed.homepage,
            parserVersion: "rss-2026.1",
            availability: feed.configured ? .available : .requiresConfiguration,
            attribution: "RSS/Atom 按来源实际字段展示，不生成热度值"
        )
    }

    public init(feed: FeedSource) { self.feed = feed }

    public func boards() async throws -> [BoardDescriptor] {
        [BoardDescriptor(id: "\(feed.id).latest", sourceID: feed.id, title: "最新", kind: "latest")]
    }

    public func fetch(board: String, context: FetchContext) async throws -> FetchResult {
        guard feed.configured else { throw SourceFailure.configurationRequired("请先配置 \(feed.title) 的 RSS 地址") }
        let response = try await context.transport.send(HTTPRequest(url: feed.feedURL, headers: context.cache.headers(for: board)))
        if let failure = HTTPMapping.failure(for: response) { throw failure }
        context.cache.store(key: board, response: response)
        let selected = BoardDescriptor(id: board, sourceID: feed.id, title: "最新", kind: "latest")
        let items = try RSSParser.parse(response.data, encoding: feed.encoding, board: selected)
        return FetchResult(sourceID: feed.id, boardID: board, fetchedAt: context.now, parserVersion: descriptor.parserVersion, items: items, etag: response.etag, lastModified: response.lastModified)
    }
}

public enum RSSParser {
    public static func parse(_ data: Data, encoding: String, board: BoardDescriptor) throws -> [NormalizedItem] {
        let decoded = decode(data, encoding: encoding).replacingOccurrences(of: "encoding=\"gbk\"", with: "encoding=\"utf-8\"", options: .caseInsensitive)
            .replacingOccurrences(of: "encoding=\"gb2312\"", with: "encoding=\"utf-8\"", options: .caseInsensitive)
        let document = try XMLDocument(data: Data(decoded.utf8), options: [.nodeLoadExternalEntitiesNever])
        let nodes = try document.nodes(forXPath: "//item|//*[local-name()='entry']")
        return nodes.enumerated().compactMap { offset, node in
            let title = text(node, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }
            let link = text(node, "link") ?? attribute(node, "link", "href")
            guard let link, let url = URL(string: link) else { return nil }
            let guid = text(node, "guid") ?? text(node, "id")
            return NormalizedItem(
                sourceID: board.sourceID,
                boardID: board.id,
                nativeID: guid,
                title: title,
                url: url,
                summary: text(node, "description") ?? text(node, "summary") ?? text(node, "content"),
                author: text(node, "author") ?? text(node, "dc:creator") ?? text(node, "name"),
                publishedAt: parseDate(text(node, "pubDate") ?? text(node, "published") ?? text(node, "updated")),
                rank: offset + 1,
                metricLabel: "最新"
            )
        }
    }

    private static func decode(_ data: Data, encoding: String) -> String {
        if encoding.lowercased() == "gbk" || encoding.lowercased() == "gb18030" {
            let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if let value = String(data: data, encoding: gbk) { return value }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func text(_ node: XMLNode, _ name: String) -> String? {
        ((try? node.nodes(forXPath: "./*[local-name()='\(name)']"))?.first?.stringValue)?.trimmedNonEmpty()
    }

    private static func attribute(_ node: XMLNode, _ name: String, _ attribute: String) -> String? {
        ((try? node.nodes(forXPath: "./*[local-name()='\(name)']"))?.first as? XMLElement)?.attribute(forName: attribute)?.stringValue
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let date = rfc822.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

public enum BuiltInFeeds {
    public static let linuxDo = FeedSource(
        id: "linuxdo",
        title: "LinuxDo",
        category: .community,
        feedURL: URL(string: "https://linux.do/top.rss?period=weekly")!,
        homepage: URL(string: "https://linux.do/")!
    )
    public static let landian = FeedSource(
        id: "landian",
        title: "蓝点网",
        category: .blog,
        feedURL: URL(string: "https://www.landiannews.com/feed")!,
        homepage: URL(string: "https://www.landiannews.com/")!
    )
    public static let poJie = FeedSource(
        id: "52pojie",
        title: "吾爱破解",
        category: .community,
        feedURL: URL(string: "https://www.52pojie.cn/forum.php?mod=guide&view=digest&rss=1")!,
        homepage: URL(string: "https://www.52pojie.cn/")!,
        encoding: "gbk"
    )
    public static let wechat = FeedSource(
        id: "wechat",
        title: "微信热文",
        category: .newMedia,
        feedURL: URL(string: "https://example.invalid/wechat.rss")!,
        homepage: URL(string: "https://mp.weixin.qq.com/")!,
        configured: false
    )
}
