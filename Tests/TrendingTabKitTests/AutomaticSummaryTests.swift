import Foundation
import GRDB
import XCTest
import TrendingTabCore
import TrendingTabAggregation
@testable import TrendingTabIntelligence
import TrendingTabNetworking
import TrendingTabPersistence
@testable import TrendingTabKit

private actor SummaryArticleFixture {
    private(set) var urls: [URL] = []
    var fails = false
    init(fails: Bool = false) { self.fails = fails }
    func read(_ url: URL) throws -> PublicArticle {
        urls.append(url)
        if fails { throw PublicArticleError.status(403) }
        return PublicArticle(url: url, title: "原文", text: String(repeating: "正文", count: 5_000), truncated: false)
    }
}

private actor SummaryGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    var count: Int { waiters.count }
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        while !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

private actor SummaryModelFixture {
    private(set) var prompts: [String] = []
    func generate(_ prompt: String) throws -> AIResult {
        prompts.append(prompt)
        guard let start = prompt.range(of: "材料为以下 JSON 数组：\n"),
              let rows = try JSONSerialization.jsonObject(with: Data(prompt[start.upperBound...].utf8)) as? [[String: Any]],
              let id = rows.first?["id"] as? String else { throw PublicArticleError.unreadable }
        let text = rows.contains { $0["excerpt"] != nil } ? "正文摘要" : "材料摘要"
        let payload = try JSONSerialization.data(withJSONObject: ["summary": text, "evidenceIDs": [id]])
        return AIResult(text: String(decoding: payload, as: UTF8.self),
            usage: AIUsage(inputTokens: 10, outputTokens: 5, estimated: false), finishReason: "stop")
    }
}

private struct SummaryProviderFixture: AIProvider {
    let connection: AIConnection
    let recorder: SummaryModelFixture
    func generate(system: String, prompt: String, json: Bool) async throws -> AIResult { try await recorder.generate(prompt) }
    func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

private struct SummaryTransportFixture: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 404, data: Data(), headers: [:], finalURL: request.url)
    }
}

final class AutomaticSummaryTests: XCTestCase, @unchecked Sendable {
    private func reports(count: Int = 5) -> [StoredItem] {
        (1...count).map { index in
            let item = NormalizedItem(sourceID: "fixture", boardID: "fixture.hot", nativeID: "\(index)",
                title: "标题\(index)", url: URL(string: "https://example.com/\(index)?session=fixture#part")!, summary: "已有摘要", rank: index)
            return StoredItem(item: item, firstSeenAt: .now, lastSeenAt: .now, previousRank: nil,
                contentHash: "hash\(index)", historical: false)
        }
    }

