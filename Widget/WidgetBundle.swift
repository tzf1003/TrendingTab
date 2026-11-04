import SwiftUI
import WidgetKit
import TrendingTabCore
import TrendingTabWidgetBridge

@main
struct TrendingWidgets: WidgetBundle {
    var body: some Widget { TrendingWidget() }
}

struct WidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var selection: WidgetSelection
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry { entry() }
    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func entry() -> WidgetEntry {
        let snapshot = SnapshotStore.read() ?? WidgetSnapshot(generation: 0, generatedAt: .now, profiles: [], tabs: [], statuses: [], unreadCount: 0)
        let selection = SnapshotStore.selection() ?? WidgetSelection(profileID: snapshot.profiles.first?.id ?? UUID(), tabID: snapshot.tabs.first?.id, page: 0, generation: snapshot.generation)
        let validTab = snapshot.tabs.contains { $0.id == selection.tabID } ? selection.tabID : snapshot.tabs.first?.id
        return WidgetEntry(date: snapshot.generatedAt, snapshot: snapshot, selection: WidgetSelection(profileID: selection.profileID, tabID: validTab, page: selection.page, generation: selection.generation))
    }
}

struct TrendingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TrendingTab", provider: Provider()) { entry in
            WidgetContent(entry: entry)
        }
        .configurationDisplayName("热榜")
        .description("查看可排序的平台、事件和主题标签。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WidgetContent: View {
    @Environment(\.widgetFamily) private var family
    var entry: WidgetEntry

    var body: some View {
        let tabs = orderedTabs
        let currentIndex = tabs.firstIndex { $0.id == entry.selection.tabID } ?? 0
        let current = tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil
        VStack(alignment: .leading, spacing: 6) {
            header(tabs: tabs, current: current, index: currentIndex)
            if let current {
                let limit = family == .systemSmall ? 3 : family == .systemMedium ? 5 : 8
                ForEach(Array(current.rows.prefix(limit).enumerated()), id: \.element.id) { _, row in
                    rowView(row, compact: family == .systemSmall)
                }
                if current.rows.isEmpty { Text(current.coverage).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("等待首次采集").font(.caption)
            }
        }
        .padding(10)
        .containerBackground(.background, for: .widget)
    }

    private var orderedTabs: [SnapshotTab] {
        guard let profile = entry.snapshot.profiles.first(where: { $0.id == entry.selection.profileID }) ?? entry.snapshot.profiles.first else {
            return entry.snapshot.tabs
        }
        return profile.orderedTabIDs.compactMap { id in entry.snapshot.tabs.first { $0.id == id } }
    }

    @ViewBuilder
    private func header(tabs: [SnapshotTab], current: SnapshotTab?, index: Int) -> some View {
        HStack {
            Button(intent: SelectTabIntent(profileID: entry.selection.profileID.uuidString, direction: -1)) { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Text(current?.title ?? "热榜").font(.headline).lineLimit(1)
            Spacer()
            Button(intent: SelectTabIntent(profileID: entry.selection.profileID.uuidString, direction: 1)) { Image(systemName: "chevron.right") }.buttonStyle(.plain)
        }
        if family != .systemSmall {
            let visible = family == .systemMedium ? 3 : 4
            HStack {
                ForEach(visibleTabs(tabs, around: index, count: visible)) { tab in
                    Text(tab.title).font(.caption2).lineLimit(1)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(tab.id == current?.id ? Color.accentColor.opacity(0.2) : Color.clear, in: Capsule())
                }
            }
        }
    }

    private func visibleTabs(_ tabs: [SnapshotTab], around index: Int, count: Int) -> [SnapshotTab] {
        guard !tabs.isEmpty else { return [] }
        let start = min(max(0, index - count / 2), max(0, tabs.count - count))
        return Array(tabs.dropFirst(start).prefix(count))
    }

    @ViewBuilder
    private func rowView(_ row: SnapshotRow, compact: Bool) -> some View {
        let label = HStack(alignment: .firstTextBaseline) {
            if let rank = row.rank { Text("\(rank)").font(.caption2).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing) }
            Text(row.title).font(.caption).lineLimit(1)
            Spacer(minLength: 2)
            if let movement = row.movement { Text(movement).font(.caption2).foregroundStyle(.orange) }
            if !compact { Text(row.sourceTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        if compact {
            label.widgetURL(URL(string: "trendingtab://tab"))
        } else if let url = row.url {
            Link(destination: url) { label }
        } else {
            label
        }
    }
}

struct SelectTabIntent: AppIntent {
    static var title: LocalizedStringResource = "切换热榜标签"
    @Parameter(title: "配置") var profileID: String
    @Parameter(title: "方向") var direction: Int

    init() {}
    init(profileID: String, direction: Int) {
        self.profileID = profileID
        self.direction = direction
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: profileID), let snapshot = SnapshotStore.read() else { return .result() }
        let profile = snapshot.profiles.first { $0.id == id } ?? snapshot.profiles.first
        let tabs = profile?.orderedTabIDs.compactMap { tabID in snapshot.tabs.first { $0.id == tabID } } ?? snapshot.tabs
        let current = SnapshotStore.selection()?.tabID
        let index = tabs.firstIndex { $0.id == current } ?? 0
        let next = tabs.isEmpty ? nil : tabs[(index + direction + tabs.count) % tabs.count].id
        _ = try SnapshotStore.updateSelection(profileID: profile?.id ?? id, tabID: next, page: 0)
        WidgetCenter.shared.reloadTimelines(ofKind: "TrendingTab")
        return .result()
    }
}
