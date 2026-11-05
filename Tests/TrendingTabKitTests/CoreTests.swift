import XCTest
@testable import TrendingTabAggregation
@testable import TrendingTabCore
@testable import TrendingTabIntelligence
@testable import TrendingTabNotifications
@testable import TrendingTabPersistence
@testable import TrendingTabSources
@testable import TrendingTabWidgetBridge

final class CoreTests: XCTestCase {
    func testStableIdentityAndCanonicalURL() {
        let first = URL(string: "https://Example.com/a?utm_source=x&id=1#part")!
        let second = URL(string: "https://Example.com/a?id=1")!
        XCTAssertEqual(NormalizedItem.canonical(first), NormalizedItem.canonical(second))
        XCTAssertEqual(NormalizedItem.stableID(sourceID: "zhihu", nativeID: "42", url: first), "zhihu:42")
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
        _ = try SnapshotStore.updateSelection(profileID: profileID, widgetID: "zhihu-widget", tabID: zhihuID, page: 0, directory: directory)
        _ = try SnapshotStore.updateSelection(profileID: profileID, widgetID: "weibo-widget", tabID: weiboID, page: 0, directory: directory)

        XCTAssertEqual(SnapshotStore.selection(widgetID: "zhihu-widget", directory: directory)?.tabID, zhihuID)
        XCTAssertEqual(SnapshotStore.selection(widgetID: "weibo-widget", directory: directory)?.tabID, weiboID)

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

    func testReleaseFeedSelectsNewerDMG() throws {
        let json = """
        {"tag_name":"v0.2.0","body":"修复小组件","assets":[{"name":"TrendingTab-0.2.0.dmg","browser_download_url":"https://example.com/TrendingTab-0.2.0.dmg","digest":"sha256:abc123"}]}
        """
        let release = try ReleaseFeed.parse(Data(json.utf8), currentVersion: "0.1.0")
        XCTAssertEqual(release?.version, "0.2.0")
        XCTAssertEqual(release?.digest, "sha256:abc123")
        XCTAssertNil(try ReleaseFeed.parse(Data(json.utf8), currentVersion: "0.2.0"))
        XCTAssertFalse(ReleaseFeed.isNewer("0.1.9", than: "0.2.0"))
    }
}
