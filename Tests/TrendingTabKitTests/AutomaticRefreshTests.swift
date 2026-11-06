import Foundation
import GRDB
import XCTest
import TrendingTabCore
@testable import TrendingTabIntelligence
import TrendingTabNetworking
import TrendingTabPersistence
@testable import TrendingTabKit

private actor RefreshFixture: HTTPTransport {
    private var calls = 0
    var count: Int { calls }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        calls += 1
        let id = calls
        let body = """
        {"data":[{"target":{"id":"\(id)","title":"热点\(id)","url":"https://www.zhihu.com/question/\(id)"}}]}
        """
        return HTTPResponse(statusCode: 200, data: Data(body.utf8), headers: [:], finalURL: request.url)
    }
}

private actor AnalysisGate {
    private var pending: [CheckedContinuation<Void, Never>] = []
    var count: Int { pending.count }
    func wait() async { await withCheckedContinuation { pending.append($0) } }
    func releaseFirst() { if !pending.isEmpty { pending.removeFirst().resume() } }
    func releaseAll() { while !pending.isEmpty { pending.removeFirst().resume() } }
}

private struct DelayedAnalysis: AIProvider {
    let connection: AIConnection
    let gate: AnalysisGate
    var succeeds = false
    func generate(system: String, prompt: String, json: Bool) async throws -> AIResult {
        await gate.wait()
        if succeeds { return AIResult(text: "{}", usage: AIUsage(inputTokens: 10, outputTokens: 5, estimated: false), finishReason: "stop") }
        throw SourceFailure.unavailable("测试中断")
    }
    func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct FairFeed: HTTPTransport {
    var count = 12
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let entries = (1...count).map { index in
            ["target": ["id": "\(index)", "title": "topic\(index)", "url": "https://www.zhihu.com/question/\(index)"]]
        }
        return HTTPResponse(statusCode: 200, data: try JSONSerialization.data(withJSONObject: ["data": entries]), headers: [:], finalURL: request.url)
    }
}

private actor TaskOrder {
    private(set) var calls: [String] = []
    func record(_ label: String) { calls.append(label) }
}

