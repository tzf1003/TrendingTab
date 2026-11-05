import AppIntents
import SwiftUI
import TrendingTabCore
import TrendingTabWidgetBridge
import WidgetKit

@main
struct TrendingWidgets: WidgetBundle {
    var body: some Widget { TrendingWidget() }
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
        sampleEntry()
    }

    func snapshot(for configuration: BoardConfigurationIntent, in context: Context) async -> WidgetEntry {
        context.isPreview ? sampleEntry() : entry(configuration: configuration, context: context)
    }

    func timeline(for configuration: BoardConfigurationIntent, in context: Context) async -> Timeline<WidgetEntry> {
        let current = entry(configuration: configuration, context: context)
        var entries = [current]
        let expirations = current.snapshot.tabs.flatMap { tab -> [Date] in
            tab.rows.map { $0.expiresAt ?? tab.expiresAt ?? (tab.updatedAt ?? current.snapshot.generatedAt).addingTimeInterval(1800) }
        }.filter { $0 > current.date }.sorted()
        for expiry in Set(expirations).sorted() {
            var expired = current
            expired.date = expiry
            expired.snapshot = current.snapshot.removingExpiredRows(at: expiry)
            entries.append(expired)
        }
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func entry(configuration: BoardConfigurationIntent, context: Context) -> WidgetEntry {
        let snapshot = SnapshotStore.read() ?? WidgetSnapshot(
            generation: 0, generatedAt: .now, profiles: [], tabs: [], statuses: [], unreadCount: 0
        )
        let widgetID = configuration.resolvedID(context)
        let profile = snapshot.profiles.first ?? WidgetProfile(
            name: "默认", orderedTabIDs: snapshot.tabs.map(\.id), defaultTabID: snapshot.tabs.first?.id
        )
        let remembered = SnapshotStore.selection(widgetID: widgetID)
        let configuredTab = configuration.board.flatMap { UUID(uuidString: $0.id) }
        let preferred = configuration.fixedBoard ? [configuredTab, profile.defaultTabID]
            : [remembered?.tabID, configuredTab, profile.defaultTabID]
        let validTab = WidgetSelection.resolvedTabID(available: snapshot.tabs.map(\.id), preferred: preferred)
        return WidgetEntry(
            date: .now, snapshot: snapshot,
            selection: WidgetSelection(profileID: profile.id, tabID: validTab, page: 0,
                                       generation: remembered?.generation ?? snapshot.generation),
            widgetID: widgetID, fixedBoard: configuration.fixedBoard
        )
    }

    private func sampleEntry() -> WidgetEntry {
        let titles = ["知乎", "微博", "抖音", "重大事件"]
        let headlines = ["发现正在发生的热点", "关注科技与生活的新变化", "多平台热榜，一眼看全", "点击标签，切换不同榜单", "打开热点，查看完整报道", "按需与 AI 继续讨论", "每次刷新，只看当前热点", "按你的习惯安排组件"]
        let tabs = titles.map { title in
            SnapshotTab(id: UUID(), title: title, kind: .sourceBoard,
                        rows: headlines.enumerated().map { index, text in
                            SnapshotRow(id: "preview-\(title)-\(index)", title: text, sourceTitle: title,
                                        rank: index + 1, movement: nil, url: nil, eventID: nil,
                                        publishedAt: nil, score: Double(10 - index))
                        }, coverage: "", updatedAt: .now)
        }
        let profile = WidgetProfile(name: "默认", orderedTabIDs: tabs.map(\.id), defaultTabID: tabs.first?.id)
        let snapshot = WidgetSnapshot(generation: 0, generatedAt: .now, profiles: [profile], tabs: tabs,
                                      statuses: [], unreadCount: 0)
        return WidgetEntry(date: .now, snapshot: snapshot,
                           selection: WidgetSelection(profileID: profile.id, tabID: tabs.first?.id,
                                                      page: 0, generation: 0),
                           widgetID: "preview", fixedBoard: false)
    }
}

