import SwiftUI
import TrendingTabCore
import TrendingTabKit
import TrendingTabSources
import UniformTypeIdentifiers

private enum SettingsSection: String, CaseIterable, Identifiable {
    case tabs
    case sources
    case refresh
    case ai
    case notifications
    case diagnostics
    case update

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tabs: "榜单标签"
        case .sources: "数据源"
        case .refresh: "自动采集"
        case .ai: "AI 分析"
        case .notifications: "通知"
        case .diagnostics: "诊断"
        case .update: "软件更新"
        }
    }

    var detail: String {
        switch self {
        case .tabs: "管理小组件和事件中心里的标签顺序与可见性。"
        case .sources: "查看各类来源的可用状态，并配置微信公众号订阅。"
        case .refresh: "设置采集间隔和自动采集行为。"
        case .ai: "配置模型连接，以及分类、摘要和深入分析任务。"
        case .notifications: "控制提醒开关、静默时段和发送频率。"
        case .diagnostics: "查看每个来源最近一次采集状态。"
        case .update: "检查新版本、查看发行说明并安装更新。"
        }
    }

    var systemImage: String {
        switch self {
        case .tabs: "rectangle.3.group"
        case .sources: "network"
        case .refresh: "arrow.triangle.2.circlepath"
        case .ai: "sparkles"
        case .notifications: "bell"
        case .diagnostics: "stethoscope"
        case .update: "arrow.down.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: TrendingAppModel
    @State private var selection: SettingsSection = .tabs
    @State private var interval = 15.0
    @State private var connectionName = ""
    @State private var modelName = ""
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var credential = ""
    @State private var protocolKind = AIProtocolKind.openAIResponses
    @State private var wechatURL = ""
    @State private var draggingTabID: UUID?
    @State private var boardOptions: [BoardDescriptor] = []

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 176)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    pageHeader
                    sectionContent
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .id(selection)
            .background(AppTheme.canvas)
        }
        .frame(minWidth: 800, idealWidth: 900, minHeight: 540, idealHeight: 640)
        .tint(AppTheme.actionTint)
        .onAppear {
            interval = model.settings.refreshInterval / 60
            wechatURL = model.feeds.first(where: { $0.id == "wechat" })?.feedURL.absoluteString ?? ""
        }
        .task {
            await loadBoardOptions()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置")
                .font(.system(size: 21, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(SettingsSection.allCases) { section in
                    let selected = selection == section
                    Button {
                        selection = section
                    } label: {
                        Label {
                            Text(section.title)
                                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: section.systemImage)
                                .foregroundStyle(selected ? AppTheme.accent : Color.secondary)
                                .frame(width: 20)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(SelectableButtonStyle(selected: selected))
                }
            }

            Spacer()

            Text("版本 \(model.currentVersion)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 22)
        .background(AppTheme.sidebar)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selection.title)
                .font(.system(size: 29, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(selection.detail)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .tabs: tabsSettings
        case .sources: sourcesSettings
        case .refresh: refreshSettings
        case .ai: aiSettings
        case .notifications: notificationSettings
        case .diagnostics: diagnosticsSettings
        case .update: updateSettings
        }
    }

    private var tabsSettings: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    SectionHeading(title: "标签顺序", detail: "拖动可排序；显示、监测和提醒分别配置。")
                    Spacer()
                    Menu {
                        ForEach(boardOptions) { board in
                            Button {
                                model.addBoardTab(board)
                            } label: {
                                let source = SourceCatalog.provider(id: board.sourceID)?.descriptor.title ?? board.sourceID
                                Label("\(source) · \(board.title)", systemImage: tabsContain(board) ? "checkmark" : "plus")
                            }
                            .disabled(tabsContain(board))
                        }
                    } label: {
                        Label("添加榜单", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .help("拖动排序")
                            .onDrag {
                                draggingTabID = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tab.title).font(.system(size: 15, weight: .medium))
                            Text(tab.kindTitle).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("显示", isOn: Binding(
                            get: { !tab.hidden },
                            set: { model.setTabHidden(tab.id, hidden: !$0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("显示 \(tab.title)")
                        Toggle("监测", isOn: Binding(
                            get: { tab.monitoringEnabled },
                            set: { model.setTabMonitoring(tab.id, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("监测 \(tab.title)")
                        Toggle("提醒", isOn: Binding(
                            get: { tab.notification.enabled },
                            set: { model.setTabNotifications(tab.id, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("提醒 \(tab.title)")
                        Button {
                            model.moveTab(id: tab.id, direction: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("上移标签")
                        .accessibilityLabel("上移 \(tab.title)")
                        Button {
                            model.moveTab(id: tab.id, direction: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == model.tabs.count - 1)
                        .help("下移标签")
                        .accessibilityLabel("下移 \(tab.title)")
                        Button(role: .destructive) {
                            model.removeTab(id: tab.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.tabs.count == 1)
                        .help("删除标签")
                        .accessibilityLabel("删除 \(tab.title)")
                    }
                    .padding(.vertical, 6)
                    .onDrop(
                        of: [UTType.text],
                        delegate: TabDropDelegate(
                            destinationID: tab.id,
                            draggingTabID: $draggingTabID,
                            model: model
                        )
                    )
                    if index != model.tabs.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private var sourcesSettings: some View {
        let providers = SourceCatalog.providers(customFeeds: model.feeds)
        return VStack(spacing: 16) {
            CardSurface {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "微信输入", detail: "填写公众号 RSS 或供应方热文接口")
                    LabeledContent("订阅地址") {
                        TextField("https://example.com/wechat.xml", text: $wechatURL)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("订阅地址")
                    }
                    HStack {
                        Text("凭据和订阅地址只保存在本机。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("保存地址") {
                            guard let url = URL(string: wechatURL) else { return }
                            model.updateWeChatFeed(url)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            ForEach(SourceCategory.allCases, id: \.self) { category in
                let items = providers.filter { $0.descriptor.category == category }
                if !items.isEmpty {
                    CardSurface {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeading(title: category.title, detail: "\(items.count) 个来源")
                            ForEach(items, id: \.descriptor.id) { provider in
                                HStack {
                                    Circle()
                                        .fill(provider.descriptor.availability == .available ? Color.green : Color.orange)
                                        .frame(width: 7, height: 7)
                                    Text(provider.descriptor.title)
                                    Spacer()
                                    Text(availabilityTitle(provider.descriptor.availability))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var refreshSettings: some View {
        VStack(spacing: 16) {
            CardSurface {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "自动采集", detail: "后台进程按设定间隔拉取已启用榜单")
                    Toggle("启用自动采集", isOn: Binding(
                        get: { model.settings.automaticCollectionEnabled },
                        set: { value in
                            updateSettings { $0.automaticCollectionEnabled = value }
                        }
                    ))
                    .toggleStyle(.switch)
                }
            }

            CardSurface {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "刷新间隔", detail: "允许 5 到 1440 分钟")
                    HStack {
                        Stepper(value: $interval, in: 5...1440, step: 5) {
                            Text("每 \(Int(interval)) 分钟")
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                        }
                        Spacer()
                        Button("应用") {
                            updateSettings { $0.refreshInterval = interval * 60 }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("小组件的实际刷新时间仍由 WidgetKit 调度；这里控制本地数据采集。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var aiSettings: some View {
        VStack(spacing: 16) {
            CardSurface {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        SectionHeading(title: "自动分析", detail: "未启用时仍会正常采集和展示热点")
                        Spacer()
                        Toggle("自动分析", isOn: Binding(
                            get: { model.settings.aiEnabled },
                            set: { value in updateSettings { $0.aiEnabled = value } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            CardSurface {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "模型连接", detail: "API Key 保存在 macOS Keychain")
                    LabeledContent("连接名称") {
                        TextField("可选", text: $connectionName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("连接名称")
                    }
                    Picker("协议", selection: $protocolKind) {
                        ForEach(AIProtocolKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    LabeledContent("API 根地址") {
                        TextField("https://api.openai.com/v1", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("API 根地址")
                    }
                    LabeledContent("模型名称") {
                        TextField("模型 ID", text: $modelName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("模型名称")
                    }
                    LabeledContent("API Key") {
                        SecureField("输入 API Key", text: $credential)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("API Key")
                    }
                    HStack {
                        Spacer()
                        Button("添加连接") {
                            guard let url = URL(string: baseURL), !modelName.isEmpty else { return }
                            let account = "ai-\(UUID().uuidString)"
                            model.addConnection(
                                AIConnection(
                                    name: connectionName.isEmpty ? modelName : connectionName,
                                    kind: protocolKind,
                                    baseURL: url,
                                    model: modelName,
                                    credentialAccount: account
                                ),
                                credential: credential
                            )
                            credential = ""
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            if !model.connections.isEmpty {
                CardSurface {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "任务分配", detail: "为不同任务选择模型连接")
                        assignmentPicker("自动分类", task: .classification)
                        assignmentPicker("消息摘要", task: .summary)
                        assignmentPicker("深入分析", task: .analysis)
                    }
                }
            }
        }
    }

    private var notificationSettings: some View {
        VStack(spacing: 16) {
            CardSurface {
                HStack {
                    SectionHeading(title: "系统提醒", detail: "事件中心始终保留内容，通知可单独关闭")
                    Spacer()
                    Toggle("系统提醒", isOn: Binding(
                        get: { model.settings.globalNotification.enabled },
                        set: { value in updateSettings { $0.globalNotification.enabled = value } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            CardSurface {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "发送规则", detail: "跨标签命中会合并成一次提醒")
                    Stepper("静默开始：\(model.settings.globalNotification.quietHoursStart):00", value: Binding(
                        get: { model.settings.globalNotification.quietHoursStart },
                        set: { value in updateSettings { $0.globalNotification.quietHoursStart = min(max(value, 0), 23) } }
                    ), in: 0...23)
                    Stepper("静默结束：\(model.settings.globalNotification.quietHoursEnd):00", value: Binding(
                        get: { model.settings.globalNotification.quietHoursEnd },
                        set: { value in updateSettings { $0.globalNotification.quietHoursEnd = min(max(value, 0), 23) } }
                    ), in: 0...23)
                    Stepper("每小时最多 \(model.settings.globalNotification.hourlyLimit) 次", value: Binding(
                        get: { model.settings.globalNotification.hourlyLimit },
                        set: { value in updateSettings { $0.globalNotification.hourlyLimit = max(1, value) } }
                    ), in: 1...20)
                    Stepper("每天最多 \(model.settings.globalNotification.dailyLimit) 次", value: Binding(
                        get: { model.settings.globalNotification.dailyLimit },
                        set: { value in updateSettings { $0.globalNotification.dailyLimit = max(1, value) } }
                    ), in: 1...50)
                }
            }
        }
    }

    private var diagnosticsSettings: some View {
        VStack(spacing: 12) {
            if model.diagnostics.isEmpty {
                CardSurface {
                    ContentUnavailableView(
                        "还没有诊断记录",
                        systemImage: "stethoscope",
                        description: Text("完成一次采集后会显示每个来源的状态。")
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(model.diagnostics) { record in
                    CardSurface(padding: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(diagnosticColor(record.state))
                                .frame(width: 8, height: 8)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).font(.body.weight(.medium))
                                Text(record.message).font(.caption).foregroundStyle(.secondary)
                                if let success = record.lastSuccessAt {
                                    Text(success.trendingRelativeText).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            StatusPill(title: record.state, color: diagnosticColor(record.state))
                        }
                    }
                }
            }
        }
    }

    private var updateSettings: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("TrendingTab \(model.currentVersion)").font(.title2.weight(.semibold))
                        Text(model.updateState).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: model.availableRelease == nil ? "shippingbox" : "arrow.down.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(model.availableRelease == nil ? Color.secondary : AppTheme.accent)
                }

                if let release = model.availableRelease {
                    Divider()
                    LabeledContent("可用版本", value: release.version)
                    if !release.notes.isEmpty {
                        Text(release.notes).font(.callout).textSelection(.enabled)
                    }
                }

                HStack {
                    Button("检查更新") {
                        Task { await model.checkForUpdate() }
                    }
                    .buttonStyle(.bordered)
                    Button("一键更新") {
                        Task {
                            if await model.installAvailableUpdate() {
                                NSApp.terminate(nil)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.availableRelease == nil)
                    Spacer()
                }
            }
        }
    }

    private func assignmentPicker(_ title: String, task: AITask) -> some View {
        Picker(title, selection: Binding<UUID?>(
            get: { model.assignment.connectionID(for: task) },
            set: { value in
                var copy = model.assignment
                switch task {
                case .classification: copy.classification = value
                case .summary: copy.summary = value
                case .analysis: copy.analysis = value
                }
                model.updateAssignment(copy)
            }
        )) {
            Text("未指定").tag(UUID?.none)
            ForEach(model.connections) { connection in
                Text(connection.name).tag(Optional(connection.id))
            }
        }
    }

    private func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var copy = model.settings
        mutate(&copy)
        model.updateSettings(copy)
    }

    private func availabilityTitle(_ availability: SourceAvailability) -> String {
        switch availability {
        case .available: "可用"
        case .requiresConfiguration: "需要配置"
        case .unavailable: "暂不可用"
        }
    }

    private func diagnosticColor(_ state: String) -> Color {
        switch state {
        case "success": .green
        case "empty", "cached": .blue
        case "failed": .red
        default: .orange
        }
    }

    private func tabsContain(_ board: BoardDescriptor) -> Bool {
        model.tabs.contains { $0.kind == .sourceBoard && $0.boardIDs == [board.id] }
    }

    private func loadBoardOptions() async {
        guard boardOptions.isEmpty else { return }
        var loaded: [BoardDescriptor] = []
        for provider in SourceCatalog.providers(customFeeds: model.feeds) {
            loaded.append(contentsOf: (try? await provider.boards()) ?? [])
        }
        boardOptions = loaded.sorted { lhs, rhs in
            let left = SourceCatalog.provider(id: lhs.sourceID)?.descriptor.category.rawValue ?? lhs.sourceID
            let right = SourceCatalog.provider(id: rhs.sourceID)?.descriptor.category.rawValue ?? rhs.sourceID
            return left == right ? lhs.title < rhs.title : left < right
        }
    }
}

private extension TabDefinition {
    var kindTitle: String {
        switch kind {
        case .sourceBoard: "平台榜单"
        case .aggregate: "聚合标签"
        case .majorEvents: "重大事件"
        case .topic: "主题标签"
        case .trackedEvents: "事件追踪"
        }
    }
}

private struct TabDropDelegate: DropDelegate {
    let destinationID: UUID
    @Binding var draggingTabID: UUID?
    let model: TrendingAppModel

    func dropEntered(info: DropInfo) {
        guard let draggingTabID else { return }
        model.moveTab(id: draggingTabID, to: destinationID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingTabID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
