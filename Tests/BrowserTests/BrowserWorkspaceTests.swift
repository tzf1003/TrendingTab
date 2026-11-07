import Foundation
import WebKit
import XCTest
import TrendingTabCore
import TrendingTabIntelligence

private actor DeferredArticle {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
final class BrowserWorkspaceTests: XCTestCase {
    private func fixture() throws -> (Process, URL) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixture-server.mjs").path]
        process.standardOutput = output
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
            line.append(byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)),
              let url = URL(string: "http://127.0.0.1:\(port)") else {
            process.terminate()
            throw NSError(domain: "Fixture", code: 1)
        }
        return (process, url)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "BrowserTestTimeout", code: 1)
    }

    private func request(_ name: AgentToolName, _ arguments: [String: String] = [:]) throws -> AgentStreamEvent.ToolRequest {
        let value: [String: Any] = ["requestID": UUID().uuidString, "toolCallID": UUID().uuidString,
                                    "name": name.rawValue, "arguments": arguments]
        return try JSONDecoder().decode(AgentStreamEvent.ToolRequest.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testContentRulesBlockBackgroundRequestsByURL() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let identifier = "trendingtab-method-test-\(UUID().uuidString)"
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let rules = #"[{"trigger":{"url-filter":".*/write"},"action":{"type":"block"}}]"#
        let compiled = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
        let list = try XCTUnwrap(compiled)
        defer { Task { try? await store.removeContentRuleList(forIdentifier: identifier) } }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(list)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.load(URLRequest(url: base.appendingPathComponent("article")))
        try await waitUntil { webView.url != nil && !webView.isLoading }
        let result = try await webView.callAsyncJavaScript("""
            const get = await fetch('/write').then(() => true, () => false);
            const post = await fetch('/write', { method: 'POST' }).then(() => true, () => false);
            return [get, post];
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(result as? [Bool], [false, false])
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 0)
    }

    func testResearchNavigationPolicyRejectsLocalAndInvalidAddresses() throws {
        for address in ["http://127.0.0.1/", "http://localhost./", "http://[::1]/", "http://0x7f000001/",
                        "http://0177.0.0.1/", "http://printer.local/", "http://device.home.arpa/",
                        "https://user:example-password@example.com/", "file:///tmp/article"] {
            XCTAssertFalse(ResearchNavigationPolicy.allows(try XCTUnwrap(URL(string: address))), address)
        }
        XCTAssertTrue(ResearchNavigationPolicy.allows(try XCTUnwrap(URL(string: "https://news.example.com/story"))))
    }

    func testResearchDeniesLocalAddressButUserCanOpenIt() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent())
        let broker = BrowserToolBroker(workspace: workspace)
        let result = try await broker.execute(request(.openAIPage, ["url": base.absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(result.contains("不能直接访问"), result)
        XCTAssertTrue(workspace.tabs.isEmpty)
        let user = workspace.newTab(url: base.appendingPathComponent("article"))
        try await waitUntil { user.finishedRevision > 0 }
        XCTAssertNil(user.error)
        XCTAssertEqual(user.webView.url?.path, "/article")
    }

    func testResearchRedirectIsCheckedBeforeTargetLoads() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { $0.path == "/redirect" })
        let broker = BrowserToolBroker(workspace: workspace)
        let result = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("redirect").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertFalse(result.contains("页面已打开"), result)
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 0)
    }

    func testResearchPageLoadsAreLimitedAndClosingReleasesCapacity() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let first = workspace.newTab(owner: .agent, taskID: "one", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { first.navigationRevision > 0 && first.webView.isLoading }
        let second = workspace.newTab(owner: .agent, taskID: "two", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { second.navigationRevision > 0 && second.webView.isLoading }
        let denied = workspace.newTab(owner: .agent, taskID: "three", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { denied.error != nil }
        XCTAssertEqual(denied.error, "研究页面正在加载，请稍后重试。")
        XCTAssertNil(denied.webView.url)
        let broker = BrowserToolBroker(workspace: workspace)
        let result = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("slow").absoluteString]),
                                              runID: "five", itemID: "item", taskTitle: "研究")
        XCTAssertEqual(result, "研究页面正在加载，请稍后重试。")

        workspace.close(first)
        let replacement = workspace.newTab(owner: .agent, taskID: "four", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { replacement.navigationRevision > 0 && replacement.webView.isLoading }
        XCTAssertNil(replacement.error)
        workspace.close(second)
        workspace.close(replacement)
        workspace.close(denied)
    }

    func testCompletedRedirectReleasesResearchLoadingCapacity() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let redirected = workspace.newTab(owner: .agent, taskID: "redirect", url: base.appendingPathComponent("redirect"), select: false)
        try await waitUntil { redirected.finishedRevision > 0 && !redirected.webView.isLoading }
        XCTAssertNil(redirected.error)
        let first = workspace.newTab(owner: .agent, taskID: "one", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { first.navigationRevision > 0 && first.webView.isLoading }
        let second = workspace.newTab(owner: .agent, taskID: "two", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { second.navigationRevision > 0 }
        XCTAssertNil(second.error)
        XCTAssertTrue(second.webView.isLoading)
        workspace.close(first)
        workspace.close(second)
        workspace.close(redirected)
    }

    func testUserTakingOverResearchPageReleasesLoadingCapacity() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let first = workspace.newTab(owner: .agent, taskID: "one", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { first.navigationRevision > 0 && first.webView.isLoading }
        let second = workspace.newTab(owner: .agent, taskID: "two", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { second.navigationRevision > 0 && second.webView.isLoading }
        workspace.selectTab(first)
        XCTAssertFalse(first.userTookControl)
        workspace.takeControl(first)
        XCTAssertTrue(first.userTookControl)
        let next = workspace.newTab(owner: .agent, taskID: "three", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { next.navigationRevision > 0 }
        XCTAssertNil(next.error)
        XCTAssertTrue(next.webView.isLoading)
        workspace.close(first)
        workspace.close(second)
        workspace.close(next)
    }

    func testAgentPageUserInteractionTakesControlAndRevokesAgentAuthority() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let agent = workspace.newTab(owner: .agent, taskID: "run", url: base.appendingPathComponent("article"), select: false)
        try await waitUntil { agent.finishedRevision > 0 && !agent.webView.isLoading }
        workspace.selectTab(agent)
        XCTAssertFalse(agent.userTookControl)
        workspace.noteUserInteraction(in: agent)
        XCTAssertTrue(agent.userTookControl)
        XCTAssertNil(agent.approvedNavigation)
    }

    func testVisibleAgentPageCanReadObserveExpandAndFollowLinks() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("article").absoluteString]),
                                     runID: "run", itemID: "item", taskTitle: "研究")
        let agent = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        workspace.selectTab(agent)
        XCTAssertFalse(agent.userTookControl)
        let reading = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]),
                                               runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(reading.contains("游客内容"), reading)
        func reference(_ label: String, in text: String) throws -> String {
            let marker = try XCTUnwrap(text.range(of: label))
            return try XCTUnwrap(text[marker.upperBound...].split(separator: "\n").first).description
        }
        let observation = try await broker.execute(request(.observeAIPage, ["tabID": agent.id.uuidString]),
                                                   runID: "run", itemID: "item", taskTitle: "研究")
        let section = try reference("可展开区域标识：", in: observation)
        let expanded = try await broker.execute(request(.expandAISection, ["reference": section]),
                                                runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(expanded.contains("区域已展开"), expanded)
        let afterExpansion = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]),
                                                      runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(afterExpansion.contains("展开后的正文"), afterExpansion)
        let link = try reference("链接标识：", in: observation)
        let opened = try await broker.execute(request(.openAIPageLink, ["reference": link]),
                                              runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(opened.contains("页面已打开"), opened)
        XCTAssertEqual(workspace.selectedID, agent.id)
        XCTAssertTrue(workspace.tabs.contains { $0.owner == .agent && $0.webView.url?.path == "/long" })
        workspace.takeControl(agent)
        let denied = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]),
                                              runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(denied.contains("权限已失效"), denied)
        let stale = try await broker.execute(request(.openAIPageLink, ["reference": link]),
                                             runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(stale.contains("失效"), stale)
    }

    func testAgentScrollingLoadsContentAndKeepsUserPageUnchanged() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let user = workspace.newTab(url: base.appendingPathComponent("scroll-article"))
        user.webView.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        try await waitUntil { user.finishedRevision > 0 }
        _ = try await user.webView.evaluateJavaScript("window.scrollTo(0, 180)")
        let userPosition = try await user.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertGreaterThan(try XCTUnwrap(userPosition), 100)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("scroll-article").absoluteString]),
                                     runID: "first", itemID: "conversation", taskTitle: "研究")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let observation = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]),
                                                   runID: "first", itemID: "conversation", taskTitle: "研究")
        let marker = try XCTUnwrap(observation.range(of: "链接标识："))
        let reference = try XCTUnwrap(observation[marker.upperBound...].split(separator: "\n").first).description
        let scrolled = try await broker.execute(request(.scrollAIPage, ["tabID": tab.id.uuidString, "direction": "down"]),
                                                runID: "first", itemID: "conversation", taskTitle: "研究")
        XCTAssertTrue(scrolled.contains("已滚动"), scrolled)
        let agentPosition = try await tab.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertGreaterThan(try XCTUnwrap(agentPosition), 100)
        let reading = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]),
                                               runID: "first", itemID: "conversation", taskTitle: "研究")
        XCTAssertTrue(reading.contains("滚动后加载的正文"), reading)
        let stale = try await broker.execute(request(.openAIPageLink, ["reference": reference]),
                                             runID: "first", itemID: "conversation", taskTitle: "研究")
        XCTAssertTrue(stale.contains("失效"), stale)
        XCTAssertEqual(workspace.selectedID, user.id)
        let userPositionAfter = try await user.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(userPositionAfter, userPosition)
        XCTAssertEqual(user.webView.url, base.appendingPathComponent("scroll-article"))

        // A follow-up can scroll the conversation's existing page in either direction.
        broker.finishRun("first")
        workspace.selectTab(tab)
        let up = try await broker.execute(request(.scrollAIPage, ["tabID": tab.id.uuidString, "direction": "up"]),
                                          runID: "follow-up", itemID: "conversation", taskTitle: "追问")
        XCTAssertTrue(up.contains("已滚动"), up)
        let agentPositionAfter = try await tab.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(agentPositionAfter, 0)
        XCTAssertFalse(tab.userTookControl)
    }

    func testAgentScrollsNestedArticleContainer() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("nested-scroll-article").absoluteString]),
                                     runID: "run", itemID: "item", taskTitle: "研究")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let result = try await broker.execute(request(.scrollAIPage, ["tabID": tab.id.uuidString, "direction": "down"]),
                                              runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(result.contains("已滚动"), result)
        let outerPosition = try await tab.webView.evaluateJavaScript("window.scrollY") as? Double
        let innerPosition = try await tab.webView.evaluateJavaScript("document.querySelector('#reader').scrollTop") as? Double
        XCTAssertEqual(outerPosition, 0)
        XCTAssertGreaterThan(try XCTUnwrap(innerPosition), 100)
        let reading = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]),
                                               runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(reading.contains("内层滚动后加载的正文"), reading)
    }

    func testAgentScrollingRequiresOwnLivePageAndValidDirection() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let user = workspace.newTab(url: base.appendingPathComponent("scroll-article"))
        try await waitUntil { user.finishedRevision > 0 }
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("scroll-article").absoluteString]),
                                     runID: "run", itemID: "item", taskTitle: "研究")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        for (target, run, item, direction) in [(user.id, "run", "item", "down"),
                                               (tab.id, "foreign", "another", "down"),
                                               (tab.id, "run", "item", "sideways")] {
            let result = try await broker.execute(request(.scrollAIPage, ["tabID": target.uuidString, "direction": direction]),
                                                 runID: run, itemID: item, taskTitle: "研究")
            XCTAssertFalse(result.contains("已滚动"), result)
        }
        let position = try await tab.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(position, 0)
        workspace.takeControl(tab)
        let takenOver = try await broker.execute(request(.scrollAIPage, ["tabID": tab.id.uuidString, "direction": "down"]),
                                                runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(takenOver.contains("权限已失效"), takenOver)
        broker.finishRun("run")
        let finished = try await broker.execute(request(.scrollAIPage, ["tabID": tab.id.uuidString, "direction": "down"]),
                                                runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(finished.contains("已结束"), finished)
    }

    func testFollowUpReusesConversationPagesWithFreshReferences() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("article").absoluteString]),
                                     runID: "first", itemID: "conversation", taskTitle: "研究")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let first = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]),
                                             runID: "first", itemID: "conversation", taskTitle: "研究")
        let marker = try XCTUnwrap(first.range(of: "链接标识："))
        let oldReference = try XCTUnwrap(first[marker.upperBound...].split(separator: "\n").first).description
        broker.finishRun("first")
        for _ in 0..<13 { workspace.newTab(owner: .agent, taskID: "first", select: false) }
        workspace.selectTab(tab)
        XCTAssertTrue(broker.researchContext(itemID: "conversation").contains(tab.id.uuidString))
        XCTAssertTrue(broker.researchContext(itemID: "conversation").contains("当前预览"))
        XCTAssertFalse(broker.researchContext(itemID: "another").contains(tab.id.uuidString))
        let reading = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]),
                                               runID: "follow-up", itemID: "conversation", taskTitle: "追问")
        XCTAssertTrue(reading.contains("游客内容"), reading)
        let stale = try await broker.execute(request(.openAIPageLink, ["reference": oldReference]),
                                             runID: "follow-up", itemID: "conversation", taskTitle: "追问")
        XCTAssertTrue(stale.contains("失效"), stale)
        let refreshed = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]),
                                                 runID: "follow-up", itemID: "conversation", taskTitle: "追问")
        XCTAssertTrue(refreshed.contains("链接标识："), refreshed)
        let foreign = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]),
                                               runID: "foreign", itemID: "another", taskTitle: "另一对话")
        XCTAssertTrue(foreign.contains("不属于当前"), foreign)
        workspace.takeControl(tab)
        XCTAssertTrue(broker.researchContext(itemID: "conversation").contains("用户已接管"))
        broker.endSession(itemID: "conversation")
        XCTAssertFalse(broker.researchContext(itemID: "conversation").contains(tab.id.uuidString))
        let reopened = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]),
                                                runID: "reopened", itemID: "conversation", taskTitle: "重新开始")
        XCTAssertTrue(reopened.contains("不属于当前"), reopened)
    }

    func testPopupOwnershipFollowsCurrentController() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let parent = workspace.newTab(owner: .agent, taskID: "run", url: base.appendingPathComponent("article"), select: false)
        try await waitUntil { parent.finishedRevision > 0 && !parent.webView.isLoading }
        parent.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        _ = try await parent.webView.evaluateJavaScript("window.open('/long', '_blank'); void 0")
        try await waitUntil { workspace.tabs.count == 2 }
        let agentChild = try XCTUnwrap(workspace.tabs.last)
        XCTAssertEqual(agentChild.owner, .agent)
        XCTAssertEqual(agentChild.agentTaskID, "run")
        XCTAssertNil(workspace.selectedID)
        workspace.selectTab(parent)
        workspace.takeControl(parent)
        _ = try await parent.webView.evaluateJavaScript("window.open('/article', '_blank'); void 0")
        try await waitUntil { workspace.tabs.count == 3 }
        let userChild = try XCTUnwrap(workspace.tabs.last)
        XCTAssertEqual(userChild.owner, .user)
        XCTAssertNil(userChild.agentTaskID)
        XCTAssertEqual(workspace.selectedID, userChild.id)
        try await waitUntil { userChild.finishedRevision > 0 && !userChild.webView.isLoading }
        let broker = BrowserToolBroker(workspace: workspace)
        let denied = try await broker.execute(request(.readAIPage, ["tabID": userChild.id.uuidString]),
                                              runID: "run", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(denied.contains("不属于当前"), denied)
    }

    func testSamePageFragmentDoesNotExhaustResearchLoadingCapacity() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let article = workspace.newTab(owner: .agent, taskID: "article", url: base.appendingPathComponent("article"), select: false)
        try await waitUntil { article.finishedRevision > 0 && !article.webView.isLoading }
        _ = try await article.webView.callAsyncJavaScript("location.hash = 'section';", arguments: [:], in: nil, contentWorld: .defaultClient)
        try await waitUntil { article.webView.url?.fragment == "section" }
        let first = workspace.newTab(owner: .agent, taskID: "one", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { first.navigationRevision > 0 && first.webView.isLoading }
        let second = workspace.newTab(owner: .agent, taskID: "two", url: base.appendingPathComponent("slow"), select: false)
        try await waitUntil { second.navigationRevision > 0 }
        XCTAssertNil(second.error)
        XCTAssertTrue(second.webView.isLoading)
        workspace.close(article)
        workspace.close(first)
        workspace.close(second)
    }

    func testPublicArticleEvidenceAndPagingAreScopedToRun() async throws {
        let broker = BrowserToolBroker(workspace: BrowserWorkspace(dataStore: .nonPersistent()), publicArticleReader: { url in
            try PublicArticleService.extract(String(repeating: "文", count: 8_010), mime: "text/plain", url: url)
        })
        let first = try await broker.execute(request(.readPublicArticle, ["url": "https://example.com/article"]), runID: "one", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(first.contains("[E1]"))
        XCTAssertTrue(first.contains("下一段位置：8000"))
        let marker = try XCTUnwrap(first.range(of: "文章标识："))
        let id = try XCTUnwrap(first[marker.upperBound...].split(separator: "\n").first).description
        let second = try await broker.execute(request(.readPublicArticle, ["articleID": id, "offset": "8000"]), runID: "one", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(second.contains("已读取至文章末尾"))
        XCTAssertTrue(second.contains("[E1]"))
        let denied = try await broker.execute(request(.readPublicArticle, ["articleID": id, "offset": "8000"]), runID: "other", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(denied.contains("不属于当前任务"))
        broker.finishRun("one")
        let expired = try await broker.execute(request(.readPublicArticle, ["articleID": id, "offset": "8000"]), runID: "one", itemID: "item", taskTitle: "研究")
        XCTAssertTrue(expired.contains("已结束"))
        XCTAssertEqual(broker.evidence.records.first?.level, .publicArticle)
    }

    func testFinishedRunRejectsItsFirstLateToolRequest() async throws {
        let workspace = BrowserWorkspace(dataStore: .nonPersistent())
        let broker = BrowserToolBroker(workspace: workspace)
        broker.finishRun("finished-before-first-tool")
        let result = try await broker.execute(
            request(.openAIPage, ["url": "https://example.com/"]),
            runID: "finished-before-first-tool", itemID: "item", taskTitle: "研究"
        )
        XCTAssertEqual(result, "任务已结束。")
        XCTAssertTrue(workspace.tabs.isEmpty)
    }

    func testSearchRejectsInvalidTimeRangeBeforeOpeningPage() async throws {
        let workspace = BrowserWorkspace(dataStore: .nonPersistent())
        let broker = BrowserToolBroker(workspace: workspace)
        let result = try await broker.execute(
            request(.searchWeb, ["query": "新闻", "timeRange": "last-century"]),
            runID: "run", itemID: "item", taskTitle: "研究"
        )
        XCTAssertTrue(result.contains("时间范围无效"), result)
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertTrue(broker.evidence.records.isEmpty)
    }

    func testMCPToolRequiresExplicitApprovalAndCancellationClearsRequest() async throws {
        var enabled = true
        let broker = BrowserToolBroker(workspace: BrowserWorkspace(dataStore: .nonPersistent()), mcpIsEnabled: { _, _ in enabled })
        func approval() throws -> AgentStreamEvent.ToolRequest {
            let value: [String: Any] = ["requestID": UUID().uuidString, "toolCallID": UUID().uuidString,
                "name": "mcp_authorize", "arguments": ["serverID": "server", "serverName": "测试服务", "toolName": "search",
                    "argumentsJSON": "{\"query\":\"热点\"}"]]
            return try JSONDecoder().decode(AgentStreamEvent.ToolRequest.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let pending = Task { try await broker.execute(approval(), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.mcpPermission != nil }
        XCTAssertEqual(broker.mcpPermission?.toolName, "search")
        broker.resolveMCPPermission(true)
        let allowed = try await pending.value
        XCTAssertEqual(allowed, "allow")
        let denied = Task { try await broker.execute(approval(), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.mcpPermission != nil }
        broker.resolveMCPPermission(false)
        let result = try await denied.value
        XCTAssertEqual(result, "deny")
        let revoked = Task { try await broker.execute(approval(), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.mcpPermission != nil }
        enabled = false
        broker.resolveMCPPermission(true)
        let revokedResult = try await revoked.value
        XCTAssertEqual(revokedResult, "deny")
        enabled = true
        let cancelled = Task { try await broker.execute(approval(), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.mcpPermission != nil }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled request should not be allowed") } catch is CancellationError {}
        try await waitUntil { broker.mcpPermission == nil }
    }

    func testEndedSessionRejectsAlreadyApprovedMCPAndDelayedArticle() async throws {
        let deferred = DeferredArticle()
        let broker = BrowserToolBroker(workspace: BrowserWorkspace(dataStore: .nonPersistent()), publicArticleReader: { url in
            await deferred.wait()
            return try PublicArticleService.extract("延迟的文章正文", mime: "text/plain", url: url)
        }, mcpIsEnabled: { _, _ in true })
        let value: [String: Any] = ["requestID": UUID().uuidString, "toolCallID": UUID().uuidString,
            "name": "mcp_authorize", "arguments": ["serverID": "server", "serverName": "测试服务", "toolName": "search", "argumentsJSON": "{}"]]
        let approval = try JSONDecoder().decode(AgentStreamEvent.ToolRequest.self, from: JSONSerialization.data(withJSONObject: value))
        let pending = Task { try await broker.execute(approval, runID: "mcp-run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.mcpPermission != nil }
        broker.resolveMCPPermission(true)
        broker.endSession(itemID: "item")
        let decision = try await pending.value
        XCTAssertEqual(decision, "deny")

        let queued = Task { try await broker.execute(approval, runID: "mcp-next", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.mcpPermission != nil }
        broker.finishRun("mcp-next")
        XCTAssertNil(broker.mcpPermission)
        let endedDecision = try await queued.value
        XCTAssertEqual(endedDecision, "deny")

        let article = Task { try await broker.execute(request(.readPublicArticle, ["url": "https://example.com/story"]), runID: "article-run", itemID: "other", taskTitle: "任务") }
        for _ in 0..<200 {
            if await deferred.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await deferred.waiting
        XCTAssertTrue(waiting)
        broker.endSession(itemID: "other")
        await deferred.resume()
        let result = try await article.value
        XCTAssertTrue(result.contains("已结束"), result)
        XCTAssertTrue(broker.evidence.records.isEmpty)
    }

    func testFormSubmissionRequiresCurrentApprovalAndCanBeCancelled() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let page = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("approval-form").absoluteString]),
                                            runID: "run", itemID: "item", taskTitle: "测试任务")
        XCTAssertTrue(page.contains("页面已打开"), page)
        var tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        var activeRun = "run"
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('[name=password]').value = 'fixture-password'")
        func observe() async throws -> String {
            let text = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]),
                                                runID: activeRun, itemID: "item", taskTitle: "测试任务")
            XCTAssertFalse(text.contains("fixture-hidden-token"))
            XCTAssertFalse(text.contains("fixture-password"))
            XCTAssertFalse(text.contains("按钮：登录"))
            let marker = try XCTUnwrap(text.range(of: "页面操作标识："))
            return try XCTUnwrap(text[marker.upperBound...].split(separator: "\n").first).description
        }
        func submissions() async throws -> Int {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Int])?["submissions"])
        }
        let initial = try await observe()
        let otherRun = try await broker.execute(request(.submitAIForm, ["reference": initial]), runID: "other", itemID: "item", taskTitle: "其他任务")
        XCTAssertTrue(otherRun.contains("失效"))
        let denied = Task { try await broker.execute(request(.submitAIForm, ["reference": initial]), runID: "run", itemID: "item", taskTitle: "测试任务") }
        try await waitUntil { broker.actionRequest != nil }
        XCTAssertEqual(broker.actionRequest?.title, "发布")
        XCTAssertEqual(broker.actionRequest?.fields, ["content：待确认内容"])
        XCTAssertFalse(broker.actionRequest?.fields.contains(where: { $0.contains("fixture-hidden-token") }) ?? true)
        broker.resolveAction(false)
        let deniedResult = try await denied.value
        XCTAssertTrue(deniedResult.contains("拒绝"))
        var count = try await submissions()
        XCTAssertEqual(count, 0)

        let changed = Task { try await broker.execute(request(.submitAIForm, ["reference": initial]), runID: "run", itemID: "item", taskTitle: "测试任务") }
        try await waitUntil { broker.actionRequest != nil }
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('[name=content]').value = '已修改'")
        broker.resolveAction(true)
        let changedResult = try await changed.value
        XCTAssertTrue(changedResult.contains("变化"))
        count = try await submissions()
        XCTAssertEqual(count, 0)

        let replacedReference = try await observe()
        let replaced = Task { try await broker.execute(request(.submitAIForm, ["reference": replacedReference]), runID: "run", itemID: "item", taskTitle: "测试任务") }
        try await waitUntil { broker.actionRequest != nil }
        _ = try await tab.webView.evaluateJavaScript("const b = document.querySelector('#submit'); b.replaceWith(b.cloneNode(true));")
        broker.resolveAction(true)
        let replacedResult = try await replaced.value
        XCTAssertTrue(replacedResult.contains("变化"), replacedResult)
        count = try await submissions()
        XCTAssertEqual(count, 0)

        let fresh = try await observe()
        let cancelled = Task { try await broker.execute(request(.submitAIForm, ["reference": fresh]), runID: "run", itemID: "item", taskTitle: "测试任务") }
        try await waitUntil { broker.actionRequest != nil }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation must not submit") } catch is CancellationError {}
        try await waitUntil { broker.actionRequest == nil }
        count = try await submissions()
        XCTAssertEqual(count, 0)

        let revoked = Task { try await broker.execute(request(.submitAIForm, ["reference": fresh]), runID: "run", itemID: "item", taskTitle: "测试任务") }
        try await waitUntil { broker.actionRequest != nil }
        broker.finishRun("run")
        let revokedResult = try await revoked.value
        XCTAssertTrue(revokedResult.contains("拒绝"))
        XCTAssertNil(broker.actionRequest)
        XCTAssertNil(broker.actionOutcome)
        count = try await submissions()
        XCTAssertEqual(count, 0)

        activeRun = "new-run"
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("approval-form").absoluteString]),
                                     runID: activeRun, itemID: "item", taskTitle: "测试任务")
        tab = try XCTUnwrap(workspace.tabs.last { $0.owner == .agent })
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('[name=content]').value = '已修改'")
        let finalReference = try await observe()
        let approved = Task { try await broker.execute(request(.submitAIForm, ["reference": finalReference]), runID: activeRun, itemID: "item", taskTitle: "测试任务") }
        try await waitUntil { broker.actionRequest != nil }
        XCTAssertEqual(broker.actionRequest?.fields, ["content：已修改"])
        broker.resolveAction(true)
        let result = try await approved.value
        XCTAssertTrue(result.contains("核对"), result)
        XCTAssertEqual(broker.actionOutcome?.itemID, "item")
        try await waitUntil { tab.webView.url?.path == "/write" }
        count = try await submissions()
        XCTAssertEqual(count, 1)
        let stale = try await broker.execute(request(.submitAIForm, ["reference": finalReference]), runID: activeRun, itemID: "item", taskTitle: "测试任务")
        XCTAssertTrue(stale.contains("失效"), stale)
        count = try await submissions()
        XCTAssertEqual(count, 1)
    }

    func testTakingOverResearchTabRevokesPendingFormAction() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("approval-form").absoluteString]),
                                     runID: "run", itemID: "item", taskTitle: "任务")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let text = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "任务")
        let marker = try XCTUnwrap(text.range(of: "页面操作标识："))
        let reference = try XCTUnwrap(text[marker.upperBound...].split(separator: "\n").first).description
        let pending = Task { try await broker.execute(request(.submitAIForm, ["reference": reference]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        workspace.selectTab(tab)
        XCTAssertNotNil(broker.actionRequest)
        workspace.takeControl(tab)
        XCTAssertNil(broker.actionRequest)
        broker.resolveAction(true)
        let result = try await pending.value
        XCTAssertTrue(result.contains("拒绝"), result)
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 0)
    }

    func testPostFormRejectsBodyChangedBySubmitHandler() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("approval-form").absoluteString]),
                                     runID: "run", itemID: "item", taskTitle: "任务")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('form').addEventListener('submit', () => { document.querySelector('[name=content]').value = 'changed'; })")
        let observed = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "任务")
        let marker = try XCTUnwrap(observed.range(of: "页面操作标识："))
        let reference = try XCTUnwrap(observed[marker.upperBound...].split(separator: "\n").first).description
        let pending = Task { try await broker.execute(request(.submitAIForm, ["reference": reference]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        XCTAssertEqual(broker.actionRequest?.fields, ["content：待确认内容"])
        broker.resolveAction(true)
        let result = try await pending.value
        XCTAssertTrue(result.contains("用户接管"), result)
        try await waitUntil { tab.needsUserAction }
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 0)
        XCTAssertEqual(tab.webView.url?.path, "/approval-form")
    }

    func testUnsupportedPostEncodingRequestsUserTakeover() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("approval-multipart").absoluteString]),
                                     runID: "run", itemID: "item", taskTitle: "任务")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let observed = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "任务")
        let marker = try XCTUnwrap(observed.range(of: "页面操作标识："))
        let reference = try XCTUnwrap(observed[marker.upperBound...].split(separator: "\n").first).description
        let pending = Task { try await broker.execute(request(.submitAIForm, ["reference": reference]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        broker.resolveAction(true)
        let result = try await pending.value
        XCTAssertTrue(result.contains("用户接管"), result)
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 0)
    }

    func testUserTabOperationGrantIsScopedAndRevokedOnTakeover() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let user = workspace.newTab(url: base.appendingPathComponent("approval-button"))
        user.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        try await waitUntil { user.finishedRevision > 0 && !user.webView.isLoading }
        let arguments = ["tabID": user.id.uuidString]
        let unapproved = try await broker.execute(request(.observeAIPage, arguments), runID: "run", itemID: "item", taskTitle: "任务")
        XCTAssertTrue(unapproved.contains("权限已失效"), unapproved)
        let permission = Task { try await broker.execute(request(.requestUserPage, ["access": "operate", "reason": "查看按钮"]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.permission != nil }
        XCTAssertEqual(broker.permission?.wantsOperation, true)
        broker.resolvePermission(.operateForRun)
        let granted = try await permission.value
        XCTAssertTrue(granted.contains(user.id.uuidString))
        let observed = try await broker.execute(request(.observeAIPage, arguments), runID: "run", itemID: "item", taskTitle: "任务")
        let marker = try XCTUnwrap(observed.range(of: "网页按钮标识："))
        let reference = try XCTUnwrap(observed[marker.upperBound...].split(separator: "\n").first).description
        let pending = Task { try await broker.execute(request(.clickAIButton, ["reference": reference]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        workspace.noteUserInteraction(in: user)
        XCTAssertNil(broker.actionRequest)
        let revoked = try await pending.value
        XCTAssertTrue(revoked.contains("拒绝"), revoked)
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 0)
        let again = try await broker.execute(request(.observeAIPage, arguments), runID: "run", itemID: "item", taskTitle: "任务")
        XCTAssertTrue(again.contains("权限已失效"), again)
        let readOnly = Task { try await broker.execute(request(.requestUserPage, ["access": "operate", "reason": "查看按钮"]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.permission != nil }
        broker.resolvePermission(.readForRun)
        let readOnlyResult = try await readOnly.value
        XCTAssertTrue(readOnlyResult.contains("未授权操作"), readOnlyResult)
        let noOperation = try await broker.execute(request(.observeAIPage, arguments), runID: "run", itemID: "item", taskTitle: "任务")
        XCTAssertTrue(noOperation.contains("权限已失效"), noOperation)
        let upgrade = Task { try await broker.execute(request(.requestUserPage, ["access": "operate", "reason": "操作按钮"]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.permission != nil }
        broker.resolvePermission(.operateForRun)
        _ = try await upgrade.value
        let refreshed = try await broker.execute(request(.observeAIPage, arguments), runID: "run", itemID: "item", taskTitle: "任务")
        let nextMarker = try XCTUnwrap(refreshed.range(of: "网页按钮标识："))
        let nextReference = try XCTUnwrap(refreshed[nextMarker.upperBound...].split(separator: "\n").first).description
        let approved = Task { try await broker.execute(request(.clickAIButton, ["reference": nextReference]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        broker.resolveAction(true)
        let result = try await approved.value
        XCTAssertTrue(result.contains("核对"), result)
        let (afterData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: afterData) as? [String: Int])
        XCTAssertEqual(after["submissions"], 1)
        XCTAssertEqual(workspace.selectedID, user.id)
    }

    func testEndingRunRejectsPendingUserGrant() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let user = workspace.newTab(url: base.appendingPathComponent("approval-button"))
        try await waitUntil { user.finishedRevision > 0 && !user.webView.isLoading }
        let pending = Task { try await broker.execute(request(.requestUserPage, ["access": "operate", "reason": "操作"]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.permission != nil }
        broker.finishRun("run")
        let result = try await pending.value
        XCTAssertTrue(result.contains("变化"), result)
        XCTAssertNil(broker.permission)
        let next = try await broker.execute(request(.observeAIPage, ["tabID": user.id.uuidString]), runID: "run", itemID: "item", taskTitle: "任务")
        XCTAssertTrue(next.contains("已结束"), next)
    }

    func testEndingSessionAfterApprovalCannotRestoreUserGrant() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let tab = workspace.newTab(url: base.appendingPathComponent("approval-button"))
        try await waitUntil { tab.finishedRevision > 0 && !tab.webView.isLoading }
        let pending = Task { try await broker.execute(request(.requestUserPage, ["access": "operate", "reason": "操作"]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.permission != nil }
        // Resume the continuation, then close the session before it can run.
        broker.resolvePermission(.operateForRun)
        broker.endSession(itemID: "item")
        let result = try await pending.value
        XCTAssertFalse(result.contains("已授权"), result)
        let late = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "任务")
        XCTAssertTrue(late.contains("已结束"), late)
    }

    func testPendingUserPermissionClosesWhenUserTakesOver() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let tab = workspace.newTab(url: base.appendingPathComponent("approval-button"))
        try await waitUntil { tab.finishedRevision > 0 && !tab.webView.isLoading }
        let pending = Task { try await broker.execute(request(.requestUserPage, ["access": "operate", "reason": "操作"]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.permission != nil }
        workspace.noteUserInteraction(in: tab)
        XCTAssertNil(broker.permission)
        let result = try await pending.value
        XCTAssertTrue(result.contains("变化"), result)
        let noGrant = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "任务")
        XCTAssertTrue(noGrant.contains("权限已失效"), noGrant)
    }

    func testUserInteractionMonitorTracksWebViewInputButNotOtherControls() async throws {
        let workspace = BrowserWorkspace(dataStore: .nonPersistent())
        let tab = workspace.newTab()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container
        tab.webView.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        container.addSubview(tab.webView)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); tab.webView.removeFromSuperview() }
        func mouse(_ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                            clickCount: 1, pressure: 1))
        }
        let initial = tab.userInteractionRevision
        NSApp.sendEvent(try mouse(CGPoint(x: 500, y: 200)))
        XCTAssertEqual(tab.userInteractionRevision, initial)
        NSApp.sendEvent(try mouse(CGPoint(x: 200, y: 200)))
        XCTAssertGreaterThan(tab.userInteractionRevision, initial)
        tab.webView.removeFromSuperview()
        let agent = workspace.newTab(owner: .agent, taskID: "run", select: false)
        agent.webView.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        container.addSubview(agent.webView)
        defer { agent.webView.removeFromSuperview() }
        workspace.selectTab(agent)
        NSApp.sendEvent(try mouse(CGPoint(x: 500, y: 200)))
        XCTAssertFalse(agent.userTookControl)
        NSApp.sendEvent(try mouse(CGPoint(x: 200, y: 200)))
        XCTAssertTrue(agent.userTookControl)
    }

    func testApprovedGetFormNavigatesOnce() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("approval-get").absoluteString]),
                                     runID: "run", itemID: "item", taskTitle: "任务")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let observed = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "任务")
        let marker = try XCTUnwrap(observed.range(of: "页面操作标识："))
        let reference = try XCTUnwrap(observed[marker.upperBound...].split(separator: "\n").first).description
        let pending = Task { try await broker.execute(request(.submitAIForm, ["reference": reference]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        XCTAssertEqual(broker.actionRequest?.method, "GET")
        XCTAssertEqual(broker.actionRequest?.fields, ["topic：news"])
        broker.resolveAction(true)
        _ = try await pending.value
        try await waitUntil { tab.webView.url?.path == "/write" }
        XCTAssertEqual(tab.webView.url?.query, "topic=news")
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 1)
    }

    func testGetFormRejectsQueryChangedBySubmitHandler() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("approval-get").absoluteString]),
                                     runID: "run", itemID: "item", taskTitle: "任务")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('form').addEventListener('submit', () => { document.querySelector('[name=topic]').value = 'changed'; })")
        let observed = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "任务")
        let marker = try XCTUnwrap(observed.range(of: "页面操作标识："))
        let reference = try XCTUnwrap(observed[marker.upperBound...].split(separator: "\n").first).description
        let pending = Task { try await broker.execute(request(.submitAIForm, ["reference": reference]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        XCTAssertEqual(broker.actionRequest?.fields, ["topic：news"])
        broker.resolveAction(true)
        _ = try await pending.value
        try await waitUntil { tab.needsUserAction }
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 0)
        XCTAssertEqual(tab.webView.url?.path, "/approval-get")
    }

    func testApprovedGetFormSupportsUnicodeRepeatedFieldsAndSubmitter() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("approval-get-unicode").absoluteString]),
                                     runID: "run", itemID: "item", taskTitle: "任务")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let observed = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "任务")
        let marker = try XCTUnwrap(observed.range(of: "页面操作标识："))
        let reference = try XCTUnwrap(observed[marker.upperBound...].split(separator: "\n").first).description
        let pending = Task { try await broker.execute(request(.submitAIForm, ["reference": reference]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        broker.resolveAction(true)
        _ = try await pending.value
        try await waitUntil { tab.webView.url?.path == "/write" }
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 1)
    }

    func testScriptedButtonNeedsConfirmationAndRejectsReplacedElement() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("approval-button").absoluteString]),
                                     runID: "run", itemID: "item", taskTitle: "任务")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        func observe() async throws -> String {
            let text = try await broker.execute(request(.observeAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "任务")
            XCTAssertFalse(text.contains("按钮：不可用"))
            let marker = try XCTUnwrap(text.range(of: "网页按钮标识："))
            return try XCTUnwrap(text[marker.upperBound...].split(separator: "\n").first).description
        }
        func submissions() async throws -> Int {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Int])?["submissions"])
        }
        let initial = try await observe()
        let denied = Task { try await broker.execute(request(.clickAIButton, ["reference": initial]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        XCTAssertEqual(broker.actionRequest?.title, "发布更新")
        broker.resolveAction(false)
        let deniedResult = try await denied.value
        XCTAssertTrue(deniedResult.contains("拒绝"))
        var count = try await submissions()
        XCTAssertEqual(count, 0)
        let changed = Task { try await broker.execute(request(.clickAIButton, ["reference": initial]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        _ = try await tab.webView.evaluateJavaScript("const b = document.querySelector('#publish'); b.replaceWith(b.cloneNode(true));")
        broker.resolveAction(true)
        let changedResult = try await changed.value
        XCTAssertTrue(changedResult.contains("变化"), changedResult)
        count = try await submissions()
        XCTAssertEqual(count, 0)
        let fresh = try await observe()
        let approved = Task { try await broker.execute(request(.clickAIButton, ["reference": fresh]), runID: "run", itemID: "item", taskTitle: "任务") }
        try await waitUntil { broker.actionRequest != nil }
        broker.resolveAction(true)
        let result = try await approved.value
        XCTAssertTrue(result.contains("核对"), result)
        count = try await submissions()
        XCTAssertEqual(count, 1)
        let stale = try await broker.execute(request(.clickAIButton, ["reference": fresh]), runID: "run", itemID: "item", taskTitle: "任务")
        XCTAssertTrue(stale.contains("失效"))
        count = try await submissions()
        XCTAssertEqual(count, 1)
    }

    func testReaderKeepsLivePageAndClearsOnNavigation() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent())
        let tab = workspace.newTab(url: base.appendingPathComponent("article"))
        tab.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        try await waitUntil { tab.finishedRevision > 0 && !tab.webView.isLoading }
        _ = try await tab.webView.evaluateJavaScript("window.scrollTo(0, 600)")
        let scrollValue = try await tab.webView.evaluateJavaScript("window.scrollY") as? Double
        let scroll = try XCTUnwrap(scrollValue)
        XCTAssertGreaterThan(scroll, 0)

        await workspace.showReader(in: tab)
        XCTAssertTrue(tab.showingReader)
        XCTAssertEqual(tab.readerContent?.url, base.appendingPathComponent("article"))
        XCTAssertEqual(tab.readerContent?.text, "游客内容")
        tab.showingReader = false
        let after = try await tab.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(after, scroll)

        let revision = tab.navigationRevision
        workspace.load(base.appendingPathComponent("login"), in: tab)
        try await waitUntil { tab.navigationRevision > revision }
        XCTAssertNil(tab.readerContent)
        XCTAssertFalse(tab.showingReader)
    }

    func testSharedLoginAndBackgroundResearchRespectUserTab() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let userTab = workspace.newTab(url: base.appendingPathComponent("login"))
        userTab.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        try await waitUntil { userTab.finishedRevision > 0 }
        XCTAssertNil(userTab.error)
        let originalURL = userTab.webView.url
        _ = try await userTab.webView.evaluateJavaScript("window.scrollTo(0,600)")
        let originalScroll = try await userTab.webView.evaluateJavaScript("window.scrollY") as? Double ?? 0
        XCTAssertGreaterThan(originalScroll, 0)

        let result = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("article").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(result.contains("页面已打开"), result)
        let agent = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        XCTAssertEqual(workspace.selectedID, userTab.id)
        XCTAssertEqual(userTab.webView.url, originalURL)
        let afterScroll = try await userTab.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(afterScroll, originalScroll)
        let text = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(text.contains("登录后可见的文章正文"), text)
        XCTAssertTrue(text.contains("[E1]"), text)
        let found = try await broker.execute(request(.findAIPage, ["tabID": agent.id.uuidString, "query": "文章正文"]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(found.contains("登录后可见的文章正文"), found)
        XCTAssertTrue(found.contains("证据编号"), found)
        let deniedSearch = try await broker.execute(request(.findAIPage, ["tabID": agent.id.uuidString, "query": "文章"]), runID: "other", itemID: "other-item", taskTitle: "测试")
        XCTAssertTrue(deniedSearch.contains("无效"), deniedSearch)
        let otherRun = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]), runID: "other", itemID: "other-item", taskTitle: "测试")
        XCTAssertTrue(otherRun.contains("不属于当前"), otherRun)
        workspace.selectTab(agent)
        workspace.takeControl(agent)
        let afterTakeover = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(afterTakeover.contains("权限已失效"), afterTakeover)
    }

    func testResearchWaitsForDelayedArticleText() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("delayed-article").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let text = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(text.contains("延迟加载的报道正文"), text)
        XCTAssertTrue(text.contains("证据编号"), text)
    }

    func testDelayedArticleReadStopsAfterRunEnds() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("delayed-article").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let pending = Task { try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试") }
        try await Task.sleep(for: .milliseconds(150))
        broker.finishRun("run")
        let text = try await pending.value
        XCTAssertTrue(text.contains("权限已失效"), text)
        XCTAssertTrue(broker.evidence.records.isEmpty)
    }

    func testDelayedArticleReadCanBeCancelled() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("delayed-article").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let pending = Task { try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试") }
        try await Task.sleep(for: .milliseconds(150))
        pending.cancel()
        do { _ = try await pending.value; XCTFail("等待中的读取应取消") } catch is CancellationError { }
        XCTAssertTrue(broker.evidence.records.isEmpty)
    }

    func testDelayedArticleReadReportsPageNavigation() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("delayed-article").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let originalRevision = tab.navigationRevision
        let pending = Task { try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试") }
        try await Task.sleep(for: .milliseconds(150))
        tab.webView.load(URLRequest(url: base.appendingPathComponent("sensitive")))
        try await waitUntil { tab.navigationRevision > originalRevision }
        let text = try await pending.value
        XCTAssertTrue(text.contains("页面导航或内容已变化"), text)
        XCTAssertTrue(broker.evidence.records.isEmpty)
    }

    func testResearchReadsArticleWithoutFormsOrEditableContent() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let result = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("sensitive").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(result.contains("页面已打开"), result)
        let agent = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        agent.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        let text = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(text.contains("可引用的新闻正文"), text)
        XCTAssertTrue(text.contains("可见的行内文字"), text)
        for excluded in ["导航区个人信息", "不可见内容", "正在编辑的内容", "输入区已有内容", "账户字段", "侧栏个人信息", "展开后的内容"] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
        let found = try await broker.execute(request(.findAIPage, ["tabID": agent.id.uuidString, "query": "正在编辑的内容"]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(found.contains("没有找到"), found)
        XCTAssertEqual(broker.evidence.records.count, 1)
        let prior = broker.evidence.followUpContext(itemID: "item")
        XCTAssertTrue(prior.contains("可引用的新闻正文"))
        XCTAssertFalse(prior.contains("正在编辑的内容"))
        XCTAssertTrue(broker.evidence.followUpContext(itemID: "different-item").isEmpty)

        _ = try await agent.webView.evaluateJavaScript("document.querySelector('details').open = true")
        let expanded = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(expanded.contains("展开后的内容"), expanded)

        let user = workspace.newTab(url: base.appendingPathComponent("sensitive"))
        user.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        try await waitUntil { user.finishedRevision > 0 }
        let requested = Task { try await broker.execute(self.request(.requestUserPage), runID: "user-run", itemID: "item", taskTitle: "测试") }
        try await waitUntil { broker.permission != nil }
        broker.resolvePermission(.readForRun)
        let userText = try await requested.value
        XCTAssertTrue(userText.contains("可引用的新闻正文"), userText)
        XCTAssertFalse(userText.contains("输入区已有内容"), userText)
        XCTAssertFalse(userText.contains("正在编辑的内容"), userText)
    }

    func testResearchExtractionUsesIsolatedJavaScriptWorld() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("hostile-extraction").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        let agent = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        agent.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        let text = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(text.contains("网页实际正文"), text)
        XCTAssertFalse(text.contains("伪造的内容"), text)
        let observed = try await broker.execute(request(.observeAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(observed.contains("下一篇报道"), observed)
        XCTAssertTrue(observed.contains("展开报道"), observed)
    }

    func testHTTPFailuresAreNotRecordedAsResearchEvidence() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        for status in [401, 403, 429, 500] {
            let url = base.appendingPathComponent("status/\(status)")
            let result = try await broker.execute(request(.openAIPage, ["url": url.absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
            let tab = try XCTUnwrap(workspace.tabs.last { $0.owner == .agent })
            XCTAssertEqual(tab.httpStatus, status)
            if status == 401 || status == 403 {
                XCTAssertTrue(result.contains("wait_for_login"), result)
            } else {
                XCTAssertTrue(result.contains("HTTP \(status)"), result)
            }
            let text = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
            XCTAssertFalse(text.contains("错误页面不应成为证据"), text)
            XCTAssertFalse(text.contains("证据编号"), text)
        }
        XCTAssertTrue(broker.evidence.records.isEmpty)
    }

    func testChildFrameFailuresDoNotReplaceMainPageStatus() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let result = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("frames").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(result.contains("页面已打开"), result)
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        XCTAssertEqual(tab.httpStatus, 200)
        XCTAssertNil(tab.error)
        XCTAssertFalse(tab.needsUserAction)
        let text = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(text.contains("主页面报道内容"), text)
    }

    func testBackgroundResearchUsesDesktopViewport() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let user = workspace.newTab()
        let result = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("responsive").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(result.contains("页面已打开"), result)
        let agent = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        XCTAssertEqual(workspace.selectedID, user.id)
        let text = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(text.contains("桌面视口中的报道"), text)
    }

    func testLiveSiteResponseClassificationWhenConfigured() async throws {
        guard let address = ProcessInfo.processInfo.environment["TRENDINGTAB_LIVE_BROWSER_URL"],
              let url = URL(string: address) else {
            throw XCTSkip("Set TRENDINGTAB_LIVE_BROWSER_URL to exercise an anonymous live site.")
        }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent())
        let broker = BrowserToolBroker(workspace: workspace)
        let result = try await broker.execute(request(.openAIPage, ["url": url.absoluteString]), runID: "live", itemID: "live", taskTitle: "真实站点检查")
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent }, result)
        let status = try XCTUnwrap(tab.httpStatus, "站点未返回可识别的 HTTP 响应：\(result)")
        print("Live WebKit host: \(url.host ?? "unknown"), HTTP status: \(status)")
        XCTContext.runActivity(named: "真实站点 HTTP 响应") { activity in
            let attachment = XCTAttachment(string: "host=\(url.host ?? "unknown") status=\(status) errorDomain=\(tab.navigationErrorDomain ?? "none") errorCode=\(tab.navigationErrorCode.map(String.init) ?? "none")")
            attachment.name = "live-site-status.txt"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        var outcome = "unknown"
        if tab.navigationErrorCode != nil {
            outcome = "navigation-error"
            XCTAssertFalse(result.contains("页面已打开"), result)
            XCTAssertTrue(broker.evidence.records.isEmpty)
        } else if status == 401 || status == 403 {
            outcome = "access-restricted"
            XCTAssertTrue(result.contains("wait_for_login"), result)
            XCTAssertTrue(broker.evidence.records.isEmpty)
        } else if status >= 400 {
            outcome = "http-error"
            XCTAssertTrue(result.contains("HTTP \(status)"), result)
            XCTAssertTrue(broker.evidence.records.isEmpty)
        } else {
            XCTAssertTrue(result.contains("页面已打开"), result)
            let content = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]), runID: "live", itemID: "live", taskTitle: "真实站点检查")
            outcome = content.contains("证据编号") ? "readable-text" : (content.contains("wait_for_login") ? "verification-required" :
                (content.contains("页面导航或内容已变化") ? "page-changing" : "no-readable-text"))
            XCTAssertTrue(content.contains("证据编号") || content.contains("wait_for_login") || content.contains("未提供可读取") || content.contains("页面导航或内容已变化"), content)
            if outcome == "page-changing" { XCTAssertTrue(broker.evidence.records.isEmpty) }
        }
        XCTContext.runActivity(named: "真实站点读取结果") { activity in
            let attachment = XCTAttachment(string: "host=\(url.host ?? "unknown") outcome=\(outcome)")
            attachment.name = "live-site-outcome.txt"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    func testLiveBingSearchExtractionWhenConfigured() async throws {
        guard ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_LIVE_BING"] == "1" else {
            throw XCTSkip("Set TRENDINGTAB_TEST_LIVE_BING to exercise actual Bing search extraction.")
        }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent())
        let broker = BrowserToolBroker(workspace: workspace)
        let destination = try ResearchWebSearch.destination(engine: .bing, request: .init(query: "macOS", timeRange: "day"))
        let opened = try await broker.execute(request(.openAIPage, ["url": destination.url.absoluteString]), runID: "live-search", itemID: "live-search", taskTitle: "搜索验证")
        XCTAssertTrue(opened.contains("页面已打开"), opened)
        let tab = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let result = try await broker.extractSearchResults(tab, engine: "bing", runID: "live-search", itemID: "live-search")
        XCTAssertTrue(result.contains("结果标识："), result)
        XCTAssertTrue(broker.evidence.records.contains { $0.level == .searchSnippet })
        let marker = try XCTUnwrap(result.range(of: "结果标识："))
        let reference = try XCTUnwrap(result[marker.upperBound...].split(separator: "\n").first).description
        let followed = try await broker.execute(request(.openSearchResult, ["resultID": reference]), runID: "live-search", itemID: "live-search", taskTitle: "搜索验证")
        XCTAssertTrue(followed.contains("页面已打开"), followed)
        let openedTab = try XCTUnwrap(workspace.tabs.last { $0.owner == .agent && $0.id != tab.id })
        let article = try await broker.execute(request(.readAIPage, ["tabID": openedTab.id.uuidString]), runID: "live-search", itemID: "live-search", taskTitle: "搜索验证")
        XCTAssertTrue(article.contains("证据编号"), article)
        XCTAssertTrue(broker.evidence.records.contains { $0.level == .pageText })
        XCTContext.runActivity(named: "搜索来源") { activity in
            let attachment = XCTAttachment(string: "host=\(openedTab.webView.url?.host ?? "unknown")")
            attachment.name = "live-search-source.txt"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    func testPiResearchScrollsAndReadsLazyContentThroughNativeBroker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let node = environment["TRENDINGTAB_TEST_NODE"], let runtime = environment["TRENDINGTAB_TEST_RUNTIME"] else {
            if environment["TRENDINGTAB_REQUIRE_PI_INTEGRATION"] == "1" {
                throw NSError(domain: "TrendingTabBrowserTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pi integration paths are required."])
            }
            throw XCTSkip("Set the Pi runtime paths to exercise browser integration.")
        }
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let user = workspace.newTab(url: base.appendingPathComponent("login"))
        try await waitUntil { user.finishedRevision > 0 }
        let bridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: URL(fileURLWithPath: runtime))
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: base.appendingPathComponent("v1"),
                                      model: "mock", credentialAccount: "fixture")
        let stream = try await bridge.run(sessionID: "browser-scroll", connection: connection, credential: "fixture",
                                          prompt: "研究滚动页面", system: "引用来源", tools: [.openAIPage, .scrollAIPage, .readAIPage], ephemeral: true)
        var text = ""
        var called: [String] = []
        for try await event in stream {
            if let request = event.toolRequest {
                called.append(request.name)
                let result = try await broker.execute(request, runID: event.runID, itemID: "item", taskTitle: "滚动研究")
                XCTAssertEqual(workspace.selectedID, user.id)
                try await bridge.respondToTool(runID: event.runID, requestID: request.requestID, text: result)
            }
            if event.type == "text_delta" { text += event.text ?? "" }
        }
        XCTAssertEqual(called, [AgentToolName.openAIPage.rawValue, AgentToolName.scrollAIPage.rawValue, AgentToolName.readAIPage.rawValue])
        XCTAssertEqual(text, "已阅读滚动后加载的正文 [E1]")
        XCTAssertEqual(broker.evidence.citations(in: text, itemID: "item").valid.first?.url.path, "/scroll-article")
        XCTAssertEqual(user.webView.url?.path, "/login")
    }

    func testPiResearchReadsVisibleLoggedInPageThroughNativeBroker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let node = environment["TRENDINGTAB_TEST_NODE"], let runtime = environment["TRENDINGTAB_TEST_RUNTIME"] else {
            if environment["TRENDINGTAB_REQUIRE_PI_INTEGRATION"] == "1" {
                throw NSError(domain: "TrendingTabBrowserTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Pi integration is required but its runtime paths were not passed to the test process."
                ])
            }
            throw XCTSkip("Set the Pi runtime paths to exercise browser integration.")
        }
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let userTab = workspace.newTab(url: base.appendingPathComponent("login"))
        try await waitUntil { userTab.finishedRevision > 0 }
        let bridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: URL(fileURLWithPath: runtime))
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: base.appendingPathComponent("v1"),
                                      model: "mock", credentialAccount: "fixture")
        let storyURL = try XCTUnwrap(URL(string: base.appendingPathComponent("article").absoluteString + "?session=private"))
        let stream = try await bridge.run(sessionID: "browser-fixture", connection: connection, credential: "fixture",
                                          prompt: "研究当前原文", system: "引用来源", tools: [.openCurrentStory, .readAIPage], ephemeral: true)
        var text = ""
        var called: [String] = []
        for try await event in stream {
            if let request = event.toolRequest {
                called.append(request.name)
                let result = try await broker.execute(request, runID: event.runID, itemID: "item", taskTitle: "测试研究", currentStoryURL: storyURL)
                XCTAssertFalse(result.contains("session=private"))
                if request.name == AgentToolName.openCurrentStory.rawValue {
                    XCTAssertEqual(workspace.selectedID, userTab.id)
                    workspace.selectTab(try XCTUnwrap(workspace.tabs.first { $0.owner == .agent }))
                }
                try await bridge.respondToTool(runID: event.runID, requestID: request.requestID, text: result)
            }
            if event.type == "text_delta" { text += event.text ?? "" }
        }
        XCTAssertEqual(called, [AgentToolName.openCurrentStory.rawValue, AgentToolName.readAIPage.rawValue])
        XCTAssertEqual(text, "已阅读登录文章 [E1]")
        XCTAssertEqual(broker.evidence.citations(in: text, itemID: "item").valid.first?.url.path, "/article")
        XCTAssertEqual(workspace.selectedID, workspace.tabs.first { $0.owner == .agent }?.id)
        XCTAssertFalse(try XCTUnwrap(workspace.selected).userTookControl)
        XCTAssertEqual(userTab.webView.url?.path, "/login")
        XCTAssertEqual(workspace.tabs.first { $0.owner == .agent }?.webView.url?.query, "session=private")
    }

    func testPiFormActionWaitsForNativeConfirmation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let node = environment["TRENDINGTAB_TEST_NODE"], let runtime = environment["TRENDINGTAB_TEST_RUNTIME"] else {
            if environment["TRENDINGTAB_REQUIRE_PI_INTEGRATION"] == "1" {
                throw NSError(domain: "TrendingTabBrowserTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pi integration paths are required."])
            }
            throw XCTSkip("Set the Pi runtime paths to exercise browser integration.")
        }
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let userTab = workspace.newTab(url: base.appendingPathComponent("login"))
        try await waitUntil { userTab.finishedRevision > 0 }
        let bridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: URL(fileURLWithPath: runtime))
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: base.appendingPathComponent("v1"),
                                      model: "mock", credentialAccount: "fixture")
        for allowed in [false, true] {
            let stream = try await bridge.run(sessionID: UUID().uuidString, connection: connection, credential: "fixture",
                                              prompt: "研究表单确认", system: "调用工具并等待用户确认",
                                              tools: [.openAIPage, .observeAIPage, .submitAIForm], ephemeral: true)
            let task = Task { @MainActor in
                var text = ""
                var names: [String] = []
                for try await event in stream {
                    if let request = event.toolRequest {
                        names.append(request.name)
                        let result = try await broker.execute(request, runID: event.runID, itemID: "item", taskTitle: "测试研究")
                        try await bridge.respondToTool(runID: event.runID, requestID: request.requestID, text: result)
                    }
                    if event.type == "text_delta" { text += event.text ?? "" }
                }
                return (text, names)
            }
            try await waitUntil { broker.actionRequest != nil }
            XCTAssertEqual(broker.actionRequest?.title, "发布")
            XCTAssertEqual(broker.actionRequest?.fields, ["content：待确认内容"])
            let (beforeData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeData) as? [String: Int])
            XCTAssertEqual(before["submissions"], 0)
            XCTAssertEqual(workspace.selectedID, userTab.id)
            broker.resolveAction(allowed)
            let (text, names) = try await task.value
            XCTAssertEqual(names, ["open_ai_page", "observe_ai_page", "submit_ai_form"])
            XCTAssertEqual(text, allowed ? "请核对提交结果。" : "用户拒绝了提交。")
            let (afterData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            let after = try XCTUnwrap(JSONSerialization.jsonObject(with: afterData) as? [String: Int])
            XCTAssertEqual(after["submissions"], allowed ? 1 : 0)
            XCTAssertEqual(workspace.selectedID, userTab.id)
        }
    }

    func testPiUserTabOperationRequiresGrantAndConfirmation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let node = environment["TRENDINGTAB_TEST_NODE"], let runtime = environment["TRENDINGTAB_TEST_RUNTIME"] else {
            if environment["TRENDINGTAB_REQUIRE_PI_INTEGRATION"] == "1" {
                throw NSError(domain: "TrendingTabBrowserTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pi integration paths are required."])
            }
            throw XCTSkip("Set the Pi runtime paths to exercise browser integration.")
        }
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let tab = workspace.newTab(url: base.appendingPathComponent("approval-button"))
        tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        try await waitUntil { tab.finishedRevision > 0 && !tab.webView.isLoading }
        let bridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: URL(fileURLWithPath: runtime))
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: base.appendingPathComponent("v1"), model: "mock", credentialAccount: "fixture")
        let stream = try await bridge.run(sessionID: UUID().uuidString, connection: connection, credential: "fixture", prompt: "研究用户标签",
                                          system: "使用授权工具", tools: [.requestUserPage, .observeAIPage, .clickAIButton], ephemeral: true)
        let task = Task { @MainActor in
            var text = ""
            var names: [String] = []
            for try await event in stream {
                if let request = event.toolRequest {
                    names.append(request.name)
                    let result = try await broker.execute(request, runID: event.runID, itemID: "item", taskTitle: "测试研究")
                    try await bridge.respondToTool(runID: event.runID, requestID: request.requestID, text: result)
                }
                if event.type == "text_delta" { text += event.text ?? "" }
            }
            return (text, names)
        }
        try await waitUntil { broker.permission != nil }
        XCTAssertEqual(broker.permission?.wantsOperation, true)
        broker.resolvePermission(.operateForRun)
        try await waitUntil { broker.actionRequest != nil }
        XCTAssertEqual(broker.actionRequest?.title, "发布更新")
        broker.resolveAction(true)
        let (text, names) = try await task.value
        XCTAssertEqual(names, ["request_user_page", "observe_ai_page", "click_ai_button"])
        XCTAssertEqual(text, "请核对用户页面操作结果。")
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 1)
        XCTAssertEqual(workspace.selectedID, tab.id)
    }

    func testCaptchaPageRequestsUserVerification() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        workspace.newTab()
        for path in ["captcha", "qr"] {
            _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent(path).absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
            let agent = try XCTUnwrap(workspace.tabs.last { $0.owner == .agent })
            let result = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
            XCTAssertTrue(result.contains("wait_for_login"), result)
        }
        XCTAssertTrue(broker.evidence.records.isEmpty)
    }

    func testWebSearchDistinguishesVerificationFromEmptyAndAvailableResults() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        workspace.newTab()
        for (path, engine, expected) in [("captcha", "bing", "wait_for_login"), ("long", "bing", "没有返回结果"), ("search-result", "bing", "测试搜索结果"), ("baidu-safety", "baidu", "wait_for_login")] {
            _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent(path).absoluteString]),
                                         runID: "run", itemID: "item", taskTitle: "测试")
            let tab = try XCTUnwrap(workspace.tabs.last { $0.owner == .agent })
            tab.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
            let result = try await broker.extractSearchResults(tab, engine: engine, runID: "run", itemID: "item")
            XCTAssertTrue(result.contains(expected), result)
            if expected == "wait_for_login" { XCTAssertTrue(result.contains(tab.id.uuidString), result) }
        }
        XCTAssertEqual(broker.evidence.records.count, 1)
    }

    func testCurrentHotTopicsOnlyReturnsFreshRowsAndScopesReferences() async throws {
        let tabID = UUID()
        let now = Date()
        let live = SnapshotRow(id: "live", title: "当前热点", sourceTitle: "知乎", rank: 1, movement: nil,
                               url: URL(string: "https://example.com/live?private=1"), eventID: nil, publishedAt: nil, score: 1,
                               expiresAt: now.addingTimeInterval(60))
        let stale = SnapshotRow(id: "stale", title: "过时热点", sourceTitle: "知乎", rank: 2, movement: nil,
                                url: URL(string: "https://example.com/stale"), eventID: nil, publishedAt: nil, score: 1,
                                expiresAt: now.addingTimeInterval(-1))
        var snapshot: WidgetSnapshot? = WidgetSnapshot(generation: 1, generatedAt: now, profiles: [],
            tabs: [SnapshotTab(id: tabID, title: "知乎", kind: .sourceBoard, rows: [live, stale], coverage: "", updatedAt: now)], statuses: [], unreadCount: 0)
        let broker = BrowserToolBroker(workspace: BrowserWorkspace(dataStore: .nonPersistent()), currentSnapshot: { snapshot })
        let listing = try await broker.execute(request(.currentHotTopics), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(listing.contains(tabID.uuidString), listing)
        XCTAssertTrue(listing.contains("当前条数：1"), listing)
        let result = try await broker.execute(request(.currentHotTopics, ["tabID": tabID.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(result.contains("当前热点"), result)
        XCTAssertFalse(result.contains("过时热点"), result)
        XCTAssertFalse(result.contains("private=1"), result)
        XCTAssertEqual(broker.evidence.records.first?.level, .feedTitle)
        let marker = try XCTUnwrap(result.range(of: "结果标识："))
        let reference = try XCTUnwrap(result[marker.upperBound...].split(separator: "；").first).description
        let foreign = try await broker.execute(request(.openSearchResult, ["resultID": reference]), runID: "other", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(foreign.contains("不属于当前任务"), foreign)
        snapshot = nil
        let unavailable = try await broker.execute(request(.currentHotTopics), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(unavailable.contains("没有可用"), unavailable)
    }

    func testResearchLinkReferencesAreScopedAndInvalidated() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let user = workspace.newTab(url: base.appendingPathComponent("login"))
        try await waitUntil { user.finishedRevision > 0 }
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("article").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        let agent = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        func observe() async throws -> String {
            let result = try await broker.execute(request(.observeAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
            let match = try XCTUnwrap(result.range(of: "[0-9A-F-]{36}", options: .regularExpression))
            return String(result[match])
        }
        let first = try await observe()
        let foreign = try await broker.execute(request(.openAIPageLink, ["reference": first]), runID: "other", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(foreign.contains("失效"))
        _ = try await agent.webView.evaluateJavaScript("document.querySelector('#next').textContent = '内容已变化'")
        let stale = try await broker.execute(request(.openAIPageLink, ["reference": first]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(stale.contains("变化"))
        let current = try await observe()
        let opened = try await broker.execute(request(.openAIPageLink, ["reference": current]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(opened.contains("页面已打开"), opened)
        XCTAssertEqual(workspace.selectedID, user.id)
        XCTAssertTrue(workspace.tabs.contains { $0.owner == .agent && $0.webView.url?.path == "/long" && $0.webView.url?.query == "page=2" })
        let revision = agent.navigationRevision
        workspace.load(base.appendingPathComponent("article"), in: agent)
        try await waitUntil { agent.navigationRevision > revision && agent.finishedRevision == agent.navigationRevision }
        let navigated = try await broker.execute(request(.openAIPageLink, ["reference": current]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(navigated.contains("失效"))
        let afterNavigation = try await observe()
        workspace.selectTab(agent)
        workspace.takeControl(agent)
        let takenOver = try await broker.execute(request(.openAIPageLink, ["reference": afterNavigation]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(takenOver.contains("失效"))
    }

    func testResearchExpansionBackgroundWriteRequiresControl() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("disclosure-background-write").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        let agent = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let observation = try await broker.execute(request(.observeAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        let marker = try XCTUnwrap(observation.range(of: "可展开区域标识："))
        let suffix = observation[marker.upperBound...]
        let match = try XCTUnwrap(suffix.range(of: "[0-9A-F-]{36}", options: .regularExpression))
        _ = try await broker.execute(request(.expandAISection, ["reference": String(suffix[match])]), runID: "run", itemID: "item", taskTitle: "测试")
        // WebKit dispatches the toggle event asynchronously after expanding the details element.
        var submissions = 0
        for _ in 0..<40 {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
            submissions = stats["submissions", default: 0]
            if submissions > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTExpectFailure("WebKit 后台请求尚未纳入逐次确认控制；此测试应在实现可靠控制后转为普通断言。") {
            XCTAssertEqual(submissions, 0)
        }
    }

    func testResearchExpandsOnlyObservedSectionForItsOwnRun() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let user = workspace.newTab(url: base.appendingPathComponent("login"))
        try await waitUntil { user.finishedRevision > 0 }
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("article").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        let agent = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        func observeSection() async throws -> String {
            let observation = try await broker.execute(request(.observeAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
            let marker = try XCTUnwrap(observation.range(of: "可展开区域标识："))
            let suffix = observation[marker.upperBound...]
            let match = try XCTUnwrap(suffix.range(of: "[0-9A-F-]{36}", options: .regularExpression))
            return String(suffix[match])
        }
        let original = try await observeSection()
        _ = try await agent.webView.evaluateJavaScript("document.querySelector('summary').textContent = '内容已变化'")
        let changed = try await broker.execute(request(.expandAISection, ["reference": original]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(changed.contains("变化"), changed)
        let reference = try await observeSection()
        let denied = try await broker.execute(request(.expandAISection, ["reference": reference]), runID: "other", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(denied.contains("失效"), denied)
        let opened = try await broker.execute(request(.expandAISection, ["reference": reference]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(opened.contains("已展开"), opened)
        XCTAssertEqual(workspace.selectedID, user.id)
        let text = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(text.contains("展开后的正文"), text)
        let stale = try await broker.execute(request(.expandAISection, ["reference": reference]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(stale.contains("失效"), stale)
    }

    func testUserPagePermissionAndNavigationInvalidation() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent())
        let broker = BrowserToolBroker(workspace: workspace)
        let tab = workspace.newTab(url: base.appendingPathComponent("article"))
        try await waitUntil { tab.finishedRevision > 0 }

        let pending = Task { try await broker.execute(self.request(.requestUserPage), runID: "run", itemID: "item", taskTitle: "测试") }
        try await waitUntil { broker.permission != nil }
        broker.resolvePermission(.deny)
        let denied = try await pending.value
        XCTAssertTrue(denied.contains("未授权"), denied)
        XCTAssertTrue(broker.evidence.records.isEmpty)

        let allowedTask = Task { try await broker.execute(self.request(.requestUserPage), runID: "run", itemID: "item", taskTitle: "测试") }
        try await waitUntil { broker.permission != nil }
        broker.resolvePermission(.readForRun)
        let allowed = try await allowedTask.value
        XCTAssertTrue(allowed.contains("游客内容"), allowed)

        let repeated = try await broker.execute(request(.requestUserPage), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(repeated.contains("游客内容"), repeated)
        XCTAssertNil(broker.permission)
        let other = workspace.newTab()
        workspace.selectTab(tab)
        workspace.close(other)
        let afterSwitch = Task { try await broker.execute(self.request(.requestUserPage), runID: "run", itemID: "item", taskTitle: "测试") }
        try await waitUntil { broker.permission != nil }
        broker.resolvePermission(.readForRun)
        let switched = try await afterSwitch.value
        XCTAssertTrue(switched.contains("游客内容"), switched)
        broker.finishRun("run")
        let changedTask = Task { try await broker.execute(self.request(.requestUserPage), runID: "next-run", itemID: "item", taskTitle: "测试") }
        try await waitUntil { broker.permission != nil }
        let revision = tab.navigationRevision
        workspace.load(base.appendingPathComponent("login"), in: tab)
        try await waitUntil { tab.navigationRevision > revision }
        broker.resolvePermission(.readForRun)
        let changed = try await changedTask.value
        XCTAssertTrue(changed.contains("发生变化"), changed)

        try await waitUntil { tab.finishedRevision == tab.navigationRevision && !tab.webView.isLoading }
        let cancelledTask = Task { try await broker.execute(self.request(.requestUserPage), runID: "cancelled", itemID: "item", taskTitle: "测试") }
        try await waitUntil { broker.permission != nil }
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("取消后不应返回页面内容")
        } catch is CancellationError {
            XCTAssertNil(broker.permission)
        }
    }

    func testAgentFormSubmissionIsStoppedBeforeSending() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        workspace.newTab()
        let agent = workspace.newTab(owner: .agent, taskID: "run", url: base.appendingPathComponent("article"), select: false)
        try await waitUntil { agent.finishedRevision > 0 }
        _ = try await agent.webView.evaluateJavaScript("document.querySelector('form').requestSubmit()")
        try await waitUntil { agent.error != nil }
        XCTAssertEqual(agent.error, "此页面操作需要用户接管。")
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 0)
        let blocked = try await broker.execute(request(.readAIPage, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(blocked.contains("wait_for_login"), blocked)
        XCTAssertTrue(blocked.contains(agent.id.uuidString), blocked)
        let waiting = Task { try await broker.execute(self.request(.waitForLogin, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试") }
        try await waitUntil { broker.loginRequest != nil }
        XCTAssertEqual(broker.loginRequest?.requiresAction, true)
        XCTAssertEqual(broker.loginRequest?.actionMethod, "POST")
        XCTAssertEqual(broker.loginRequest?.actionAddress, base.appendingPathComponent("write").absoluteString)
        broker.showLoginPage()
        _ = try await agent.webView.evaluateJavaScript("document.querySelector('form').requestSubmit()")
        try await waitUntil { agent.webView.url?.path == "/write" && !agent.webView.isLoading }
        broker.resumeAfterLogin()
        let resumed = try await waiting.value
        XCTAssertTrue(resumed.contains("游客内容"), resumed)
        let (updatedData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let updatedStats = try XCTUnwrap(JSONSerialization.jsonObject(with: updatedData) as? [String: Int])
        XCTAssertEqual(updatedStats["submissions"], 1)
    }

    func testUserCanResumeBlockedPageWithoutNavigation() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let user = workspace.newTab()
        let agent = workspace.newTab(owner: .agent, taskID: "run", url: base.appendingPathComponent("article"), select: false)
        try await waitUntil { agent.finishedRevision > 0 }
        _ = try await agent.webView.evaluateJavaScript("document.querySelector('form').requestSubmit()")
        try await waitUntil { agent.needsUserAction }
        let waiting = Task { try await broker.execute(self.request(.waitForLogin, ["tabID": agent.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试") }
        try await waitUntil { broker.loginRequest != nil }
        broker.showLoginPage()
        broker.resumeAfterLogin()
        let result = try await waiting.value
        XCTAssertTrue(result.contains("游客内容"), result)
        XCTAssertFalse(agent.needsUserAction)
        XCTAssertNil(agent.blockedAction)
        XCTAssertNil(agent.error)
        XCTAssertEqual(workspace.selectedID, user.id)
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(stats["submissions"], 0)
    }

    func testLongArticleIsReadInBoundedSegments() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("long").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        let tab = try XCTUnwrap(workspace.tabs.first)
        let first = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(first.contains("下一段位置：8000"), first.prefix(300).description)
        XCTAssertFalse(first.contains("终点"))
        let second = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString, "offset": "8000"]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(second.contains("终点"))
        XCTAssertTrue(second.contains("已读取至页面末尾"))
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('article').textContent += '变化'")
        let changed = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString, "offset": "8000"]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(changed.contains("页面内容已变化"))
        _ = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString]), runID: "run", itemID: "item", taskTitle: "测试")
        let revision = tab.navigationRevision
        workspace.load(base.appendingPathComponent("long"), in: tab)
        try await waitUntil { tab.navigationRevision > revision && tab.finishedRevision == tab.navigationRevision }
        let navigated = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString, "offset": "8000"]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(navigated.contains("读取会话已失效"))
        let invalid = try await broker.execute(request(.readAIPage, ["tabID": tab.id.uuidString, "offset": "-1"]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(invalid.contains("位置无效"))
    }

    func testLoginWaitRestoresResearchAndCancellation() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), researchURLAllowed: { _ in true })
        let broker = BrowserToolBroker(workspace: workspace)
        let user = workspace.newTab(url: base.appendingPathComponent("article"))
        try await waitUntil { user.finishedRevision > 0 }
        _ = try await broker.execute(request(.openAIPage, ["url": base.appendingPathComponent("challenge").absoluteString]), runID: "run", itemID: "item", taskTitle: "测试")
        let agent = try XCTUnwrap(workspace.tabs.first { $0.owner == .agent })
        let tabID = agent.id.uuidString
        let reading = try await broker.execute(request(.readAIPage, ["tabID": tabID]), runID: "run", itemID: "item", taskTitle: "测试")
        XCTAssertTrue(reading.contains("wait_for_login"), reading)
        let foreign = try await broker.execute(request(.waitForLogin, ["tabID": tabID]), runID: "other", itemID: "other-item", taskTitle: "测试")
        XCTAssertTrue(foreign.contains("不存在"), foreign)

        let waiting = Task { try await broker.execute(self.request(.waitForLogin, ["tabID": tabID]), runID: "run", itemID: "item", taskTitle: "测试") }
        try await waitUntil { broker.loginRequest != nil }
        broker.resumeAfterLogin()
        XCTAssertNotNil(broker.loginRequest)
        XCTAssertNotNil(broker.loginMessage)
        broker.showLoginPage()
        XCTAssertEqual(workspace.selectedID, agent.id)
        XCTAssertTrue(agent.userTookControl)
        var revision = agent.navigationRevision
        var otherOrigin = try XCTUnwrap(URLComponents(url: base, resolvingAgainstBaseURL: false))
        otherOrigin.host = "localhost"
        workspace.load(try XCTUnwrap(otherOrigin.url).appendingPathComponent("article"), in: agent)
        try await waitUntil { agent.navigationRevision > revision && agent.finishedRevision == agent.navigationRevision }
        workspace.takeControl(agent)
        broker.resumeAfterLogin()
        XCTAssertNotNil(broker.loginRequest)
        XCTAssertEqual(broker.loginMessage, "请返回原站点页面后继续。")
        revision = agent.navigationRevision
        workspace.load(base.appendingPathComponent("login"), in: agent)
        try await waitUntil { agent.navigationRevision > revision && agent.finishedRevision == agent.navigationRevision }
        revision = agent.navigationRevision
        workspace.load(base.appendingPathComponent("article"), in: agent)
        try await waitUntil { agent.navigationRevision > revision && agent.finishedRevision == agent.navigationRevision }
        workspace.takeControl(agent)
        broker.resumeAfterLogin()
        let resumed = try await waiting.value
        XCTAssertTrue(resumed.contains("登录后可见的文章正文"), resumed)
        XCTAssertEqual(workspace.selectedID, user.id)
        XCTAssertFalse(agent.userTookControl)

        let cancelled = Task { try await broker.execute(self.request(.waitForLogin, ["tabID": tabID]), runID: "run", itemID: "item", taskTitle: "测试") }
        try await waitUntil { broker.loginRequest != nil }
        broker.showLoginPage()
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("取消后不应读取页面") }
        catch is CancellationError { XCTAssertNil(broker.loginRequest) }
        XCTAssertTrue(agent.userTookControl)
    }

    func testNamedWebsiteStoreSharesLoginAcrossWorkspaceInstances() async throws {
        let (server, base) = try fixture()
        defer { server.terminate() }
        let identifier = UUID()
        var first: BrowserWorkspace? = BrowserWorkspace(dataStore: WKWebsiteDataStore(forIdentifier: identifier))
        var login: BrowserWorkspace.Tab? = first?.newTab(url: base.appendingPathComponent("login"))
        try await waitUntil { (login?.finishedRevision ?? 0) > 0 }
        var second: BrowserWorkspace? = BrowserWorkspace(dataStore: WKWebsiteDataStore(forIdentifier: identifier))
        var article: BrowserWorkspace.Tab? = second?.newTab(url: base.appendingPathComponent("article"))
        try await waitUntil { (article?.finishedRevision ?? 0) > 0 }
        let text = try await article?.webView.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertTrue(text?.contains("登录后可见的文章正文") == true)
        if let login { first?.close(login) }
        if let article { second?.close(article) }
        login = nil
        article = nil
        first = nil
        second = nil
        // A WebKit network process may keep the store open beyond the view lifetime;
        // clear only this isolated test store's data while it is still in use.
        let cleanupStore = WKWebsiteDataStore(forIdentifier: identifier)
        await cleanupStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func testWebsiteDataCanBeClearedForOneSite() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        func cookie(_ host: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [.domain: host, .path: "/", .name: "session", .value: "fixture", .secure: "TRUE"]))
        }
        await store.httpCookieStore.setCookie(try cookie("example.com"))
        await store.httpCookieStore.setCookie(try cookie("news.example.com"))
        await store.httpCookieStore.setCookie(try cookie("example.org"))
        let types: Set<String> = [WKWebsiteDataTypeCookies]
        let records = await store.dataRecords(ofTypes: types)
        let selected = try XCTUnwrap(records.first { $0.displayName == "example.com" })
        await BrowserWorkspace.clearWebsiteData(selected, in: store)
        let remaining = await store.httpCookieStore.allCookies()
        XCTAssertFalse(remaining.contains { $0.domain == "example.com" })
        XCTAssertFalse(remaining.contains { $0.domain == "news.example.com" })
        XCTAssertTrue(remaining.contains { $0.domain == "example.org" })
    }
}
