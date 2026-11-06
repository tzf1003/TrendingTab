import Foundation
import TrendingTabCore

public struct NotificationCandidate: Equatable, Sendable {
    public var event: EventCluster
    public var title: String
    public var body: String
    public var fingerprint: String
}

public enum AlertPolicy {
    public static func candidates(events: [EventCluster], tabs: [TabDefinition], now: Date) -> [NotificationCandidate] {
        let monitored = tabs.filter { $0.monitoringEnabled && $0.notification.enabled }
        var output: [UUID: NotificationCandidate] = [:]
        for event in events where event.status == "major" {
            let matching = monitored.filter { tab in
                guard !tab.blockedEventIDs.contains(event.id) else { return false }
                if tab.kind == .majorEvents {
                    let cited = Set(event.assessmentSourceIDs ?? [])
                    return (event.importance ?? 0) >= tab.filter.minimumImportance && (event.confidence ?? 0) >= tab.filter.minimumConfidence &&
                        (cited.count >= tab.filter.minimumIndependentSources || !cited.isDisjoint(with: tab.filter.authoritativeSourceIDs))
                }
                return tab.trackedEventIDs.contains(event.id) || tab.filter.includedWords.contains { event.title.localizedCaseInsensitiveContains($0) }
            }
            guard !matching.isEmpty else { continue }
            let fingerprint = "\(event.id.uuidString)|\(event.materialFingerprint)|\(event.importance ?? 0)".sha256Prefix
            output[event.id] = NotificationCandidate(event: event, title: event.title, body: event.summary ?? "有新的重要进展", fingerprint: fingerprint)
        }
        return Array(output.values)
    }

    public static func allows(_ policy: NotificationPolicy, now: Date, hourlyCount: Int, dailyCount: Int) -> Bool {
        guard policy.enabled else { return false }
        let hour = Calendar.current.component(.hour, from: now)
        let quiet = policy.quietHoursStart < policy.quietHoursEnd
            ? (hour >= policy.quietHoursStart && hour < policy.quietHoursEnd)
            : (hour >= policy.quietHoursStart || hour < policy.quietHoursEnd)
        return !quiet && hourlyCount < policy.hourlyLimit && dailyCount < policy.dailyLimit
    }
}