private struct FairAnalysis: AIProvider {
    let connection: AIConnection
    let order: TaskOrder
    func generate(system: String, prompt: String, json: Bool) async throws -> AIResult {
        if prompt.contains("主题描述：") {
            await order.record(prompt.contains("主题甲") ? "主题甲" : "主题乙")
            return AIResult(text: "{\"matchedIDs\":[]}", usage: AIUsage(inputTokens: 10, outputTokens: 5, estimated: false), finishReason: "stop")
        }
        await order.record("事件")
        throw SourceFailure.unavailable("测试事件判断失败")
    }
    func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct HeaderChangeAnalysis: AIProvider {
    let connection: AIConnection
    let order: TaskOrder
    func generate(system: String, prompt: String, json: Bool) async throws -> AIResult {
        let text: String
        if prompt.contains("主题描述：") {
            await order.record("主题")
            text = "{\"matchedIDs\":[]}"
        } else {
            await order.record("事件")
            guard let line = prompt.split(separator: "\n").first(where: { $0.hasPrefix("- ") }),
                  let id = line.dropFirst(2).components(separatedBy: ": ").first, !id.isEmpty else {
                throw SourceFailure.unavailable("测试材料缺少证据")
            }
            let payload: [String: Any] = ["importance": 30, "confidence": 0.9, "summary": "测试摘要", "evidenceIDs": [id]]
            text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        }
        return AIResult(text: text, usage: AIUsage(inputTokens: 10, outputTokens: 5, estimated: false), finishReason: "stop")
    }
    func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct PausedHeaderAnalysis: AIProvider {
    let connection: AIConnection
    let gate: AnalysisGate
    func generate(system: String, prompt: String, json: Bool) async throws -> AIResult {
        await gate.wait()
        guard let line = prompt.split(separator: "\n").first(where: { $0.hasPrefix("- ") }),
              let id = line.dropFirst(2).components(separatedBy: ": ").first, !id.isEmpty else {
            throw SourceFailure.unavailable("测试材料缺少证据")
        }
        let payload: [String: Any] = ["importance": 30, "confidence": 0.9, "summary": "测试摘要", "evidenceIDs": [id]]
        return AIResult(text: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self),
                        usage: AIUsage(inputTokens: 10, outputTokens: 5, estimated: false), finishReason: "stop")
    }
    func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class TestHeaderStore {
    var value: String?
    var shouldSave = true
    func save(_ value: String) -> Bool {
        guard shouldSave else { return false }
        self.value = value
        return true
    }
}

private struct PausedTopicAnalysis: AIProvider {
    let connection: AIConnection
    let order: TaskOrder
    let gate: AnalysisGate
    func generate(system: String, prompt: String, json: Bool) async throws -> AIResult {
        guard prompt.contains("主题描述：") else { throw SourceFailure.unavailable("测试事件判断失败") }
        await order.record(prompt.contains("主题甲") ? "主题甲" : "主题乙")
        await gate.wait()
        return AIResult(text: "{\"matchedIDs\":[]}", usage: AIUsage(inputTokens: 10, outputTokens: 5, estimated: false), finishReason: "stop")
    }
    func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
final class AutomaticRefreshTests: XCTestCase {
    func testEditingConnectionPreservesAssignmentAndKeepsCredentialSeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let connection = AIConnection(name: "原连接", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "old", credentialAccount: "test-account")
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let store = TestHeaderStore()
        let model = TrendingAppModel(database: database, transport: FairFeed(count: 1), snapshotDirectory: directory,
            automaticCredential: { _ in nil }, automaticProvider: nil,
            credentialWriter: { _, value in store.save(value) })
        var edited = connection
        edited.model = "new"
        edited.baseURL = URL(string: "https://example.org/custom")!
        try model.updateConnection(edited)
        XCTAssertEqual(model.connections, [edited])
        XCTAssertEqual(model.assignment.classification, connection.id)
        XCTAssertEqual(try database.document([AIConnection].self, key: "connections"), [edited])
        var invalid = edited
        invalid.credentialAccount = "another-account"
        XCTAssertThrowsError(try model.updateConnection(invalid))
        invalid = edited
        invalid.maxOutputTokens = invalid.contextWindow + 1
        XCTAssertThrowsError(try model.updateConnection(invalid))
        XCTAssertEqual(model.connections, [edited])
        try database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_connection_update BEFORE UPDATE ON documents WHEN NEW.key = 'connections' BEGIN SELECT RAISE(FAIL, 'fixture failure'); END")
        }
        var unsaved = edited
        unsaved.model = "unsaved"
        XCTAssertThrowsError(try model.updateConnection(unsaved))
        XCTAssertEqual(model.connections, [edited])
        XCTAssertEqual(try database.document([AIConnection].self, key: "connections"), [edited])
        XCTAssertFalse(model.updateConnectionCredential(connection.id, credential: "  "))
        XCTAssertNil(store.value)
        store.shouldSave = false
        XCTAssertFalse(model.updateConnectionCredential(connection.id, credential: "replacement"))
        store.shouldSave = true
        XCTAssertTrue(model.updateConnectionCredential(connection.id, credential: "replacement"))
        XCTAssertEqual(store.value, "replacement")
        XCTAssertEqual(try database.document([AIConnection].self, key: "connections"), [edited])
        model.stop()
    }

    func testEditingConnectionDiscardsInflightClassification() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        var settings = AppSettings.standard
        settings.aiEnabled = true
        settings.dailyRequestLimit = 2
        let source = TabDefinition(title: "知乎", kind: .sourceBoard, boardIDs: ["zhihu.hot"], sort: .sourceRank)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "old", credentialAccount: "test-account")
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument(settings, key: "settings")
        try database.saveDocument([source], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let gate = AnalysisGate()
        let model = TrendingAppModel(database: database, transport: FairFeed(count: 1), snapshotDirectory: directory,
            automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in
                PausedHeaderAnalysis(connection: connection, gate: gate)
            })
        await model.refresh(manual: true)
        for _ in 0..<200 {
            if await gate.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        var edited = connection
        edited.model = "new"
        try model.updateConnection(edited)
        for _ in 0..<200 {
            if await gate.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let waiting = await gate.count
        XCTAssertEqual(waiting, 2)
        await gate.releaseFirst()
        for _ in 0..<200 {
            let count = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_runs WHERE state = 'discarded'") ?? 0 }
            if count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.events.first?.status, "pending-analysis")
        await gate.releaseAll()
        for _ in 0..<200 {
            if model.events.first?.status == "candidate" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let states = try await database.writer.read { db in try String.fetchAll(db, sql: "SELECT state FROM ai_runs ORDER BY state") }
        XCTAssertEqual(states, ["completed", "discarded"])
        XCTAssertEqual(model.events.first?.status, "candidate")
        model.stop()
    }

    func testHeaderChangeDiscardsInflightResultAndKeepsBudgetAccounting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        var settings = AppSettings.standard
        settings.aiEnabled = true
        settings.dailyRequestLimit = 2
        let source = TabDefinition(title: "知乎", kind: .sourceBoard, boardIDs: ["zhihu.hot"], sort: .sourceRank)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: UUID().uuidString)
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument(settings, key: "settings")
        try database.saveDocument([source], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let gate = AnalysisGate()
        let headers = TestHeaderStore()
        let model = TrendingAppModel(database: database, transport: FairFeed(count: 1), snapshotDirectory: directory,
            automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in
                PausedHeaderAnalysis(connection: connection, gate: gate)
            }, headerReader: { _ in headers.value }, headerWriter: { _, value in headers.save(value) })
        await model.refresh(manual: true)
        for _ in 0..<200 {
            if await gate.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.setConnectionHeaders(connection.id, headers: ["X-Fixture": "new"]))
        for _ in 0..<200 {
            if await gate.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let waiting = await gate.count
        XCTAssertEqual(waiting, 2)
        await gate.releaseFirst()
        for _ in 0..<200 {
            let count = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_runs WHERE state = 'discarded'") ?? 0 }
            if count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.events.first?.status, "pending-analysis")
        await gate.releaseAll()
        for _ in 0..<200 {
            if model.events.first?.status == "candidate" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let states = try await database.writer.read { db in try String.fetchAll(db, sql: "SELECT state FROM ai_runs ORDER BY state") }
        let accountedTokens = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT SUM(reserved_tokens) FROM ai_runs") }
        XCTAssertEqual(states, ["completed", "discarded"])
        XCTAssertEqual(accountedTokens, 30)
        XCTAssertEqual(model.events.first?.status, "candidate")
        model.stop()
    }

    func testChangingClassificationHeadersReevaluatesExistingItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        var settings = AppSettings.standard
        settings.aiEnabled = true
        let source = TabDefinition(title: "知乎", kind: .sourceBoard, boardIDs: ["zhihu.hot"], sort: .sourceRank)
        let topic = TabDefinition(title: "甲", kind: .topic, boardIDs: ["zhihu.hot"], filter: TabFilter(semanticPrompt: "主题甲"), sort: .reciprocalRankFusion)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: UUID().uuidString)
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument(settings, key: "settings")
        try database.saveDocument([source, topic], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let order = TaskOrder()
        let headers = TestHeaderStore()
        let model = TrendingAppModel(database: database, transport: FairFeed(count: 1), snapshotDirectory: directory,
            automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in
                HeaderChangeAnalysis(connection: connection, order: order)
            }, headerReader: { _ in headers.value }, headerWriter: { _, value in headers.save(value) })
        await model.refresh(manual: true)
        for _ in 0..<200 {
            if model.events.first?.status == "candidate", model.snapshot?.tabs.first(where: { $0.id == topic.id })?.coverage == "没有匹配内容" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.events.first?.status, "candidate")
        XCTAssertEqual(model.snapshot?.tabs.first(where: { $0.id == topic.id })?.coverage, "没有匹配内容")
        let before = await order.calls.count
        XCTAssertEqual(before, 2)
        headers.shouldSave = false
        XCTAssertFalse(model.setConnectionHeaders(connection.id, headers: ["X-Fixture": "changed"]))
        XCTAssertEqual(model.events.first?.status, "candidate")
        headers.shouldSave = true
        XCTAssertTrue(model.setConnectionHeaders(connection.id, headers: ["X-Fixture": "changed"]))
        XCTAssertEqual(model.events.first?.status, "pending-analysis")
        for _ in 0..<200 {
            if await order.calls.count >= before + 2, model.events.first?.status == "candidate",
               model.snapshot?.tabs.first(where: { $0.id == topic.id })?.coverage == "没有匹配内容" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = await order.calls.count
        XCTAssertEqual(after, before + 2)
        XCTAssertEqual(model.events.first?.status, "candidate")
        XCTAssertEqual(model.snapshot?.tabs.first(where: { $0.id == topic.id })?.coverage, "没有匹配内容")
        XCTAssertTrue(model.setConnectionHeaders(connection.id, headers: ["X-Fixture": "changed"]))
        try await Task.sleep(for: .milliseconds(150))
        let repeated = await order.calls.count
        XCTAssertEqual(repeated, after)
        model.stop()
    }

    func testEnablingHiddenTopicMonitoringAnalyzesExistingFeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        var settings = AppSettings.standard
        settings.aiEnabled = true
        let source = TabDefinition(title: "知乎", kind: .sourceBoard, boardIDs: ["zhihu.hot"], sort: .sourceRank)
        let topic = TabDefinition(title: "甲", kind: .topic, boardIDs: ["zhihu.hot"], filter: TabFilter(semanticPrompt: "主题甲"), sort: .reciprocalRankFusion, hidden: true)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: UUID().uuidString)
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument(settings, key: "settings")
        try database.saveDocument([source, topic], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let order = TaskOrder()
        let model = TrendingAppModel(database: database, transport: FairFeed(), snapshotDirectory: directory,
                                     automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in
            FairAnalysis(connection: connection, order: order)
        })
        await model.refresh(manual: true)
        for _ in 0..<200 {
            if await order.calls.count >= 12 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = await order.calls
        XCTAssertFalse(before.contains("主题甲"))
        model.setTabMonitoring(topic.id, enabled: true)
        for _ in 0..<200 {
            if await order.calls.contains("主题甲") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = await order.calls
        XCTAssertTrue(after.contains("主题甲"))
        model.setTabHidden(topic.id, hidden: false)
        for _ in 0..<200 {
            if model.snapshot?.tabs.first(where: { $0.id == topic.id })?.coverage == "没有匹配内容" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.snapshot?.tabs.first(where: { $0.id == topic.id })?.coverage, "没有匹配内容")
        model.setTabNotifications(topic.id, enabled: true)
        XCTAssertEqual(model.snapshot?.tabs.first(where: { $0.id == topic.id })?.coverage, "没有匹配内容")
        model.stop()
    }

    func testAutomaticQueueStopsAtRequestBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        var settings = AppSettings.standard
        settings.aiEnabled = true
        settings.dailyRequestLimit = 2
        settings.dailyTokenLimit = 10_000_000
        let source = TabDefinition(title: "知乎", kind: .sourceBoard, boardIDs: ["zhihu.hot"], sort: .sourceRank)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: UUID().uuidString)
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument(settings, key: "settings")
        try database.saveDocument([source], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let order = TaskOrder()
        let model = TrendingAppModel(database: database, transport: FairFeed(), snapshotDirectory: directory,
                                     automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in
            FairAnalysis(connection: connection, order: order)
        })
        await model.refresh(manual: true)
        for _ in 0..<200 {
            if await order.calls.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
        let count = await order.calls.count
        XCTAssertEqual(count, 2)
        model.stop()
    }

