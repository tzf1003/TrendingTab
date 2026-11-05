import Foundation
import TrendingTabCore

public struct OpenedItemTarget: Codable, Equatable, Sendable {
    public var itemID: String?
    public var eventID: UUID?

    public init(itemID: String? = nil, eventID: UUID? = nil) {
        self.itemID = itemID
        self.eventID = eventID
    }
}

public enum SnapshotStore {
    public static func snapshotURL(fileManager: FileManager = .default, directory: URL? = nil) -> URL {
        sharedDirectory(fileManager: fileManager, directory: directory)
            .appendingPathComponent("widget-snapshot.json")
    }

    public static func selectionURL(fileManager: FileManager = .default, directory: URL? = nil) -> URL {
        sharedDirectory(fileManager: fileManager, directory: directory)
            .appendingPathComponent("widget-selection.json")
    }

    public static func selectionsURL(fileManager: FileManager = .default, directory: URL? = nil) -> URL {
        sharedDirectory(fileManager: fileManager, directory: directory)
            .appendingPathComponent("widget-selections.json")
    }

    public static func openedItemURL(fileManager: FileManager = .default, directory: URL? = nil) -> URL {
        sharedDirectory(fileManager: fileManager, directory: directory)
            .appendingPathComponent("widget-opened-item.txt")
    }

    public static func write(
        _ snapshot: WidgetSnapshot,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) throws {
        let parent = snapshotURL(fileManager: fileManager, directory: directory).deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent("widget-snapshot-\(UUID().uuidString).tmp")
        try TrendingJSON.data(snapshot).write(to: temporary, options: .atomic)
        let destination = snapshotURL(fileManager: fileManager, directory: directory)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    public static func read(fileManager: FileManager = .default, directory: URL? = nil) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(fileManager: fileManager, directory: directory)) else { return nil }
        return try? TrendingJSON.value(WidgetSnapshot.self, from: data)
    }

    public static func updateSelection(
        profileID: UUID,
        widgetID: String = "shared",
        tabID: UUID?,
        page: Int?,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) throws -> WidgetSelection {
        let url = selectionsURL(fileManager: fileManager, directory: directory)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result = WidgetSelection(profileID: profileID, tabID: tabID, page: page ?? 0, generation: 1)
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinated in
            do {
                var selections = (try? Data(contentsOf: coordinated)).flatMap { try? TrendingJSON.value([String: WidgetSelection].self, from: $0) } ?? [:]
                let current = selections[widgetID]
                let snapshot = read(fileManager: fileManager, directory: directory)
                let profile = snapshot?.profiles.first { $0.id == profileID } ?? snapshot?.profiles.first
                let resolvedProfile = profile?.id ?? profileID
                let validTabs = snapshot?.tabs.map(\.id) ?? []
                let requested = tabID ?? current?.tabID ?? profile?.defaultTabID
                let resolvedTab = validTabs.contains(requested ?? UUID()) ? requested : validTabs.first
                let count = snapshot?.tabs.first { $0.id == resolvedTab }?.rows.count ?? 0
                let requestedPage = page ?? current?.page ?? 0
                let resolvedPage = max(0, min(requestedPage, max(0, count - 1)))
                result = WidgetSelection(profileID: resolvedProfile, tabID: resolvedTab, page: resolvedPage, generation: (current?.generation ?? 0) + 1)
                selections[widgetID] = result
                try TrendingJSON.data(selections).write(to: coordinated, options: .atomic)
            } catch {
                operationError = error
            }
        }
        if let error = operationError ?? coordinationError { throw error }
        return result
    }

    public static func selection(fileManager: FileManager = .default, directory: URL? = nil) -> WidgetSelection? {
        let stored = selections(fileManager: fileManager, directory: directory)
        if let current = stored["shared"] { return current }
        return legacySelection(fileManager: fileManager, directory: directory)
    }

    public static func selection(
        widgetID: String,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) -> WidgetSelection? {
        let stored = selections(fileManager: fileManager, directory: directory)
        if let current = stored[widgetID] { return current }
        return widgetID == "shared" ? legacySelection(fileManager: fileManager, directory: directory) : nil
    }

    public static func selections(fileManager: FileManager = .default, directory: URL? = nil) -> [String: WidgetSelection] {
        guard let data = try? Data(contentsOf: selectionsURL(fileManager: fileManager, directory: directory)) else { return [:] }
        return (try? TrendingJSON.value([String: WidgetSelection].self, from: data)) ?? [:]
    }

    public static func recordOpenedItem(
        _ itemID: String,
        eventID: UUID? = nil,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) throws {
        let url = openedItemURL(fileManager: fileManager, directory: directory)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TrendingJSON.data(OpenedItemTarget(itemID: itemID, eventID: eventID)).write(to: url, options: .atomic)
    }

    public static func consumeOpenedTarget(fileManager: FileManager = .default, directory: URL? = nil) -> OpenedItemTarget? {
        let url = openedItemURL(fileManager: fileManager, directory: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? fileManager.removeItem(at: url)
        if let target = try? TrendingJSON.value(OpenedItemTarget.self, from: data) {
            return target
        }
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return OpenedItemTarget(itemID: value)
    }

    public static func consumeOpenedItem(fileManager: FileManager = .default, directory: URL? = nil) -> String? {
        consumeOpenedTarget(fileManager: fileManager, directory: directory)?.itemID
    }

    private static func legacySelection(fileManager: FileManager = .default, directory: URL? = nil) -> WidgetSelection? {
        guard let data = try? Data(contentsOf: selectionURL(fileManager: fileManager, directory: directory)) else { return nil }
        return try? TrendingJSON.value(WidgetSelection.self, from: data)
    }

    private static func sharedDirectory(fileManager: FileManager, directory: URL?) -> URL {
        directory ?? TrendingPaths.sharedDirectory(fileManager: fileManager)
    }
}
