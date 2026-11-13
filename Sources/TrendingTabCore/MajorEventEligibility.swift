import Foundation

/// The publication contract shared by the major-events list and notifications.
public enum MajorEventEligibility {
    public static func passes(_ event: EventCluster, filter: TabFilter) -> Bool {
        event.status == "major" && qualifies(importance: event.importance, confidence: event.confidence,
                                              citedSources: Set(event.assessmentSourceIDs ?? []), filter: filter)
    }

    public static func qualifies(importance: Int?, confidence: Double?, citedSources: Set<String>, filter: TabFilter) -> Bool {
        (importance ?? 0) >= filter.minimumImportance && (confidence ?? 0) >= filter.minimumConfidence &&
            (citedSources.count >= filter.minimumIndependentSources || !citedSources.isDisjoint(with: filter.authoritativeSourceIDs))
    }

    public static func meetsAssessmentThresholds(_ event: EventCluster, filter: TabFilter) -> Bool {
        (event.importance ?? 0) >= filter.minimumImportance && (event.confidence ?? 0) >= filter.minimumConfidence
    }

    public static func hasRequiredEvidence(_ event: EventCluster, filter: TabFilter) -> Bool {
        let citedSources = Set(event.assessmentSourceIDs ?? [])
        return citedSources.count >= filter.minimumIndependentSources || !citedSources.isDisjoint(with: filter.authoritativeSourceIDs)
    }
}