    func testRaisedBudgetAllowsMoreThanOneHundredEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        var settings = AppSettings.standard
        settings.aiEnabled = true
        settings.dailyRequestLimit = 200
        settings.dailyTokenLimit = 10_000_000
        let source = TabDefinition(title: "知乎", kind: .sourceBoard, boardIDs: ["zhihu.hot"], sort: .sourceRank)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: UUID().uuidString)
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument(settings, key: "settings")
        try database.saveDocument([source], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let order = TaskOrder()
        let model = TrendingAppModel(database: database, transport: FairFeed(count: 105), snapshotDirectory: directory,
                                     automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in
            FairAnalysis(connection: connection, order: order)
        })
        await model.refresh(manual: true)
        for _ in 0..<500 {
            if await order.calls.count >= 105 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let count = await order.calls.count
        XCTAssertEqual(count, 105)
        model.stop()
    }

    func testTopicRotationSurvivesAnalysisRescheduling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        var settings = AppSettings.standard
        settings.aiEnabled = true
        let source = TabDefinition(title: "知乎", kind: .sourceBoard, boardIDs: ["zhihu.hot"], sort: .sourceRank)
        let topicA = TabDefinition(title: "甲", kind: .topic, boardIDs: ["zhihu.hot"], filter: TabFilter(semanticPrompt: "主题甲"), sort: .reciprocalRankFusion)
        let topicB = TabDefinition(title: "乙", kind: .topic, boardIDs: ["zhihu.hot"], filter: TabFilter(semanticPrompt: "主题乙"), sort: .reciprocalRankFusion)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: UUID().uuidString)
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument(settings, key: "settings")
        try database.saveDocument([source, topicA, topicB], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let order = TaskOrder()
        let gate = AnalysisGate()
        let model = TrendingAppModel(database: database, transport: FairFeed(), snapshotDirectory: directory,
                                     automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in
            PausedTopicAnalysis(connection: connection, order: order, gate: gate)
        })
        await model.refresh(manual: true)
        for _ in 0..<200 {
            if await gate.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let firstCalls = await order.calls
        XCTAssertEqual(firstCalls, ["主题甲"])
        settings.dailyRequestLimit += 1
        model.updateSettings(settings)
        for _ in 0..<200 {
            if await gate.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let calls = await order.calls
        XCTAssertEqual(Array(calls.prefix(2)), ["主题甲", "主题乙"])
        model.stop()
        await gate.releaseAll()
    }

    func testSemanticTopicsTakeTurnsWithEventAnalysis() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        var settings = AppSettings.standard
        settings.aiEnabled = true
        let source = TabDefinition(title: "知乎", kind: .sourceBoard, boardIDs: ["zhihu.hot"], sort: .sourceRank)
        let topicA = TabDefinition(title: "甲", kind: .topic, boardIDs: ["zhihu.hot"], filter: TabFilter(semanticPrompt: "主题甲"), sort: .reciprocalRankFusion)
        let topicB = TabDefinition(title: "乙", kind: .topic, boardIDs: ["zhihu.hot"], filter: TabFilter(semanticPrompt: "主题乙"), sort: .reciprocalRankFusion)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: UUID().uuidString)
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument(settings, key: "settings")
        try database.saveDocument([source, topicA, topicB], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let order = TaskOrder()
        let model = TrendingAppModel(database: database, transport: FairFeed(), snapshotDirectory: directory,
                                     automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in FairAnalysis(connection: connection, order: order) })
        await model.refresh(manual: true)
        for _ in 0..<200 {
            if await order.calls.count >= 6 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let calls = await order.calls
        XCTAssertEqual(Array(calls.prefix(6)), ["事件", "主题甲", "事件", "主题乙", "事件", "主题甲"])
        model.stop()
    }
    func testRefreshContinuesWhilePreviousAnalysisWaitsAndDoesNotRestoreOldEvents() async throws {
        try await exerciseRefreshWithLateResult(succeeds: false)
    }

    func testLateSuccessfulResultCannotRestoreAnOlderEvent() async throws {
        try await exerciseRefreshWithLateResult(succeeds: true)
    }

    private func exerciseRefreshWithLateResult(succeeds: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        var settings = AppSettings.standard
        settings.aiEnabled = true
        let tab = TabDefinition(title: "知乎", kind: .sourceBoard, boardIDs: ["zhihu.hot"], sort: .sourceRank)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: UUID().uuidString)
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument(settings, key: "settings")
        try database.saveDocument([tab], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let gate = AnalysisGate()
        let transport = RefreshFixture()
        let model = TrendingAppModel(database: database, transport: transport, snapshotDirectory: directory,
                                     automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in
            DelayedAnalysis(connection: connection, gate: gate, succeeds: succeeds)
        })
        await model.refresh(manual: true)
        for _ in 0..<100 {
            if await gate.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let firstCount = await gate.count
        XCTAssertEqual(firstCount, 1)
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.items.map(\.item.title), ["热点1"])

        await model.refresh(manual: true)
        for _ in 0..<100 {
            if await gate.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let secondCount = await gate.count
        XCTAssertEqual(secondCount, 2)
        XCTAssertEqual(model.items.map(\.item.title), ["热点2"])
        await gate.releaseFirst()
        for _ in 0..<100 {
            let count = try await database.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_runs WHERE state = ?", arguments: [succeeds ? "discarded" : "unknown-accounted"]) ?? 0
            }
            if count > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let accounted = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_runs WHERE state = ?", arguments: [succeeds ? "discarded" : "unknown-accounted"]) ?? 0
        }
        XCTAssertEqual(accounted, 1)
        XCTAssertEqual(model.events.map(\.title), ["热点2"])
        XCTAssertEqual(try database.events().map(\.title), ["热点2"])
        model.stop()
        await gate.releaseAll()
    }

    func testEnablingAnalysisSchedulesExistingFeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let tab = TabDefinition(title: "知乎", kind: .sourceBoard, boardIDs: ["zhihu.hot"], sort: .sourceRank)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: UUID().uuidString)
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument([tab], key: "tabs")
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        let gate = AnalysisGate()
        let transport = RefreshFixture()
        let model = TrendingAppModel(database: database, transport: transport, snapshotDirectory: directory,
                                     automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in
            DelayedAnalysis(connection: connection, gate: gate)
        })
        await model.refresh(manual: true)
        XCTAssertEqual(model.items.map(\.item.title), ["热点1"])
        var settings = model.settings
        settings.aiEnabled = true
        model.updateSettings(settings)
        for _ in 0..<100 {
            if await gate.count > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let started = await gate.count
        XCTAssertEqual(started, 1)
        XCTAssertEqual(model.items.map(\.item.title), ["热点1"])
        model.addTopicTab(title: "技术", included: [], excluded: [], semanticPrompt: "开发者关注的技术")
        for _ in 0..<100 {
            if await gate.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pending = await gate.count
        let fetches = await transport.count
        XCTAssertEqual(pending, 2)
        XCTAssertEqual(fetches, 1, "配置主题后应分析现有内容，不必等待重新采集")
        model.stop()
        await gate.releaseAll()
    }
}
