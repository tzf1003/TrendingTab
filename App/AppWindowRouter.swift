import AppKit
import SwiftUI
import TrendingTabCore
import TrendingTabKit
import TrendingTabWidgetBridge

@MainActor
final class AppWindowRouter: NSObject, NSWindowDelegate {
    static let shared = AppWindowRouter()

    private weak var model: TrendingAppModel?
    private var eventWindowController: NSWindowController?
    private var pendingURL: URL?

    private override init() { super.init() }

    func configure(model: TrendingAppModel) {
        self.model = model
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let url = pendingURL {
                pendingURL = nil
                handle(url: url)
            } else {
                handleActivation()
            }
        }
    }

    func handleActivation() {
        guard let model, let target = SnapshotStore.consumeOpenedTarget() else { return }
        model.reveal(itemID: target.itemID, eventID: target.eventID)
        showEventCenter()
    }

    func handle(url: URL) {
        guard let target = WidgetNavigationTarget(url: url) else { return }
        _ = SnapshotStore.consumeOpenedTarget()
        guard let model else {
            pendingURL = url
            return
        }
        model.reveal(itemID: target.itemID, eventID: target.eventID, tabID: target.tabID)
        showEventCenter()
    }

    func showEventCenter() {
        guard let model else { return }

        if eventWindowController == nil {
            let content = NSHostingController(rootView: EventCenterView(model: model))
            let window = BrowserWindow(contentViewController: content)
            window.title = "TrendingTab"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1380, height: 820))
            window.minSize = NSSize(width: 1100, height: 640)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.collectionBehavior = [.fullScreenPrimary]
            window.center()
            eventWindowController = NSWindowController(window: window)
        }

        eventWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === eventWindowController?.window else { return }
        model?.analysisChat.clearAll()
        eventWindowController = nil
    }
}

@MainActor
final class TrendingTabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindowRouter.shared.showEventCenter()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppWindowRouter.shared.handle(url: url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppWindowRouter.shared.handleActivation()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppWindowRouter.shared.handleActivation()
    }
}
