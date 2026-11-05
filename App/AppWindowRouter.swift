import AppKit
import SwiftUI
import TrendingTabKit
import TrendingTabWidgetBridge

@MainActor
final class AppWindowRouter {
    static let shared = AppWindowRouter()

    private weak var model: TrendingAppModel?
    private var eventWindowController: NSWindowController?

    private init() {}

    func configure(model: TrendingAppModel) {
        self.model = model
        DispatchQueue.main.async { [weak self] in
            self?.handleActivation()
        }
    }

    func handleActivation() {
        guard let model, let target = SnapshotStore.consumeOpenedTarget() else { return }
        model.reveal(itemID: target.itemID, eventID: target.eventID)
        showEventCenter()
    }

    func showEventCenter() {
        guard let model else { return }

        if eventWindowController == nil {
            let content = NSHostingController(rootView: EventCenterView(model: model))
            let window = NSWindow(contentViewController: content)
            window.title = "TrendingTab"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1120, height: 720))
            window.minSize = NSSize(width: 900, height: 580)
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.fullScreenPrimary]
            window.center()
            eventWindowController = NSWindowController(window: window)
        }

        eventWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class TrendingTabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppWindowRouter.shared.handleActivation()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppWindowRouter.shared.handleActivation()
    }
}
