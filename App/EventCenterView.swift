import AppKit
import SwiftUI
import TrendingTabCore
import TrendingTabKit
import TrendingTabSources

struct EventCenterView: View {
    @ObservedObject var model: TrendingAppModel
    @State private var selectedTabID: SnapshotTab.ID?
    @State private var selectedRowID: SnapshotRow.ID?
    @State private var openedRow: SnapshotRow?
    @State private var missingStoryURL = false
    @State private var dismissedRevealToken: Int?
    @State private var presentedRevealToken: Int?
    @State private var unresolvedReveal = false
    @State private var revealRevision = 0
    @State private var showsChat = true
    @AppStorage("research.mode.enabled") private var researchMode = false
    @StateObject private var browserTools: BrowserToolBroker
    @StateObject private var browser: BrowserWorkspace
    @State private var chatDrafts: [SnapshotRow.ID: String] = [:]

    init(model: TrendingAppModel) {
        self.model = model
        let workspace = BrowserWorkspace(waitsForInitialViewport: true)
        _browser = StateObject(wrappedValue: workspace)
        _browserTools = StateObject(wrappedValue: BrowserToolBroker(workspace: workspace, currentSnapshot: { [weak model] in model?.snapshot }))
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 276, idealWidth: 318, maxWidth: 410, maxHeight: .infinity)

