import Foundation
import TrendingTabCore

public struct AggregatedRow: Equatable, Sendable {
    public var stored: StoredItem
    public var score: Double
    public var movement: String?
    public var event: EventCluster?

    public init(stored: StoredItem, score: Double, movement: String?, event: EventCluster? = nil) {
        self.stored = stored
        self.score = score
        self.movement = movement
        self.event = event
    }
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
    /// The caller supplies decisions only for the current rule, model and content identity.
    public static func scopedItems(tab: TabDefinition, items: [StoredItem], sources: [SourceDescriptor], now: Date) -> [StoredItem] {
        let categories = Dictionary(sources.map { ($0.id, $0.category) }, uniquingKeysWith: { first, _ in first })
        return items.filter { candidate in
            let age = now.timeIntervalSince(candidate.lastSeenAt)
            guard age <= tab.filter.timeWindow, !candidate.historical else { return false }
            if !tab.boardIDs.isEmpty && !tab.boardIDs.contains(candidate.item.boardID) { return false }
            if !tab.filter.sourceIDs.isEmpty && !tab.filter.sourceIDs.contains(candidate.item.sourceID) { return false }
            if !tab.filter.categories.isEmpty {
                guard let category = categories[candidate.item.sourceID], tab.filter.categories.contains(category) else { return false }
            }
            let text = "\(candidate.item.title) \(candidate.item.summary ?? "")".lowercased()
            if tab.filter.excludedWords.contains(where: { text.contains($0.lowercased()) }) { return false }
            if !tab.filter.includedWords.isEmpty && !tab.filter.includedWords.contains(where: { text.contains($0.lowercased()) }) { return false }
            return true
        }
    }

    public static func rows(tab: TabDefinition, items: [StoredItem], events: [EventCluster], sources: [SourceDescriptor], now: Date, semanticDecisions: [String: Bool] = [:]) -> (rows: [AggregatedRow], coverage: String) {
        let scoped = scopedItems(tab: tab, items: items, sources: sources, now: now)
        switch tab.kind {
        case .sourceBoard, .aggregate, .topic:
            let semantic = tab.kind == .topic && tab.filter.semanticPrompt?.trimmedNonEmpty() != nil
            let included = semantic ? scoped.filter { semanticDecisions[$0.id] == true } : scoped
            let rows = included.map { stored in
                AggregatedRow(stored: stored, score: RankFusion.score(rank: stored.item.rank, age: now.timeIntervalSince(stored.lastSeenAt)), movement: RankFusion.movement(current: stored.item.rank, previous: stored.previousRank))
            }.sorted { lhs, rhs in
                switch tab.sort {
                case .newest: (lhs.stored.item.publishedAt ?? lhs.stored.firstSeenAt) > (rhs.stored.item.publishedAt ?? rhs.stored.firstSeenAt)
                case .sourceRank: (lhs.stored.item.rank ?? Int.max) < (rhs.stored.item.rank ?? Int.max)
                case .importance, .reciprocalRankFusion: lhs.score > rhs.score
                }
            }
            let pending = semantic && scoped.contains { semanticDecisions[$0.id] == nil }
            let coverage = pending ? "部分内容待分析" : (rows.isEmpty ? "没有匹配内容" : "已覆盖当前材料")
            return (rows, coverage)
        case .majorEvents, .trackedEvents:
            let allowed = events.filter { event in
                if tab.blockedEventIDs.contains(event.id) { return false }
                if tab.kind == .trackedEvents { return tab.trackedEventIDs.contains(event.id) }
                return MajorEventEligibility.passes(event, filter: tab.filter)
            }.sorted { ($0.importance ?? 0, $0.updatedAt) > ($1.importance ?? 0, $1.updatedAt) }
            let rows = allowed.compactMap { event -> AggregatedRow? in
                guard let stored = items.first(where: { event.itemIDs.contains($0.id) }) else { return nil }
                return AggregatedRow(stored: stored, score: Double(event.importance ?? 0), movement: event.category, event: event)
            }
            let pending = events.contains { $0.status == "pending-analysis" }
            return (rows, pending ? "部分内容待分析" : (rows.isEmpty ? "没有匹配内容" : "已覆盖当前材料"))
        }
    }

