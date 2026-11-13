import Foundation
import TrendingTabCore

public enum EventSummaryParser {
    public static func parse(_ text: String, allowedEvidence: Set<String>) throws -> String {
        try parseBrief(text, allowedEvidence: allowedEvidence).overview
    }

    public static func parseBrief(_ text: String, allowedEvidence: Set<String>) throws -> EventBrief {
        struct Payload: Decodable {
            let summary: String
            let importanceAnalysis: String?
            let openQuestions: [String]?
            let evidenceIDs: [String]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: ModelJSON.data(text))
        let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 8_000, !payload.evidenceIDs.isEmpty,
              Set(payload.evidenceIDs).isSubset(of: allowedEvidence) else {
            throw SourceFailure.unavailable("摘要引用无效。")
        }
        let importance = payload.importanceAnalysis?.trimmingCharacters(in: .whitespacesAndNewlines)
        let openQuestions = (payload.openQuestions ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return EventBrief(overview: summary, importanceAnalysis: importance?.isEmpty == false ? importance : nil,
                          openQuestions: openQuestions, evidenceIDs: Array(Set(payload.evidenceIDs)).sorted())
    }
}
