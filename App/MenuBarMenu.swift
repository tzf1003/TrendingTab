import SwiftUI
import TrendingTabKit

struct MenuBarMenu: View {
    @ObservedObject var model: TrendingAppModel

    var body: some View {
        Text(model.running ? "正在刷新热点…" : "每 \(Int(model.settings.refreshInterval / 60)) 分钟自动刷新")

        Button(model.running ? "刷新中" : "立即刷新") {
            Task { await model.refresh(manual: true) }
        }
        .disabled(model.running)

        Button(model.settings.automaticCollectionEnabled ? "暂停自动采集" : "恢复自动采集") {
            var copy = model.settings
            copy.automaticCollectionEnabled.toggle()
            model.updateSettings(copy)
        }

        Divider()

        Button("打开事件中心") {
            AppWindowRouter.shared.showEventCenter()
        }
        SettingsLink {
            Text("设置")
        }

        if let update = model.availableRelease {
            Divider()
            Text("发现新版本 \(update.version)")
        }

        Divider()
        Button("退出 TrendingTab") {
            NSApp.terminate(nil)
        }
    }
}