            reader
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)

            if showsChat {
                AnalysisConversationView(
                    chat: model.analysisChat,
                    browserTools: browserTools,
                    row: openedRow,
                    draft: chatDraft(for: openedRow?.id),
                    researchMode: $researchMode,
                    hasConnection: hasAnalysisConnection,
                    researchRestriction: model.researchUnavailableReason,
                    send: { text, id in model.sendChatMessage(text, itemID: id, evidenceFallback: fallbackEvidence(for: id), researchContext: browserTools.researchContext(itemID: id), toolHandler: researchHandler(for: id), onRunFinished: { browserTools.finishRun($0) }, evidenceSnapshot: evidenceSnapshot(for: id)) },
                    retry: { id in model.retryChat(itemID: id, evidenceFallback: fallbackEvidence(for: id), researchContext: browserTools.researchContext(itemID: id), toolHandler: researchHandler(for: id), onRunFinished: { browserTools.finishRun($0) }, evidenceSnapshot: evidenceSnapshot(for: id)) },
                    openSource: { missingStoryURL = false; browser.openStory($0, inNewTab: true) },
                    endSession: { id in model.analysisChat.clear(itemID: id); browserTools.endSession(itemID: id) },
                    close: { showsChat = false }
                )
                .frame(minWidth: 340, idealWidth: 356, maxWidth: 400, maxHeight: .infinity)
            }
        }
        .background(AppTheme.canvas)
        .frame(minWidth: 1100, minHeight: 580)
        .tint(AppTheme.actionTint)
        .onChange(of: model.pendingEventToken, initial: true) { _, _ in reconcileSelection() }
        .onChange(of: model.snapshot) { _, _ in reconcileSelection() }
        .onChange(of: model.tabs) { _, _ in reconcileSelection() }
        .onChange(of: displayedRow?.id, initial: true) { _, _ in
            if openedRow == nil, let row = displayedRow { openStory(row) }
        }
    }

    private var tabs: [SnapshotTab] {
        guard let snapshot = model.snapshot else {
            return model.tabs.filter { !$0.hidden }.map {
                SnapshotTab(id: $0.id, title: $0.title, kind: $0.kind,
                            rows: [], coverage: "等待首次采集", updatedAt: nil)
            }
        }
        guard let profile = snapshot.profiles.first else { return snapshot.tabs }
        let ordered = profile.orderedTabIDs.compactMap { id in snapshot.tabs.first { $0.id == id } }
        let orderedIDs = Set(ordered.map(\.id))
        return ordered + snapshot.tabs.filter { !orderedIDs.contains($0.id) }
    }

    private var currentTab: SnapshotTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    private var sortedRows: [SnapshotRow] {
        guard let tab = currentTab else { return [] }
        let sortsByRank = tab.kind == .sourceBoard
        return tab.rows.sorted { lhs, rhs in
            let leftRank = lhs.rank ?? Int.max
            let rightRank = rhs.rank ?? Int.max
            if sortsByRank && leftRank != rightRank { return leftRank < rightRank }
            return lhs.score > rhs.score
        }
    }

    private var displayedRow: SnapshotRow? {
        guard !waitingForReveal else { return nil }
        return sortedRows.first { $0.id == selectedRowID } ?? sortedRows.first
    }

    private var waitingForReveal: Bool {
        if unresolvedReveal { return true }
        let token = model.pendingEventToken
        guard dismissedRevealToken != token,
              model.requestedItemID != nil || model.requestedEventID != nil || model.requestedTabID != nil else {
            return false
        }
        if presentedRevealToken != token { return true }
        if let itemID = model.requestedItemID {
            return !sortedRows.contains { $0.id == itemID }
        }
        return false
    }

    private var hasAnalysisConnection: Bool {
        guard let id = model.assignment.analysis else { return false }
        return model.connections.contains { $0.id == id }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            tabPager
            Divider()
            feedList
                .id(currentTab?.id)
            Divider()
            sidebarFooter
        }
        .background(PaneSurface(role: .sidebar))
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text("事件中心")
                .font(.system(size: 23, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if model.running {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在刷新")
            } else {
                Button(action: refresh) {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(SelectableButtonStyle())
                .help("立即刷新")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 8)
    }

    private var tabPager: some View {
        HStack(spacing: 4) {
            pagerButton("上一个榜单", icon: "chevron.left", direction: -1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            let selected = currentTab?.id == tab.id
                            Button {
                                selectTab(tab.id)
                            } label: {
                                Text(tab.title)
                                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                                    .lineLimit(1)
                                    .foregroundStyle(selected ? AppTheme.accent : Color.primary)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 32)
                            }
                            .buttonStyle(SelectableButtonStyle(selected: selected))
                            .id(tab.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: currentTab?.id, initial: true) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: tabs.map(\.id)) { _, _ in
                    if let id = currentTab?.id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            pagerButton("下一个榜单", icon: "chevron.right", direction: 1)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("榜单标签")
    }

    private var feedList: some View {
        let rows = sortedRows
        let selection = openedRow?.id
        let showsRank = currentTab?.kind == .sourceBoard
        return ScrollViewReader { proxy in
            ScrollView {
                if rows.isEmpty {
                    feedEmptyState
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { row in
                            feedRow(row, selected: row.id == selection, showsRank: showsRank)
                                .id(row.id)
                        }
                    }
                    .padding(8)
                }
            }
            .onChange(of: selection, initial: true) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: revealRevision) { _, _ in
                if let selection { proxy.scrollTo(selection) }
            }
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Text("\(sortedRows.count) 条热点")
                .monospacedDigit()
            Spacer(minLength: 4)
            if model.running {
                Text("正在刷新")
            } else if let date = currentTab?.updatedAt {
                UpdateTimeLabel(date: date)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var feedEmptyState: some View {
        ContentUnavailableView {
            Label(
                model.running ? "正在获取榜单" : "当前没有热点",
                systemImage: model.running ? "arrow.triangle.2.circlepath" : "list.number"
            )
        } description: {
            if let tab = currentTab, tab.coverage != "已覆盖当前材料" {
                Text(tab.coverage)
            } else if currentTab == nil {
                Text("可在设置中显示或添加榜单。")
            }
        } actions: {
            if currentTab != nil && !model.running {
                Button("立即刷新", action: refresh)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private func feedRow(_ row: SnapshotRow, selected: Bool, showsRank: Bool) -> some View {
        Button {
            selectStory(row, inNewTab: false)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if showsRank, let rank = row.rank {
                    Text("\(rank)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle((1...3).contains(rank) ? AppTheme.accent : Color.secondary)
                        .frame(minWidth: 24, alignment: .trailing)
                        .padding(.top, 2)
                        .accessibilityLabel("榜位 \(rank)")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.system(size: 16, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    UpdateTimeLabel(date: updateDate(for: row))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if selected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.top, 5)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
        }
        .buttonStyle(SelectableButtonStyle(selected: selected))
        .highPriorityGesture(TapGesture().modifiers(.command).onEnded {
            selectStory(row, inNewTab: true)
        })
        .contextMenu {
            Button("在新标签中打开") { selectStory(row, inNewTab: true) }
        }
        .help(row.title)
    }

    private func selectStory(_ row: SnapshotRow, inNewTab: Bool) {
        dismissReveal()
        selectedRowID = row.id
        openStory(row, inNewTab: inNewTab)
    }

    private var reader: some View {
        VStack(spacing: 0) {
            if !showsChat {
                HStack {
                    Spacer()
                    Button {
                        showsChat = true
                    } label: {
                        Label("显示 AI 对话", systemImage: "sidebar.right")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            ZStack {
                BrowserWorkspaceView(workspace: browser)
                    .opacity(missingStoryURL ? 0 : 1)
                    .allowsHitTesting(!missingStoryURL)
                    .accessibilityHidden(missingStoryURL)
                if missingStoryURL {
                    VStack(spacing: 12) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("暂无可用原文链接").font(.headline)
                        Text("当前热点没有可打开的网页地址。")
                            .foregroundStyle(.secondary)
                        if !browser.tabs.isEmpty {
                            Button("查看已打开的页面") { missingStoryURL = false }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PaneSurface(role: .reader))
    }

    @ViewBuilder
    private var readerContent: some View {
        if let row = displayedRow {
            let item = model.items.first { $0.id == row.id }
            let event = event(for: row)
            StoryDetailView(
                row: row,
                tabTitle: currentTab?.title,
                item: item,
                event: event,
                reports: reports(for: row, event: event),
                sourceNames: sourceNames,
                updateDate: updateDate(for: row),
                openAnalysis: { openAnalysis(for: row.id) }
            )
            .id(StoryIdentity(tabID: currentTab?.id, rowID: row.id, revealRevision: revealRevision))
        } else if waitingForReveal {
            if model.snapshot == nil {
                ContentUnavailableView(
                    "正在等待榜单",
                    systemImage: "clock",
                    description: Text("榜单就绪后会定位链接中的热点。")
                )
            } else {
                ContentUnavailableView(
                    "链接中的热点已掉榜",
                    systemImage: "link",
                    description: Text("可从左侧选择当前榜单中的热点。")
                )
            }
        } else {
            ContentUnavailableView(
                "还没有选中的热点",
                systemImage: "newspaper",
                description: Text("从左侧选择榜单和热点，查看来源、摘要与原文。")
            )
        }
    }

    private func pagerButton(_ title: String, icon: String, direction: Int) -> some View {
        Button {
            let available = tabs
            guard let index = available.firstIndex(where: { $0.id == currentTab?.id }),
                  available.count > 1 else { return }
            selectTab(available[(index + direction + available.count) % available.count].id)
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 32)
        }
        .buttonStyle(SelectableButtonStyle())
        .disabled(tabs.count < 2)
        .help(title)
    }

    private func refresh() {
        Task { await model.refresh(manual: true) }
    }

    private func selectTab(_ id: SnapshotTab.ID) {
        let changedTab = id != currentTab?.id
        dismissReveal()
        selectedTabID = id
        if changedTab { selectedRowID = nil }
        normalizeSelection()
        if changedTab, let row = sortedRows.first(where: { $0.id == selectedRowID }) { openStory(row) }
    }

    private func normalizeSelection() {
        selectedTabID = currentTab?.id
        if !sortedRows.contains(where: { $0.id == selectedRowID }) {
            selectedRowID = sortedRows.first?.id
        }
    }

    private func reconcileSelection() {
        if dismissedRevealToken != model.pendingEventToken {
            revealRequestedRow()
        }
        if !unresolvedReveal { normalizeSelection() }
    }

    private func revealRequestedRow() {
        let preferredID = model.requestedTabID
        let itemID = model.requestedItemID
        let eventID = model.requestedEventID
        guard itemID != nil || eventID != nil || preferredID != nil else {
            dismissReveal()
            return
        }

        let available = tabs
        let preferredTab = available.first { $0.id == preferredID }
        let searchOrder = preferredTab.map { preferred in
            [preferred] + available.filter { $0.id != preferred.id }
        } ?? available

        if let itemID {
            if let tab = searchOrder.first(where: { $0.rows.contains { $0.id == itemID } }) {
                reveal(tabID: tab.id, rowID: itemID)
                return
            }
        } else if let eventID {
            let related = Set(model.events.first { $0.id == eventID }?.itemIDs ?? [])
            for tab in searchOrder {
                if let row = tab.rows.first(where: { $0.eventID == eventID })
                    ?? tab.rows.first(where: { related.contains($0.id) }) {
                    reveal(tabID: tab.id, rowID: row.id)
                    return
                }
            }
        } else if let preferredTab {
            reveal(tabID: preferredTab.id, rowID: nil)
            return
        }

        if let preferredTab { selectedTabID = preferredTab.id }
        unresolvedReveal = true
    }

    private func reveal(tabID: SnapshotTab.ID, rowID: SnapshotRow.ID?) {
        let isNewRequest = presentedRevealToken != model.pendingEventToken
        let changedTab = selectedTabID != tabID
        if isNewRequest || changedTab || (rowID != nil && selectedRowID != rowID) || unresolvedReveal {
            revealRevision += 1
        }
        presentedRevealToken = model.pendingEventToken
        selectedTabID = tabID
        if rowID != nil || isNewRequest || changedTab { selectedRowID = rowID }
        unresolvedReveal = false
        if isNewRequest || changedTab, let tab = tabs.first(where: { $0.id == tabID }),
           let row = tab.rows.first(where: { $0.id == rowID }) ?? tab.rows.first { openStory(row) }
    }

    private func dismissReveal() {
        dismissedRevealToken = model.pendingEventToken
        unresolvedReveal = false
    }

    private func event(for row: SnapshotRow) -> EventCluster? {
        if let eventID = row.eventID, let event = model.events.first(where: { $0.id == eventID }) {
            return event
        }
        return model.events.first { $0.itemIDs.contains(row.id) }
    }

    private func reports(for row: SnapshotRow, event: EventCluster?) -> [StoredItem] {
        let ids = Set(event?.itemIDs ?? []).union([row.id])
        return model.items.filter { ids.contains($0.id) }.sorted { lhs, rhs in
            if lhs.id == row.id { return rhs.id != row.id }
            if rhs.id == row.id { return false }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
    }

    private var sourceNames: [String: String] {
        Dictionary(
            SourceCatalog.providers(customFeeds: model.feeds).map { ($0.descriptor.id, $0.descriptor.title) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func updateDate(for row: SnapshotRow) -> Date? {
        model.items.first { $0.id == row.id }?.lastSeenAt
            ?? currentTab?.updatedAt
            ?? model.snapshot?.generatedAt
    }

    private func chatDraft(for itemID: SnapshotRow.ID?) -> Binding<String> {
        guard let itemID else { return .constant("") }
        return Binding(
            get: { chatDrafts[itemID, default: ""] },
            set: { chatDrafts[itemID] = $0.isEmpty ? nil : $0 }
        )
    }

    private func openStory(_ row: SnapshotRow, inNewTab: Bool = false) {
        openedRow = row
        let candidates = [row.url, model.items.first(where: { $0.id == row.id })?.item.url]
        if let url = candidates.compactMap({ $0 }).first(where: {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil
        }) {
            missingStoryURL = false
            browser.openStory(url, inNewTab: inNewTab)
        } else {
            missingStoryURL = true
        }
    }

    private func fallbackEvidence(for itemID: String) -> String? {
        guard let row = openedRow, row.id == itemID else { return nil }
        return "[1] \(row.title)\n来源：\(row.sourceTitle)\n来源地址：\(row.url.map(AIVisibleAddress.string(for:)) ?? "")"
    }

    private func openAnalysis(for itemID: SnapshotRow.ID) {
        showsChat = true
        let session = model.analysisChat.session(for: itemID)
        guard hasAnalysisConnection, session.messages.isEmpty, !session.isStreaming, session.error == nil else { return }
        model.sendChatMessage(AnalysisConversationView.initialPrompt, itemID: itemID, evidenceFallback: fallbackEvidence(for: itemID),
                              toolHandler: researchHandler(for: itemID), onRunFinished: { browserTools.finishRun($0) }, evidenceSnapshot: evidenceSnapshot(for: itemID))
    }

    private func evidenceSnapshot(for itemID: String) -> AnalysisChatModel.EvidenceSnapshot {
        { Set(browserTools.evidence.records.filter { $0.itemID == itemID }.map(\.id)) }
    }

    private func researchHandler(for itemID: String) -> AnalysisChatModel.ToolHandler? {
        guard researchMode, model.analysisChat.supportsResearch else { return nil }
        let title = model.items.first { $0.id == itemID }?.item.title ?? openedRow?.title ?? "热点研究"
        let storyURL = model.items.first { $0.id == itemID }?.item.url ?? (openedRow?.id == itemID ? openedRow?.url : nil)
        return { request, runID in try await browserTools.execute(request, runID: runID, itemID: itemID, taskTitle: title, currentStoryURL: storyURL) }
    }
}

private struct StoryIdentity: Hashable {
    let tabID: SnapshotTab.ID?
    let rowID: SnapshotRow.ID
    let revealRevision: Int
}

private struct UpdateTimeLabel: View {
    let date: Date?

    var body: some View {
        if let date {
            Text("更新于 \(date.formatted(.dateTime.month().day().hour().minute()))")
        } else {
            Text("更新时间未知")
        }
    }
}

private struct StoryDetailView: View {
    let row: SnapshotRow
    let tabTitle: String?
    let item: StoredItem?
    let event: EventCluster?
    let reports: [StoredItem]
    let sourceNames: [String: String]
    let updateDate: Date?
    let openAnalysis: () -> Void

    private var originalURL: URL? { row.url ?? item?.item.url }
    private var sourceSummary: String? { nonEmpty(item?.item.summary) }
    private var eventSummary: String? { nonEmpty(event?.summary) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                Divider()
                article
                if let eventSummary, eventSummary != sourceSummary {
                    Divider()
                    readingSection("事件摘要", text: eventSummary)
                }
                if reports.contains(where: { $0.id != row.id }) {
                    Divider()
                    relatedReports
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 790, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                if let tabTitle {
                    Text(tabTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                }
                if let event, event.status == "major", tabTitle != "重大事件" {
                    StatusPill(title: "重大事件")
                }
            }

            Text(row.title)
                .font(.system(size: 31, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { metadata }.fixedSize()
                VStack(alignment: .leading, spacing: 6) { metadata }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let originalURL {
                    Link(destination: originalURL) {
                        Label("打开原文", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(action: openAnalysis) {
                    Label("深入分析", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var metadata: some View {
        Label(row.sourceTitle, systemImage: "newspaper")
        if let rank = row.rank {
            Text("榜位 \(rank)")
                .monospacedDigit()
        }
        if let category = nonEmpty(event?.category) {
            Label(category, systemImage: "tag")
        }
        UpdateTimeLabel(date: updateDate)
    }

    @ViewBuilder
    private var article: some View {
        if let sourceSummary {
            readingSection("新闻摘要", text: sourceSummary)
        } else if eventSummary == nil {
            VStack(alignment: .leading, spacing: 7) {
                SectionHeading(title: "新闻内容")
                Text(originalURL == nil ? "来源暂未提供正文或摘要。" : "来源暂未提供摘要，可打开原文阅读。")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readingSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeading(title: title)
            Text(text)
                .font(.system(size: 16))
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var relatedReports: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeading(title: "相关报道")
                .padding(.bottom, 4)

            ForEach(reports.filter { $0.id != row.id }) { report in
                Link(destination: report.item.url) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.item.title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                            Text(sourceNames[report.item.sourceID] ?? report.item.sourceID)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(SelectableButtonStyle())
            }
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

@MainActor
private struct AnalysisConversationView: View {
    static let initialPrompt = "这条新闻发生了什么？请整理已知事实、时间线和待确认的信息。"

    @ObservedObject var chat: AnalysisChatModel
    @ObservedObject var browserTools: BrowserToolBroker
    let row: SnapshotRow?
    @Binding var draft: String
    @Binding var researchMode: Bool
    let hasConnection: Bool
    let researchRestriction: String?
    let send: (String, SnapshotRow.ID) -> Void
    let retry: (SnapshotRow.ID) -> Void
    let openSource: (URL) -> Void
    let endSession: (SnapshotRow.ID) -> Void
    let close: () -> Void
    @State private var confirmingEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if chat.supportsResearch {
                Picker("对话方式", selection: $researchMode) {
                    Text("直接回答").tag(false)
                    Text("深度研究").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                if researchMode {
                    if let researchRestriction {
                        Label(researchRestriction, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                    }
                    Label("研究会使用应用内的站点登录状态。网页脚本可能未经确认发送后台请求；读取的内容会发送给所选模型。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                } else {
                    Text("启用深度研究后，可搜索和操作 AI 页面。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
            Divider()
            if let row {
                let session = chat.session(for: row.id)
                transcript(row: row, session: session)
                    .id(row.id)
                Divider()
                composer(itemID: row.id, isStreaming: session.isStreaming)
            } else {
                ContentUnavailableView(
                    "选择热点后开始对话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("每条热点有自己的对话。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PaneSurface(role: .inspector))
        .onDisappear {
            browserTools.resolvePermission(.deny)
            browserTools.resolveMCPPermission(false)
            browserTools.resolveLogin(false)
            browserTools.resolveAction(false)
        }
        .confirmationDialog("结束当前对话？", isPresented: $confirmingEnd) {
            if let row { Button("结束对话", role: .destructive) { endSession(row.id) } }
        } message: {
            Text("本次对话和研究材料将从内存中清除。")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 对话")
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let row {
                    Text(row.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(row.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let row, !chat.session(for: row.id).messages.isEmpty {
                Button { confirmingEnd = true } label: {
                    Label("结束对话", systemImage: "trash").labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }.buttonStyle(SelectableButtonStyle()).help("结束对话并清除研究材料")
            }
            Button(action: close) {
                Label("隐藏 AI 对话", systemImage: "sidebar.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(SelectableButtonStyle())
            .help("隐藏 AI 对话")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var researchBlocked: Bool { researchMode && researchRestriction != nil }

    private func transcript(row: SnapshotRow, session: AnalysisChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if !hasConnection {
                        configurationNotice
                    }
                    if let permission = browserTools.permission, permission.itemID == row.id {
                        permissionCard(permission)
                            .id(permission.id)
                    }
                    if let permission = browserTools.mcpPermission, permission.itemID == row.id {
                        mcpPermissionCard(permission)
                            .id(permission.id)
                    }
                    if let login = browserTools.loginRequest, login.itemID == row.id {
                        loginCard(login)
                            .id(login.id)
                    }
                    if let action = browserTools.actionRequest, action.itemID == row.id {
                        actionCard(action).id(action.id)
                    }
                    if let outcome = browserTools.actionOutcome, outcome.itemID == row.id {
                        Label(outcome.message, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if session.messages.isEmpty && session.error == nil {
                        intro(itemID: row.id, isStreaming: session.isStreaming)
                    }
                    ForEach(session.messages) { message in
                        if !message.text.isEmpty {
                            messageView(message, itemID: row.id)
                        }
                    }
                    if session.modelRequests > 0 {
                        Text("已完成请求：\(session.modelRequests) 次 · \(session.estimatedUsage ? "约 " : "")\(session.usageTokens) tokens")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !session.activityLog.isEmpty {
                        DisclosureGroup("研究过程（\(session.activityLog.count)）") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(session.activityLog.enumerated()), id: \.offset) { _, activity in
                                    Label(activity, systemImage: "circle.dotted")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.top, 6)
                        }.font(.caption)
                    }
                    if session.isStreaming {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(session.activity ?? "正在生成…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let error = session.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            if hasConnection && !session.isStreaming {
                                Button("重试", systemImage: "arrow.clockwise") { retry(row.id) }
                                    .buttonStyle(.bordered)
                                    .disabled(researchBlocked)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("conversation-bottom")
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .onChange(of: session.messages.count, initial: true) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                if session.isStreaming { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: session.isStreaming) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .onChange(of: session.error) { _, error in
                if error != nil { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: browserTools.permission?.id) { _, id in
                if let id, browserTools.permission?.itemID == row.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: browserTools.mcpPermission?.id) { _, id in
                if let id, browserTools.mcpPermission?.itemID == row.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: browserTools.loginRequest?.id) { _, id in
                if let id, browserTools.loginRequest?.itemID == row.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: browserTools.actionRequest?.id) { _, id in
                if let id, browserTools.actionRequest?.itemID == row.id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func permissionCard(_ permission: BrowserToolBroker.PermissionRequest) -> some View {
        CardSurface(padding: 13) {
            VStack(alignment: .leading, spacing: 8) {
                Label(permission.wantsOperation ? "申请操作用户页面" : "申请读取用户页面", systemImage: "hand.raised")
                    .font(.system(size: 14, weight: .semibold))
                Text("任务：\(permission.taskTitle)").lineLimit(2).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(permission.title).lineLimit(2)
                Text(permission.address).lineLimit(1).foregroundStyle(.secondary)
                Text(permission.reason).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(permission.wantsOperation ? "允许后，AI 可观察和操作这个页面；通过工具执行的表单和按钮操作会逐次确认。网页自身脚本可能另行发送请求。" : "允许后，当前页面的可见文字会发送给所选模型。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    if permission.wantsOperation {
                        Button("本轮允许操作") { browserTools.resolvePermission(.operateForRun) }
                        Button("仅允许读取") { browserTools.resolvePermission(.readForRun) }
                    } else {
                        Button("本轮允许") { browserTools.resolvePermission(.readForRun) }
                    }
                    Button("在 AI 标签中打开") { browserTools.resolvePermission(.openAIPage) }
                    Button("拒绝") { browserTools.resolvePermission(.deny) }
                }.controlSize(.small)
            }
        }
    }

    private func loginCard(_ login: BrowserToolBroker.LoginRequest) -> some View {
        CardSurface(padding: 13) {
            VStack(alignment: .leading, spacing: 8) {
                Label(login.requiresAction ? "等待用户处理页面操作" : "等待登录或验证", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 14, weight: .semibold))
                Text("任务：\(login.taskTitle)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Text(login.address).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                if let method = login.actionMethod, let address = login.actionAddress {
                    Text("待处理操作：\(method) \(address)")
                        .font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    Text("打开页面后，请检查操作内容并自行决定是否提交。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(login.requiresAction ? "打开页面，检查并手动处理页面操作；返回原站点后可继续研究。AI 将读取此标签当前页面的可见文字。" : "打开页面并完成验证，返回原站点后继续。AI 将读取此标签当前页面的可见文字。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let message = browserTools.loginMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(login.requiresAction ? "打开页面" : "打开验证页面") { browserTools.showLoginPage() }
                    Button("完成并继续") { browserTools.resumeAfterLogin() }
                    Button("取消") { browserTools.resolveLogin(false) }
                }.controlSize(.small)
            }
        }
    }

    private func actionCard(_ action: BrowserToolBroker.ActionRequest) -> some View {
        CardSurface(padding: 13) {
            VStack(alignment: .leading, spacing: 8) {
                Label("确认页面操作", systemImage: "hand.raised")
                    .font(.system(size: 14, weight: .semibold))
                Text("任务：\(action.taskTitle)").font(.caption).foregroundStyle(.secondary)
                Text("页面：\(action.pageAddress)").font(.caption).textSelection(.enabled)
                Text("操作：\(action.title)").font(.system(size: 12, weight: .medium))
                Text("\(action.method) \(action.destination)").font(.caption).textSelection(.enabled)
                if !action.fields.isEmpty {
                    Text("本次操作内容").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(action.fields.enumerated()), id: \.offset) { _, field in
                                Text(field).font(.system(size: 11)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 150)
                }
                Text(action.method.hasPrefix("网页输入") ? "确认后填写此输入框。站点可能在输入时发送请求；提交表单将单独确认。" :
                    (action.method == "网页按钮" ? "确认后网页将执行此按钮及其网站脚本，请核对执行结果。" : "确认后网页将执行此按钮；隐藏字段由网站处理。提交后请核对结果。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("确认本次操作") { browserTools.resolveAction(true) }
                    Button("拒绝") { browserTools.resolveAction(false) }
                }.controlSize(.small)
            }
        }
    }

    private func mcpPermissionCard(_ permission: BrowserToolBroker.MCPPermissionRequest) -> some View {
        CardSurface(padding: 13) {
            VStack(alignment: .leading, spacing: 8) {
                Label("确认扩展工具调用", systemImage: "hand.raised")
                    .font(.system(size: 14, weight: .semibold))
                Text("任务：\(permission.taskTitle)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("服务：\(permission.serverName) · 工具：\(permission.toolName)")
                    .font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                Text("调用参数") .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(permission.argumentsJSON).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
                HStack {
                    Button("允许本次调用") { browserTools.resolveMCPPermission(true) }
                    Button("拒绝") { browserTools.resolveMCPPermission(false) }
                }.controlSize(.small)
            }
        }
    }

    private var configurationNotice: some View {
        CardSurface(padding: 13) {
            VStack(alignment: .leading, spacing: 7) {
                Label("配置分析模型", systemImage: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                Text("在设置的「AI 分析」中添加模型连接和 API Key，再为「深入分析」分配该连接。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func intro(itemID: SnapshotRow.ID, isStreaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "从一个问题开始", detail: "围绕当前热点提问，也可以继续追问细节。")
            if hasConnection {
                promptButton("发生了什么？", prompt: Self.initialPrompt, itemID: itemID)
                promptButton("有哪些影响？", prompt: "这条新闻可能带来哪些影响？请区分已知影响与推测。", itemID: itemID)
            }
        }
        .disabled(isStreaming)
    }

    private func messageView(_ message: AnalysisChatMessage, itemID: String) -> some View {
        let isUser = if case .user = message.role { true } else { false }
        let citations = browserTools.evidence.citations(in: message.text, itemID: itemID, allowedEvidenceIDs: message.evidenceIDs)
        return VStack(alignment: .leading, spacing: 6) {
            Label(isUser ? "你" : "AI", systemImage: isUser ? "person.crop.circle" : "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isUser ? Color.secondary : AppTheme.accent)
                .accessibilityAddTraits(.isHeader)
            Text(message.text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !isUser && !citations.valid.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(citations.valid) { source in
                        Button { openSource(source.url) } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Text("[\(source.id)]").monospaced()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title.isEmpty ? (source.url.host ?? "网页来源") : source.title)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    Text("\(source.level.rawValue) · \(source.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right.square")
                            }
                        }.buttonStyle(.plain).foregroundStyle(AppTheme.accent)
                    }
                }.padding(.top, 4)
            }
            if !isUser && !citations.unknown.isEmpty {
                Label("无法验证引用：\(citations.unknown.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(isUser ? 11 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUser ? Color.primary.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func promptButton(_ title: String, prompt: String, itemID: SnapshotRow.ID) -> some View {
        Button(title) { send(prompt, itemID) }
            .buttonStyle(.bordered)
            .disabled(researchBlocked)
    }

    private func composer(itemID: SnapshotRow.ID, isStreaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("就这条热点提问…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .lineLimit(2...5)
                .accessibilityLabel("对话输入")
                .disabled(!hasConnection)

            HStack {
                if !isStreaming, hasConnection, case .assistant? = chat.session(for: itemID).messages.last?.role {
                    promptButton("继续分析", prompt: "请继续分析，补充尚待确认的信息和接下来值得关注的线索。", itemID: itemID)
                }
                Spacer()
                if isStreaming {
                    Button("停止", systemImage: "stop.fill") {
                        chat.cancel(itemID: itemID)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("发送", systemImage: "arrow.up") {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        send(text, itemID)
                        draft = ""
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasConnection || researchBlocked || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("发送（⌘↩）")
                }
            }
        }
        .padding(14)
        .background(SurfacePalette.inspector)
    }
}
