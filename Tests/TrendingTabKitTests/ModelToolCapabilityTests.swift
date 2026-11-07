import Foundation
import XCTest
import TrendingTabCore
import TrendingTabIntelligence
import TrendingTabNetworking
import TrendingTabPersistence
@testable import TrendingTabKit

@MainActor
private final class CapabilityProbe {
    var error: Error?
    var credential = "public-fixture"
    var headers = "{}"
    var paused = false
    var waiting: CheckedContinuation<Void, Never>?
    func run() async throws -> String {
        if paused { await withCheckedContinuation { waiting = $0 } }
        if let error { throw error }
        return "工具调用测试成功。"
    }
}

@MainActor
final class ModelToolCapabilityTests: XCTestCase {
    private func model(_ database: AppDatabase, _ probe: CapabilityProbe) -> TrendingAppModel {
        TrendingAppModel(database: database, transport: URLSessionTransport(), snapshotDirectory: nil,
            automaticCredential: { _ in probe.credential }, automaticProvider: nil,
            headerReader: { _ in probe.headers }, headerWriter: { _, value in probe.headers = value; return true },
            credentialWriter: { _, value in probe.credential = value; return true },
            connectionTester: { _, _, _, _ in try await probe.run() })
    }

    private func fixture() throws -> (AppDatabase, AIConnection) {
        let database = try AppDatabase(path: ":memory:")
        let connection = AIConnection(name: "Fixture", kind: .openAIChat,
            baseURL: URL(string: "https://example.com/v1")!, model: "text", credentialAccount: "fixture")
        try database.saveDocument([connection], key: "connections")
        var assignment = AIAssignment.empty
        assignment.analysis = connection.id
        try database.saveDocument(assignment, key: "assignment")
        return (database, connection)
    }

    func testMissingToolIsRememberedButNetworkFailureDoesNotReplaceAResult() async throws {
        let (database, connection) = try fixture()
        let probe = CapabilityProbe()
        let app = model(database, probe)
        probe.error = AgentConnectionTester.TestError.missingTool
        do { _ = try await app.testConnection(connection.id, kind: .tools); XCTFail("Expected missing tool") }
        catch is AgentConnectionTester.TestError { }
        XCTAssertEqual(app.toolCapabilities[connection.id]?.state, .notVerified)
        let restored = model(database, probe)
        XCTAssertEqual(restored.toolCapabilities[connection.id]?.state, .notVerified)
        XCTAssertNotNil(restored.researchUnavailableReason)
        restored.sendChatMessage("研究问题", itemID: "story", toolHandler: { _, _ in
            XCTFail("Rejected research must not execute tools"); return ""
        })
        XCTAssertEqual(restored.analysisChat.session(for: "story").error, restored.researchUnavailableReason)
        restored.retryChat(itemID: "story", toolHandler: { _, _ in "" })
        XCTAssertFalse(restored.analysisChat.session(for: "story").isStreaming)
        XCTAssertEqual(restored.analysisChat.session(for: "story").messages.map(\.text), ["研究问题"])
        probe.error = nil
        _ = try await app.testConnection(connection.id, kind: .tools)
        XCTAssertEqual(app.toolCapabilities[connection.id]?.state, .verified)
        XCTAssertNil(app.researchUnavailableReason)
        probe.error = URLError(.timedOut)
        do { _ = try await app.testConnection(connection.id, kind: .tools); XCTFail("Expected timeout") }
        catch is URLError { }
        XCTAssertEqual(app.toolCapabilities[connection.id]?.state, .verified)
        app.stop(); restored.stop()
    }