    public static func snapshot(tabs: [TabDefinition], profiles: [WidgetProfile], items: [StoredItem], events: [EventCluster], statuses: [SourceStatus], sources: [SourceDescriptor], unread: Int, generation: Int, now: Date, lifetime: TimeInterval = 1800, semanticDecisions: [UUID: [String: Bool]] = [:]) -> WidgetSnapshot {
        let rendered = tabs.filter { !$0.hidden }.map { tab in
            let result = rows(tab: tab, items: items, events: events, sources: sources, now: now, semanticDecisions: semanticDecisions[tab.id] ?? [:])
            let names = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.title) })
            return SnapshotTab(
                id: tab.id,
                title: tab.title,
                kind: tab.kind,
                rows: result.rows.prefix(30).map { row in
                    if let event = row.event {
                        return SnapshotRow(id: "event:\(event.id.uuidString)", title: event.title, sourceTitle: "重大事件", rank: nil,
                                           movement: row.movement, url: nil, eventID: event.id, publishedAt: event.updatedAt,
                                           score: row.score, expiresAt: event.updatedAt.addingTimeInterval(min(lifetime, tab.filter.timeWindow)))
                    }
                    return SnapshotRow(id: row.stored.id, title: row.stored.item.title, sourceTitle: names[row.stored.item.sourceID] ?? row.stored.item.sourceID, rank: row.stored.item.rank, movement: row.movement, url: row.stored.item.url, eventID: events.first { $0.itemIDs.contains(row.stored.id) }?.id, publishedAt: row.stored.item.publishedAt, score: row.score, expiresAt: row.stored.lastSeenAt.addingTimeInterval(min(lifetime, tab.filter.timeWindow)))
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
    public static func isPersonnelChange(_ title: String) -> Bool {
        personnelChange(in: title) != nil
    }

    public static func group(_ items: [StoredItem], now: Date) -> [EventCluster] {
        var clusters: [EventCluster] = []
        let titleTokens = Dictionary(items.map { ($0.item.title, Set(tokenize($0.item.title))) }, uniquingKeysWith: { first, _ in first })
        for stored in items.sorted(by: { ($0.lastSeenAt, $0.id) > ($1.lastSeenAt, $1.id) }) {
            let tokens = titleTokens[stored.item.title] ?? []
            let hasChinese = stored.item.title.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
            let numbers = Set(tokens.filter { $0.allSatisfy(\.isNumber) })
            if let index = clusters.firstIndex(where: { cluster in
                let existing = titleTokens[cluster.title] ?? []
                let shared = existing.intersection(tokens).count
                let overlap = Double(shared) / Double(max(1, min(existing.count, tokens.count)))
                let coverage = Double(shared) / Double(max(1, max(existing.count, tokens.count)))
                let exact = cluster.title.lowercased() == stored.item.title.lowercased()
                // Short Chinese fragments alone do not identify an event.
                let enough = !hasChinese || shared >= 3
                let existingNumbers = Set(existing.filter { $0.allSatisfy(\.isNumber) })
                let compatibleNumbers = numbers.isEmpty || existingNumbers.isEmpty || numbers == existingNumbers
                let titleMatch = exact || (enough && compatibleNumbers && overlap >= 0.6 && coverage >= 0.45)
                let personnel = personnelRelationship(cluster.title, stored.item.title)
                let eligibleTitleMatch = titleMatch && personnel != .conflict
                return (eligibleTitleMatch || personnel == .same) && now.timeIntervalSince(cluster.updatedAt) < 48 * 3600
            }) {
                var cluster = clusters[index]
                if !cluster.itemIDs.contains(stored.id) { cluster.itemIDs.append(stored.id) }
                cluster.updatedAt = max(cluster.updatedAt, stored.lastSeenAt)
                cluster.groupingReason = personnelRelationship(cluster.title, stored.item.title) == .same
                    ? "人事变动主体与动作一致"
                    : "标题相似"
                clusters[index] = cluster
            } else {
                clusters.append(EventCluster(title: stored.item.title, itemIDs: [stored.id], independentSourceCount: 1,
                                             groupingReason: "单条报道", materialFingerprint: stored.id.sha256Prefix,
                                             updatedAt: stored.lastSeenAt, createdAt: stored.firstSeenAt))
            }
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return clusters.map { cluster in
            var result = cluster
            let reports = cluster.itemIDs.sorted().compactMap { byID[$0] }
            result.independentSourceCount = Set(reports.map { $0.item.sourceID }).count
            result.materialFingerprint = reports.map { "\($0.id)\u{0}\($0.contentHash)" }.joined(separator: "\u{0}").sha256Prefix
            return result
        }
    }

    private static func tokenize(_ title: String) -> [String] {
        let text = title.lowercased()
        let pattern = "[\\x{3400}-\\x{9FFF}]+|[a-z]+|[0-9]+"
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { match -> [String] in
            let word = String(text[Range(match.range, in: text)!])
            guard let first = word.unicodeScalars.first, (0x3400...0x9FFF).contains(first.value) else {
                return word.count >= 2 || word.allSatisfy(\.isNumber) ? [word] : []
            }
            let characters = Array(word)
            guard characters.count > 1 else { return [] }
            return zip(characters, characters.dropFirst()).map { String([$0, $1]) }
        }
    }

    private enum PersonnelRelationship {
        case unrelated, same, conflict
    }

    private static func personnelRelationship(_ lhs: String, _ rhs: String) -> PersonnelRelationship {
        guard let left = personnelChange(in: lhs), let right = personnelChange(in: rhs),
              !left.actions.isDisjoint(with: right.actions) else {
            return .unrelated
        }
        return left.subject == right.subject ? .same : .conflict
    }

    private static func personnelChange(in title: String) -> (subject: String, actions: Set<String>)? {
        let actions = [
            ("resignation", ["引咎辞职", "辞去职务", "辞去", "辞职", "辞任"]),
            ("departure", ["任期届满", "卸任", "离任"]),
            ("appointment", ["任命", "就任", "接任"]),
        ]
        let matches = actions.compactMap { family, words -> (String, Range<String.Index>)? in
            words.compactMap { word in title.range(of: word).map { (family, $0) } }
                .min { $0.1.lowerBound < $1.1.lowerBound }
        }
        guard let first = matches.min(by: { $0.1.lowerBound < $1.1.lowerBound }) else { return nil }
        var actionFamilies = Set(matches.map(\.0))
        if actionFamilies.contains("resignation") || actionFamilies.contains("departure") {
            actionFamilies.insert("exit")
        }
        let prefix = String(title[..<first.1.lowerBound])
        let subject = prefix
            .replacingOccurrences(of: "宣布", with: "")
            .replacingOccurrences(of: "正式", with: "")
            .replacingOccurrences(of: "将", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard subject.count >= 2, subject.count <= 32 else { return nil }
        return (subject, actionFamilies)
    }
}
