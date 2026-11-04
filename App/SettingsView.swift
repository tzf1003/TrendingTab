import SwiftUI
import TrendingTabCore
import TrendingTabCore
import TrendingTabKit
import TrendingTabPersistence
import TrendingTabSources

struct SettingsView: View {
    @ObservedObject var model: TrendingAppModel
    @State private var interval = 15.0
    @State private var connectionName = ""
    @State private var modelName = ""
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var credential = ""
    @State private var protocolKind = AIProtocolKind.openAIResponses
    @State private var wechatURL = ""

    var body: some View {
        TabView {
            tabList.tabItem { Text("标签") }
            sourceList.tabItem { Text("数据源") }
            refreshSettings.tabItem { Text("刷新") }
            aiSettings.tabItem { Text("AI") }
            notificationSettings.tabItem { Text("通知") }
            diagnostics.tabItem { Text("诊断") }
        }
        .padding(16)
        .frame(width: 760, height: 520)
        .onAppear { interval = model.settings.refreshInterval / 60 }
    }

    private var tabList: some View {
        List {
            ForEach(model.tabs) { tab in
                HStack {
                    Text(tab.title)
                    Spacer()
                    Text(tab.kind.rawValue).foregroundStyle(.secondary)
                }
            }
            .onMove(perform: model.moveTabs)
        }
    }

    private var sourceList: some View {
        Form {
            ForEach(SourceCatalog.providers(customFeeds: model.feeds).map(\.descriptor)) { source in
                LabeledContent(source.title) {
                    Text("\(source.category.title) · \(source.availability.rawValue)")
                }
            }
            TextField("微信 RSS 地址", text: $wechatURL)
            Button("保存微信 RSS") {
                if let url = URL(string: wechatURL) { model.updateWeChatFeed(url) }
            }
        }
    }

    private var refreshSettings: some View {
        Form {
            Picker("采集间隔", selection: $interval) {
                Text("5 分钟").tag(5.0)
                Text("15 分钟").tag(15.0)
                Text("30 分钟").tag(30.0)
                Text("60 分钟").tag(60.0)
            }
            Button("应用") {
                var copy = model.settings
                copy.refreshInterval = interval * 60
                model.updateSettings(copy)
            }
            Text("小组件显示更新由系统调度，最近采集时间以诊断页为准。")
        }
    }

    private var aiSettings: some View {
        Form {
            Toggle("启用自动分析", isOn: Binding(get: { model.settings.aiEnabled }, set: { value in
                var copy = model.settings
                copy.aiEnabled = value
                model.updateSettings(copy)
            }))
            TextField("连接名称", text: $connectionName)
            Picker("协议", selection: $protocolKind) {
                ForEach(AIProtocolKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("API 根地址", text: $baseURL)
            TextField("模型", text: $modelName)
            SecureField("API Key", text: $credential)
            Button("添加连接") {
                guard let url = URL(string: baseURL) else { return }
                let account = "ai-\(UUID().uuidString)"
                model.addConnection(AIConnection(name: connectionName, kind: protocolKind, baseURL: url, model: modelName, credentialAccount: account), credential: credential)
                credential = ""
            }
            Text("自动任务发送标题、来源和已有摘要。凭据保存在 Keychain。")
            ForEach(model.connections) { connection in
                Text("\(connection.name) · \(connection.kind.title) · \(connection.model)")
            }
        }
    }

    private var notificationSettings: some View {
        Form {
            Toggle("启用提醒", isOn: Binding(get: { model.settings.globalNotification.enabled }, set: { value in
                var copy = model.settings
                copy.globalNotification.enabled = value
                model.updateSettings(copy)
            }))
            LabeledContent("免打扰", value: "23:00–08:00")
            LabeledContent("频率", value: "每小时 3 次，每天 10 次")
            LabeledContent("同一事件冷却", value: "6 小时")
        }
    }

    private var diagnostics: some View {
        List(model.diagnostics) { record in
            VStack(alignment: .leading) {
                Text(record.title).font(.headline)
                Text("\(record.state) · \(record.message)").font(.caption)
                if let success = record.lastSuccessAt {
                    Text("最近成功：\(success.formatted(date: .abbreviated, time: .standard))").font(.caption2)
                }
            }
        }
    }
}