    func testExistingSettingsKeepValuesAndDefaultOriginalReadingOff() throws {
        var settings = AppSettings.standard
        settings.refreshInterval = 1_800
        settings.aiEnabled = true
        settings.dailyRequestLimit = 47
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: TrendingJSON.data(settings)) as? [String: Any])
        object.removeValue(forKey: "automaticSummaryReadOriginal")
        let decoded = try TrendingJSON.value(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.refreshInterval, 1_800)
        XCTAssertTrue(decoded.aiEnabled)
        XCTAssertEqual(decoded.dailyRequestLimit, 47)
        XCTAssertFalse(decoded.automaticSummaryReadOriginal)
        var enabled = decoded
        enabled.automaticSummaryReadOriginal = true
        XCTAssertEqual(try TrendingJSON.value(AppSettings.self, from: TrendingJSON.data(enabled)), enabled)
    }

    func testDisabledSummaryUsesFeedWithoutReadingArticles() async throws {
        let reader = SummaryArticleFixture()
        let material = try await AutomaticSummaryMaterial.prepare(reports: reports(), readOriginal: false) { try await reader.read($0) }
        let urls = await reader.urls
        XCTAssertTrue(urls.isEmpty)
        XCTAssertTrue(material.prompt.contains("已有摘要"))
        XCTAssertFalse(material.prompt.contains("正文正文"))
        XCTAssertEqual(material.evidenceLevel, "标题与摘要")
        XCTAssertFalse(material.prompt.contains("session=fixture"))
    }

    func testOriginalReadingIsBoundedAndKeepsSourceIdentity() async throws {
        let reader = SummaryArticleFixture()
        let source = reports()
        let material = try await AutomaticSummaryMaterial.prepare(reports: source, readOriginal: true) { try await reader.read($0) }
        let urls = await reader.urls
        XCTAssertEqual(urls, Array(source.prefix(3).map(\.item.url)))
        XCTAssertEqual(material.originalItemIDs, Set(source.prefix(3).map(\.id)))
        XCTAssertEqual(material.allowedEvidence, Set(source.map(\.id)))
        XCTAssertEqual(material.evidenceLevel, "标题、摘要与原文摘录")
        XCTAssertFalse(material.prompt.contains("session=fixture"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(material.materialJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual((rows.first?["excerpt"] as? String)?.count, 6_000)
        XCTAssertEqual(rows.first?["id"] as? String, source.first?.id)
        XCTAssertEqual(rows.first?["originalStatus"] as? String, "已读取，摘录已截断")
    }

    func testUnavailableOriginalRemainsFeedEvidence() async throws {
        let reader = SummaryArticleFixture(fails: true)
        let material = try await AutomaticSummaryMaterial.prepare(reports: reports(count: 1), readOriginal: true) { try await reader.read($0) }
        XCTAssertEqual(material.evidenceLevel, "标题与摘要")
        XCTAssertTrue(material.originalItemIDs.isEmpty)
        XCTAssertTrue(material.prompt.contains("未取得正文"))
        XCTAssertTrue(material.prompt.contains("已有摘要"))
    }

    func testSameOriginalMaterialKeepsAutomaticRequestIdentity() async throws {
        let reader = SummaryArticleFixture()
        let source = reports()
        let first = try await AutomaticSummaryMaterial.prepare(reports: source, readOriginal: true) { try await reader.read($0) }
        let second = try await AutomaticSummaryMaterial.prepare(reports: source.reversed(), readOriginal: true) { try await reader.read($0) }
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: "fixture")
        func identity(_ material: AutomaticSummaryMaterial) throws -> String {
            try AutomaticTaskIdentity.make(kind: "summary", connection: connection, headers: [:],
                system: AutomaticSummaryMaterial.system, prompt: material.prompt, rule: "original-enabled", promptVersion: 1)
        }
        XCTAssertEqual(try identity(first), try identity(second))
        let database = try AppDatabase(path: ":memory:")
        XCTAssertEqual(try database.reserveAIRun(id: UUID(), tokens: 100, now: .now, taskKey: identity(first)), .reserved)
        XCTAssertEqual(try database.reserveAIRun(id: UUID(), tokens: 100, now: .now, taskKey: identity(second)), .duplicateUnknown)
    }

    func testCancelledOriginalReadingCannotContinueToNextArticle() async throws {
        let reader = SummaryArticleFixture()
        let source = reports()
        let task = Task {
            try await AutomaticSummaryMaterial.prepare(reports: source, readOriginal: true) { url in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await reader.read(url)
            }
        }
        do { _ = try await task.value; XCTFail("取消后必须停止材料准备") }
        catch is CancellationError { }
        let urls = await reader.urls
        XCTAssertEqual(urls.count, 1)
    }

    @MainActor
    private func application(readOriginal: Bool, reader: @escaping AutomaticSummaryMaterial.ArticleReader,
                             recorder: SummaryModelFixture) throws -> (TrendingAppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let source = reports().map { original -> NormalizedItem in
            var item = original.item
            item.title = "同一新闻事件"
            return item
        }
        try database.save(result: FetchResult(sourceID: "fixture", boardID: "fixture.hot", fetchedAt: .now, parserVersion: "test", items: source))
        let stored = try database.recentItems(since: .distantPast)
        var event = try XCTUnwrap(EventGrouper.group(stored, now: .now).first)
        XCTAssertEqual(event.itemIDs.count, 5)
        event.importance = 80
        event.confidence = 0.9
        event.assessmentSourceIDs = ["fixture"]
        event.status = "major"
        event.summary = "先前摘要"
        try database.save(events: [event])
        var settings = AppSettings.standard
        settings.automaticSummaryReadOriginal = readOriginal
        settings.dailyTokenLimit = 1_000_000
        let tab = TabDefinition(title: "重大事件", kind: .majorEvents,
            filter: TabFilter(authoritativeSourceIDs: ["fixture"]), sort: .importance)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: "summary-fixture")
        var assignment = AIAssignment.empty
        assignment.summary = connection.id
        try database.saveDocument(settings, key: "settings")
        try database.saveDocument([tab], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let model = TrendingAppModel(database: database, transport: SummaryTransportFixture(), snapshotDirectory: directory,
            automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in SummaryProviderFixture(connection: connection, recorder: recorder) },
            automaticArticleReader: reader)
        XCTAssertEqual(model.events.first?.status, "major")
        return (model, directory)
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("自动摘要没有到达预期状态")
    }

    @MainActor
    func testChangingOriginalReadingReevaluatesSummaryAndPreservesBasisAfterReload() async throws {
        let reader = SummaryArticleFixture()
        let recorder = SummaryModelFixture()
        let (model, directory) = try application(readOriginal: false, reader: { try await reader.read($0) }, recorder: recorder)
        defer { model.stop(); try? FileManager.default.removeItem(at: directory) }
        var settings = model.settings
        settings.aiEnabled = true
        model.updateSettings(settings)
        try await waitUntil { model.events.first?.summary == "材料摘要" }
        XCTAssertEqual(model.events.first?.evidenceLevel, "标题与摘要")
        let unread = await reader.urls
        XCTAssertTrue(unread.isEmpty)
        settings.automaticSummaryReadOriginal = true
        model.updateSettings(settings)
        try await waitUntil { model.events.first?.summary == "正文摘要" }
        let urls = await reader.urls
        let prompts = await recorder.prompts
        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(model.events.first?.evidenceLevel, "标题、摘要与原文摘录")
        model.load()
        XCTAssertEqual(model.events.first?.evidenceLevel, "标题、摘要与原文摘录")
        let persisted = try await model.database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM documents UNION ALL SELECT payload FROM events")
        }
        XCTAssertFalse(persisted.contains { $0.contains("正文正文") })
    }

    @MainActor
    func testExpiredMaterialsDuringOriginalReadNeverReachModel() async throws {
        let gate = SummaryGate()
        let reader = SummaryArticleFixture()
        let recorder = SummaryModelFixture()
        let (model, directory) = try application(readOriginal: true, reader: { url in
            await gate.wait()
            return try await reader.read(url)
        }, recorder: recorder)
        defer { model.stop(); try? FileManager.default.removeItem(at: directory) }
        var settings = model.settings
        settings.aiEnabled = true
        model.updateSettings(settings)
        try await waitUntil { await gate.count == 1 }
        try await model.database.writer.write { db in
            try db.execute(sql: "UPDATE items SET last_seen_at = ?", arguments: [Date.now.addingTimeInterval(-7_200)])
        }
        model.load()
        XCTAssertTrue(model.items.isEmpty)
        await gate.release()
        try await waitUntil { !model.analyzingMajorEvents }
        let urls = await reader.urls
        XCTAssertEqual(urls.count, 3)
        let prompts = await recorder.prompts
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(model.events.isEmpty)
        let count = try await model.database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_runs") }
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testDisablingAnalysisDuringOriginalReadStopsBeforeReservation() async throws {
        let gate = SummaryGate()
        let reader = SummaryArticleFixture()
        let recorder = SummaryModelFixture()
        let (model, directory) = try application(readOriginal: true, reader: { url in
            await gate.wait()
            return try await reader.read(url)
        }, recorder: recorder)
        defer { model.stop(); try? FileManager.default.removeItem(at: directory) }
        var settings = model.settings
        settings.aiEnabled = true
        model.updateSettings(settings)
        try await waitUntil { await gate.count == 1 }
        settings.aiEnabled = false
        settings.automaticSummaryReadOriginal = false
        model.updateSettings(settings)
        await gate.release()
        try await waitUntil { await reader.urls.count == 1 }
        settings.aiEnabled = true
        model.updateSettings(settings)
        try await waitUntil { model.events.first?.summary == "材料摘要" }
        let prompts = await recorder.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(prompts.first?.contains("正文正文") == true)
    }

    @MainActor
    func testExhaustedBudgetDoesNotReadOriginalArticles() async throws {
        let reader = SummaryArticleFixture()
        let recorder = SummaryModelFixture()
        let (model, directory) = try application(readOriginal: true, reader: { try await reader.read($0) }, recorder: recorder)
        defer { model.stop(); try? FileManager.default.removeItem(at: directory) }
        var settings = model.settings
        settings.dailyRequestLimit = 1
        model.updateSettings(settings)
        let id = UUID()
        XCTAssertTrue(try model.database.reserveAIRun(id: id, tokens: 100, now: .now))
        try model.database.finishAIRun(id: id, state: "completed", actualTokens: 100)
        XCTAssertFalse(try model.database.canReserveAIRun(tokens: 1, now: .now))
        settings.aiEnabled = true
        model.updateSettings(settings)
        try await Task.sleep(for: .milliseconds(200))
        let urls = await reader.urls
        let prompts = await recorder.prompts
        XCTAssertTrue(urls.isEmpty)
        XCTAssertTrue(prompts.isEmpty)
    }
}
