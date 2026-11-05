import AppIntents
import Foundation
import TrendingTabCore
import TrendingTabWidgetBridge
import WidgetKit

struct BoardOption: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "榜单")
    static let defaultQuery = BoardQuery()

    var id: String
    var title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct BoardQuery: EntityQuery {
    func defaultResult() async throws -> BoardOption? {
        options().first
    }

    func entities(for identifiers: [BoardOption.ID]) async throws -> [BoardOption] {
        options().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [BoardOption] {
        options()
    }

    private func options() -> [BoardOption] {
        guard let snapshot = SnapshotStore.read() else { return [] }
        let tabs = snapshot.tabs
        let orderedIDs = snapshot.profiles.first?.orderedTabIDs ?? tabs.map(\.id)
        let ordered = orderedIDs.compactMap { id in tabs.first { $0.id == id } }
        return (ordered.isEmpty ? tabs : ordered).map {
            BoardOption(id: $0.id.uuidString, title: $0.title)
        }
    }
}

struct BoardConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "热榜"
    static let description = IntentDescription("选择默认榜单。多个可切换组件请选择不同的独立配置。")

    @Parameter(title: "默认榜单") var board: BoardOption?
    @Parameter(title: "固定榜单", default: false) var fixedBoard: Bool
    @Parameter(title: "独立配置", default: .one) var slot: WidgetSlot

    init() {
        fixedBoard = false
        slot = .one
    }

    func resolvedID(_ context: TimelineProviderContext) -> String {
        let boardKey = board?.id ?? "current"
        let mode = fixedBoard ? "fixed" : "dynamic"
        return "widget-\(mode)-\(boardKey)-\(slot.rawValue)"
    }
}

enum WidgetSlot: String, AppEnum {
    case one, two, three, four, five, six, seven, eight

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "独立配置")
    static let caseDisplayRepresentations: [WidgetSlot: DisplayRepresentation] = [
        .one: "组件 1", .two: "组件 2", .three: "组件 3", .four: "组件 4",
        .five: "组件 5", .six: "组件 6", .seven: "组件 7", .eight: "组件 8",
    ]
}

struct OpenItemIntent: AppIntent {
    static let title: LocalizedStringResource = "打开热榜事件"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "条目") var itemID: String
    @Parameter(title: "事件") var eventID: String

    init() {
        itemID = ""
        eventID = ""
    }

    init(itemID: String, eventID: String) {
        self.itemID = itemID
        self.eventID = eventID
    }

    func perform() async throws -> some IntentResult {
        guard !itemID.isEmpty || !eventID.isEmpty else { return .result() }
        try SnapshotStore.recordOpenedItem(
            itemID,
            eventID: UUID(uuidString: eventID)
        )
        return .result()
    }
}

struct ChooseTabIntent: AppIntent {
    static let title: LocalizedStringResource = "选择热榜标签"
    static let isDiscoverable = false

    @Parameter(title: "配置") var profileID: String
    @Parameter(title: "小组件") var widgetID: String
    @Parameter(title: "标签") var tabID: String

    init() {
        profileID = ""
        widgetID = "shared"
        tabID = ""
    }

    init(profileID: String, widgetID: String, tabID: String) {
        self.profileID = profileID
        self.widgetID = widgetID
        self.tabID = tabID
    }

    func perform() async throws -> some IntentResult {
        guard let profileID = UUID(uuidString: profileID), let tabID = UUID(uuidString: tabID) else {
            return .result()
        }
        _ = try SnapshotStore.updateSelection(
            profileID: profileID,
            widgetID: widgetID,
            tabID: tabID,
            page: 0
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "TrendingTab")
        return .result()
    }
}

struct SelectTabIntent: AppIntent {
    static let title: LocalizedStringResource = "切换热榜标签"
    static let isDiscoverable = false

    @Parameter(title: "配置") var profileID: String
    @Parameter(title: "小组件") var widgetID: String
    @Parameter(title: "方向") var direction: Int
    @Parameter(title: "当前标签") var currentTabID: String

    init() {
        profileID = ""
        widgetID = "shared"
        direction = 1
        currentTabID = ""
    }

    init(profileID: String, widgetID: String, direction: Int, currentTabID: String = "") {
        self.profileID = profileID
        self.widgetID = widgetID
        self.direction = direction
        self.currentTabID = currentTabID
    }

    func perform() async throws -> some IntentResult {
        guard let profileID = UUID(uuidString: profileID), let snapshot = SnapshotStore.read() else {
            return .result()
        }
        let profile = snapshot.profiles.first { $0.id == profileID } ?? snapshot.profiles.first
        let tabs = profile?.orderedTabIDs.compactMap { id in
            snapshot.tabs.first { $0.id == id }
        } ?? snapshot.tabs
        guard !tabs.isEmpty else { return .result() }

        let remembered = SnapshotStore.selection(widgetID: widgetID)
        let currentID = WidgetSelection.resolvedTabID(
            available: tabs.map(\.id),
            preferred: [remembered?.tabID, UUID(uuidString: currentTabID), profile?.defaultTabID]
        )
        let currentIndex = tabs.firstIndex { $0.id == currentID } ?? 0
        let nextIndex = (currentIndex + direction + tabs.count) % tabs.count
        _ = try SnapshotStore.updateSelection(
            profileID: profile?.id ?? profileID,
            widgetID: widgetID,
            tabID: tabs[nextIndex].id,
            page: 0
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "TrendingTab")
        return .result()
    }
}
