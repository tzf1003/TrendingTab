import XCTest
import GRDB
@testable import TrendingTabAggregation
@testable import TrendingTabCore
@testable import TrendingTabIntelligence
@testable import TrendingTabNotifications
@testable import TrendingTabPersistence
@testable import TrendingTabSources
@testable import TrendingTabWidgetBridge

final class CoreTests: XCTestCase {
    func testPublicArticleLiveReadWhenConfigured() async throws {
        guard let raw = ProcessInfo.processInfo.environment["TRENDINGTAB_PUBLIC_ARTICLE_TEST_URL"], let url = URL(string: raw) else {
            throw XCTSkip("Set TRENDINGTAB_PUBLIC_ARTICLE_TEST_URL for an actual public HTTPS read.")
        }
        let article = try await PublicArticleService().read(url)
        XCTAssertEqual(article.url, url)
        XCTAssertFalse(article.text.isEmpty)
    }
    func testPublicArticleAddressPolicyRejectsSpecialUseAddresses() async throws {
        for address in ["0.1.2.3", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254",
                        "172.31.1.1", "192.168.1.1", "192.0.2.1", "198.18.0.1", "198.51.100.2",
                        "203.0.113.2", "224.0.0.1", "255.255.255.255", "not-an-ip"] {
            XCTAssertFalse(PublicArticleService.isPublicIPv4(address), address)
        }
        for address in ["1.1.1.1", "8.8.8.8", "172.32.0.1", "100.128.0.1"] {
            XCTAssertTrue(PublicArticleService.isPublicIPv4(address), address)
        }
        for raw in ["http://127.0.0.1/", "http://[::1]/", "file:///etc/passwd", "http://user@example.com/"] {
            do { _ = try await PublicArticleService().read(URL(string: raw)!); XCTFail("Expected rejection for \(raw)") }
            catch PublicArticleError.invalidURL { }
        }
        // A hostname resolving to loopback must be rejected after DNS resolution too.
        do { _ = try await PublicArticleService().read(URL(string: "http://localhost./")!); XCTFail("Expected DNS rejection") }
        catch PublicArticleError.invalidURL { }
    }

    func testPublicArticleExtractionSeparatesContentFromNavigation() throws {
        let url = URL(string: "https://example.com/story?id=1")!
        let article = try PublicArticleService.extract("""
            <html><head><title>报道标题</title><script>误导内容</script></head>
            <body><nav>导航</nav><article><p>正文一</p><p>正文二</p></article><footer>页脚</footer></body></html>
            """, mime: "text/html", url: url)
        XCTAssertEqual(article.title, "报道标题")
        XCTAssertEqual(article.text, "正文一 正文二")
        XCTAssertEqual(article.url, url)
        XCTAssertFalse(article.truncated)
        XCTAssertThrowsError(try PublicArticleService.extract("<body><script>x</script></body>", mime: "text/html", url: url))
        XCTAssertEqual(try PublicArticleService.extract("测试文字", mime: "text/plain", url: url).text, "测试文字")
        let long = try PublicArticleService.extract(String(repeating: "文", count: 200_001), mime: "text/plain", url: url)
        XCTAssertEqual(long.text.count, 200_000)
        XCTAssertTrue(long.truncated)
    }
    func testCustomModelHeadersAreValidated() throws {
        XCTAssertEqual(try AIRequestHeaders.parse(""), [:])
        XCTAssertEqual(try AIRequestHeaders.parse("{\"X-Project\":\"!literal-$HOME\"}"), ["X-Project": "!literal-$HOME"])
        XCTAssertThrowsError(try AIRequestHeaders.parse("{\"Bad Header\":\"value\"}"))
        XCTAssertThrowsError(try AIRequestHeaders.parse("{\"X-Test\":\"one\\r\\ntwo\"}"))
        XCTAssertFalse(AIRequestHeaders.valid(["Host": "example.com"]))
        XCTAssertFalse(AIRequestHeaders.valid(["X-Test": "a", "x-test": "b"]))
    }
    func testExistingModelConnectionGainsContextDefault() throws {
        let json = """
        {"id":"BCA19081-A6E1-49A9-BDBE-4D6A177408C6","name":"测试","kind":"openai-chat","baseURL":"https://example.com/v1","model":"model","credentialAccount":"fixture","timeout":30,"maxOutputTokens":1000}
        """
        let connection = try JSONDecoder().decode(AIConnection.self, from: Data(json.utf8))
        XCTAssertEqual(connection.contextWindow, 128_000)
        XCTAssertEqual(connection.maxOutputTokens, 1000)
        XCTAssertEqual(try JSONDecoder().decode(AIConnection.self, from: JSONEncoder().encode(connection)), connection)
    }
    func testResearchCitationsResolveOnlyEvidenceForTheCurrentConversation() {
        var ledger = ResearchEvidenceLedger()
        let url = URL(string: "https://example.com/story?id=7")!
        let first = ledger.register(itemID: "a", runID: "run-a", title: "报道", url: url,
                                    level: .pageText, content: "事实")
        let second = ledger.register(itemID: "b", runID: "run-b", title: "另一条", url: url,
                                     level: .searchSnippet, content: "摘要")
        let citations = ledger.citations(in: "依据 [\(first.id)]、【\(first.id)】、[\(second.id)] 和 [E99]。", itemID: "a")
        XCTAssertEqual(citations.valid.map(\.id), [first.id])
        XCTAssertEqual(citations.unknown, [second.id, "E99"])
        XCTAssertNotEqual(first.contentFingerprint, second.contentFingerprint)
        XCTAssertTrue(ledger.citations(in: "[E1】不是有效引用", itemID: "a").valid.isEmpty)
        ledger.remove(itemID: "a")
        XCTAssertEqual(ledger.citations(in: "[\(first.id)] [\(second.id)]", itemID: "b").valid.map(\.id), [second.id])
        XCTAssertEqual(ledger.citations(in: "[\(first.id)]", itemID: "a").unknown, [first.id])
    }

