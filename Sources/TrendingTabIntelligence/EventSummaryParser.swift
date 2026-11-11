import Foundation
import TrendingTabCore

public enum EventSummaryParser {
    public static func parse(_ text: String, allowedEvidence: Set<String>) throws -> String {
        struct Payload: Decodable { let summary: String; let evidenceIDs: [String] }
        let payload = try JSONDecoder().decode(Payload.self, from: ModelJSON.data(text))
        let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 8_000, !payload.evidenceIDs.isEmpty,
              Set(payload.evidenceIDs).isSubset(of: allowedEvidence) else {
            throw SourceFailure.unavailable("摘要引用无效。")
        }
        return summary
    }
}
