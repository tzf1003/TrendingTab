import Foundation
import GRDB
import XCTest
import TrendingTabAggregation
import TrendingTabCore
@testable import TrendingTabIntelligence
import TrendingTabNetworking
import TrendingTabPersistence
@testable import TrendingTabKit

private actor MonitoringCalls {
    private(set) var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
}

private struct MonitoringProvider: AIProvider {
    let connection: AIConnection
    let calls: MonitoringCalls
    var fails = false
    var invalidOutput = false

    func generate(system: String, prompt: String, json: Bool) async throws -> AIResult {
        await calls.record(prompt)
        if fails { throw SourceFailure.unavailable("测试连接失败") }
        if invalidOutput {
            return AIResult(text: "{}", usage: AIUsage(inputTokens: 100, outputTokens: 50, estimated: false), finishReason: "stop")
        }
        let ids = prompt.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") }.compactMap {
            String($0.dropFirst(2)).components(separatedBy: ": [").first
        }
        let payload: [String: Any] = ["importance": 90, "confidence": 0.95, "category": "科技",
            "summary": "多来源报道了卫星发射", "reason": "公开报道", "evidenceIDs": ids, "matchedTopicIDs": []]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return AIResult(text: "```json\n\(text)\n```", usage: AIUsage(inputTokens: 100, outputTokens: 50, estimated: false), finishReason: "stop")
    }

    func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct NoMonitoringNetwork: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw SourceFailure.unavailable("测试禁止联网") }
}

@MainActor
final class MajorEventMonitoringTests: XCTestCase {
    private func stored(_ source: String, _ id: String, _ title: String, now: Date = .now) -> StoredItem {
        StoredItem(item: NormalizedItem(sourceID: source, boardID: "\(source).hot", nativeID: id, title: title,
            url: URL(string: "https://example.com/\(source)/\(id)")!, rank: 1), firstSeenAt: now, lastSeenAt: now,
            previousRank: nil, contentHash: title.sha256Prefix, historical: false)
    }