    func testReloadRejectsChangedCredentialsAndCapabilityDocumentContainsOnlyDigest() async throws {
        let (database, connection) = try fixture()
        let probe = CapabilityProbe()
        let app = model(database, probe)
        _ = try await app.testConnection(connection.id, kind: .tools)
        let document = try XCTUnwrap(database.document([UUID: ModelToolCapability].self, key: "modelToolCapabilities"))
        let data = try TrendingJSON.data(document)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(probe.credential))
        XCTAssertEqual(document[connection.id]?.fingerprint.count, 64)
        probe.credential += "-changed"
        let restored = model(database, probe)
        XCTAssertNil(restored.toolCapabilities[connection.id])
        app.stop(); restored.stop()
    }

    func testTextChecksAndIdenticalConfigurationPreserveToolResult() async throws {
        let (database, connection) = try fixture()
        let probe = CapabilityProbe()
        let app = model(database, probe)
        _ = try await app.testConnection(connection.id, kind: .streaming)
        XCTAssertNil(app.toolCapabilities[connection.id])
        probe.error = URLError(.timedOut)
        do { _ = try await app.testConnection(connection.id, kind: .tools); XCTFail("Expected timeout") }
        catch is URLError { }
        XCTAssertNil(app.toolCapabilities[connection.id])
        probe.error = AgentConnectionTester.TestError.missingTool
        do { _ = try await app.testConnection(connection.id, kind: .tools); XCTFail("Expected missing tool") }
        catch is AgentConnectionTester.TestError { }
        let result = app.toolCapabilities[connection.id]
        probe.error = nil
        _ = try await app.testConnection(connection.id, kind: .streaming)
        XCTAssertTrue(app.setConnectionHeaders(connection.id, headers: [:]))
        try app.updateConnection(connection)
        XCTAssertEqual(app.toolCapabilities[connection.id], result)
        app.stop()
    }

    func testConnectionHeadersAndCredentialChangesInvalidateSavedCapability() async throws {
        let (database, connection) = try fixture()
        let probe = CapabilityProbe()
        let app = model(database, probe)
        _ = try await app.testConnection(connection.id, kind: .tools)
        XCTAssertTrue(app.setConnectionHeaders(connection.id, headers: ["X-Route": "next"]))
        XCTAssertNil(app.toolCapabilities[connection.id])
        XCTAssertNil(model(database, probe).toolCapabilities[connection.id])
        _ = try await app.testConnection(connection.id, kind: .tools)
        XCTAssertTrue(app.updateConnectionCredential(connection.id, credential: "other-fixture"))
        XCTAssertNil(app.toolCapabilities[connection.id])
        _ = try await app.testConnection(connection.id, kind: .tools)
        var edited = connection
        edited.model = "replacement"
        try app.updateConnection(edited)
        XCTAssertNil(app.toolCapabilities[connection.id])
        XCTAssertNil(model(database, probe).toolCapabilities[connection.id])
        app.stop()
    }

    func testAChangedConnectionDiscardsTheInflightTest() async throws {
        let (database, connection) = try fixture()
        let probe = CapabilityProbe()
        probe.paused = true
        let app = model(database, probe)
        let pending = Task { try await app.testConnection(connection.id, kind: .tools) }
        for _ in 0..<100 where probe.waiting == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(probe.waiting)
        XCTAssertTrue(app.updateConnectionCredential(connection.id, credential: "rotated-fixture"))
        probe.waiting?.resume()
        do { _ = try await pending.value; XCTFail("Old test must not apply") }
        catch { }
        XCTAssertNil(app.toolCapabilities[connection.id])
        app.stop()
    }

    func testRejectedResearchKeepsAQuestionForRetryWithoutCallingTools() {
        let chat = AnalysisChatModel()
        let connection = AIConnection(name: "text", kind: .openAIChat,
            baseURL: URL(string: "https://example.com/v1")!, model: "text", credentialAccount: "fixture")
        chat.send("研究问题", itemID: "item", evidence: "标题", connection: connection, credential: "fixture",
                  toolHandler: { _, _ in XCTFail("Rejected research must not execute a tool"); return "" },
                  researchRestriction: "工具调用测试未通过")
        XCTAssertFalse(chat.session(for: "item").isStreaming)
        XCTAssertEqual(chat.session(for: "item").messages.map(\.text), ["研究问题"])
        XCTAssertEqual(chat.session(for: "item").error, "工具调用测试未通过")
    }
}
