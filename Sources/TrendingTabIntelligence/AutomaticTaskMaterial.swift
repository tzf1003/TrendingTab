import Foundation
import TrendingTabCore

/// A delayed result is usable only while all of its source material remains current.
public enum AutomaticTaskMaterial {
    public static func isCurrent(_ original: [StoredItem], in current: [StoredItem], cutoff: Date) -> Bool {
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return !original.isEmpty && original.allSatisfy { item in
            guard let fresh = byID[item.id] else { return false }
            return fresh.lastSeenAt >= cutoff && fresh.contentHash == item.contentHash && fresh.item.url == item.item.url
        }
    }

    public static func eventIsCurrent(_ event: EventCluster, in events: [EventCluster], items: [StoredItem], cutoff: Date) -> Bool {
        guard events.contains(where: { $0.id == event.id && $0.materialFingerprint == event.materialFingerprint }),
              !event.itemIDs.isEmpty else { return false }
        let freshIDs = Set(items.filter { $0.lastSeenAt >= cutoff }.map(\.id))
        return event.itemIDs.allSatisfy { freshIDs.contains($0) }
    }
}
