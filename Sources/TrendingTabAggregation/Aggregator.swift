import Foundation
import TrendingTabCore

public struct AggregatedRow: Equatable, Sendable {
    public var stored: StoredItem
    public var score: Double
    public var movement: String?
}

public enum RankFusion {
    public static func score(rank: Int?, age: TimeInterval) -> Double {
        let rankScore = rank.map { 1.0 / (60.0 + Double($0)) } ?? 0
        let recency = max(0, 1 - age / (48 * 3600))
        return rankScore * 0.8 + recency * 0.2
    }

    public static func movement(current: Int?, previous: Int?) -> String? {
        guard let current else { return nil }
        guard let previous else { return "新" }
        let delta = previous - current
        if delta >= 3 { return "↑\(delta)" }
        if delta <= -3 { return "↓\(-delta)" }
        return nil
    }
}

public enum TabAggregator {
    public static func rows(tab: TabDefinition, items: [StoredItem], events: [EventCluster], sources: [SourceDescriptor], now: Date) -> (rows: [AggregatedRow], coverage: String) {
        let scoped = items.filter { candidate in
            let age = now.timeIntervalSince(candidate.lastSeenAt)
            guard age <= tab.filter.timeWindow, !candidate.historical else { return false }
            if !tab.boardIDs.isEmpty && !tab.boardIDs.contains(candidate.item.boardID) && tab.kind == .sourceBoard { return false }
            if !tab.filter.sourceIDs.isEmpty && !tab.filter.sourceIDs.contains(candidate.item.sourceID) { return false }
            let text = "\(candidate.item.title) \(candidate.item.summary ?? "")".lowercased()
            if tab.filter.excludedWords.contains(where: { text.contains($0.lowercased()) }) { return false }
            if !tab.filter.includedWords.isEmpty && !tab.filter.includedWords.contains(where: { text.contains($0.lowercased()) }) { return false }
            return true
        }
        switch tab.kind {
        case .sourceBoard, .aggregate, .topic:
            let rows = scoped.map { stored in
                AggregatedRow(stored: stored, score: RankFusion.score(rank: stored.item.rank, age: now.timeIntervalSince(stored.lastSeenAt)), movement: RankFusion.movement(current: stored.item.rank, previous: stored.previousRank))
            }.sorted { lhs, rhs in
                switch tab.sort {
                case .newest: (lhs.stored.item.publishedAt ?? lhs.stored.firstSeenAt) > (rhs.stored.item.publishedAt ?? rhs.stored.firstSeenAt)
                case .sourceRank: (lhs.stored.item.rank ?? Int.max) < (rhs.stored.item.rank ?? Int.max)
                case .importance, .reciprocalRankFusion: lhs.score > rhs.score
                }
            }
            let coverage = tab.kind == .topic && tab.filter.semanticPrompt != nil ? "规则已匹配，语义结果由 AI 队列补充" : "已覆盖当前材料"
            return (rows, coverage)
        case .majorEvents, .trackedEvents:
            let allowed = events.filter { event in
                if tab.blockedEventIDs.contains(event.id) { return false }
                if tab.kind == .trackedEvents { return tab.trackedEventIDs.contains(event.id) }
                let authoritative = event.itemIDs.contains { id in
                    items.contains { $0.id == id && tab.filter.authoritativeSourceIDs.contains($0.item.sourceID) }
                }
                let passes = (event.importance ?? 0) >= tab.filter.minimumImportance && (event.confidence ?? 0) >= tab.filter.minimumConfidence && (event.independentSourceCount >= tab.filter.minimumIndependentSources || authoritative)
                return event.status == "major" && passes
            }.sorted { ($0.importance ?? 0, $0.updatedAt) > ($1.importance ?? 0, $1.updatedAt) }
            let rows = allowed.compactMap { event -> AggregatedRow? in
                guard let stored = items.first(where: { event.itemIDs.contains($0.id) }) else { return nil }
                return AggregatedRow(stored: stored, score: Double(event.importance ?? 0), movement: event.category)
            }
            let pending = events.contains { $0.status == "pending-analysis" }
            return (rows, pending ? "部分内容待分析" : (rows.isEmpty ? "没有匹配内容" : "已覆盖当前材料"))
        }
    }

    public static func snapshot(tabs: [TabDefinition], profiles: [WidgetProfile], items: [StoredItem], events: [EventCluster], statuses: [SourceStatus], sources: [SourceDescriptor], unread: Int, generation: Int, now: Date, lifetime: TimeInterval = 1800) -> WidgetSnapshot {
        let rendered = tabs.filter { !$0.hidden }.map { tab in
            let result = rows(tab: tab, items: items, events: events, sources: sources, now: now)
            let names = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.title) })
            return SnapshotTab(
                id: tab.id,
                title: tab.title,
                kind: tab.kind,
                rows: result.rows.prefix(30).map { row in
                    SnapshotRow(id: row.stored.id, title: row.stored.item.title, sourceTitle: names[row.stored.item.sourceID] ?? row.stored.item.sourceID, rank: row.stored.item.rank, movement: row.movement, url: row.stored.item.url, eventID: events.first { $0.itemIDs.contains(row.stored.id) }?.id, publishedAt: row.stored.item.publishedAt, score: row.score, expiresAt: row.stored.lastSeenAt.addingTimeInterval(min(lifetime, tab.filter.timeWindow)))
                },
                coverage: result.coverage,
                updatedAt: result.rows.map(\.stored.lastSeenAt).max(),
                expiresAt: result.rows.map(\.stored.lastSeenAt).max().map {
                    $0.addingTimeInterval(min(lifetime, tab.filter.timeWindow))
                }
            )
        }
        return WidgetSnapshot(generation: generation, generatedAt: now, profiles: profiles, tabs: rendered, statuses: statuses, unreadCount: unread)
    }
}

public enum EventGrouper {
    public static func group(_ items: [StoredItem], now: Date) -> [EventCluster] {
        var clusters: [EventCluster] = []
        for stored in items.sorted(by: { $0.lastSeenAt > $1.lastSeenAt }) {
            let tokens = Set(tokenize(stored.item.title))
            if let index = clusters.firstIndex(where: { cluster in
                let existing = Set(tokenize(cluster.title))
                let overlap = Double(existing.intersection(tokens).count) / Double(max(1, min(existing.count, tokens.count)))
                return overlap >= 0.6 && now.timeIntervalSince(cluster.updatedAt) < 48 * 3600
            }) {
                var cluster = clusters[index]
                if !cluster.itemIDs.contains(stored.id) { cluster.itemIDs.append(stored.id) }
                cluster.independentSourceCount = Set(cluster.itemIDs.map { $0.split(separator: ":").first.map(String.init) ?? $0 }).count
                cluster.updatedAt = max(cluster.updatedAt, stored.lastSeenAt)
                cluster.materialFingerprint = cluster.itemIDs.sorted().joined(separator: "|").sha256Prefix
                clusters[index] = cluster
            } else {
                clusters.append(EventCluster(title: stored.item.title, itemIDs: [stored.id], independentSourceCount: 1, materialFingerprint: stored.id.sha256Prefix, updatedAt: stored.lastSeenAt, createdAt: stored.firstSeenAt))
            }
        }
        return clusters
    }

    private static func tokenize(_ title: String) -> [String] {
        title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
    }
}
