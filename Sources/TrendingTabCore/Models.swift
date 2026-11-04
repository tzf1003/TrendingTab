import Foundation

public enum SourceCategory: String, Codable, CaseIterable, Sendable {
    case hotSearch = "hot-search"
    case news
    case video
    case blog
    case community
    case newMedia = "new-media"

    public var title: String {
        switch self {
        case .hotSearch: "热搜平台"
        case .news: "新闻平台"
        case .video: "视频平台"
        case .blog: "博客与科技"
        case .community: "社区"
        case .newMedia: "新媒体"
        }
    }
}

public enum SourceAvailability: String, Codable, Sendable {
    case available
    case requiresConfiguration
    case unavailable
}

public enum TransportMode: String, Codable, Sendable {
    case local
    case remote
}

public struct SourceDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var category: SourceCategory
    public var homepage: URL
    public var minimumInterval: TimeInterval
    public var parserVersion: String
    public var availability: SourceAvailability
    public var attribution: String?

    public init(
        id: String,
        title: String,
        category: SourceCategory,
        homepage: URL,
        minimumInterval: TimeInterval = 300,
        parserVersion: String,
        availability: SourceAvailability = .available,
        attribution: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.homepage = homepage
        self.minimumInterval = minimumInterval
        self.parserVersion = parserVersion
        self.availability = availability
        self.attribution = attribution
    }
}

public struct BoardDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sourceID: String
    public var title: String
    public var kind: String

    public init(id: String, sourceID: String, title: String, kind: String = "hot") {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.kind = kind
    }
}

public struct NormalizedItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sourceID: String
    public var boardID: String
    public var nativeID: String?
    public var title: String
    public var url: URL
    public var summary: String?
    public var author: String?
    public var publishedAt: Date?
    public var rank: Int?
    public var rawMetric: Double?
    public var metricLabel: String?

    public init(
        sourceID: String,
        boardID: String,
        nativeID: String?,
        title: String,
        url: URL,
        summary: String? = nil,
        author: String? = nil,
        publishedAt: Date? = nil,
        rank: Int? = nil,
        rawMetric: Double? = nil,
        metricLabel: String? = nil
    ) {
        self.sourceID = sourceID
        self.boardID = boardID
        self.nativeID = nativeID
        self.title = title
        self.url = url
        self.summary = summary
        self.author = author
        self.publishedAt = publishedAt
        self.rank = rank
        self.rawMetric = rawMetric
        self.metricLabel = metricLabel
        self.id = Self.stableID(sourceID: sourceID, nativeID: nativeID, url: url)
    }

    public static func stableID(sourceID: String, nativeID: String?, url: URL) -> String {
        if let nativeID, !nativeID.isEmpty {
            return "\(sourceID):\(nativeID)"
        }
        return "\(sourceID):url:\(canonical(url).sha256Prefix)"
    }

    public static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        let tracking = Set(["utm_source", "utm_medium", "utm_campaign", "utm_content", "spm"])
        components.queryItems = components.queryItems?.filter { !tracking.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url?.absoluteString ?? url.absoluteString
    }
}

public struct FetchResult: Codable, Equatable, Sendable {
    public var sourceID: String
    public var boardID: String
    public var fetchedAt: Date
    public var parserVersion: String
    public var items: [NormalizedItem]
    public var etag: String?
    public var lastModified: String?

    public init(
        sourceID: String,
        boardID: String,
        fetchedAt: Date,
        parserVersion: String,
        items: [NormalizedItem],
        etag: String? = nil,
        lastModified: String? = nil
    ) {
        self.sourceID = sourceID
        self.boardID = boardID
        self.fetchedAt = fetchedAt
        self.parserVersion = parserVersion
        self.items = items
        self.etag = etag
        self.lastModified = lastModified
    }
}

public enum SourceFailure: Error, Codable, Equatable, Sendable {
    case network(String)
    case timeout
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case schemaChanged(String)
    case configurationRequired(String)
    case unavailable(String)

    public var message: String {
        switch self {
        case .network(let value): "网络错误：\(value)"
        case .timeout: "请求超时"
        case .unauthorized: "需要认证"
        case .forbidden: "访问受限"
        case .rateLimited(let value): "来源限流\(value.map { "，\(Int($0)) 秒后重试" } ?? "")"
        case .schemaChanged(let value): "数据结构变化：\(value)"
        case .configurationRequired(let value): value
        case .unavailable(let value): value
        }
    }
}

public enum FetchOutcome: Sendable {
    case fetched(FetchResult)
    case notModified(Date)
    case empty(FetchResult)
    case failed(SourceFailure)
}

public struct SourceStatus: Codable, Equatable, Sendable, Identifiable {
    public var sourceID: String
    public var boardID: String
    public var state: String
    public var message: String
    public var lastSuccessAt: Date?
    public var checkedAt: Date
    public var stale: Bool

    public var id: String { "\(sourceID)/\(boardID)" }

    public init(
        sourceID: String,
        boardID: String,
        state: String,
        message: String,
        lastSuccessAt: Date?,
        checkedAt: Date,
        stale: Bool
    ) {
        self.sourceID = sourceID
        self.boardID = boardID
        self.state = state
        self.message = message
        self.lastSuccessAt = lastSuccessAt
        self.checkedAt = checkedAt
        self.stale = stale
    }
}
