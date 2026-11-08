import SwiftUI
import TrendingTabCore
import TrendingTabIntelligence
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
        let (bridge, installer) = Self.makeAgentRuntime()
        let model = TrendingAppModel(database: database, agentBridge: bridge, runtimeInstaller: installer)
        model.start()
        _model = StateObject(wrappedValue: model)
        AppWindowRouter.shared.configure(model: model)
    }

    private static func makeAgentRuntime() -> (AgentBridge, AgentRuntimeInstaller?) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let node = environment["TRENDINGTAB_AGENT_NODE"], let script = environment["TRENDINGTAB_AGENT_SCRIPT"] {
            return (AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: URL(fileURLWithPath: script)), nil)
        }
        #endif
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let root = resources.appendingPathComponent("AgentRuntime", isDirectory: true)
        let executable = root.appendingPathComponent("bin/node")
        let script = root.appendingPathComponent("runtime.mjs")
        let bridge = AgentBridge(executableURL: executable, scriptURL: script)
        guard let package = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let bundledVersion = try? AgentRuntimeManifest.bundledVersion(package: package),
              let bundledPiVersion = try? AgentRuntimeManifest.bundledPiVersion(package: package) else {
            return (bridge, nil)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrendingTab/AgentRuntime", isDirectory: true)
        let installer = AgentRuntimeInstaller(root: support, appVersion: version, systemVersion: systemVersion,
            bundledExecutable: executable, bundledHealthScript: root.appendingPathComponent("runtime-health.mjs"),
            bundledPiVersion: bundledPiVersion, bundledVersion: bundledVersion)
        return (bridge, installer)
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