struct TrendingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TrendingTab", intent: BoardConfigurationIntent.self,
                               provider: Provider()) { entry in
            WidgetContent(entry: entry)
        }
        .configurationDisplayName("热榜")
        .description("实时热点与多平台榜单。编辑组件可选择默认榜单与独立配置。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct WidgetContent: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    private var allTabs: [SnapshotTab] {
        let tabs = entry.snapshot.tabs
        let profile = entry.snapshot.profiles.first { $0.id == entry.selection.profileID }
            ?? entry.snapshot.profiles.first
        let ordered = profile?.orderedTabIDs.compactMap { id in tabs.first { $0.id == id } } ?? tabs
        return ordered.isEmpty ? tabs : ordered
    }

    private var currentIndex: Int { allTabs.firstIndex { $0.id == entry.selection.tabID } ?? 0 }
    private var currentTab: SnapshotTab? {
        allTabs.indices.contains(currentIndex) ? allTabs[currentIndex] : allTabs.first
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = WidgetLayout(family: family, size: geometry.size)
            let rows = Array((currentTab?.rows ?? []).prefix(layout.rowCount))
            VStack(spacing: 6) {
                tabBar(layout: layout)
                if rows.isEmpty {
                    emptyState(layout: layout)
                } else {
                    newsGrid(rows, layout: layout)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        .widgetURL(WidgetNavigationTarget(tabID: currentTab?.id).url)
    }

    private func tabBar(layout: WidgetLayout) -> some View {
        HStack(spacing: 3) {
            if !entry.fixedBoard {
                pager(direction: -1)
            }
            if family == .systemSmall || entry.fixedBoard {
                Text(currentTab?.title ?? "热榜")
                    .font(.system(size: layout.fontSize, weight: .bold))
                    .foregroundStyle(WidgetTheme.accent)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: entry.fixedBoard ? .leading : .center)
            } else {
                let visible = visibleTabs(count: family == .systemMedium ? 4 : 5)
                ForEach(visible) { tab in
                    Button(intent: ChooseTabIntent(profileID: entry.selection.profileID.uuidString,
                                                   widgetID: entry.widgetID, tabID: tab.id.uuidString)) {
                        Text(tab.title)
                            .font(.system(size: layout.tabFontSize, weight: .semibold))
                            .foregroundStyle(tab.id == currentTab?.id ? WidgetTheme.accent : Color.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 4)
                            .background(tab.id == currentTab?.id ? WidgetTheme.accent.opacity(0.13) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            if !entry.fixedBoard {
                pager(direction: 1)
            }
        }
        .frame(height: 27)
    }

    private func newsGrid(_ rows: [SnapshotRow], layout: WidgetLayout) -> some View {
        let midpoint = (rows.count + 1) / 2
        let columns = layout.columns == 2 ? [Array(rows.prefix(midpoint)), Array(rows.dropFirst(midpoint))] : [rows]
        return HStack(alignment: .top, spacing: 12) {
            ForEach(columns.indices, id: \.self) { index in
                VStack(spacing: 0) {
                    ForEach(columns[index]) { row in
                        Link(destination: WidgetNavigationTarget(itemID: row.id, eventID: row.eventID,
                                                                  tabID: currentTab?.id).url) {
                            HStack(spacing: 4) {
                                Text(row.title)
                                    .font(.system(size: layout.fontSize, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(layout.lineLimit)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if row.movement == "新" {
                                    Circle().fill(WidgetTheme.accent).frame(width: 4, height: 4)
                                        .accessibilityLabel("新上榜")
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if row.id != columns[index].last?.id {
                            Divider().opacity(0.28)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if layout.columns == 2 && index == 0 { Divider().opacity(0.35) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func emptyState(layout: WidgetLayout) -> some View {
        Link(destination: WidgetNavigationTarget(tabID: currentTab?.id).url) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(WidgetTheme.accent)
                Text(currentTab?.coverage ?? "等待首次采集")
                    .font(.system(size: layout.fontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("打开热榜刷新")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func pager(direction: Int) -> some View {
        Button(intent: SelectTabIntent(profileID: entry.selection.profileID.uuidString,
                                       widgetID: entry.widgetID, direction: direction,
                                       currentTabID: currentTab?.id.uuidString ?? "")) {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(allTabs.count < 2)
    }

    private func visibleTabs(count: Int) -> [SnapshotTab] {
        let start = min(max(0, currentIndex - count / 2), max(0, allTabs.count - count))
        return Array(allTabs.dropFirst(start).prefix(count))
    }
}

private struct WidgetLayout {
    let columns: Int
    let rowCount: Int
    let fontSize: CGFloat
    let tabFontSize: CGFloat
    let lineLimit: Int

    init(family: WidgetFamily, size: CGSize) {
        columns = family == .systemMedium ? 2 : 1
        fontSize = family == .systemLarge ? 16 : 14
        tabFontSize = family == .systemLarge ? 14 : 12.5
        lineLimit = 1
        let minimumHeight: CGFloat = family == .systemSmall ? 20 : family == .systemLarge ? 27 : 25
        let available = max(minimumHeight, size.height - 18 - 27 - 6)
        let rowsPerColumn = max(1, Int(available / minimumHeight))
        rowCount = (family == .systemSmall ? min(5, rowsPerColumn) : rowsPerColumn) * columns
    }
}

private enum WidgetTheme {
    static let accent = Color(red: 0.85, green: 0.30, blue: 0.17)
}