    func testChineseReportsWithDifferentWordingFormOneMultiSourceEvent() throws {
        let reports = [stored("weibo", "1", "中国成功发射新一代卫星"), stored("baidu", "2", "我国成功发射新一代卫星")]
        let groups = EventGrouper.group(reports, now: .now)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.independentSourceCount, 2)
        XCTAssertEqual(Set(try XCTUnwrap(groups.first).itemIDs), Set(reports.map(\.id)))
        XCTAssertEqual(groups.map(\.materialFingerprint), EventGrouper.group(reports.reversed(), now: .now).map(\.materialFingerprint))
    }

    func testPersonnelResignationReportsWithDifferentPhrasingFormOneEvent() throws {
        let reports = [
            stored("weibo", "1", "黄仁勋宣布辞去董事长职务"),
            stored("baidu", "2", "黄仁勋辞职获批，将卸任公司董事长"),
        ]

        let groups = EventGrouper.group(reports, now: .now)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(groups.first).itemIDs), Set(reports.map(\.id)))
        XCTAssertTrue(EventGrouper.isPersonnelChange(reports[0].item.title))
        XCTAssertTrue(EventGrouper.isPersonnelChange(reports[1].item.title))
    }

    func testPersonnelChangesForDifferentPeopleStaySeparate() {
        let reports = [
            stored("weibo", "1", "张三辞去公司董事长职务"),
            stored("baidu", "2", "李四宣布辞去公司董事长职务"),
        ]

        XCTAssertEqual(EventGrouper.group(reports, now: .now).count, 2)
    }

    func testShortSharedFragmentsAndDifferentEventNumbersStaySeparate() {
        let reports = [stored("weibo", "1", "四川发生6级地震"), stored("baidu", "2", "四川发生3级地震"),
            stored("news", "3", "北京今日天气晴朗"), stored("news", "4", "上海今日天气阴雨")]
        XCTAssertEqual(EventGrouper.group(reports, now: .now).count, 4)
    }

    func testFencedModelJSONRetainsFieldAndEvidenceValidation() throws {
        let valid = "{\"importance\":80,\"confidence\":0.9,\"summary\":\"摘要\",\"evidenceIDs\":[\"weibo:1\"]}"
        XCTAssertEqual(try AssessmentParser.parse("```json\n\(valid)\n```", allowedEvidence: ["weibo:1"], allowedTopics: []).importance, 80)
        XCTAssertThrowsError(try AssessmentParser.parse("```json\n\(valid)\n```", allowedEvidence: ["other"], allowedTopics: []))
        XCTAssertThrowsError(try AssessmentParser.parse("说明\n\(valid)", allowedEvidence: ["weibo:1"], allowedTopics: []))
        XCTAssertThrowsError(try AssessmentParser.parse(valid.replacingOccurrences(of: "0.9", with: "90"), allowedEvidence: ["weibo:1"], allowedTopics: []))
        XCTAssertEqual(try EventSummaryParser.parse("```json\n{\"summary\":\"摘要\",\"evidenceIDs\":[\"weibo:1\"]}\n```", allowedEvidence: ["weibo:1"]), "摘要")
        let batch = try SemanticTopicBatch(description: "卫星", items: [stored("weibo", "1", "卫星发射")])
        XCTAssertEqual(try batch.parse("```json\n{\"matchedIDs\":[\"weibo:1\"]}\n```"), ["weibo:1"])
    }

    func testMonitoringPrioritizesMultiSourceEvidenceAndPublishesFencedAssessment() async throws {
        try await exerciseMonitoring(fails: false)
    }

    func testFailedClassificationStopsThePassAndExplainsTheFailure() async throws {
        try await exerciseMonitoring(fails: true)
    }

    func testInvalidAssessmentContinuesToOtherCandidatesAndAccountsForReturnedUsage() async throws {
        try await exerciseMonitoring(fails: false, invalidOutput: true)
    }

    func testEventSessionUsesLinkedReportsAsEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let now = Date()
        let reports = [
            stored("weibo", "1", "黄仁勋宣布辞去董事长职务", now: now),
            stored("baidu", "2", "黄仁勋辞职获批，将卸任公司董事长", now: now),
            stored("news", "3", "黄仁勋离任后继任安排待公布", now: now),
        ]
        for report in reports {
            try database.save(result: FetchResult(sourceID: report.item.sourceID, boardID: report.item.boardID,
                fetchedAt: report.lastSeenAt, parserVersion: "fixture", items: [report.item]))
        }
        let event = EventCluster(title: "黄仁勋辞职", itemIDs: reports.map(\.id), independentSourceCount: 3,
                                 materialFingerprint: "event", updatedAt: now, createdAt: now)
        try database.save(events: [event])
        let model = TrendingAppModel(database: database, transport: NoMonitoringNetwork(), snapshotDirectory: directory,
                                     automaticCredential: { _ in nil }, automaticProvider: nil)
        defer { model.stop() }

        let evidence = model.analysisEvidence(for: "event:\(event.id.uuidString)")

        for report in reports {
            XCTAssertTrue(evidence.contains(report.item.title))
            XCTAssertTrue(evidence.contains("来源：\(report.item.sourceID)"))
        }
    }

    func testMergedEventsKeepOldEventLinksResolvable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let now = Date()
        let reports = [
            stored("weibo", "1", "黄仁勋宣布辞去董事长职务", now: now),
            stored("baidu", "2", "黄仁勋辞职获批，将卸任公司董事长", now: now),
        ]
        for report in reports {
            try database.save(result: FetchResult(sourceID: report.item.sourceID, boardID: report.item.boardID,
                fetchedAt: report.lastSeenAt, parserVersion: "fixture", items: [report.item]))
        }
        let earliest = EventCluster(title: reports[0].item.title, itemIDs: [reports[0].id], independentSourceCount: 1,
                                    materialFingerprint: "first", updatedAt: now.addingTimeInterval(-60), createdAt: now.addingTimeInterval(-120))
        let later = EventCluster(title: reports[1].item.title, itemIDs: [reports[1].id], independentSourceCount: 1,
                                 materialFingerprint: "second", updatedAt: now, createdAt: now.addingTimeInterval(-30))
        try database.save(events: [earliest, later])

        let model = TrendingAppModel(database: database, transport: NoMonitoringNetwork(), snapshotDirectory: directory,
                                     automaticCredential: { _ in nil }, automaticProvider: nil)
        XCTAssertEqual(try XCTUnwrap(model.events.first).id, earliest.id)
        model.reveal(eventID: later.id)
        XCTAssertEqual(model.requestedEventID, earliest.id)
        model.stop()

        let restored = TrendingAppModel(database: database, transport: NoMonitoringNetwork(), snapshotDirectory: directory,
                                        automaticCredential: { _ in nil }, automaticProvider: nil)
        defer { restored.stop() }
        restored.reveal(eventID: later.id)
        XCTAssertEqual(restored.requestedEventID, earliest.id)
    }

    private func exerciseMonitoring(fails: Bool, invalidOutput: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        let connection = AIConnection(name: "测试", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!, model: "test", credentialAccount: "fixture")
        let tab = TabDefinition(title: "重大事件", kind: .majorEvents, sort: .importance)
        var assignment = AIAssignment.empty
        assignment.classification = connection.id
        try database.saveDocument([connection], key: "connections")
        try database.saveDocument(assignment, key: "assignment")
        try database.saveDocument([tab], key: "tabs")
        let now = Date()
        let reports = [stored("weibo", "1", "中国成功发射新一代卫星", now: now.addingTimeInterval(-60)),
            stored("baidu", "2", "我国成功发射新一代卫星", now: now.addingTimeInterval(-60)),
            stored("zhihu", "3", "音乐综艺开播", now: now)]
        for report in reports {
            try database.save(result: FetchResult(sourceID: report.item.sourceID, boardID: report.item.boardID,
                fetchedAt: report.lastSeenAt, parserVersion: "fixture", items: [report.item]))
        }
        let calls = MonitoringCalls()
        let model = TrendingAppModel(database: database, transport: NoMonitoringNetwork(), snapshotDirectory: directory,
            automaticCredential: { _ in "fixture" }, automaticProvider: { connection, _ in
                MonitoringProvider(connection: connection, calls: calls, fails: fails, invalidOutput: invalidOutput)
            })
        defer { model.stop() }
        XCTAssertTrue(try XCTUnwrap(model.majorEventAnalysisCoverage).contains("开启 AI 分析"))
        var settings = model.settings
        settings.aiEnabled = true
        settings.dailyRequestLimit = fails || invalidOutput ? 100 : 1
        model.updateSettings(settings)
        for _ in 0..<200 {
            if model.majorEventAnalysisIssue != nil && !model.analyzingMajorEvents { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let prompts = await calls.prompts
        XCTAssertEqual(prompts.count, invalidOutput ? 2 : 1)
        XCTAssertTrue(try XCTUnwrap(prompts.first).contains("weibo:1"))
        XCTAssertTrue(try XCTUnwrap(prompts.first).contains("baidu:2"))
        XCTAssertFalse(try XCTUnwrap(prompts.first).contains("zhihu:3"))
        XCTAssertTrue(try XCTUnwrap(prompts.first).contains("发布时间："))
        XCTAssertTrue(try XCTUnwrap(prompts.first).contains("已有摘要："))
        XCTAssertTrue(try XCTUnwrap(prompts.first).contains("重要人物、政府领导人或重要组织负责人"))
        let states = try await database.writer.read { try String.fetchAll($0, sql: "SELECT state FROM ai_runs") }
        if fails || invalidOutput {
            XCTAssertEqual(states, Array(repeating: invalidOutput ? "failed-accounted" : "unknown-accounted", count: invalidOutput ? 2 : 1))
            XCTAssertEqual(model.events.filter { $0.status == "major" }.count, 0)
            XCTAssertTrue(try XCTUnwrap(model.majorEventAnalysisCoverage).contains(invalidOutput ? "模型输出缺少必要字段" : "测试连接失败"))
            if invalidOutput {
                XCTAssertNil(model.majorEventAnalysisIssue)
                XCTAssertEqual(model.eventDiagnostics.values.filter { $0.stage == "failed" }.count, 2)
            } else {
                XCTAssertEqual(model.diagnostics.first { $0.id == "event-analysis" }?.state, "failed")
            }
            if invalidOutput {
                let tokens = try await database.writer.read { try Int.fetchOne($0, sql: "SELECT reserved_tokens FROM ai_runs") }
                XCTAssertEqual(tokens, 150)
            }
        } else {
            XCTAssertEqual(states, ["completed"])
            XCTAssertEqual(model.events.filter { $0.status == "major" }.count, 1)
            XCTAssertEqual(model.snapshot?.tabs.first?.rows.count, 1)
            XCTAssertEqual(model.events.first { $0.status == "major" }?.assessmentSourceIDs, ["baidu", "weibo"])
            XCTAssertEqual(model.events.first { $0.status == "major" }?.assessmentReason, "公开报道")
            XCTAssertEqual(model.events.first { $0.status == "major" }?.assessmentEvidenceIDs, ["baidu:2", "weibo:1"])
            XCTAssertEqual(model.events.first { $0.status == "major" }?.assessmentVersion, 2)
            XCTAssertNotNil(model.events.first { $0.status == "major" }?.assessedAt)
            XCTAssertEqual(model.events.first { $0.status == "major" }?.brief?.importanceAnalysis, "公开报道")
            let event = try XCTUnwrap(model.events.first { $0.status == "major" })
            let diagnostic = try XCTUnwrap(model.eventDiagnostics[event.id])
            XCTAssertEqual(diagnostic.stage, "published")
            XCTAssertEqual(diagnostic.materialIDs, ["baidu:2", "weibo:1"])
            XCTAssertEqual(diagnostic.sourceIDs, ["baidu", "weibo"])
            XCTAssertEqual(diagnostic.evidenceIDs, ["baidu:2", "weibo:1"])
            XCTAssertEqual(diagnostic.assessmentVersion, 2)
            XCTAssertTrue(try XCTUnwrap(model.snapshot?.tabs.first?.coverage).contains("预算不足"))
        }
    }
}
