import SwiftUI
import TrendingTabKit

struct MenuBarMenu: View {
    @ObservedObject var model: TrendingAppModel

    var body: some View {
        Button("打开事件中心", systemImage: "rectangle.split.2x1") {
            AppWindowRouter.shared.showEventCenter()
        }
        SettingsLink {
            if let release = model.availableRelease {
                Label("设置（可更新至 \(release.version)）", systemImage: "gearshape")
            } else {
                Label("设置…", systemImage: "gearshape")
            }
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button(model.running ? "正在刷新…" : "立即刷新", systemImage: "arrow.clockwise") {
            Task { await model.refresh(manual: true) }
        }
        .disabled(model.running)

        Button(
            model.settings.automaticCollectionEnabled ? "暂停自动采集" : "恢复自动采集",
            systemImage: model.settings.automaticCollectionEnabled ? "pause" : "play"
        ) {
            var settings = model.settings
            settings.automaticCollectionEnabled.toggle()
            model.updateSettings(settings)
        }

        Divider()

        Button("退出", systemImage: "power") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