    func testFollowUpResearchContextIsScopedBoundedAndClearedWithSession() {
        var ledger = ResearchEvidenceLedger()
        let url = URL(string: "https://example.com/article?session=private#section")!
        let unrelated = ledger.register(itemID: "other", runID: "other-run", title: "无关标题", url: url,
                                        level: .pageText, content: "无关材料")
        for index in 0..<30 {
            _ = ledger.register(itemID: "current", runID: "run-\(index)", title: "材料\(index)", url: url,
                                level: .pageText, content: "事实\(index)" + String(repeating: "文", count: 2_500))
        }
        let context = ledger.followUpContext(itemID: "current")
        XCTAssertTrue(context.contains("事实29"))
        XCTAssertTrue(context.contains("https://example.com/article"))
        XCTAssertFalse(context.contains("session=private"))
        XCTAssertFalse(context.contains("#section"))
        XCTAssertFalse(context.contains("无关材料"))
        XCTAssertFalse(context.contains("[\(unrelated.id)]"))
        XCTAssertLessThanOrEqual(context.count, 12_000)
        ledger.remove(itemID: "current")
        XCTAssertTrue(ledger.followUpContext(itemID: "current").isEmpty)
        XCTAssertTrue(ledger.followUpContext(itemID: "other").contains("无关材料"))
    }

    func testStableIdentityAndCanonicalURL() {
        let first = URL(string: "https://Example.com/a?utm_source=x&id=1#part")!
        let second = URL(string: "https://Example.com/a?id=1")!
        XCTAssertEqual(NormalizedItem.canonical(first), NormalizedItem.canonical(second))
        XCTAssertEqual(NormalizedItem.stableID(sourceID: "zhihu", nativeID: "42", url: first), "zhihu:42")
    }

    func testModelVisibleAddressRemovesCredentialsQueryAndFragment() throws {
        let url = try XCTUnwrap(URL(string: "https://reader:example-password@example.com/article?id=42&token=private#section"))
        XCTAssertEqual(AIVisibleAddress.string(for: url), "https://example.com/article")
        XCTAssertEqual(AIVisibleAddress.string(for: try XCTUnwrap(URL(string: "file:///tmp/article"))), "")
    }

    func testRankFusionKeepsPlatformOrderAndMovement() {
        XCTAssertGreaterThan(RankFusion.score(rank: 1, age: 60), RankFusion.score(rank: 20, age: 60))
        XCTAssertEqual(RankFusion.movement(current: 2, previous: nil), "新")
        XCTAssertEqual(RankFusion.movement(current: 2, previous: 8), "↑6")
    }

