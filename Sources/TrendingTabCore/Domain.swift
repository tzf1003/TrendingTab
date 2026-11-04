import Foundation

public enum TabKind: String, Codable, CaseIterable, Sendable {
    case sourceBoard
    case aggregate
    case majorEvents
    case topic
    case trackedEvents
}

public enum SortMode: String, Codable, CaseIterable, Sendable {
    case sourceRank
    case reciprocalRankFusion
    case newest
    case importance
}

public struct TabFilter: Codable, Equatable, Sendable {
    public var includedWords: [String]
    public var excludedWords: [String]
    public var sourceIDs: [String]
    public var categories: [SourceCategory]
    public var semanticPrompt: String?
    public var minimumImportance: Int
    public var minimumConfidence: Double
    public var minimumIndependentSources: Int
    public var authoritativeSourceIDs: [String]
    public var timeWindow: TimeInterval

    public init(
        includedWords: [String] = [],
        excludedWords: [String] = [],
        sourceIDs: [String] = [],
        categories: [SourceCategory] = [],
        semanticPrompt: String? = nil,
        minimumImportance: Int = 75,
        minimumConfidence: Double = 0.8,
        minimumIndependentSources: Int = 2,
        authoritativeSourceIDs: [String] = [],
        timeWindow: TimeInterval = 48 * 3600
    ) {
        self.includedWords = includedWords
        self.excludedWords = excludedWords
        self.sourceIDs = sourceIDs
        self.categories = categories
        self.semanticPrompt = semanticPrompt
        self.minimumImportance = minimumImportance
        self.minimumConfidence = minimumConfidence
        self.minimumIndependentSources = minimumIndependentSources
        self.authoritativeSourceIDs = authoritativeSourceIDs
        self.timeWindow = timeWindow
    }
}

public struct NotificationPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var quietHoursStart: Int
    public var quietHoursEnd: Int
    public var hourlyLimit: Int
    public var dailyLimit: Int
    public var cooldown: TimeInterval

    public static let standard = NotificationPolicy(
        enabled: false,
        quietHoursStart: 23,
        quietHoursEnd: 8,
        hourlyLimit: 3,
        dailyLimit: 10,
        cooldown: 6 * 3600
    )

    public init(enabled: Bool, quietHoursStart: Int, quietHoursEnd: Int, hourlyLimit: Int, dailyLimit: Int, cooldown: TimeInterval) {
        self.enabled = enabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.hourlyLimit = hourlyLimit
        self.dailyLimit = dailyLimit
        self.cooldown = cooldown
    }
}

public struct TabDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var kind: TabKind
    public var boardIDs: [String]
    public var filter: TabFilter
    public var sort: SortMode
    public var monitoringEnabled: Bool
    public var notification: NotificationPolicy
    public var hidden: Bool
    public var trackedEventIDs: [UUID]
    public var blockedEventIDs: [UUID]
    public var rulesVersion: Int

    public init(
        id: UUID = UUID(),
        title: String,
        kind: TabKind,
        boardIDs: [String] = [],
        filter: TabFilter = TabFilter(),
        sort: SortMode,
        monitoringEnabled: Bool = false,
        notification: NotificationPolicy = .standard,
        hidden: Bool = false,
        trackedEventIDs: [UUID] = [],
        blockedEventIDs: [UUID] = [],
        rulesVersion: Int = 1
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.boardIDs = boardIDs
        self.filter = filter
        self.sort = sort
        self.monitoringEnabled = monitoringEnabled
        self.notification = notification
        self.hidden = hidden
        self.trackedEventIDs = trackedEventIDs
        self.blockedEventIDs = blockedEventIDs
        self.rulesVersion = rulesVersion
    }
}

public struct WidgetProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var orderedTabIDs: [UUID]
    public var defaultTabID: UUID?

    public init(id: UUID = UUID(), name: String, orderedTabIDs: [UUID], defaultTabID: UUID?) {
        self.id = id
        self.name = name
        self.orderedTabIDs = orderedTabIDs
        self.defaultTabID = defaultTabID
    }
}

public struct WidgetSelection: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var tabID: UUID?
    public var page: Int
    public var generation: Int

    public init(profileID: UUID, tabID: UUID?, page: Int, generation: Int) {
        self.profileID = profileID
        self.tabID = tabID
        self.page = page
        self.generation = generation
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var refreshInterval: TimeInterval
    public var automaticCollectionEnabled: Bool
    public var launchAtLogin: Bool
    public var aiEnabled: Bool
    public var dailyRequestLimit: Int
    public var dailyTokenLimit: Int
    public var promptVersion: Int
    public var globalNotification: NotificationPolicy

    public static let standard = AppSettings(
        refreshInterval: 15 * 60,
        automaticCollectionEnabled: true,
        launchAtLogin: false,
        aiEnabled: false,
        dailyRequestLimit: 100,
        dailyTokenLimit: 100_000,
        promptVersion: 1,
        globalNotification: .standard
    )

    public init(
        refreshInterval: TimeInterval,
        automaticCollectionEnabled: Bool,
        launchAtLogin: Bool,
        aiEnabled: Bool,
        dailyRequestLimit: Int,
        dailyTokenLimit: Int,
        promptVersion: Int,
        globalNotification: NotificationPolicy
    ) {
        self.refreshInterval = min(max(refreshInterval, 5 * 60), 1440 * 60)
        self.automaticCollectionEnabled = automaticCollectionEnabled
        self.launchAtLogin = launchAtLogin
        self.aiEnabled = aiEnabled
        self.dailyRequestLimit = dailyRequestLimit
        self.dailyTokenLimit = dailyTokenLimit
        self.promptVersion = promptVersion
        self.globalNotification = globalNotification
    }
}

