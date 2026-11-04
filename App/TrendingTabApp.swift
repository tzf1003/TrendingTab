import SwiftUI
import TrendingTabCore
import TrendingTabKit
import TrendingTabPersistence
import TrendingTabSources

@main
struct TrendingTabApp: App {
    @StateObject private var model: TrendingAppModel

    init() {
        let database = try! AppDatabase.live()
        _model = StateObject(wrappedValue: TrendingAppModel(database: database))
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

        Window("事件中心", id: "events") {
            EventCenterView(model: model)
        }
    }
}
