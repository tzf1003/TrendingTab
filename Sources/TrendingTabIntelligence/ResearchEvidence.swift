import CryptoKit
import Foundation
import TrendingTabCore

public struct ResearchEvidence: Identifiable, Equatable, Sendable {
    public enum Level: String, Sendable { case pageText = "页面可见文字", publicArticle = "匿名网页提取文字", searchSnippet = "搜索摘要", feedTitle = "榜单标题" }
    public let id: String
    public let itemID: String
    public let runID: String
    public let title: String
    public let url: URL
    public let level: Level
    public let capturedAt: Date
    public let contentFingerprint: String
    public let excerpt: String
}

/// In-memory evidence scoped to the conversation. A citation is usable only for its own item.
public struct ResearchEvidenceLedger: Sendable {
    public private(set) var records: [ResearchEvidence] = []
    private var nextID = 1

    public init() {}

    public mutating func remove(itemID: String) {
        records.removeAll { $0.itemID == itemID }
    }

    @discardableResult
    public mutating func register(itemID: String, runID: String, title: String, url: URL,
                                  level: ResearchEvidence.Level, content: String, excerpt: String? = nil, now: Date = .now) -> ResearchEvidence {
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        let record = ResearchEvidence(id: "E\(nextID)", itemID: itemID, runID: runID, title: title,
                                      url: url, level: level, capturedAt: now, contentFingerprint: digest,
                                      excerpt: String((excerpt ?? content).prefix(2_000)))
        nextID += 1
        records.append(record)
        return record
    }

    /// Carries previously read material into a follow-up without mixing conversations.
    /// The bounded text is kept in memory with the ledger and discarded with the session.
    public func followUpContext(itemID: String) -> String {
        let recent = records.filter { $0.itemID == itemID }.suffix(20)
        var blocks: [String] = []
        var remaining = 12_000
        for record in recent.reversed() {
            let header = "[\(record.id)] \(String(record.title.prefix(300)))\n材料类型：\(record.level.rawValue)\n来源：\(AIVisibleAddress.string(for: record.url))\n获取时间：\(record.capturedAt.ISO8601Format())\n以下为有限摘录："
            guard remaining > header.count + 2 else { break }
            let excerpt = String(record.excerpt.prefix(remaining - header.count - 2))
            let block = header + excerpt
            blocks.append(block)
            remaining -= block.count + 2
        }
        return blocks.reversed().joined(separator: "\n\n")
    }

    public func citations(in text: String, itemID: String) -> (valid: [ResearchEvidence], unknown: [String]) {
        let pattern = #"\[(E[1-9][0-9]*)\]|【(E[1-9][0-9]*)】"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        var seen: Set<String> = []
        var valid: [ResearchEvidence] = []
        var unknown: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let range = Range(match.range(at: 1), in: text) ?? Range(match.range(at: 2), in: text) else { continue }
            let id = String(text[range])
            guard seen.insert(id).inserted else { continue }
            if let record = records.first(where: { $0.id == id && $0.itemID == itemID }) { valid.append(record) }
            else { unknown.append(id) }
        }
        return (valid, unknown)
    }
}
