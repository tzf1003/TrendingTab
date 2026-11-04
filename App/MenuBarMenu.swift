import SwiftUI
import TrendingTabCore
import TrendingTabKit
import TrendingTabPersistence
import TrendingTabSources

struct MenuBarMenu: View {
    @ObservedObject var model: TrendingAppModel

    var body: some View {
        Button(model.running ? "正在刷新…" : "立即刷新") {
            Task { await model.refresh(manual: true) }
        }
        .disabled(model.running)
        Button(model.settings.automaticCollectionEnabled ? "暂停自动采集" : "恢复自动采集") {
            var copy = model.settings
            copy.automaticCollectionEnabled.toggle()
            model.updateSettings(copy)
        }
        Divider()
        if model.events.filter({ $0.status == "major" }).isEmpty {
            Text("暂无未读重大事件")
        } else {
            ForEach(model.events.filter { $0.status == "major" }.prefix(5)) { event in
                Text(event.title).lineLimit(1)
            }
        }
        Divider()
        SettingsLink { Text("设置") }
        Button("事件中心") { NSApp.sendAction(Selector(("showWindow:")), to: nil, from: nil) }
        Button("退出") { NSApp.terminate(nil) }
    }
}
