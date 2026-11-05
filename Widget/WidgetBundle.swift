import AppIntents
import SwiftUI
import TrendingTabCore
import TrendingTabWidgetBridge
import WidgetKit

@main
struct TrendingWidgets: WidgetBundle {
    var body: some Widget {
        TrendingWidget()
    }
}

struct WidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var selection: WidgetSelection
    var widgetID: String
    var fixedBoard: Bool
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        entry(configuration: BoardConfigurationIntent(), context: context)
    }

    func snapshot(for configuration: BoardConfigurationIntent, in context: Context) async -> WidgetEntry {
        entry(configuration: configuration, context: context)
    }

    func timeline(for configuration: BoardConfigurationIntent, in context: Context) async -> Timeline<WidgetEntry> {
        Timeline(
            entries: [entry(configuration: configuration, context: context)],
            policy: .after(Date().addingTimeInterval(15 * 60))
        )
    }

    private func entry(configuration: BoardConfigurationIntent, context: Context) -> WidgetEntry {
        let snapshot = SnapshotStore.read() ?? WidgetSnapshot(
            generation: 0,
            generatedAt: .now,
            profiles: [],
            tabs: [],
            statuses: [],
            unreadCount: 0
        )
        let widgetID = configuration.resolvedID(context)
        let profile = snapshot.profiles.first ?? WidgetProfile(
            name: "默认",
            orderedTabIDs: snapshot.tabs.map(\.id),
            defaultTabID: snapshot.tabs.first?.id
        )
        let remembered = SnapshotStore.selection(widgetID: widgetID)
        let configuredTab = configuration.board.flatMap { UUID(uuidString: $0.id) }
        let requested = configuration.fixedBoard
            ? configuredTab
            : remembered?.tabID ?? configuredTab ?? profile.defaultTabID
        let validTab = snapshot.tabs.contains { $0.id == requested }
            ? requested
            : snapshot.tabs.first?.id
        let selection = WidgetSelection(
            profileID: profile.id,
            tabID: validTab,
            page: 0,
            generation: remembered?.generation ?? snapshot.generation
        )
        return WidgetEntry(
            date: snapshot.generatedAt,
            snapshot: snapshot,
            selection: selection,
            widgetID: widgetID,
            fixedBoard: configuration.fixedBoard
        )
    }
}

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
    static let description = IntentDescription("每个固定榜单的组件拥有独立标签；需要随箭头切换时关闭“固定此组件”。")

    @Parameter(title: "默认榜单") var board: BoardOption?
    @Parameter(title: "固定此组件", default: true) var fixedBoard: Bool

    init() {
        fixedBoard = true
    }

    func resolvedID(_ context: TimelineProviderContext) -> String {
        let boardKey = board?.id ?? "current"
        let mode = fixedBoard ? "fixed" : "dynamic"
        return "widget-\(mode)-\(boardKey)-\(context.family.rawValue)"
    }
}

