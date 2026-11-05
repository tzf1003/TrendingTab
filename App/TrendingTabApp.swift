import SwiftUI
import TrendingTabCore
import TrendingTabKit
import TrendingTabPersistence
import TrendingTabSources
import TrendingTabWidgetBridge

@main
struct TrendingTabApp: App {
    @NSApplicationDelegateAdaptor(TrendingTabAppDelegate.self) private var appDelegate
    @StateObject private var model: TrendingAppModel

    init() {
        let database = try! AppDatabase.live()
        let model = TrendingAppModel(database: database)
        model.start()
        _model = StateObject(wrappedValue: model)
        AppWindowRouter.shared.configure(model: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(model: model)
        } label: {
            Label(model.events.filter { $0.status == "major" }.isEmpty ? "热榜" : "热榜 \(model.events.filter { $0.status == "major" }.count)", systemImage: "flame")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }

    }
}
