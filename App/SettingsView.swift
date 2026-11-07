import SwiftUI
import TrendingTabCore
import TrendingTabKit
import TrendingTabIntelligence
import TrendingTabSources
import UniformTypeIdentifiers
import WebKit

private enum SettingsSection: String, CaseIterable, Identifiable {
    case tabs
    case sources
    case refresh
    case ai
    case browser
    case runtime
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
        case .browser: "浏览器"
        case .runtime: "Agent 运行时"
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
        case .browser: "管理应用内浏览器的网站数据和登录状态。"
        case .runtime: "查看运行时版本，检查更新或回退到上一版本。"
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
        case .browser: "globe"
        case .runtime: "cpu"
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
    @State private var modelTimeout = 45
    @State private var modelOutputTokens = 1200
    @State private var modelContextWindow = 128_000
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var credential = ""
    @State private var customHeaders = ""
    @State private var connectionMessage = ""
    @State private var confirmAutomaticRetry = false
    @State private var editingHeadersID: UUID?
    @State private var editedHeaders = ""
    @State private var editedHeadersMessage = ""
    @State private var editingConnectionID: UUID?
    @State private var editingCredentialID: UUID?
    @State private var editedCredential = ""
    @State private var editedCredentialMessage = ""
    @AppStorage("research.search.provider") private var researchSearchProvider = "web"
    @AppStorage("research.search.engine") private var researchSearchEngine = "bing"
    @State private var researchSearchKey = ""
    @State private var searchKeyMessage = ""
    @State private var mcpProfiles: [MCPProfile] = []
    @State private var mcpName = ""
    @State private var mcpType = "http"
    @State private var mcpAddress = ""
    @State private var mcpCommand = ""
    @State private var mcpArguments = "[]"
    @State private var mcpSecrets = ""
    @State private var mcpTools = ""
    @State private var mcpMessage = ""
    @State private var mcpDiscoveryID: String?
    @State private var mcpDiscoveryBusy = false
    @State private var mcpDiscovery: AgentMCPDiscovery?
    @State private var mcpSelectedTools: Set<String> = []
    @State private var websiteRecords: [WKWebsiteDataRecord] = []
    @State private var websiteRecordsLoaded = false
    @State private var websiteRecordsBusy = false
    @State private var testingConnectionID: UUID?
    @State private var connectionTestResults: [UUID: String] = [:]
    @State private var protocolKind = AIProtocolKind.openAIResponses
    @State private var wechatURL = ""
    @State private var draggingTabID: UUID?
    @State private var topicTitle = ""
    @State private var topicIncluded = ""
    @State private var topicExcluded = ""
    @State private var topicPrompt = ""
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
            .background(PaneSurface(role: .reader))
        }
        .frame(minWidth: 800, idealWidth: 900, minHeight: 540, idealHeight: 640)
        .tint(AppTheme.actionTint)
        .onAppear {
            interval = model.settings.refreshInterval / 60
            wechatURL = model.feeds.first(where: { $0.id == "wechat" })?.feedURL.absoluteString ?? ""
            mcpProfiles = MCPConfigurationStore.load()
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
        .background(PaneSurface(role: .sidebar))
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
        case .browser: browserSettings
        case .runtime: runtimeSettings
        case .notifications: notificationSettings
        case .diagnostics: diagnosticsSettings
        case .update: updateSettings
        }
    }

    private var tabsSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardSurface {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(title: "每个组件，各看各的榜单", detail: "在桌面右键组件，选择“编辑小组件”进行配置。")
                    Label("专用榜单：选择知乎、微博等“显示榜单”，开启“固定显示此榜单”。", systemImage: "pin")
                    Label("自由切换：关闭固定显示，同尺寸的多个组件分别选择“组件 1”“组件 2”等编号。", systemImage: "rectangle.on.rectangle")
                }
                .font(.system(size: 13))
            }
            tabOrderSettings
            CardSurface {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(title: "添加主题", detail: "关键词使用逗号分隔；语义描述通过自动分类模型处理。")
                    TextField("主题名称", text: $topicTitle).textFieldStyle(.roundedBorder)
                    TextField("包含关键词（可选）", text: $topicIncluded).textFieldStyle(.roundedBorder)
                    TextField("排除关键词（可选）", text: $topicExcluded).textFieldStyle(.roundedBorder)
                    TextField("语义描述（可选）", text: $topicPrompt).textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("添加主题") {
                            let split: (String) -> [String] = { $0.components(separatedBy: CharacterSet(charactersIn: ",，")) }
                            model.addTopicTab(title: topicTitle, included: split(topicIncluded), excluded: split(topicExcluded), semanticPrompt: topicPrompt)
                            topicTitle = ""; topicIncluded = ""; topicExcluded = ""; topicPrompt = ""
                        }.disabled(topicTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var tabOrderSettings: some View {
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
                    Stepper("每日自动请求上限：\(model.settings.dailyRequestLimit) 次", value: Binding(
                        get: { model.settings.dailyRequestLimit },
                        set: { value in updateSettings { $0.dailyRequestLimit = value } }
                    ), in: 1...10_000, step: 10)
                    Stepper("每日自动 token 上限：\(model.settings.dailyTokenLimit)", value: Binding(
                        get: { model.settings.dailyTokenLimit },
                        set: { value in updateSettings { $0.dailyTokenLimit = value } }
                    ), in: 1_000...10_000_000, step: 10_000)
                    Text("手动对话的用量单独显示；自动任务达到任一上限后暂停。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("自动摘要读取公开原文", isOn: Binding(
                        get: { model.settings.automaticSummaryReadOriginal },
                        set: { value in updateSettings { $0.automaticSummaryReadOriginal = value } }
                    ))
                    Text("重大事件摘要最多匿名读取 3 篇原文，每篇使用最多 6,000 字摘录并发送给摘要模型。读取失败时使用已有材料；正文只在本轮内存中保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.unknownAutomaticRuns > 0 {
                        HStack {
                            Text("\(model.unknownAutomaticRuns) 次自动任务的结果未知，已保守计入用量。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("允许重新分析") { confirmAutomaticRetry = true }
                        }
                    }
                }
            }
            .confirmationDialog("允许重新分析结果未知的任务？", isPresented: $confirmAutomaticRetry) {
                Button("允许重新分析") { model.retryUnknownAutomaticRuns() }
            } message: {
                Text("已有用量记录会保留；后续请求可能产生额外费用，并受每日预算限制。")
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
                    LabeledContent("自定义请求头") {
                        SecureField("可选，JSON 对象", text: $customHeaders)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("自定义请求头，JSON 对象")
                    }
                    Text("请求头保存在钥匙串，例如 {\"X-Project\":\"project-id\"}。")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("请求超时：\(modelTimeout) 秒", value: $modelTimeout, in: 5...180, step: 5)
                    Stepper("最大输出：\(modelOutputTokens) tokens", value: $modelOutputTokens, in: 256...32768, step: 256)
                    Stepper("上下文窗口：\(modelContextWindow) tokens", value: $modelContextWindow, in: 4096...1_048_576, step: 4096)
                    if modelOutputTokens > modelContextWindow {
                        Text("最大输出不能超过上下文窗口。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if !connectionMessage.isEmpty {
                            Text(connectionMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("添加连接") {
                            guard let url = URL(string: baseURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                                  url.host != nil, url.user == nil, url.password == nil,
                                  !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  !credential.isEmpty, modelOutputTokens <= modelContextWindow else {
                                connectionMessage = "请填写有效的 API 地址、模型和 API Key。"
                                return
                            }
                            let headers: [String: String]
                            do { headers = try AIRequestHeaders.parse(customHeaders) }
                            catch { connectionMessage = error.localizedDescription; return }
                            let account = "ai-\(UUID().uuidString)"
                            let saved = model.addConnection(
                                AIConnection(
                                    name: connectionName.isEmpty ? modelName : connectionName,
                                    kind: protocolKind,
                                    baseURL: url,
                                    model: modelName,
                                    credentialAccount: account,
                                    timeout: TimeInterval(modelTimeout),
                                    maxOutputTokens: modelOutputTokens,
                                    contextWindow: modelContextWindow
                                ),
                                credential: credential, headers: headers
                            )
                            if saved {
                                credential = ""
                                customHeaders = ""
                                connectionMessage = "连接已保存。"
                            } else { connectionMessage = "无法保存连接，请检查钥匙串访问权限。" }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(modelOutputTokens > modelContextWindow)
                    }
                }
            }

            CardSurface {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "研究搜索", detail: "选择搜索入口；搜索 API 密钥保存在钥匙串")
                    Picker("搜索方式", selection: $researchSearchProvider) {
                        Text("网页搜索").tag("web")
                        Text("Brave Search API").tag("brave")
                        Text("Tavily API").tag("tavily")
                    }
                    if researchSearchProvider == "web" {
                        Picker("默认搜索引擎", selection: $researchSearchEngine) {
                            Text("必应").tag("bing")
                            Text("百度").tag("baidu")
                            Text("Google").tag("google")
                        }
                    } else {
                        LabeledContent("API Key") {
                            SecureField("输入或更新密钥", text: $researchSearchKey).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text(searchKeyMessage).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("保存密钥") {
                                let value = researchSearchKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !value.isEmpty else { searchKeyMessage = "请输入 API Key。"; return }
                                if KeychainStore.save(value, account: "research-search-\(researchSearchProvider)") {
                                    researchSearchKey = ""
                                    searchKeyMessage = "密钥已保存。"
                                } else { searchKeyMessage = "无法保存密钥，请检查钥匙串访问权限。" }
                            }
                        }
                    }
                }
            }

            mcpSettings

            if !model.connections.isEmpty {
                CardSurface {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "连接测试", detail: "测试会向所选模型发起请求，可能产生费用。")
                        ForEach(model.connections) { connection in
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(connection.name) · \(connection.model)").fontWeight(.medium)
                                HStack {
                                    Button("测试流式") { testConnection(connection.id, kind: .streaming) }
                                    Button("测试结构化输出") { testConnection(connection.id, kind: .structured) }
                                    Button("测试工具调用") { testConnection(connection.id, kind: .tools) }
                                    Button("编辑连接") { editingConnectionID = connection.id }
                                    Button("更新密钥") {
                                        editingCredentialID = connection.id
                                        editedCredential = ""
                                        editedCredentialMessage = ""
                                    }
                                    Button("设置请求头") {
                                        editingHeadersID = connection.id
                                        editedHeaders = ""
                                        editedHeadersMessage = ""
                                    }
                                    if testingConnectionID == connection.id { ProgressView().controlSize(.small) }
                                }.disabled(testingConnectionID != nil)
                                if editingConnectionID == connection.id {
                                    ConnectionEditor(connection: connection, model: model) {
                                        editingConnectionID = nil
                                    }
                                    .id(connection.id)
                                }
                                if editingCredentialID == connection.id {
                                    SecureField("输入新的 API Key", text: $editedCredential)
                                        .textFieldStyle(.roundedBorder)
                                    HStack {
                                        Text(editedCredentialMessage).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("取消") { editingCredentialID = nil; editedCredential = "" }
                                        Button("保存密钥") {
                                            guard model.updateConnectionCredential(connection.id, credential: editedCredential) else {
                                                editedCredentialMessage = "请输入密钥并检查钥匙串访问权限。"
                                                return
                                            }
                                            editedCredential = ""
                                            editingCredentialID = nil
                                            connectionTestResults[connection.id] = "密钥已更新。"
                                        }
                                    }
                                }
                                if editingHeadersID == connection.id {
                                    SecureField("输入完整的 JSON 请求头，留空清除", text: $editedHeaders)
                                        .textFieldStyle(.roundedBorder)
                                    HStack {
                                        Text(editedHeadersMessage).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("取消") { editingHeadersID = nil; editedHeaders = "" }
                                        Button("保存请求头") {
                                            do {
                                                let headers = try AIRequestHeaders.parse(editedHeaders)
                                                guard model.setConnectionHeaders(connection.id, headers: headers) else {
                                                    editedHeadersMessage = "无法保存请求头，请检查钥匙串访问权限。"
                                                    return
                                                }
                                                editedHeaders = ""
                                                editingHeadersID = nil
                                                connectionTestResults[connection.id] = "请求头已保存。"
                                            } catch { editedHeadersMessage = error.localizedDescription }
                                        }
                                    }
                                }
                                if let result = connectionTestResults[connection.id] {
                                    Text(result).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
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

    private var mcpSettings: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "MCP 扩展工具", detail: "深度研究可使用已启用的工具；每次调用前需要确认。连接配置保存在钥匙串。")
                ForEach(mcpProfiles) { profile in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(profile.server.name).fontWeight(.medium)
                            Text("\(profile.server.config.type == "http" ? "Streamable HTTP" : "本地 stdio") · \(profile.server.enabledTools.isEmpty ? "未启用工具" : profile.server.enabledTools.joined(separator: "、"))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("发现工具") { discoverMCPTools(profile) }.disabled(mcpDiscoveryBusy)
                        Button(profile.enabled ? "停用" : "启用") {
                            var next = mcpProfiles
                            guard let index = next.firstIndex(where: { $0.id == profile.id }) else { return }
                            next[index].enabled.toggle()
                            if MCPConfigurationStore.save(next) { mcpProfiles = next; mcpMessage = "连接已更新。" }
                            else { mcpMessage = "无法保存连接，请检查钥匙串访问权限。" }
                        }
                        Button("删除", role: .destructive) {
                            let next = mcpProfiles.filter { $0.id != profile.id }
                            if MCPConfigurationStore.save(next) { mcpProfiles = next; mcpMessage = "连接已删除。" }
                            else { mcpMessage = "无法保存连接，请检查钥匙串访问权限。" }
                        }
                    }
                    if mcpDiscoveryID == profile.id, let discovery = mcpDiscovery {
                        VStack(alignment: .leading, spacing: 6) {
                            if discovery.tools.isEmpty { Text("服务没有提供工具。") .font(.caption).foregroundStyle(.secondary) }
                            ForEach(discovery.tools) { tool in
                                Toggle(isOn: Binding(get: { mcpSelectedTools.contains(tool.name) }, set: { selected in
                                    if selected { mcpSelectedTools.insert(tool.name) } else { mcpSelectedTools.remove(tool.name) }
                                })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name).font(.system(size: 12, weight: .medium))
                                        if !tool.description.isEmpty { Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                    }
                                }
                            }
                            if discovery.truncated { Text("当前仅显示前 100 个工具，未显示的已启用工具会保留。") .font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Button("取消") { mcpDiscoveryID = nil; mcpDiscovery = nil }
                                Button("保存工具选择") {
                                    var next = mcpProfiles
                                    guard let index = next.firstIndex(where: { $0.id == profile.id }) else { return }
                                    let discovered = Set(discovery.tools.map(\.name))
                                    let retained = discovery.truncated ? Set(profile.server.enabledTools).subtracting(discovered) : []
                                    let selected = retained.union(mcpSelectedTools).sorted()
                                    guard selected.count <= 100 else { mcpMessage = "每个连接最多启用 100 个工具。"; return }
                                    next[index].server.enabledTools = selected
                                    if MCPConfigurationStore.save(next) { mcpProfiles = next; mcpDiscoveryID = nil; mcpDiscovery = nil; mcpMessage = "工具选择已保存。" }
                                    else { mcpMessage = "无法保存工具选择。" }
                                }
                            }.controlSize(.small)
                        }.padding(.leading, 8)
                    }
                    Divider()
                }
                TextField("连接名称", text: $mcpName).textFieldStyle(.roundedBorder)
                Picker("传输方式", selection: $mcpType) {
                    Text("Streamable HTTP").tag("http")
                    Text("本地 stdio").tag("stdio")
                }
                if mcpType == "http" {
                    TextField("服务地址，例如 https://example.com/mcp", text: $mcpAddress).textFieldStyle(.roundedBorder)
                    SecureField("请求头 JSON，可选", text: $mcpSecrets).textFieldStyle(.roundedBorder)
                } else {
                    TextField("可执行文件的绝对路径", text: $mcpCommand).textFieldStyle(.roundedBorder)
                    TextField("启动参数 JSON 数组，例如 []", text: $mcpArguments).textFieldStyle(.roundedBorder)
                    SecureField("环境变量 JSON 对象，可选", text: $mcpSecrets).textFieldStyle(.roundedBorder)
                    Text("本地连接会运行所选程序，请使用你信任的服务。") .font(.caption).foregroundStyle(.secondary)
                }
                TextField("启用的工具名称，用逗号分隔，也可保存后发现", text: $mcpTools).textFieldStyle(.roundedBorder)
                HStack {
                    Text(mcpMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("添加 MCP 连接") { addMCPConnection() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func addMCPConnection() {
        let name = mcpName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = mcpTools.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !name.isEmpty, name.count <= 200, mcpProfiles.count < 8, tools.count <= 100,
              tools.allSatisfy({ $0.count <= 256 }), Set(tools).count == tools.count else {
            mcpMessage = "请填写连接名称和不重复的工具名称，最多添加 8 个连接。"; return
        }
        let secrets: [String: String]
        if mcpSecrets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { secrets = [:] }
        else if let data = mcpSecrets.data(using: .utf8), data.count <= 32_768,
                let decoded = try? JSONDecoder().decode([String: String].self, from: data) { secrets = decoded }
        else { mcpMessage = "请求头或环境变量应为 JSON 字符串对象。"; return }
        let config: AgentMCPServer.Configuration
        if mcpType == "http" {
            guard let url = URL(string: mcpAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  AIRequestHeaders.valid(secrets),
                  !secrets.keys.contains(where: { ["mcp-session-id", "mcp-protocol-version"].contains($0.lowercased()) }) else {
                mcpMessage = "请填写有效的服务地址和请求头。"; return
            }
            config = .init(type: "http", url: url.absoluteString, headers: secrets)
        } else {
            let command = mcpCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard command.hasPrefix("/"), let data = mcpArguments.data(using: .utf8),
                  let arguments = try? JSONDecoder().decode([String].self, from: data), arguments.count <= 100,
                  arguments.allSatisfy({ $0.count <= 4096 && !$0.contains("\0") }), secrets.count <= 100,
                  secrets.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && $0.key.count <= 256 &&
                      $0.key.rangeOfCharacter(from: .newlines.union(CharacterSet(charactersIn: "\0"))) == nil &&
                      $0.value.rangeOfCharacter(from: .newlines.union(CharacterSet(charactersIn: "\0"))) == nil && $0.value.count <= 4096 }) else {
                mcpMessage = "请填写绝对路径、JSON 参数数组和有效环境变量。"; return
            }
            config = .init(type: "stdio", command: command, args: arguments, env: secrets)
        }
        let profile = MCPProfile(server: AgentMCPServer(id: UUID().uuidString, name: name, config: config, enabledTools: tools))
        let next = mcpProfiles + [profile]
        guard MCPConfigurationStore.save(next) else { mcpMessage = "无法保存连接，请检查钥匙串访问权限。"; return }
        mcpProfiles = next; mcpName = ""; mcpAddress = ""; mcpCommand = ""; mcpArguments = "[]"; mcpSecrets = ""; mcpTools = ""
        mcpMessage = "连接已保存。"
    }

    private func discoverMCPTools(_ profile: MCPProfile) {
        mcpDiscoveryBusy = true
        mcpDiscoveryID = profile.id
        mcpDiscovery = nil
        mcpMessage = "正在连接服务…"
        Task {
            do {
                let result = try await model.discoverMCPTools(config: profile.server.config)
                guard mcpProfiles.contains(where: { $0.id == profile.id }) else { mcpDiscoveryBusy = false; return }
                mcpDiscovery = result
                mcpSelectedTools = Set(profile.server.enabledTools).intersection(result.tools.map(\.name))
                mcpMessage = "请选择要启用的工具。"
            } catch { mcpMessage = (error as? LocalizedError)?.errorDescription ?? "无法读取服务工具列表。" }
            mcpDiscoveryBusy = false
        }
    }

    private func testConnection(_ id: UUID, kind: AgentConnectionTest) {
        testingConnectionID = id
        connectionTestResults[id] = nil
        Task {
            do { connectionTestResults[id] = try await model.testConnection(id, kind: kind) }
            catch { connectionTestResults[id] = error.localizedDescription }
            testingConnectionID = nil
        }
    }

    private var browserSettings: some View {
        VStack(spacing: 16) {
            CardSurface {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "应用内浏览器", detail: "用户标签与 AI 标签共享在此浏览器中登录的网站身份。")
                    Text("网站数据保存在本机。清除某个站点的数据后，可能需要重新登录该站点。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("AI 工具发起的表单和按钮操作需要确认。网站脚本可能未经确认发送后台请求，请仅在信任的网站使用已登录身份开展研究。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text(websiteRecordsLoaded ? "\(websiteRecords.count) 个站点有本地数据" : "加载站点列表以管理数据")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if websiteRecordsBusy { ProgressView().controlSize(.small) }
                        Button("刷新列表") { Task { await refreshWebsiteRecords() } }
                            .disabled(websiteRecordsBusy)
                    }
                    ForEach(websiteRecords, id: \.displayName) { record in
                        Divider()
                        HStack {
                            Text(record.displayName).lineLimit(1)
                            Spacer()
                            Button("清除数据") {
                                Task {
                                    websiteRecordsBusy = true
                                    await BrowserWorkspace.clearWebsiteData(record, in: BrowserWorkspace.persistentDataStore())
                                    await refreshWebsiteRecords()
                                }
                            }.disabled(websiteRecordsBusy)
                        }
                    }
                }
            }
        }
        .task { if !websiteRecordsLoaded { await refreshWebsiteRecords() } }
    }

    @MainActor private func refreshWebsiteRecords() async {
        websiteRecordsBusy = true
        let records = await BrowserWorkspace.persistentDataStore().dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        websiteRecords = records.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        websiteRecordsLoaded = true
        websiteRecordsBusy = false
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
                    Link("打开发布页面", destination: URL(string: "https://github.com/tzf1003/TrendingTab/releases")!)
                }
            }
        }
    }

    private var runtimeSettings: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Agent 运行时", detail: "应用每天检查兼容更新，安装由你手动启动。")
                LabeledContent("应用版本", value: model.currentVersion)
                LabeledContent("运行时版本", value: model.runtimeVersion)
                LabeledContent("Pi 版本", value: model.runtimePiVersion)
                Text(model.runtimeUpdateState).foregroundStyle(.secondary)
                if let release = model.availableRuntime {
                    LabeledContent("可用版本", value: release.version)
                }
                HStack {
                    Button("检查更新") { Task { await model.checkForRuntimeUpdate() } }
                    Button("一键更新") { Task { await model.installRuntimeUpdate() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.availableRuntime == nil)
                    Button("回退上一版本") { Task { await model.rollbackRuntime() } }
                        .disabled(!model.runtimeCanRollback)
                }
                .disabled(model.runtimeBusy)
                Link("打开发布页面", destination: URL(string: "https://github.com/tzf1003/TrendingTab/releases")!)
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

private struct ConnectionEditor: View {
    @ObservedObject var model: TrendingAppModel
    let onClose: () -> Void
    @State private var draft: AIConnection
    @State private var address: String
    @State private var timeout: Int
    @State private var message = ""

    init(connection: AIConnection, model: TrendingAppModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _draft = State(initialValue: connection)
        _address = State(initialValue: connection.baseURL.absoluteString)
        _timeout = State(initialValue: Int(connection.timeout))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("连接名称", text: $draft.name).textFieldStyle(.roundedBorder)
            Picker("协议", selection: $draft.kind) {
                ForEach(AIProtocolKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
            }
            TextField("API 根地址", text: $address).textFieldStyle(.roundedBorder)
            TextField("模型 ID", text: $draft.model).textFieldStyle(.roundedBorder)
            Stepper("请求超时：\(timeout) 秒", value: $timeout, in: 5...180, step: 5)
            Stepper("最大输出：\(draft.maxOutputTokens) tokens", value: $draft.maxOutputTokens, in: 256...32768, step: 256)
            Stepper("上下文窗口：\(draft.contextWindow) tokens", value: $draft.contextWindow, in: 4096...1_048_576, step: 4096)
            HStack {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onClose)
                Button("保存连接") {
                    guard let url = URL(string: address) else { message = "请输入有效的 API 地址。"; return }
                    var updated = draft
                    updated.baseURL = url
                    updated.timeout = TimeInterval(timeout)
                    do { try model.updateConnection(updated); onClose() }
                    catch { message = error.localizedDescription }
                }
            }
        }
        .padding(10)
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