    func testMajorEventRequiresEvidence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = StoredItem(item: NormalizedItem(sourceID: "zhihu", boardID: "zhihu.hot", nativeID: "1", title: "测试", url: URL(string: "https://example.com/1")!, rank: 1), firstSeenAt: now, lastSeenAt: now, previousRank: nil, contentHash: "a", historical: false)
        let event = EventCluster(title: "测试", itemIDs: [item.id], independentSourceCount: 1, importance: 90, confidence: 0.9, status: "major", materialFingerprint: "a", updatedAt: now, createdAt: now)
        let tab = TabDefinition(title: "重大事件", kind: .majorEvents, sort: .importance)
        let result = TabAggregator.rows(tab: tab, items: [item], events: [event], sources: [], now: now)
        XCTAssertTrue(result.rows.isEmpty)
    }

    func testMajorTabAndAlertUseOnlyAssessedSources() throws {
        let now = Date()
        let item = StoredItem(item: NormalizedItem(sourceID: "zhihu", boardID: "zhihu.hot", nativeID: "1", title: "测试", url: URL(string: "https://example.com/1")!, rank: 1), firstSeenAt: now, lastSeenAt: now, previousRank: nil, contentHash: "a", historical: false)
        var event = EventCluster(title: "测试", itemIDs: [item.id], independentSourceCount: 2, importance: 90, confidence: 0.9,
                                 assessmentSourceIDs: ["zhihu"], status: "major", materialFingerprint: "a", updatedAt: now, createdAt: now)
        var policy = NotificationPolicy.standard
        policy.enabled = true
        let normal = TabDefinition(title: "重大事件", kind: .majorEvents, sort: .importance, monitoringEnabled: true, notification: policy)
        let authoritative = TabDefinition(title: "一手事件", kind: .majorEvents, filter: TabFilter(authoritativeSourceIDs: ["zhihu"]), sort: .importance, monitoringEnabled: true, notification: policy)
        XCTAssertTrue(TabAggregator.rows(tab: normal, items: [item], events: [event], sources: [], now: now).rows.isEmpty)
        XCTAssertTrue(AlertPolicy.candidates(events: [event], tabs: [normal], now: now).isEmpty)
        XCTAssertEqual(TabAggregator.rows(tab: authoritative, items: [item], events: [event], sources: [], now: now).rows.count, 1)
        XCTAssertEqual(AlertPolicy.candidates(events: [event], tabs: [authoritative], now: now).count, 1)
        event.assessmentSourceIDs = ["zhihu", "weibo"]
        XCTAssertEqual(TabAggregator.rows(tab: normal, items: [item], events: [event], sources: [], now: now).rows.count, 1)
        XCTAssertEqual(AlertPolicy.candidates(events: [event], tabs: [normal], now: now).count, 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: TrendingJSON.data(event)) as? [String: Any])
        json.removeValue(forKey: "assessmentSourceIDs")
        let legacy = try TrendingJSON.value(EventCluster.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.assessmentSourceIDs)
    }

    func testEventFingerprintChangesWhenEvidenceContentChanges() throws {
        let now = Date()
        var item = StoredItem(item: NormalizedItem(sourceID: "zhihu", boardID: "zhihu.hot", nativeID: "1", title: "测试事件", url: URL(string: "https://example.com/1")!, rank: 1), firstSeenAt: now, lastSeenAt: now, previousRank: nil, contentHash: "original", historical: false)
        let original = try XCTUnwrap(EventGrouper.group([item], now: now).first)
        item.contentHash = "updated"
        let updated = try XCTUnwrap(EventGrouper.group([item], now: now).first)
        XCTAssertEqual(original.itemIDs, updated.itemIDs)
        XCTAssertNotEqual(original.materialFingerprint, updated.materialFingerprint)
    }

    func testDelayedAutomaticResultRequiresCurrentMaterial() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-1800)
        let item = StoredItem(item: NormalizedItem(sourceID: "zhihu", boardID: "zhihu.hot", nativeID: "1", title: "事件",
                                                  url: URL(string: "https://example.com/1")!),
                              firstSeenAt: now, lastSeenAt: now, previousRank: nil, contentHash: "original", historical: false)
        XCTAssertTrue(AutomaticTaskMaterial.isCurrent([item], in: [item], cutoff: cutoff))
        XCTAssertFalse(AutomaticTaskMaterial.isCurrent([item], in: [], cutoff: cutoff))
        var changed = item
        changed.contentHash = "changed"
        XCTAssertFalse(AutomaticTaskMaterial.isCurrent([item], in: [changed], cutoff: cutoff))
        changed = item
        changed.lastSeenAt = cutoff.addingTimeInterval(-1)
        XCTAssertFalse(AutomaticTaskMaterial.isCurrent([item], in: [changed], cutoff: cutoff))
        changed = item
        changed.item.url = URL(string: "https://example.com/other")!
        XCTAssertFalse(AutomaticTaskMaterial.isCurrent([item], in: [changed], cutoff: cutoff))
        XCTAssertFalse(AutomaticTaskMaterial.isCurrent([], in: [item], cutoff: cutoff))
        let event = EventCluster(title: "事件", itemIDs: [item.id, "other"], independentSourceCount: 2,
                                 materialFingerprint: "evidence", updatedAt: now, createdAt: now)
        var second = item
        second.item = NormalizedItem(sourceID: "weibo", boardID: "weibo.hot", nativeID: "2", title: "事件", url: URL(string: "https://example.com/2")!)
        let linked = EventCluster(id: event.id, title: event.title, itemIDs: [item.id, second.id], independentSourceCount: 2,
                                  materialFingerprint: event.materialFingerprint, updatedAt: now, createdAt: now)
        XCTAssertTrue(AutomaticTaskMaterial.eventIsCurrent(linked, in: [linked], items: [item, second], cutoff: cutoff))
        second.lastSeenAt = cutoff.addingTimeInterval(-1)
        XCTAssertFalse(AutomaticTaskMaterial.eventIsCurrent(linked, in: [linked], items: [item, second], cutoff: cutoff))
        XCTAssertFalse(AutomaticTaskMaterial.eventIsCurrent(linked, in: [], items: [item], cutoff: cutoff))
    }

    func testSemanticTopicShowsOnlyResolvedMatchesAndTracksCoverage() {
        let now = Date()
        func item(_ id: String, _ title: String, _ source: String) -> StoredItem {
            StoredItem(item: NormalizedItem(sourceID: source, boardID: "\(source).hot", nativeID: id, title: title,
                                            url: URL(string: "https://example.com/\(id)")!),
                       firstSeenAt: now, lastSeenAt: now, previousRank: nil, contentHash: id, historical: false)
        }
        let one = item("1", "AI 产品发布", "tech")
        let two = item("2", "AI 价格调整", "tech")
        let excluded = item("3", "AI 广告", "tech")
        let other = item("4", "AI 发布", "news")
        let sources = [SourceDescriptor(id: "tech", title: "科技", category: .blog, homepage: URL(string: "https://example.com")!, parserVersion: "1"),
                       SourceDescriptor(id: "news", title: "新闻", category: .news, homepage: URL(string: "https://example.com")!, parserVersion: "1")]
        let filter = TabFilter(includedWords: ["AI"], excludedWords: ["广告"], categories: [.blog], semanticPrompt: "产品发布")
        let tab = TabDefinition(title: "AI", kind: .topic, filter: filter, sort: .reciprocalRankFusion)
        let items = [one, two, excluded, other]
        let pending = TabAggregator.rows(tab: tab, items: items, events: [], sources: sources, now: now, semanticDecisions: [one.id: true])
        XCTAssertEqual(pending.rows.map(\.stored.id), [one.id])
        XCTAssertEqual(pending.coverage, "部分内容待分析")
        let finished = TabAggregator.rows(tab: tab, items: items, events: [], sources: sources, now: now, semanticDecisions: [one.id: false, two.id: false])
        XCTAssertTrue(finished.rows.isEmpty)
        XCTAssertEqual(finished.coverage, "没有匹配内容")
    }

    func testSemanticBatchValidatesModelReferences() throws {
        let now = Date()
        let item = StoredItem(item: NormalizedItem(sourceID: "test", boardID: "test.hot", nativeID: "1", title: "AI 发布",
                                               url: URL(string: "https://example.com/")!), firstSeenAt: now,
                              lastSeenAt: now, previousRank: nil, contentHash: "1", historical: false)
        let batch = try SemanticTopicBatch(description: "AI 产品", items: [item])
        XCTAssertTrue(batch.prompt.contains(item.id))
        let data = try JSONSerialization.data(withJSONObject: ["matchedIDs": [item.id]])
        XCTAssertEqual(try batch.parse(String(decoding: data, as: UTF8.self)), [item.id])
        XCTAssertEqual(try batch.parse("{\"matchedIDs\":[]}"), [])
        XCTAssertThrowsError(try batch.parse("{\"matchedIDs\":[\"unknown\"]}"))
        XCTAssertThrowsError(try batch.parse("{\"matchedIDs\":\"invalid\"}"))
        let duplicate = try JSONSerialization.data(withJSONObject: ["matchedIDs": [item.id, item.id]])
        XCTAssertThrowsError(try batch.parse(String(decoding: duplicate, as: UTF8.self)))
    }

    func testQuietHoursAndNotificationDeduplication() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let night = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 23, minute: 30))!
        XCTAssertFalse(AlertPolicy.allows(.standard, now: night, hourlyCount: 0, dailyCount: 0))
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))!
        var enabled = NotificationPolicy.standard
        enabled.enabled = true
        XCTAssertTrue(AlertPolicy.allows(enabled, now: day, hourlyCount: 2, dailyCount: 9))
        XCTAssertFalse(AlertPolicy.allows(enabled, now: day, hourlyCount: 3, dailyCount: 0))
    }

    func testAssessmentRejectsUnknownEvidence() throws {
        let json = """
        {"importance":80,"confidence":0.9,"category":"科技","summary":"摘要","reason":"原因","evidenceIDs":["known","unknown"],"matchedTopicIDs":[]}
        """
        XCTAssertThrowsError(try AssessmentParser.parse(json, allowedEvidence: ["known"], allowedTopics: []))
    }

    func testMajorAssessmentRequiresCitedIndependentOrAuthoritativeSources() throws {
        func assessment(_ ids: String, importance: String = "80", confidence: String = "0.9") throws -> ModelAssessment {
            let json = """
            {"importance":\(importance),"confidence":\(confidence),"category":"科技","summary":"摘要","reason":"原因","evidenceIDs":\(ids),"matchedTopicIDs":[]}
            """
            return try AssessmentParser.parse(json, allowedEvidence: ["a", "b", "c"], allowedTopics: [])
        }
        let sources = ["a": "one", "b": "one", "c": "two"]
        XCTAssertFalse(AssessmentParser.qualifiesAsMajor(try assessment("[\"a\",\"b\"]"), evidenceSources: sources, authoritativeSources: []))
        XCTAssertTrue(AssessmentParser.qualifiesAsMajor(try assessment("[\"a\",\"c\"]"), evidenceSources: sources, authoritativeSources: []))
        XCTAssertTrue(AssessmentParser.qualifiesAsMajor(try assessment("[\"a\"]"), evidenceSources: sources, authoritativeSources: ["one"]))
        XCTAssertFalse(AssessmentParser.qualifiesAsMajor(try assessment("[\"a\",\"c\"]", confidence: "0.7"), evidenceSources: sources, authoritativeSources: []))
        XCTAssertThrowsError(try assessment("[]"))
        XCTAssertThrowsError(try assessment("[\"a\"]", importance: "1e30"))
        XCTAssertThrowsError(try assessment("[\"a\"]", confidence: "2"))
    }

    func testAutomaticSummaryRequiresKnownEvidence() throws {
        XCTAssertEqual(try EventSummaryParser.parse(#"{"summary":" 已知情况 ","evidenceIDs":["known"]}"#, allowedEvidence: ["known"]), "已知情况")
        XCTAssertThrowsError(try EventSummaryParser.parse(#"{"summary":"摘要","evidenceIDs":["unknown"]}"#, allowedEvidence: ["known"]))
        XCTAssertThrowsError(try EventSummaryParser.parse(#"{"summary":"摘要","evidenceIDs":[]}"#, allowedEvidence: ["known"]))
        XCTAssertThrowsError(try EventSummaryParser.parse(#"{"summary":" ","evidenceIDs":["known"]}"#, allowedEvidence: ["known"]))
    }

    func testRSSAndBaiduFixtures() throws {
        let rss = """
        <rss><channel><item><title>蓝点测试</title><link>https://www.landiannews.com/a</link><pubDate>Wed, 04 Nov 2026 01:00:00 +0800</pubDate><description>摘要</description></item></channel></rss>
        """
        let board = BoardDescriptor(id: "landian.latest", sourceID: "landian", title: "最新")
        let parsed = try RSSParser.parse(Data(rss.utf8), encoding: "utf-8", board: board)
        XCTAssertEqual(parsed.first?.title, "蓝点测试")
        XCTAssertEqual(parsed.first?.metricLabel, "最新")

        let html = """
        <html><!--s-data:{"data":{"cards":[{"content":[{"word":"百度测试","desc":"描述","query":"百度测试","hotScore":"100"}]}]}}--></html>
        """
        let baidu = try BaiduSourceProvider.parse(Data(html.utf8), board: BoardDescriptor(id: "baidu.realtime", sourceID: "baidu", title: "热搜"))
        XCTAssertEqual(baidu.first?.title, "百度测试")
        XCTAssertEqual(baidu.first?.rank, 1)
    }

    func testDatabaseMigrationAndAIRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trendingtab-test-\(UUID().uuidString).sqlite")
        let database = try AppDatabase(path: url.path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = NormalizedItem(sourceID: "zhihu", boardID: "zhihu.hot", nativeID: "7", title: "条目", url: URL(string: "https://www.zhihu.com/question/7")!, rank: 1)
        try database.save(result: FetchResult(sourceID: "zhihu", boardID: "zhihu.hot", fetchedAt: now, parserVersion: "test", items: [item]))
        XCTAssertEqual(try database.recentItems(since: now.addingTimeInterval(-10)).count, 1)
        XCTAssertTrue(try database.reserveAIRun(id: UUID(), tokens: 100, now: now))
        XCTAssertEqual(try database.recoverUnknownAIRuns(), 1)
        let snapshot = WidgetSnapshot(generation: 3, generatedAt: now, profiles: [], tabs: [], statuses: [], unreadCount: 0)
        let sharedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("trendingtab-shared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sharedDirectory) }
        try SnapshotStore.write(snapshot, directory: sharedDirectory)
        XCTAssertEqual(SnapshotStore.read(directory: sharedDirectory)?.generation, 3)
        try? FileManager.default.removeItem(at: url)
    }

    func testAIReservationsAreReconciledAndUnknownRunsStayAccounted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trendingtab-budget-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try AppDatabase(path: url.path)
        var settings = AppSettings.standard
        settings.dailyTokenLimit = 1_000
        try database.saveDocument(settings, key: "settings")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = UUID()
        XCTAssertTrue(try database.reserveAIRun(id: first, tokens: 800, now: now))
        XCTAssertFalse(try database.reserveAIRun(id: UUID(), tokens: 201, now: now))
        try database.finishAIRun(id: first, state: "completed", actualTokens: 400)
        XCTAssertTrue(try database.reserveAIRun(id: UUID(), tokens: 600, now: now))
        XCTAssertEqual(try database.recoverUnknownAIRuns(), 1)
        XCTAssertFalse(try database.reserveAIRun(id: UUID(), tokens: 1, now: now))
    }

    func testUnknownAITaskDoesNotAutomaticallyRepeatAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trendingtab-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("app.sqlite").path
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let database = try AppDatabase(path: path)
            XCTAssertEqual(try database.reserveAIRun(id: UUID(), tokens: 400, now: now, taskKey: "same-task"), .reserved)
            XCTAssertEqual(try database.reserveAIRun(id: UUID(), tokens: 400, now: now, taskKey: "same-task"), .duplicateUnknown)
        }
        let reopened = try AppDatabase(path: path)
        XCTAssertEqual(try reopened.recoverUnknownAIRuns(), 1)
        XCTAssertEqual(try reopened.unknownAIRunCount(), 1)
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: now))
        XCTAssertEqual(try reopened.reserveAIRun(id: UUID(), tokens: 400, now: tomorrow, taskKey: "same-task"), .duplicateUnknown)
        let changed = UUID()
        XCTAssertEqual(try reopened.reserveAIRun(id: changed, tokens: 400, now: tomorrow, taskKey: "changed-material"), .reserved)
        try reopened.finishAIRun(id: changed, state: "completed", actualTokens: 100)
        XCTAssertEqual(try reopened.reserveAIRun(id: UUID(), tokens: 400, now: tomorrow, taskKey: "changed-material"), .reserved)
        XCTAssertEqual(try reopened.acknowledgeUnknownAIRuns(), 1)
        XCTAssertEqual(try reopened.unknownAIRunCount(), 0)
        XCTAssertEqual(try reopened.reserveAIRun(id: UUID(), tokens: 400, now: tomorrow, taskKey: "same-task"), .reserved)
        let original = try reopened.writer.read { db in try Row.fetchOne(db, sql: "SELECT state, reserved_tokens FROM ai_runs WHERE task_key = ? ORDER BY created_at LIMIT 1", arguments: ["same-task"]) }
        XCTAssertEqual(original?["state"] as String?, "unknown-reviewed")
        XCTAssertEqual(original?["reserved_tokens"] as Int?, 400)
    }

    func testAutomaticTaskIdentityChangesWithMaterialAndConfiguration() throws {
        var connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "one", credentialAccount: "test")
        func key(_ connection: AIConnection, prompt: String = "标题", rule: String = "规则", version: Int = 1,
                 headers: [String: String] = ["A": "1", "B": "2"]) throws -> String {
            try AutomaticTaskIdentity.make(kind: "classification", connection: connection, headers: headers,
                                           system: "系统提示", prompt: prompt, rule: rule, promptVersion: version)
        }
        let original = try key(connection)
        XCTAssertEqual(original, try key(connection, headers: ["B": "2", "A": "1"]))
        XCTAssertNotEqual(original, try key(connection, prompt: "更新标题"))
        XCTAssertNotEqual(original, try key(connection, rule: "更新规则"))
        XCTAssertNotEqual(original, try key(connection, version: 2))
        XCTAssertNotEqual(original, try key(connection, headers: ["A": "changed"]))
        connection.model = "two"
        XCTAssertNotEqual(original, try key(connection))
    }

    func testRetryOfUnknownTaskStillConsumesDailyBudget() throws {
        let database = try AppDatabase(path: ":memory:")
        var settings = AppSettings.standard
        settings.dailyRequestLimit = 2
        settings.dailyTokenLimit = 800
        try database.saveDocument(settings, key: "settings")
        let now = Date()
        XCTAssertEqual(try database.reserveAIRun(id: UUID(), tokens: 400, now: now, taskKey: "task"), .reserved)
        XCTAssertEqual(try database.recoverUnknownAIRuns(), 1)
        XCTAssertEqual(try database.acknowledgeUnknownAIRuns(), 1)
        XCTAssertEqual(try database.reserveAIRun(id: UUID(), tokens: 400, now: now, taskKey: "task"), .reserved)
        XCTAssertEqual(try database.reserveAIRun(id: UUID(), tokens: 1, now: now, taskKey: "another"), .budgetExhausted)
    }

    func testAIResultAndBudgetCommitTogether() throws {
        let database = try AppDatabase(path: ":memory:")
        let now = Date()
        let existing = EventCluster(title: "原事件", itemIDs: ["old"], independentSourceCount: 1, importance: 0, confidence: 0,
                                    status: "candidate", materialFingerprint: "old", updatedAt: now, createdAt: now)
        let updated = EventCluster(title: "新事件", itemIDs: ["new"], independentSourceCount: 1, importance: 0, confidence: 0,
                                   status: "candidate", materialFingerprint: "new", updatedAt: now, createdAt: now)
        try database.save(events: [existing])
        let payload = try TrendingJSON.data(["one": true])
        XCTAssertThrowsError(try database.completeAIRun(id: UUID(), state: "completed", actualTokens: 20,
            events: [updated], documentKey: "test-cache", documentPayload: payload))
        XCTAssertEqual(try database.events().first?.title, "原事件")
        XCTAssertNil(try database.document([String: Bool].self, key: "test-cache"))
        let id = UUID()
        XCTAssertEqual(try database.reserveAIRun(id: id, tokens: 100, now: now, taskKey: "test"), .reserved)
        try database.completeAIRun(id: id, state: "completed", actualTokens: 20, events: [updated], documentKey: "test-cache", documentPayload: payload)
        XCTAssertEqual(try database.events().first?.title, "新事件")
        XCTAssertEqual(try database.document([String: Bool].self, key: "test-cache"), ["one": true])
        let row = try database.writer.read { db in try Row.fetchOne(db, sql: "SELECT state, reserved_tokens FROM ai_runs WHERE id = ?", arguments: [id.uuidString]) }
        XCTAssertEqual(row?["state"] as String?, "completed")
        XCTAssertEqual(row?["reserved_tokens"] as Int?, 20)
    }

    func testExpiryPersistsItemsEventsAndCacheTogether() throws {
        let database = try AppDatabase(path: ":memory:")
        let now = Date()
        let cutoff = now.addingTimeInterval(-1800)
        let stale = NormalizedItem(sourceID: "old", boardID: "old.hot", nativeID: "1", title: "旧热点", url: URL(string: "https://example.com/old")!)
        let fresh = NormalizedItem(sourceID: "new", boardID: "new.hot", nativeID: "1", title: "新热点", url: URL(string: "https://example.com/new")!)
        try database.save(result: FetchResult(sourceID: "old", boardID: "old.hot", fetchedAt: cutoff.addingTimeInterval(-1), parserVersion: "test", items: [stale]))
        try database.save(result: FetchResult(sourceID: "new", boardID: "new.hot", fetchedAt: now, parserVersion: "test", items: [fresh]))
        let oldEvent = EventCluster(title: "旧事件", itemIDs: [stale.id], independentSourceCount: 1, materialFingerprint: "old", updatedAt: now, createdAt: now)
        let newEvent = EventCluster(title: "新事件", itemIDs: [fresh.id], independentSourceCount: 1, materialFingerprint: "new", updatedAt: now, createdAt: now)
        try database.save(events: [oldEvent])
        try database.saveDocument(["old": true], key: "cache")
        XCTAssertThrowsError(try database.prune(now: now, itemCutoff: cutoff, events: [newEvent], documents: ["cache": Data([0xff])]))
        XCTAssertEqual(try database.recentItems(since: .distantPast).count, 2)
        XCTAssertEqual(try database.events().first?.title, "旧事件")
        try database.prune(now: now, itemCutoff: cutoff, events: [newEvent], documents: ["cache": TrendingJSON.data(["new": true])])
        XCTAssertEqual(try database.recentItems(since: .distantPast).map(\.id), [fresh.id])
        XCTAssertEqual(try database.events().first?.title, "新事件")
        XCTAssertEqual(try database.document([String: Bool].self, key: "cache"), ["new": true])
    }

    func testAITaskIdentityMigrationPreservesExistingReservations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trendingtab-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("app.sqlite").path
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let legacy = try DatabaseQueue(path: path)
            try legacy.write { db in
                try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1')")
                try db.execute(sql: "CREATE TABLE ai_runs (id TEXT PRIMARY KEY, state TEXT NOT NULL, reserved_tokens INTEGER NOT NULL, created_at DATETIME NOT NULL, payload TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO ai_runs VALUES (?, 'reserved', 250, ?, '{}')", arguments: [UUID().uuidString, now])
            }
        }
        let database = try AppDatabase(path: path)
        XCTAssertEqual(try database.recoverUnknownAIRuns(), 1)
        let row = try database.writer.read { db in try Row.fetchOne(db, sql: "SELECT state, reserved_tokens, task_key FROM ai_runs") }
        XCTAssertEqual(row?["state"] as String?, "unknown-accounted")
        XCTAssertEqual(row?["reserved_tokens"] as Int?, 250)
        XCTAssertNil(row?["task_key"] as String?)
    }

    func testAIBudgetIsScopedToLocalCalendarDayAndRejectsInvalidReservation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trendingtab-day-budget-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try AppDatabase(path: url.path)
        var settings = AppSettings.standard
        settings.dailyRequestLimit = 1
        settings.dailyTokenLimit = 100
        try database.saveDocument(settings, key: "settings")
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: day))
        XCTAssertTrue(try database.reserveAIRun(id: UUID(), tokens: 100, now: tomorrow))
        XCTAssertFalse(try database.reserveAIRun(id: UUID(), tokens: -1, now: day))
        XCTAssertTrue(try database.reserveAIRun(id: UUID(), tokens: 100, now: day))
        XCTAssertFalse(try database.reserveAIRun(id: UUID(), tokens: 1, now: day))
    }

    func testDatabaseRemovesInactiveBoardsAndStaleItems() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trendingtab-retention-\(UUID().uuidString).sqlite")
        let database = try AppDatabase(path: url.path)
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldBoardItem = NormalizedItem(sourceID: "weibo", boardID: "weibo.hot", nativeID: "old", title: "微博", url: URL(string: "https://example.com/weibo")!, rank: 1)
        let currentBoardItem = NormalizedItem(sourceID: "zhihu", boardID: "zhihu.hot", nativeID: "new", title: "知乎", url: URL(string: "https://example.com/zhihu")!, rank: 1)
        try database.save(result: FetchResult(sourceID: "weibo", boardID: "weibo.hot", fetchedAt: now.addingTimeInterval(-3600), parserVersion: "test", items: [oldBoardItem]))
        try database.save(result: FetchResult(sourceID: "zhihu", boardID: "zhihu.hot", fetchedAt: now.addingTimeInterval(-60), parserVersion: "test", items: [currentBoardItem]))

        XCTAssertEqual(Set(try database.recentItems(since: .distantPast).map(\.item.boardID)), Set(["weibo.hot", "zhihu.hot"]))
        try database.clear(boardsNotIn: ["zhihu.hot"])
        XCTAssertEqual(try database.recentItems(since: .distantPast).map(\.item.boardID), ["zhihu.hot"])

        try database.prune(now: now, itemCutoff: now.addingTimeInterval(-1800))
        XCTAssertEqual(try database.recentItems(since: .distantPast).map(\.item.boardID), ["zhihu.hot"])
    }

    func testWidgetSelectionsAreIndependentAndOpenTargetKeepsItem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trendingtab-widget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let profileID = UUID()
        let zhihuID = UUID()
        let weiboID = UUID()
        let snapshot = WidgetSnapshot(
            generation: 1,
            generatedAt: .now,
            profiles: [WidgetProfile(id: profileID, name: "默认", orderedTabIDs: [zhihuID, weiboID], defaultTabID: zhihuID)],
            tabs: [
                SnapshotTab(id: zhihuID, title: "知乎", kind: .sourceBoard, rows: [], coverage: "", updatedAt: nil),
                SnapshotTab(id: weiboID, title: "微博", kind: .sourceBoard, rows: [], coverage: "", updatedAt: nil)
            ],
            statuses: [],
            unreadCount: 0
        )
        try SnapshotStore.write(snapshot, directory: directory)
        let small = WidgetSelectionScope(initialTabID: zhihuID, fixedBoard: false, slot: "one", size: .small)
        let medium = WidgetSelectionScope(initialTabID: zhihuID, fixedBoard: false, slot: "one", size: .medium)
        let anotherMedium = WidgetSelectionScope(initialTabID: zhihuID, fixedBoard: false, slot: "two", size: .medium)
        let weiboMedium = WidgetSelectionScope(initialTabID: weiboID, fixedBoard: false, slot: "one", size: .medium)
        let scopes = [small, medium, anotherMedium, weiboMedium]
        for scope in scopes {
            _ = try SnapshotStore.updateSelection(profileID: profileID, widgetID: scope.storageKey,
                                                  tabID: zhihuID, page: 0, directory: directory)
        }
        // Switching one configuration keeps the other sizes, slots and starting boards intact.
        _ = try SnapshotStore.updateSelection(profileID: profileID, widgetID: medium.storageKey,
                                              tabID: weiboID, page: 0, directory: directory)
        for scope in scopes {
            let selection = SnapshotStore.selection(widgetID: scope.storageKey, directory: directory)
            XCTAssertEqual(selection?.tabID, scope == medium ? weiboID : zhihuID)
            XCTAssertEqual(scope.resolvedTabID(available: [zhihuID, weiboID], profileDefault: zhihuID,
                                               remembered: selection), selection?.tabID)
        }

        let eventID = UUID()
        try SnapshotStore.recordOpenedItem("weibo:item", eventID: eventID, directory: directory)
        XCTAssertEqual(
            SnapshotStore.consumeOpenedTarget(directory: directory),
            OpenedItemTarget(itemID: "weibo:item", eventID: eventID)
        )
    }

    func testCatalogCoversSeventeenSources() {
        let ids = Set(SourceCatalog.providers().map { $0.descriptor.id })
        XCTAssertEqual(ids.count, 17)
        XCTAssertTrue(ids.contains("wechat"))
        XCTAssertEqual(SourceCatalog.provider(id: "wechat")?.descriptor.availability, .requiresConfiguration)
    }

    func testExpiredSnapshotHidesNewsWithoutDiscardingConfiguration() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tabID = UUID()
        let profile = WidgetProfile(name: "默认", orderedTabIDs: [tabID], defaultTabID: tabID)
        let row = SnapshotRow(id: "weibo:1", title: "新闻", sourceTitle: "微博", rank: 1, movement: nil,
                              url: URL(string: "https://example.com/1"), eventID: nil, publishedAt: nil, score: 1)
        let snapshot = WidgetSnapshot(generation: 1, generatedAt: now, profiles: [profile],
                                      tabs: [SnapshotTab(id: tabID, title: "微博", kind: .sourceBoard,
                                                         rows: [row], coverage: "", updatedAt: now)],
                                      statuses: [], unreadCount: 0)
        XCTAssertEqual(snapshot.removingExpiredRows(at: now.addingTimeInterval(60)).tabs.first?.rows.count, 1)
        let expired = snapshot.removingExpiredRows(at: now.addingTimeInterval(1801))
        XCTAssertEqual(expired.tabs.first?.rows.count, 0)
        XCTAssertEqual(expired.profiles, [profile])
        XCTAssertEqual(expired.tabs.first?.id, tabID)
    }

    func testWidgetLinkRoundTripsPreciseItemAndTab() throws {
        let tabID = UUID()
        let eventID = UUID()
        let itemID = "weibo:中文 /?&=123"
        let target = WidgetNavigationTarget(itemID: itemID, eventID: eventID, tabID: tabID)
        XCTAssertEqual(WidgetNavigationTarget(url: target.url), target)
        XCTAssertNil(WidgetNavigationTarget(url: URL(string: "https://example.com/item?item=1")!))
        XCTAssertNil(WidgetNavigationTarget(url: URL(string: "trendingtab://item")!))
        XCTAssertEqual(WidgetNavigationTarget(url: WidgetNavigationTarget().url), WidgetNavigationTarget())
    }

    func testCurrentBoardReplacesDroppedItemsAndObservations() throws {
        let database = try AppDatabase(path: ":memory:")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = NormalizedItem(sourceID: "weibo", boardID: "weibo.hot", nativeID: "old",
                                 title: "已掉榜", url: URL(string: "https://example.com/old")!, rank: 1)
        let current = NormalizedItem(sourceID: "weibo", boardID: "weibo.hot", nativeID: "current",
                                     title: "当前热点", url: URL(string: "https://example.com/current")!, rank: 1)
        try database.save(result: FetchResult(sourceID: "weibo", boardID: "weibo.hot", fetchedAt: now,
                                             parserVersion: "test", items: [old]))
        try database.save(result: FetchResult(sourceID: "weibo", boardID: "weibo.hot", fetchedAt: now.addingTimeInterval(60),
                                             parserVersion: "test", items: [current]))
        XCTAssertEqual(try database.recentItems(since: .distantPast).map(\.id), [current.id])
        XCTAssertEqual(try database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observations") }, 1)
        XCTAssertTrue(try database.recentItems(since: now.addingTimeInterval(120)).isEmpty)
        try database.save(result: FetchResult(sourceID: "weibo", boardID: "weibo.hot", fetchedAt: now.addingTimeInterval(120),
                                             parserVersion: "test", items: []))
        XCTAssertTrue(try database.recentItems(since: .distantPast).isEmpty)
    }

    func testMixedBoardKeepsFreshRowsWhenOlderSourceExpires() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let items = ["old", "fresh"].enumerated().map { index, id in
            let seen = index == 0 ? now.addingTimeInterval(-1740) : now
            return StoredItem(item: NormalizedItem(sourceID: id, boardID: "\(id).hot", nativeID: id,
                                                   title: id, url: URL(string: "https://example.com/\(id)")!, rank: 1),
                              firstSeenAt: seen, lastSeenAt: seen, previousRank: nil, contentHash: id, historical: false)
        }
        let tab = TabDefinition(title: "聚合", kind: .aggregate, sort: .reciprocalRankFusion)
        let snapshot = TabAggregator.snapshot(tabs: [tab], profiles: [], items: items, events: [], statuses: [],
                                              sources: [], unread: 0, generation: 1, now: now)
        XCTAssertEqual(snapshot.removingExpiredRows(at: now.addingTimeInterval(61)).tabs.first?.rows.map(\.id), ["fresh:fresh"])
    }

    func testDeletedSelectionFallsBackToConfiguredBoard() {
        let first = UUID(), configured = UUID(), deleted = UUID()
        XCTAssertEqual(WidgetSelection.resolvedTabID(available: [first, configured], preferred: [deleted, configured, first]), configured)
        XCTAssertEqual(WidgetSelection.resolvedTabID(available: [first, configured], preferred: [configured, first]), configured)
        XCTAssertNil(WidgetSelection.resolvedTabID(available: [], preferred: [configured]))
    }

    func testFixedWidgetUsesItsConfiguredBoardAcrossReloads() {
        let zhihuID = UUID(), weiboID = UUID(), deletedID = UUID()
        let scope = WidgetSelectionScope(initialTabID: weiboID, fixedBoard: true, slot: "one", size: .small)
        let selection = WidgetSelection(profileID: UUID(), tabID: zhihuID, page: 0, generation: 1)
        XCTAssertEqual(scope.resolvedTabID(available: [zhihuID, weiboID], profileDefault: zhihuID,
                                           remembered: selection), weiboID)
        var reconfigured = scope
        reconfigured.initialTabID = zhihuID
        XCTAssertEqual(reconfigured.resolvedTabID(available: [zhihuID, weiboID], profileDefault: weiboID,
                                                 remembered: selection), zhihuID)
        reconfigured.initialTabID = deletedID
        XCTAssertEqual(reconfigured.resolvedTabID(available: [zhihuID, weiboID], profileDefault: weiboID,
                                                 remembered: selection), weiboID)
        XCTAssertEqual(reconfigured.resolvedTabID(available: [zhihuID], profileDefault: deletedID,
                                                 remembered: selection), zhihuID)
        XCTAssertNil(scope.resolvedTabID(available: [], profileDefault: zhihuID, remembered: selection))
    }

    func testReleaseFeedSelectsNewerDMG() throws {
        let json = """
        {"tag_name":"v0.2.0","body":"修复小组件","assets":[{"name":"TrendingTab-0.2.0.dmg","browser_download_url":"https://example.com/TrendingTab-0.2.0.dmg","digest":"sha256:abc123"}]}
        """
        let release = try ReleaseFeed.parse(Data(json.utf8), currentVersion: "0.1.0")
        XCTAssertEqual(release?.version, "0.2.0")
        XCTAssertEqual(release?.digest, "sha256:abc123")
        XCTAssertNil(try ReleaseFeed.parse(Data(json.utf8), currentVersion: "0.2.0"))
        XCTAssertFalse(ReleaseFeed.isNewer("0.1.9", than: "0.2.0"))
        let withRuntime = """
        {"tag_name":"v0.2.0","assets":[{"name":"TrendingTab-AgentRuntime-0.2.0.dmg","browser_download_url":"https://example.com/runtime.dmg"},{"name":"TrendingTab-0.2.0.dmg","browser_download_url":"https://example.com/app.dmg"}]}
        """
        XCTAssertEqual(try ReleaseFeed.parse(Data(withRuntime.utf8), currentVersion: "0.1.0")?.assetName, "TrendingTab-0.2.0.dmg")
    }

    func testReleaseFeedDistinguishesRateLimitFromOtherHTTPFailures() throws {
        for (status, headers, expected) in [
            (403, ["X-RateLimit-Remaining": "0"], AppUpdateError.rateLimited),
            (429, [:], .rateLimited),
            (403, [:], .http(403)),
            (503, [:], .http(503))
        ] {
            let response = try XCTUnwrap(HTTPURLResponse(url: ReleaseFeed.latest, statusCode: status,
                                                         httpVersion: nil, headerFields: headers))
            XCTAssertThrowsError(try ReleaseFeed.validateResponse(response)) {
                XCTAssertEqual($0 as? AppUpdateError, expected)
            }
        }
        let success = try XCTUnwrap(HTTPURLResponse(url: ReleaseFeed.latest, statusCode: 200,
                                                    httpVersion: nil, headerFields: [:]))
        XCTAssertNoThrow(try ReleaseFeed.validateResponse(success))
    }
}
