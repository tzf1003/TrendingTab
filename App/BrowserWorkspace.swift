import AppKit
import Combine
import Darwin
import SwiftUI
import WebKit

private final class LocalEventMonitor: @unchecked Sendable {
    let token: Any
    init(_ token: Any) { self.token = token }
    deinit { NSEvent.removeMonitor(token) }
}

@MainActor
final class BrowserWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        var candidate = responder as? NSView
        while let view = candidate {
            if let page = view as? WorkspaceWebView, !page.permitsKeyboardFocus { return false }
            candidate = view.superview
        }
        return super.makeFirstResponder(responder)
    }
}

@MainActor
private final class WorkspaceWebView: WKWebView {
    var permitsKeyboardFocus = false
    override var acceptsFirstResponder: Bool { permitsKeyboardFocus && super.acceptsFirstResponder }
}

enum BrowserPageStyle: Equatable {
    case desktop, mobile

    static func initialStyle(for size: CGSize) -> Self {
        size.width > 0 && size.height > size.width ? .mobile : .desktop
    }

    var title: String { self == .mobile ? "手机版" : "电脑版" }
    var symbol: String { self == .mobile ? "iphone" : "desktopcomputer" }
    var opposite: Self { self == .mobile ? .desktop : .mobile }
    var userAgent: String? {
        self == .mobile
            ? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            : nil
    }
}

enum ResearchNavigationPolicy {
    static func allows(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              let raw = url.host?.lowercased(), url.absoluteString.count <= 4096 else { return false }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host.contains("."), !host.contains(":"), host != "localhost",
              !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".home.arpa"),
              host.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else { return false }
        var address = in_addr()
        // inet_aton also recognizes historical numeric IPv4 forms such as hexadecimal and octal.
        return host.withCString { inet_aton($0, &address) == 0 }
    }
}

