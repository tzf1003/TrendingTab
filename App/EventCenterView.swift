import SwiftUI
import TrendingTabCore
import TrendingTabKit

struct EventCenterView: View {
    @ObservedObject var model: TrendingAppModel
    @State private var selectedTabID: SnapshotTab.ID?
    @State private var selectedRowID: SnapshotRow.ID?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 300, idealWidth: 350, maxWidth: 410, maxHeight: .infinity)

            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.canvas)
        .frame(minWidth: 900, minHeight: 580)
        .onAppear {
            revealRequestedRow()
            normalizeSelection()
        }
        .onChange(of: model.pendingEventToken) { _, _ in revealRequestedRow() }
        .onChange(of: model.snapshot?.generation) { _, _ in normalizeSelection() }
    }

    private var tabs: [SnapshotTab] {
        guard let snapshot = model.snapshot ?? fallbackSnapshot else { return [] }
        guard let profile = snapshot.profiles.first else { return snapshot.tabs }
        let ordered = profile.orderedTabIDs.compactMap { id in snapshot.tabs.first { $0.id == id } }
        return ordered.isEmpty ? snapshot.tabs : ordered
    }

    private var fallbackSnapshot: WidgetSnapshot? {
        guard !model.tabs.isEmpty else { return nil }
        return WidgetSnapshot(
            generation: 0,
            generatedAt: .now,
            profiles: model.profiles,
            tabs: model.tabs.filter { !$0.hidden }.map {
                SnapshotTab(id: $0.id, title: $0.title, kind: $0.kind, rows: [], coverage: "等待首次采集", updatedAt: nil)
            },
            statuses: [],
            unreadCount: 0
        )
    }

    private var currentTab: SnapshotTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    private var sortedRows: [SnapshotRow] {
        (currentTab?.rows ?? []).sorted(by: heatOrder)
    }

    private var currentRow: SnapshotRow? {
        sortedRows.first { $0.id == selectedRowID } ?? sortedRows.first
    }

    private var currentItem: StoredItem? {
        guard let currentRow else { return nil }
        return model.items.first { $0.id == currentRow.id }
    }

    private var currentEvent: EventCluster? {
        guard let currentRow else { return nil }
        if let eventID = currentRow.eventID, let event = model.events.first(where: { $0.id == eventID }) {
            return event
        }
        return model.events.first { $0.itemIDs.contains(currentRow.id) }
    }

    private var currentReports: [StoredItem] {
        if let event = currentEvent {
            return model.items.filter { event.itemIDs.contains($0.id) }
        }
        return currentItem.map { [$0] } ?? []
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            brandHeader
            Divider().opacity(0.55)
            tabPager
            Divider().opacity(0.4)
            feedList
            Divider().opacity(0.4)
            sidebarFooter
        }
        .background(AppTheme.sidebar)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.accent)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text("TrendingTab").font(.headline)
                    Text("实时热点，只保留当下").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refresh(manual: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.running)
                .help("立即刷新")
            }

            HStack(spacing: 8) {
                StatusPill(
                    title: model.running ? "正在刷新" : "当前榜单",
                    color: model.running ? .orange : .green
                )
                if let generatedAt = model.snapshot?.generatedAt ?? currentTab?.updatedAt {
                    Text(generatedAt.trendingRelativeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var tabPager: some View {
        HStack(spacing: 4) {
            pagerButton(systemName: "chevron.left", direction: -1)
                .disabled(tabs.count < 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(tabs) { tab in
                        Button {
                            selectedTabID = tab.id
                            selectedRowID = nil
                            normalizeSelection()
                        } label: {
                            Text(tab.title)
                                .font(.system(size: 14.5, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .foregroundStyle(tab.id == currentTab?.id ? AppTheme.accent : .primary)
                                .background(
                                    tab.id == currentTab?.id ? AppTheme.accentSoft : Color.primary.opacity(0.055),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }

            pagerButton(systemName: "chevron.right", direction: 1)
                .disabled(tabs.count < 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var feedList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if sortedRows.isEmpty {
                    sidebarEmptyState
                } else {
                    ForEach(sortedRows) { row in
                        feedRow(row)
                    }
                }
            }
            .padding(10)
        }
    }

    private var sidebarFooter: some View {
        HStack {
            Text("\(sortedRows.count) 条")
            Spacer()
            Text("仅显示当前榜单")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var sidebarEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wind")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.running ? "正在获取当前榜单" : "当前没有可显示的热点")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.running {
                Button("立即刷新") {
                    Task { await model.refresh(manual: true) }
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    private func feedRow(_ row: SnapshotRow) -> some View {
        let selected = row.id == currentRow?.id
        return Button {
            selectedRowID = row.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(selected ? AppTheme.accent : Color.clear)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title)
                        .font(.system(size: 14.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    HStack(spacing: 7) {
                        Text(updateDate(for: row).trendingRelativeText)
                        if let movement = row.movement, !movement.isEmpty {
                            Text(movement)
                                .foregroundStyle(movement.hasPrefix("↓") ? Color.secondary : AppTheme.accent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selected ? AppTheme.accent : Color.secondary.opacity(0.4))
                    .padding(.top, 4)
            }
            .padding(.vertical, 9)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        if let row = currentRow {
            StoryDetailView(
                row: row,
                tab: currentTab,
                item: currentItem,
                event: currentEvent,
                reports: currentReports,
                updateDate: updateDate(for: row),
                analysis: currentEvent?.id == model.analysisEventID ? model.analysisText : "",
                analyze: {
                    guard let event = currentEvent else { return }
                    Task { await model.analyzeEvent(event) }
                }
            )
        } else {
            ContentUnavailableView(
                "选择一条热点",
                systemImage: "rectangle.stack",
                description: Text("左侧只展示当前榜单；内容掉榜后会立即消失。")
            )
        }
    }

    private func pagerButton(systemName: String, direction: Int) -> some View {
        Button {
            moveTab(direction)
        } label: {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func moveTab(_ direction: Int) {
        guard !tabs.isEmpty else { return }
        let currentIndex = tabs.firstIndex { $0.id == currentTab?.id } ?? 0
        let nextIndex = (currentIndex + direction + tabs.count) % tabs.count
        selectedTabID = tabs[nextIndex].id
        selectedRowID = nil
        normalizeSelection()
    }

    private func heatOrder(_ lhs: SnapshotRow, _ rhs: SnapshotRow) -> Bool {
        let leftRank = lhs.rank ?? Int.max
        let rightRank = rhs.rank ?? Int.max
        if leftRank != rightRank { return leftRank < rightRank }
        return lhs.score > rhs.score
    }

    private func updateDate(for row: SnapshotRow) -> Date {
        model.items.first(where: { $0.id == row.id })?.lastSeenAt
            ?? row.publishedAt
            ?? currentTab?.updatedAt
            ?? model.snapshot?.generatedAt
            ?? .now
    }

    private func normalizeSelection() {
        if !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = tabs.first?.id
        }
        if !sortedRows.contains(where: { $0.id == selectedRowID }) {
            selectedRowID = sortedRows.first?.id
        }
    }

    private func revealRequestedRow() {
        if let itemID = model.requestedItemID {
            for tab in tabs {
                if tab.rows.contains(where: { $0.id == itemID }) {
                    selectedTabID = tab.id
                    selectedRowID = itemID
                    return
                }
            }
        }

        if let eventID = model.requestedEventID {
            let relatedItemIDs = Set(model.events.first { $0.id == eventID }?.itemIDs ?? [])
            for tab in tabs {
                if let row = tab.rows.first(where: { $0.eventID == eventID || relatedItemIDs.contains($0.id) }) {
                    selectedTabID = tab.id
                    selectedRowID = row.id
                    return
                }
            }
        }

        normalizeSelection()
    }
}

private struct StoryDetailView: View {
    var row: SnapshotRow
    var tab: SnapshotTab?
    var item: StoredItem?
    var event: EventCluster?
    var reports: [StoredItem]
    var updateDate: Date
    var analysis: String
    var analyze: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                summarySection
                reportsSection
                analysisSection
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 34)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppTheme.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatusPill(title: tab?.title ?? row.sourceTitle, color: AppTheme.accent)
                Text(updateDate.trendingRelativeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let url = row.url {
                    Link(destination: url) {
                        Label("打开原文", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }

            Text(row.title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 14) {
                Label(row.sourceTitle, systemImage: "newspaper")
                if let rank = row.rank {
                    Label("榜位 \(rank)", systemImage: "flame")
                }
                if let publishedAt = row.publishedAt {
                    Label(publishedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var summarySection: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    SectionHeading(
                        title: event?.summary == nil ? "事件摘要" : "AI 事件摘要",
                        detail: event?.summary == nil ? "尚未完成自动分析" : "根据当前可用的标题与摘要生成"
                    )
                    Spacer()
                    if let event {
                        StatusPill(
                            title: statusTitle(event.status),
                            color: event.status == "major" ? AppTheme.accent : .secondary,
                            systemImage: event.status == "major" ? "sparkles" : nil
                        )
                    }
                }

                let hasSummary = event?.summary != nil || item?.item.summary != nil
                Text(event?.summary ?? item?.item.summary ?? "这条热点还没有生成摘要。打开原文，或在配置 AI 后执行深入分析。")
                    .font(.body)
                    .foregroundStyle(hasSummary ? Color.primary : Color.secondary)
                    .textSelection(.enabled)

                if let category = event?.category, !category.isEmpty {
                    Label(category, systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var reportsSection: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 13) {
                SectionHeading(title: "相关报道", detail: reports.count > 1 ? "同一事件下的当前内容" : "当前热点原文")
                if reports.isEmpty {
                    Text("没有可打开的相关内容。").foregroundStyle(.secondary)
                } else {
                    ForEach(reports) { stored in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "link")
                                .foregroundStyle(AppTheme.accent)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Link(stored.item.title, destination: stored.item.url)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("\(stored.item.sourceID) · \(stored.lastSeenAt.trendingRelativeText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if stored.id != reports.last?.id {
                            Divider().opacity(0.45)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var analysisSection: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeading(title: "深入分析", detail: "按需读取最多三篇可获得的内容")
                    Spacer()
                    Button(analysis.isEmpty ? "开始分析" : "重新分析", action: analyze)
                        .buttonStyle(QuietButtonStyle(prominent: true))
                        .disabled(event == nil)
                }

                if !analysis.isEmpty {
                    Text(analysis)
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    Text("可以继续追问事件经过、来源差异、潜在影响和仍待确认的信息。")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusTitle(_ status: String) -> String {
        switch status {
        case "major": "重大事件"
        case "candidate": "候选事件"
        case "pending-analysis": "待分析"
        default: status
        }
    }
}