public struct StoredItem: Codable, Equatable, Sendable, Identifiable {
    public var item: NormalizedItem
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var previousRank: Int?
    public var contentHash: String
    public var historical: Bool

    public var id: String { item.id }

    public init(item: NormalizedItem, firstSeenAt: Date, lastSeenAt: Date, previousRank: Int?, contentHash: String, historical: Bool) {
        self.item = item
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.previousRank = previousRank
        self.contentHash = contentHash
        self.historical = historical
    }
}

public struct EventCluster: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var itemIDs: [String]
    public var independentSourceCount: Int
    public var importance: Int?
    public var confidence: Double?
    public var category: String?
    public var summary: String?
    public var evidenceLevel: String
    public var status: String
    public var materialFingerprint: String
    public var updatedAt: Date
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        itemIDs: [String],
        independentSourceCount: Int,
        importance: Int? = nil,
        confidence: Double? = nil,
        category: String? = nil,
        summary: String? = nil,
        evidenceLevel: String = "标题与摘要",
        status: String = "candidate",
        materialFingerprint: String,
        updatedAt: Date,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.itemIDs = itemIDs
        self.independentSourceCount = independentSourceCount
        self.importance = importance
        self.confidence = confidence
        self.category = category
        self.summary = summary
        self.evidenceLevel = evidenceLevel
        self.status = status
        self.materialFingerprint = materialFingerprint
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
}

public struct SnapshotRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var sourceTitle: String
    public var rank: Int?
    public var movement: String?
    public var url: URL?
    public var eventID: UUID?
    public var publishedAt: Date?
    public var score: Double

    public init(id: String, title: String, sourceTitle: String, rank: Int?, movement: String?, url: URL?, eventID: UUID?, publishedAt: Date?, score: Double) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.rank = rank
        self.movement = movement
        self.url = url
        self.eventID = eventID
        self.publishedAt = publishedAt
        self.score = score
    }
}

public struct SnapshotTab: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var kind: TabKind
    public var rows: [SnapshotRow]
    public var coverage: String
    public var updatedAt: Date?

    public init(id: UUID, title: String, kind: TabKind, rows: [SnapshotRow], coverage: String, updatedAt: Date?) {
        self.id = id
        self.title = title
        self.kind = kind
        self.rows = rows
        self.coverage = coverage
        self.updatedAt = updatedAt
    }
}

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var generation: Int
    public var generatedAt: Date
    public var profiles: [WidgetProfile]
    public var tabs: [SnapshotTab]
    public var statuses: [SourceStatus]
    public var unreadCount: Int

    public init(version: Int = currentVersion, generation: Int, generatedAt: Date, profiles: [WidgetProfile], tabs: [SnapshotTab], statuses: [SourceStatus], unreadCount: Int) {
        self.version = version
        self.generation = generation
        self.generatedAt = generatedAt
        self.profiles = profiles
        self.tabs = tabs
        self.statuses = statuses
        self.unreadCount = unreadCount
    }
}

public enum AIProtocolKind: String, Codable, CaseIterable, Sendable {
    case openAIResponses = "openai-responses"
    case openAIChat = "openai-chat"
    case anthropicMessages = "anthropic-messages"

    public var title: String {
        switch self {
        case .openAIResponses: "OpenAI Responses"
        case .openAIChat: "OpenAI Chat Completions"
        case .anthropicMessages: "Anthropic Messages"
        }
    }
}

public enum AITask: String, Codable, CaseIterable, Sendable {
    case classification
    case summary
    case analysis
}

public struct AIConnection: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: AIProtocolKind
    public var baseURL: URL
    public var model: String
    public var credentialAccount: String
    public var timeout: TimeInterval
    public var maxOutputTokens: Int

    public init(id: UUID = UUID(), name: String, kind: AIProtocolKind, baseURL: URL, model: String, credentialAccount: String, timeout: TimeInterval = 45, maxOutputTokens: Int = 1200) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.credentialAccount = credentialAccount
        self.timeout = timeout
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct AIAssignment: Codable, Equatable, Sendable {
    public var classification: UUID?
    public var summary: UUID?
    public var analysis: UUID?

    public static let empty = AIAssignment(classification: nil, summary: nil, analysis: nil)

    public func connectionID(for task: AITask) -> UUID? {
        switch task {
        case .classification: classification
        case .summary: summary
        case .analysis: analysis
        }
    }
}

public struct ModelAssessment: Codable, Equatable, Sendable {
    public var importance: Int
    public var confidence: Double
    public var category: String
    public var summary: String
    public var reason: String
    public var evidenceIDs: [String]
    public var matchedTopicIDs: [UUID]

    public init(importance: Int, confidence: Double, category: String, summary: String, reason: String, evidenceIDs: [String], matchedTopicIDs: [UUID]) {
        self.importance = importance
        self.confidence = confidence
        self.category = category
        self.summary = summary
        self.reason = reason
        self.evidenceIDs = evidenceIDs
        self.matchedTopicIDs = matchedTopicIDs
    }
}