/// Keeps WebKit views alive independently of SwiftUI's view reconstruction.
@MainActor
final class BrowserWorkspace: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    enum Owner { case user, agent }
    static let websiteStoreID = UUID(uuidString: "D8A7243E-6C70-40A6-A716-94F738F37C18")!
    static func persistentDataStore() -> WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: websiteStoreID) }

    private static let appearanceScriptMarker = "// TrendingTab automatic page appearance\n"
    private static let appearanceScript: String = {
        guard let url = Bundle(for: BrowserWorkspace.self).url(forResource: "darkreader", withExtension: "js", subdirectory: "BrowserTheme"),
              let engine = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Missing bundled browser theme engine")
            return ""
        }
        return appearanceScriptMarker + engine + """

            DarkReader.setFetchMethod(window.fetch.bind(window));
            DarkReader.auto({
                darkSchemeBackgroundColor: '#20252b',
                darkSchemeTextColor: '#e8e6e3'
            });
            """
    }()

    static func clearWebsiteData(_ record: WKWebsiteDataRecord, in store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: [record])
        let name = record.displayName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty else { return }
        let cookies = await store.httpCookieStore.allCookies()
        for cookie in cookies {
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if domain == name || domain.hasSuffix("." + name) {
                await store.httpCookieStore.deleteCookie(cookie)
            }
        }
    }

    @MainActor final class Tab: Identifiable, ObservableObject {
        struct BlockedAction {
            let method: String
            let destination: URL
        }
        struct ApprovedNavigation {
            let method: String
            let destination: URL
            let fields: [(name: String, value: String)]
        }
        struct ReaderContent {
            let title: String
            let text: String
            let url: URL
        }
        let id = UUID()
        let owner: Owner
        let agentTaskID: String?
        let webView: WKWebView
        let audio: BrowserAudioController
        @Published var title = "新标签"
        @Published var address = ""
        @Published var loading = false
        @Published var onlySecureContent = false
        @Published var error: String?
        @Published var pinned = false
        @Published var readerContent: ReaderContent?
        @Published var showingReader = false
        @Published var extractingReader = false
        @Published var userTookControl = false
        @Published fileprivate(set) var isMuted = true
        @Published fileprivate(set) var hasAudioPlayback = false
        @Published fileprivate(set) var pageStyle: BrowserPageStyle = .desktop
        fileprivate var preferredPageStyle: BrowserPageStyle?
        var needsUserAction = false
        var blockedAction: BlockedAction?
        var approvedNavigation: ApprovedNavigation?
        var httpStatus: Int?
        var navigationErrorCode: Int?
        var navigationErrorDomain: String?
        var observations: [NSKeyValueObservation] = []
        var navigationRevision = 0
        var userInteractionRevision = 0
        var finishedRevision = 0
        var activeNavigation: WKNavigation?
        var researchNavigationPending = false
        var researchLoadLimited = false
        var loadRequestRevision = 0

        init(owner: Owner, agentTaskID: String?, webView: WKWebView) {
            self.owner = owner
            self.agentTaskID = agentTaskID
            self.webView = webView
            audio = BrowserAudioController(webView: webView)
            audio.onPlaybackChange = { [weak self] playing in self?.hasAudioPlayback = playing }
        }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published var selectedID: UUID? {
        didSet {
            for tab in tabs { (tab.webView as? WorkspaceWebView)?.permitsKeyboardFocus = tab.id == selectedID }
            if oldValue != selectedID, let previous = tabs.first(where: { $0.id == oldValue }),
               let window = previous.webView.window, let responder = window.firstResponder as? NSView,
               responder === previous.webView || responder.isDescendant(of: previous.webView) {
                window.makeFirstResponder(selected?.webView)
            }
            if oldValue != selectedID { selectionRevision += 1; authorityChanges.send() }
        }
    }
    let authorityChanges = PassthroughSubject<Void, Never>()
    private(set) var selectionRevision = 0
    private var currentStoryTabID: UUID?
    private var researchLoads: Set<UUID> = []
    private let dataStore: WKWebsiteDataStore
    private let researchURLAllowed: (URL) -> Bool
    private var userInputMonitor: LocalEventMonitor?
    private(set) var viewportSize = CGSize(width: 1024, height: 768)
    private let waitsForInitialViewport: Bool
    private var hasInitialViewport = false
    private var pendingInitialLoads: [UUID: (url: URL, revision: Int)] = [:]

    init(dataStore: WKWebsiteDataStore? = nil, waitsForInitialViewport: Bool = false,
         researchURLAllowed: @escaping (URL) -> Bool = ResearchNavigationPolicy.allows) {
        self.dataStore = dataStore ?? Self.persistentDataStore()
        self.waitsForInitialViewport = waitsForInitialViewport
        self.researchURLAllowed = researchURLAllowed
        super.init()
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.recordUserInput(event) }
            return event
        }) { userInputMonitor = LocalEventMonitor(token) }
    }

    private func recordUserInput(_ event: NSEvent) {
        guard let tab = selected, let window = event.window,
              tab.webView.window === window else { return }
        let target: NSView?
        if event.type == .keyDown {
            target = window.firstResponder as? NSView
        } else {
            target = window.contentView?.hitTest(event.locationInWindow)
        }
        guard let target, target === tab.webView || target.isDescendant(of: tab.webView) else { return }
        noteUserInteraction(in: tab)
    }

    func noteUserInteraction(in tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if tab.owner == .agent {
            takeControl(tab)
            return
        }
        tab.userInteractionRevision += 1
        authorityChanges.send()
    }

    /// Selecting an AI tab only previews it. Explicit toolbar actions or input
    /// inside its page transfer control to the user and revoke agent authority.
    func takeControl(_ tab: Tab) {
        guard tab.owner == .agent, tabs.contains(where: { $0 === tab }) else { return }
        guard !tab.userTookControl else { return }
        tab.userTookControl = true
        tab.approvedNavigation = nil
        researchLoads.remove(tab.id)
        tab.researchNavigationPending = false
        authorityChanges.send()
    }

    func allowsResearchNavigation(to url: URL) -> Bool { researchURLAllowed(url) }

    var selected: Tab? { tabs.first { $0.id == selectedID } }

    /// Record layout for the next navigation; resizing never changes a live page.
    func updateViewportSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        viewportSize = size
        guard !hasInitialViewport else { return }
        hasInitialViewport = true
        let pending = pendingInitialLoads
        pendingInitialLoads.removeAll()
        // Begin the initial request only once the reading pane has real bounds.
        // Dispatch out of AppKit layout before publishing tab state to SwiftUI.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for (id, request) in pending {
                if let tab = tabs.first(where: { $0.id == id }), tab.loadRequestRevision == request.revision {
                    load(request.url, in: tab)
                }
            }
        }
    }

    private func preparePageStyle(in tab: Tab) {
        tab.pageStyle = tab.preferredPageStyle ?? .initialStyle(for: viewportSize)
        tab.webView.customUserAgent = tab.pageStyle.userAgent
    }

    func togglePageStyle(in tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        noteUserInteraction(in: tab)
        tab.preferredPageStyle = tab.pageStyle.opposite
        preparePageStyle(in: tab)
        if tab.webView.url != nil { tab.webView.reload() }
    }

    func toggleMuted(in tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        tab.isMuted.toggle()
        tab.audio.setMuted(tab.isMuted)
    }

    @discardableResult
    func newTab(owner: Owner = .user, taskID: String? = nil, url: URL? = nil, select: Bool = true) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Supply a responsive viewport only when a mobile page omitted its own.
        // Preserve site-authored viewport settings, including login pages.
        configuration.userContentController.addUserScript(WKUserScript(source: """
            if (/iPhone.*Mobile/.test(navigator.userAgent) && !document.querySelector('meta[name="viewport" i]')) {
                const viewport = document.createElement('meta');
                viewport.name = 'viewport';
                viewport.content = 'width=device-width, initial-scale=1';
                document.head?.append(viewport);
            }
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        return addTab(owner: owner, taskID: taskID, configuration: configuration, url: url, select: select)
    }

    private func addTab(owner: Owner, taskID: String?, configuration: WKWebViewConfiguration, url: URL?, select: Bool) -> Tab {
        // Popup configurations may share the parent's controller. Give every tab
        // its own sound handler and default, while preserving other user scripts.
        let scripts = configuration.userContentController.userScripts.filter {
            !$0.source.hasPrefix(BrowserAudioController.scriptMarker) && !$0.source.hasPrefix(Self.appearanceScriptMarker)
        }
        configuration.userContentController = WKUserContentController()
        for script in scripts { configuration.userContentController.addUserScript(script) }
        // The isolated world keeps the bundled engine out of the site's globals.
        // Its media query follows WebKit's effective appearance in every frame,
        // including background tabs, without reloading or replacing page content.
        configuration.userContentController.addUserScript(WKUserScript(source: Self.appearanceScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Background research starts with the same viewport as the reading pane.
        let initialFrame = CGRect(origin: .zero, size: viewportSize)
        let webView = WorkspaceWebView(frame: initialFrame, configuration: configuration)
        webView.underPageBackgroundColor = .windowBackgroundColor
        let tab = Tab(owner: owner, agentTaskID: taskID, webView: webView)
        preparePageStyle(in: tab)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        tab.observations = [
            webView.observe(\.title, options: [.initial, .new]) { [weak tab] view, _ in
                Task { @MainActor in tab?.title = view.title?.isEmpty == false ? view.title! : "新标签" }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak tab] view, _ in
                Task { @MainActor in tab?.address = view.url?.absoluteString ?? "" }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak tab] view, _ in
                Task { @MainActor in tab?.loading = view.isLoading }
            },
            webView.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak tab] view, _ in
                Task { @MainActor in tab?.onlySecureContent = view.hasOnlySecureContent }
            }
        ]
        tabs.append(tab)
        if select { selectedID = tab.id }
        if let url { load(url, in: tab) }
        return tab
    }

    func openStory(_ url: URL, inNewTab: Bool = false) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if !inNewTab, let tab = tabs.first(where: { $0.id == currentStoryTabID && !$0.pinned }) {
            selectedID = tab.id
            load(url, in: tab)
        } else {
            let tab = newTab(url: url)
            if !inNewTab { currentStoryTabID = tab.id }
        }
    }

    func load(_ url: URL, in tab: Tab) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            tab.error = "请输入 HTTP 或 HTTPS 地址。"
            return
        }
        tab.loadRequestRevision += 1
        if waitsForInitialViewport && !hasInitialViewport {
            pendingInitialLoads[tab.id] = (url, tab.loadRequestRevision)
            return
        }
        tab.error = nil
        preparePageStyle(in: tab)
        tab.webView.load(URLRequest(url: url))
    }

    func close(_ tab: Tab) {
        pendingInitialLoads.removeValue(forKey: tab.id)
        (tab.webView as? WorkspaceWebView)?.permitsKeyboardFocus = false
        if let window = tab.webView.window, let responder = window.firstResponder as? NSView,
           responder === tab.webView || responder.isDescendant(of: tab.webView) { window.makeFirstResponder(nil) }
        tab.approvedNavigation = nil
        researchLoads.remove(tab.id)
        tab.researchNavigationPending = false
        tab.webView.stopLoading()
        tab.audio.setMuted(true)
        tab.webView.pauseAllMediaPlayback(completionHandler: nil)
        tab.audio.navigationStarted()
        tabs.removeAll { $0.id == tab.id }
        authorityChanges.send()
        if currentStoryTabID == tab.id { currentStoryTabID = nil }
        if selectedID == tab.id { selectedID = tabs.last(where: { $0.owner == .user })?.id }
    }

    /// Extracts visible article text without changing the live page or its session.
    func showReader(in tab: Tab) async {
        guard !tab.extractingReader, !tab.loading, (tab.httpStatus ?? 200) < 400, let url = tab.webView.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            tab.error = "请等待网页加载完成后再打开阅读模式。"
            return
        }
        let revision = tab.navigationRevision
        tab.extractingReader = true
        defer { tab.extractingReader = false }
        do {
            let result = try await tab.webView.callAsyncJavaScript("""
                return (() => {
                    const root = document.querySelector('article') || document.querySelector('main') || document.body;
                    return { title: document.title || '', text: (root?.innerText || '').trim().slice(0, 200000) };
                })();
                """, arguments: [:], in: nil, contentWorld: .defaultClient)
            guard tabs.contains(where: { $0 === tab }), tab.navigationRevision == revision,
                  tab.webView.url == url, !tab.webView.isLoading else { return }
            guard let values = result as? [String: Any], let text = values["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                tab.error = "此页面暂时无法提取可阅读的文字。"
                return
            }
            tab.readerContent = Tab.ReaderContent(title: values["title"] as? String ?? "", text: text, url: url)
            tab.error = nil
            tab.showingReader = true
        } catch {
            guard tab.navigationRevision == revision, tab.webView.url == url else { return }
            tab.error = "无法打开阅读模式：\(error.localizedDescription)"
        }
    }

    func selectTab(_ tab: Tab) { selectedID = tab.id }

    func stopResearchLoading(_ tab: Tab) {
        researchLoads.remove(tab.id)
        tab.researchNavigationPending = false
        tab.webView.stopLoading()
    }

    private func allowResearchLoad(in tab: Tab, mainFrame: Bool) -> Bool {
        guard mainFrame else { return true }
        guard researchLoads.contains(tab.id) || researchLoads.count < 2 else {
            tab.researchLoadLimited = true
            tab.navigationRevision += 1
            tab.finishedRevision = tab.navigationRevision
            tab.error = "研究页面正在加载，请稍后重试。"
            return false
        }
        researchLoads.insert(tab.id)
        tab.researchNavigationPending = true
        return true
    }

    private func finishResearchLoad(_ tab: Tab) {
        guard !tab.researchNavigationPending else { return }
        researchLoads.remove(tab.id)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        tab.researchNavigationPending = false
        tab.researchLoadLimited = false
        tab.navigationRevision += 1
        tab.audio.navigationStarted()
        authorityChanges.send()
        tab.needsUserAction = false
        tab.blockedAction = nil
        tab.httpStatus = nil
        tab.navigationErrorCode = nil
        tab.navigationErrorDomain = nil
        tab.readerContent = nil
        tab.showingReader = false
        tab.activeNavigation = navigation
        tab.error = nil
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }), tab.activeNavigation === navigation {
            tab.researchNavigationPending = false
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let tab = tabs.first(where: { $0.webView === webView }), tab.activeNavigation === navigation {
            finishResearchLoad(tab)
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            tab.navigationErrorCode = (error as NSError).code
            tab.navigationErrorDomain = (error as NSError).domain
            tab.error = error.localizedDescription
            tab.finishedRevision = tab.navigationRevision
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let tab = tabs.first(where: { $0.webView === webView }), tab.activeNavigation === navigation {
            finishResearchLoad(tab)
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            tab.navigationErrorCode = (error as NSError).code
            tab.navigationErrorDomain = (error as NSError).domain
            tab.error = error.localizedDescription
            tab.finishedRevision = tab.navigationRevision
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }), tab.activeNavigation === navigation {
            finishResearchLoad(tab)
            tab.navigationErrorCode = nil
            tab.navigationErrorDomain = nil
            if let status = tab.httpStatus, status >= 400 {
                tab.error = "网页返回 HTTP \(status)，请检查页面或稍后重试。"
            } else {
                tab.error = nil
            }
            tab.finishedRevision = tab.navigationRevision
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           let tab = tabs.first(where: { $0.webView === webView }) {
            tab.httpStatus = response.statusCode
            if tab.owner == .agent && (response.statusCode == 401 || response.statusCode == 403) {
                tab.needsUserAction = true
            }
        }
        // Keep the response visible so the user can inspect a verification page.
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        researchLoads.remove(tab.id)
        tab.researchNavigationPending = false
        tab.navigationErrorCode = WKError.webContentProcessTerminated.rawValue
        tab.navigationErrorDomain = WKError.errorDomain
        tab.audio.navigationStarted()
        tab.error = "页面进程已停止，请重新加载。"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // App-opening links are not document navigations. Preserve the current
        // article and its permissions when a site tries to launch a native app.
        if let scheme = navigationAction.request.url?.scheme,
           !WKWebView.handlesURLScheme(scheme.lowercased()) {
            decisionHandler(.cancel)
            return
        }
        guard let tab = tabs.first(where: { $0.webView === webView }), tab.owner == .agent,
              !tab.userTookControl else { decisionHandler(.allow); return }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !mainFrame, navigationAction.request.url?.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        guard let destination = navigationAction.request.url, allowsResearchNavigation(to: destination) else {
            if mainFrame {
                researchLoads.remove(tab.id)
                tab.researchNavigationPending = false
                tab.navigationRevision += 1
                tab.finishedRevision = tab.navigationRevision
                tab.error = "研究页面不能访问此地址。"
            }
            decisionHandler(.cancel)
            return
        }
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        let method = (navigationAction.request.httpMethod ?? "GET").uppercased()
        let form = navigationAction.navigationType == .formSubmitted || navigationAction.navigationType == .formResubmitted
        guard (scheme == "http" || scheme == "https"), method == "GET", !form else {
            if mainFrame, let approved = tab.approvedNavigation,
               approved.method == method, Self.sameActionDestination(approved.destination, destination, method: method,
                                                                      request: navigationAction.request, fields: approved.fields) {
                tab.approvedNavigation = nil
                decisionHandler(allowResearchLoad(in: tab, mainFrame: true) ? .allow : .cancel)
                return
            }
            if mainFrame {
                researchLoads.remove(tab.id)
                tab.researchNavigationPending = false
                tab.navigationRevision += 1
                tab.finishedRevision = tab.navigationRevision
                tab.needsUserAction = true
                tab.blockedAction = Tab.BlockedAction(method: method, destination: destination)
                tab.error = "此页面操作需要用户接管。"
            }
            decisionHandler(.cancel)
            return
        }
        if mainFrame, let current = webView.url, Self.isSameDocumentFragment(current, destination) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(allowResearchLoad(in: tab, mainFrame: mainFrame) ? .allow : .cancel)
    }

    private static func isSameDocumentFragment(_ current: URL, _ destination: URL) -> Bool {
        guard var left = URLComponents(url: current, resolvingAgainstBaseURL: false),
              var right = URLComponents(url: destination, resolvingAgainstBaseURL: false),
              left.percentEncodedFragment != right.percentEncodedFragment else { return false }
        left.percentEncodedFragment = nil
        right.percentEncodedFragment = nil
        return left == right
    }

    private static func sameActionDestination(_ expected: URL, _ actual: URL, method: String,
                                              request: URLRequest, fields: [(name: String, value: String)]) -> Bool {
        guard let left = URLComponents(url: expected, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: actual, resolvingAgainstBaseURL: false),
              left.scheme?.lowercased() == right.scheme?.lowercased(),
              left.host?.lowercased() == right.host?.lowercased(), left.port == right.port,
              left.percentEncodedPath == right.percentEncodedPath else { return false }
        let encoded: String
        if method == "GET" {
            encoded = right.percentEncodedQuery ?? ""
        } else {
            guard method == "POST", left.percentEncodedQuery == right.percentEncodedQuery,
                  request.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/x-www-form-urlencoded",
                  let body = request.httpBody, body.count <= 100_000,
                  let text = String(data: body, encoding: .utf8) else { return false }
            encoded = text
        }
        func decode(_ value: Substring) -> String? {
            String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        let parts = encoded.isEmpty ? [] : encoded.split(separator: "&", omittingEmptySubsequences: false)
        let actualFields = parts.map { part -> (String?, String?) in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (decode(pair[0]), pair.count == 2 ? decode(pair[1]) : "")
        }
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        guard actualFields.count == fields.count else { return false }
        return zip(actualFields, fields).allSatisfy { actual, expected in
            guard let name = actual.0, let value = actual.1 else { return false }
            return normalized(name) == normalized(expected.name) && normalized(value) == normalized(expected.value)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let scheme = navigationAction.request.url?.scheme,
           !WKWebView.handlesURLScheme(scheme.lowercased()) { return nil }
        let parent = tabs.first { $0.webView === webView }
        let owner: Owner = parent?.userTookControl == true ? .user : (parent?.owner ?? .user)
        if owner == .agent,
           let url = navigationAction.request.url, !allowsResearchNavigation(to: url) { return nil }
        let child = addTab(owner: owner, taskID: owner == .agent ? parent?.agentTaskID : nil,
                           configuration: configuration, url: nil, select: false)
        if let parent {
            child.preferredPageStyle = parent.preferredPageStyle
            child.pageStyle = parent.pageStyle
            child.webView.customUserAgent = parent.webView.customUserAgent
        }
        if owner == .user { selectTab(child) }
        return child.webView
    }
}

struct BrowserWorkspaceView: View {
    @ObservedObject var workspace: BrowserWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach([BrowserWorkspace.Owner.user, .agent], id: \.self) { owner in
                        let tabs = workspace.tabs.filter { $0.owner == owner }
                        if !tabs.isEmpty {
                            Text(owner == .user ? "用户" : "AI")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(tabs) { tab in
                                BrowserTabButton(tab: tab, selected: tab.id == workspace.selectedID,
                                                 select: { workspace.selectTab(tab) }, close: { workspace.close(tab) })
                            }
                        }
                    }
                    Button { workspace.newTab() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("新建用户标签")
                }.padding(8)
            }.scrollIndicators(.hidden)
            Divider()
            if let tab = workspace.selected {
                BrowserTabContent(workspace: workspace, tab: tab)
            } else {
                ZStack {
                    BrowserPageDeck(workspace: workspace, selectedID: nil).allowsHitTesting(false).accessibilityHidden(true)
                    ContentUnavailableView("选择一条热点", systemImage: "globe", description: Text("原文将在这里打开。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.canvas)
                }
            }
        }
    }

}

private struct BrowserTabContent: View {
    @ObservedObject var workspace: BrowserWorkspace
    @ObservedObject var tab: BrowserWorkspace.Tab
    @State private var address = ""
    @State private var showingSiteInformation = false

    private var siteInformation: BrowserSiteInformation {
        BrowserSiteInformation(url: tab.webView.url, loading: tab.loading,
                               finished: tab.navigationRevision > 0 && tab.finishedRevision == tab.navigationRevision,
                               navigationFailed: tab.navigationErrorCode != nil,
                               onlySecureContent: tab.onlySecureContent)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .zIndex(1)
            Divider()
            if let error = tab.error {
                HStack { Text(error).font(.caption); Spacer(); Button("重试") { workspace.noteUserInteraction(in: tab); tab.webView.reload() } }
                    .padding(8)
            }
            ZStack {
                BrowserPageDeck(workspace: workspace, selectedID: tab.id)
                    .allowsHitTesting(!tab.showingReader)
                    .accessibilityHidden(tab.showingReader)
                if tab.showingReader, let content = tab.readerContent {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(content.title).font(.title2.bold()).textSelection(.enabled)
                            Link(content.url.host ?? "查看原文", destination: content.url)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(content.text).font(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxWidth: 720, alignment: .leading).padding(24)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.canvas)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Button { workspace.noteUserInteraction(in: tab); tab.webView.goBack() } label: { Image(systemName: "chevron.left") }.help("后退")
            Button { workspace.noteUserInteraction(in: tab); tab.webView.goForward() } label: { Image(systemName: "chevron.right") }.help("前进")
            Button {
                workspace.noteUserInteraction(in: tab)
                if tab.loading { tab.webView.stopLoading() } else { tab.webView.reload() }
            } label: {
                Image(systemName: tab.loading ? "xmark" : "arrow.clockwise")
            }.help("刷新")
            Button { showingSiteInformation.toggle() } label: {
                Image(systemName: siteInformation.connection.symbol)
            }
                .foregroundStyle(.secondary)
                .help("站点信息")
                .accessibilityLabel("站点信息")
                .popover(isPresented: $showingSiteInformation) {
                    BrowserSiteInformationView(information: siteInformation, owner: tab.owner,
                                               userTookControl: tab.userTookControl, httpStatus: tab.httpStatus)
                }
            TextField("输入网址", text: $address)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("网页地址")
                .onSubmit {
                    workspace.noteUserInteraction(in: tab)
                    let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: value.contains("://") ? value : "https://" + value) { workspace.load(url, in: tab) }
                }
            Button { workspace.togglePageStyle(in: tab) } label: {
                Image(systemName: tab.pageStyle.symbol)
            }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .help("当前为\(tab.pageStyle.title)，切换至\(tab.pageStyle.opposite.title)并刷新")
                .accessibilityLabel("切换至\(tab.pageStyle.opposite.title)并刷新")
                .accessibilityValue(tab.pageStyle.title)
            audioButton
            Button {
                workspace.noteUserInteraction(in: tab)
                if tab.showingReader { tab.showingReader = false }
                else { Task { await workspace.showReader(in: tab) } }
            } label: {
                Image(systemName: tab.showingReader ? "doc.text.fill" : "doc.text")
            }.disabled(tab.extractingReader).help(tab.showingReader ? "返回原网页" : "阅读模式")
            Button { if let url = tab.webView.url { NSWorkspace.shared.open(url) } } label: {
                Image(systemName: "arrow.up.forward.square")
            }.help("在浏览器中打开")
            if tab.owner == .agent && !tab.userTookControl {
                Text("AI 可操作").font(.caption).foregroundStyle(.secondary)
                    .help("当前为 AI 页面预览；在网页中点击、输入或滚动会接管此页面。")
                Button("接管此页面") { workspace.takeControl(tab) }
                    .buttonStyle(.bordered)
                    .help("停止 AI 操作并接管此页面")
            } else if tab.owner == .agent {
                Text("已由你接管").font(.caption).foregroundStyle(.secondary)
                    .help("AI 可在新标签继续研究。")
            }
        }
        .buttonStyle(.borderless).padding(8)
        .onChange(of: tab.id) { _, _ in address = tab.address; showingSiteInformation = false }
        .onChange(of: tab.webView.url?.host) { _, _ in showingSiteInformation = false }
        .onChange(of: tab.address, initial: true) { _, value in address = value }
    }

    private var audioButton: some View {
        Button { workspace.toggleMuted(in: tab) } label: {
            Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(tab.hasAudioPlayback ? AppTheme.accent : .secondary)
        }
        .keyboardShortcut("m", modifiers: [.command, .option])
        .help(tab.isMuted ? "开启此标签的声音" : "静音此标签")
        .accessibilityLabel(tab.isMuted ? "开启网页声音" : "静音网页")
        .accessibilityValue(tab.isMuted ? "已静音" : "声音已开启")
        .overlay(alignment: .topTrailing) {
            if tab.isMuted && tab.hasAudioPlayback {
                Button { workspace.toggleMuted(in: tab) } label: {
                    VStack(alignment: .trailing, spacing: 0) {
                        Rectangle().fill(AppTheme.actionTint).frame(width: 8, height: 8).rotationEffect(.degrees(45)).padding(.trailing, 5).offset(y: 4)
                        Text("网页有声音，点击开启")
                            .font(.caption).foregroundStyle(.white).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(AppTheme.actionTint, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("网页有声音，点击开启")
                .offset(y: 23)
            }
        }
    }
}

private struct BrowserTabButton: View {
    @ObservedObject var tab: BrowserWorkspace.Tab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                Label(tab.title, systemImage: tab.owner == .user ? "person" : "sparkles")
                    .lineLimit(1).frame(maxWidth: 130)
            }.buttonStyle(.plain)
            Button { tab.pinned.toggle() } label: {
                Image(systemName: tab.pinned ? "pin.fill" : "pin").font(.caption2)
            }.buttonStyle(.plain).help(tab.pinned ? "取消固定" : "固定标签")
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
        }.padding(6).background(selected ? AppTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Keep background pages in the window's view tree. Detaching an AI page until
/// preview can suspend the rendering work used by dynamic article sites.
@MainActor
private final class BrowserDeckView: NSView {
    weak var selectedPage: WKWebView?
    var viewportDidChange: ((CGSize) -> Void)?
    private var reportedSize: CGSize = .zero
    override func accessibilityChildren() -> [Any]? { selectedPage.map { [$0] } ?? [] }
    override func layout() {
        super.layout()
        if bounds.size != reportedSize {
            reportedSize = bounds.size
            viewportDidChange?(bounds.size)
        }
    }
}

private struct BrowserPageDeck: NSViewRepresentable {
    @ObservedObject var workspace: BrowserWorkspace
    let selectedID: UUID?

    func makeNSView(context: Context) -> BrowserDeckView { BrowserDeckView() }

    func updateNSView(_ view: BrowserDeckView, context: Context) {
        let tabs = workspace.tabs
        view.viewportDidChange = { [weak workspace] size in workspace?.updateViewportSize(size) }
        view.selectedPage = tabs.first(where: { $0.id == selectedID })?.webView
        let liveViews = Set(tabs.map { ObjectIdentifier($0.webView) })
        for child in view.subviews where !liveViews.contains(ObjectIdentifier(child)) { child.removeFromSuperview() }
        for tab in tabs {
            let page = tab.webView
            if page.superview !== view {
                page.frame = view.bounds
                page.autoresizingMask = [.width, .height]
                view.addSubview(page)
            }
            page.setAccessibilityHidden(tab.id != selectedID)
        }
        if let selected = tabs.first(where: { $0.id == selectedID })?.webView {
            view.addSubview(selected, positioned: .above, relativeTo: nil)
        }
    }
}