struct TrendingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "TrendingTab",
            intent: BoardConfigurationIntent.self,
            provider: Provider()
        ) { entry in
            WidgetContent(entry: entry)
        }
        .configurationDisplayName("热榜")
        .description("固定为知乎、微博或任意榜单，让多个组件各自显示不同内容。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct WidgetContent: View {
    @Environment(\.widgetFamily) private var family
    var entry: WidgetEntry

    private var allTabs: [SnapshotTab] {
        let tabs = entry.snapshot.tabs
        guard let profile = entry.snapshot.profiles.first(where: { $0.id == entry.selection.profileID })
            ?? entry.snapshot.profiles.first else {
            return tabs
        }
        let ordered = profile.orderedTabIDs.compactMap { id in tabs.first { $0.id == id } }
        return ordered.isEmpty ? tabs : ordered
    }

    private var displayedTabs: [SnapshotTab] {
        if entry.fixedBoard, let id = entry.selection.tabID {
            return allTabs.filter { $0.id == id }
        }
        return allTabs
    }

    private var currentIndex: Int {
        max(0, displayedTabs.firstIndex { $0.id == entry.selection.tabID } ?? 0)
    }

    private var currentTab: SnapshotTab? {
        displayedTabs.indices.contains(currentIndex) ? displayedTabs[currentIndex] : displayedTabs.first
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = metrics(for: geometry.size)
            let rows = Array((currentTab?.rows ?? []).prefix(metrics.rowCount))
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                tabBar(metrics: metrics)
                if rows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentTab?.coverage ?? "等待首次采集")
                            .font(.system(size: metrics.fontSize, weight: .medium))
                        Text("打开 TrendingTab 立即刷新")
                            .font(.system(size: max(10, metrics.fontSize - 2)))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    rowGrid(rows, metrics: metrics)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 5, leading: 7, bottom: 6, trailing: 7))
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .containerBackground(for: .widget) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor), AppWidgetTheme.accent.opacity(0.045)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private func tabBar(metrics: WidgetMetrics) -> some View {
        let visibleCount = family == .systemSmall ? 1 : family == .systemMedium ? 3 : 5
        return HStack(spacing: 1) {
            if !entry.fixedBoard {
                pagerButton(direction: -1, enabled: allTabs.count > 1, size: metrics.fontSize)
            }

            if family == .systemSmall {
                Text(currentTab?.title ?? "热榜")
                    .font(.system(size: metrics.fontSize + 1, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(visibleTabs(around: currentIndex, count: visibleCount)) { tab in
                    if entry.fixedBoard {
                        Text(tab.title)
                            .font(.system(size: metrics.fontSize, weight: .semibold))
                            .foregroundStyle(AppWidgetTheme.accent)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AppWidgetTheme.accent.opacity(0.12), in: Capsule())
                    } else {
                        Button(intent: ChooseTabIntent(
                            profileID: entry.selection.profileID.uuidString,
                            widgetID: entry.widgetID,
                            tabID: tab.id.uuidString
                        )) {
                            Text(tab.title)
                                .font(.system(size: metrics.fontSize, weight: .semibold))
                                .foregroundStyle(tab.id == currentTab?.id ? AppWidgetTheme.accent : Color.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    tab.id == currentTab?.id ? AppWidgetTheme.accent.opacity(0.12) : Color.clear,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }

            if !entry.fixedBoard {
                pagerButton(direction: 1, enabled: allTabs.count > 1, size: metrics.fontSize)
            }
        }
        .frame(height: metrics.headerHeight)
    }

    private func rowGrid(_ rows: [SnapshotRow], metrics: WidgetMetrics) -> some View {
        let split = splitRows(rows, columns: metrics.columnCount)
        return HStack(alignment: .top, spacing: metrics.columnSpacing) {
            ForEach(Array(split.enumerated()), id: \.offset) { _, columnRows in
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    ForEach(columnRows) { row in
                        rowView(row, metrics: metrics)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func rowView(_ row: SnapshotRow, metrics: WidgetMetrics) -> some View {
        Button(intent: OpenItemIntent(
            itemID: row.id,
            eventID: row.eventID?.uuidString ?? ""
        )) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.title)
                    .font(.system(size: metrics.fontSize, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let movement = row.movement, !movement.isEmpty {
                    Text(movement)
                        .font(.system(size: max(9, metrics.fontSize - 3), weight: .semibold))
                        .foregroundStyle(AppWidgetTheme.accent)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: metrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pagerButton(direction: Int, enabled: Bool, size: CGFloat) -> some View {
        Button(intent: SelectTabIntent(
            profileID: entry.selection.profileID.uuidString,
            widgetID: entry.widgetID,
            direction: direction
        )) {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: max(10, size - 2), weight: .bold))
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
    }

    private func visibleTabs(around index: Int, count: Int) -> [SnapshotTab] {
        guard !displayedTabs.isEmpty else { return [] }
        let start = min(max(0, index - count / 2), max(0, displayedTabs.count - count))
        return Array(displayedTabs.dropFirst(start).prefix(count))
    }

    private func splitRows(_ rows: [SnapshotRow], columns: Int) -> [[SnapshotRow]] {
        guard columns == 2 else { return [rows] }
        let midpoint = (rows.count + 1) / 2
        return [Array(rows.prefix(midpoint)), Array(rows.dropFirst(midpoint))]
    }

    private func metrics(for size: CGSize) -> WidgetMetrics {
        let columnCount = family == .systemSmall ? 1 : 2
        let fontSize: CGFloat
        let rowHeight: CGFloat
        let headerHeight: CGFloat

        switch family {
        case .systemSmall:
            fontSize = 13.5
            rowHeight = 21
            headerHeight = 25
        case .systemMedium:
            fontSize = 14
            rowHeight = 23
            headerHeight = 25
        default:
            fontSize = 15.5
            rowHeight = 25
            headerHeight = 28
        }

        let verticalPadding: CGFloat = 11
        let sectionSpacing: CGFloat = 5
        let rowSpacing: CGFloat = family == .systemLarge ? 5 : 4
        let available = max(rowHeight, size.height - verticalPadding - headerHeight - sectionSpacing)
        let rowsPerColumn = max(1, Int((available + rowSpacing) / (rowHeight + rowSpacing)))

        return WidgetMetrics(
            columnCount: columnCount,
            rowCount: rowsPerColumn * columnCount,
            fontSize: fontSize,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            columnSpacing: 12,
            sectionSpacing: sectionSpacing,
            headerHeight: headerHeight
        )
    }
}

private struct WidgetMetrics {
    var columnCount: Int
    var rowCount: Int
    var fontSize: CGFloat
    var rowHeight: CGFloat
    var rowSpacing: CGFloat
    var columnSpacing: CGFloat
    var sectionSpacing: CGFloat
    var headerHeight: CGFloat
}

private enum AppWidgetTheme {
    static let accent = Color(red: 0.95, green: 0.34, blue: 0.19)
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

    init() {
        profileID = ""
        widgetID = "shared"
        direction = 1
    }

    init(profileID: String, widgetID: String, direction: Int) {
        self.profileID = profileID
        self.widgetID = widgetID
        self.direction = direction
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
        let currentIndex = tabs.firstIndex { $0.id == remembered?.tabID } ?? 0
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
