import Foundation
import TrendingTabCore

public enum SnapshotStore {
    public static func snapshotURL(fileManager: FileManager = .default) -> URL {
        TrendingPaths.sharedDirectory(fileManager: fileManager).appendingPathComponent("widget-snapshot.json")
    }

    public static func selectionURL(fileManager: FileManager = .default) -> URL {
        TrendingPaths.sharedDirectory(fileManager: fileManager).appendingPathComponent("widget-selection.json")
    }

    public static func write(_ snapshot: WidgetSnapshot, fileManager: FileManager = .default) throws {
        let directory = snapshotURL(fileManager: fileManager).deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("widget-snapshot-\(UUID().uuidString).tmp")
        try TrendingJSON.data(snapshot).write(to: temporary, options: .atomic)
        let destination = snapshotURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    public static func read(fileManager: FileManager = .default) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(fileManager: fileManager)) else { return nil }
        return try? TrendingJSON.value(WidgetSnapshot.self, from: data)
    }

    public static func updateSelection(profileID: UUID, tabID: UUID?, page: Int?, fileManager: FileManager = .default) throws -> WidgetSelection {
        let url = selectionURL(fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result = WidgetSelection(profileID: profileID, tabID: tabID, page: page ?? 0, generation: 1)
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinated in
            do {
                let current = (try? Data(contentsOf: coordinated)).flatMap { try? TrendingJSON.value(WidgetSelection.self, from: $0) }
                let snapshot = read(fileManager: fileManager)
                let profile = snapshot?.profiles.first { $0.id == profileID } ?? snapshot?.profiles.first
                let resolvedProfile = profile?.id ?? profileID
                let validTabs = snapshot?.tabs.map(\.id) ?? []
                let requested = tabID ?? current?.tabID ?? profile?.defaultTabID
                let resolvedTab = validTabs.contains(requested ?? UUID()) ? requested : validTabs.first
                let count = snapshot?.tabs.first { $0.id == resolvedTab }?.rows.count ?? 0
                let requestedPage = page ?? current?.page ?? 0
                let resolvedPage = max(0, min(requestedPage, max(0, count - 1)))
                result = WidgetSelection(profileID: resolvedProfile, tabID: resolvedTab, page: resolvedPage, generation: (current?.generation ?? 0) + 1)
                try TrendingJSON.data(result).write(to: coordinated, options: .atomic)
            } catch {
                operationError = error
            }
        }
        if let error = operationError ?? coordinationError { throw error }
        return result
    }

    public static func selection(fileManager: FileManager = .default) -> WidgetSelection? {
        guard let data = try? Data(contentsOf: selectionURL(fileManager: fileManager)) else { return nil }
        return try? TrendingJSON.value(WidgetSelection.self, from: data)
    }
}
