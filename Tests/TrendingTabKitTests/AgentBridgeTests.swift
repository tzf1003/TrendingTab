import Foundation
import XCTest
import TrendingTabCore
@testable import TrendingTabIntelligence
import TrendingTabKit

final class AgentBridgeTests: XCTestCase {
    func testFailedRuntimeRecoversForNextTaskWithoutReplayingFailedTask() async throws {
        guard let node = ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_NODE"] else {
            throw XCTSkip("Set the Node path to exercise runtime recovery.")
        }
        let healthy = try XCTUnwrap(Bundle.module.url(forResource: "agent-delayed-cancel", withExtension: "mjs"))
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).mjs")
        try "process.exit(1)".write(to: broken, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: broken) }
        let bridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: broken)
        let recovered = expectation(description: "failed runtime is reported")
        await bridge.setRuntimeRecovery { failedScript in
            XCTAssertEqual(failedScript, broken)
            recovered.fulfill()
            return (URL(fileURLWithPath: node), healthy)
        }
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!,
                                      model: "mock", credentialAccount: "fixture")
        do {
            let stream = try await bridge.run(sessionID: "failed", connection: connection,
                credential: "fixture", prompt: "second", system: "test")
            for try await _ in stream { }
            XCTFail("The failed task must report its failure")
        } catch is AgentBridgeError { }
        let stream = try await bridge.run(sessionID: "recovered", connection: connection,
            credential: "fixture", prompt: "second", system: "test")
        var completed = false
        for try await event in stream { if event.type == "completed" { completed = true } }
        XCTAssertTrue(completed)
        await fulfillment(of: [recovered], timeout: 5)
    }

    @MainActor
    func testIdleRuntimeReadersDoNotStarveOtherTasks() async throws {
        guard let node = ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_NODE"] else {
            throw XCTSkip("Set TRENDINGTAB_TEST_NODE to exercise concurrent runtime readers.")
        }
        let script = try XCTUnwrap(Bundle.module.url(forResource: "agent-delayed-cancel", withExtension: "mjs"))
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!,
                                      model: "mock", credentialAccount: "fixture")
        var bridges: [AgentBridge] = []
        for index in 0..<12 {
            let bridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: script)
            let stream = try await bridge.run(sessionID: "idle-\(index)", connection: connection,
                                              credential: "fixture", prompt: "second", system: "test")
            for try await _ in stream { }
            bridges.append(bridge)
        }
        let completed = expectation(description: "another task runs while readers are idle")
        let followUp = Task {
            do {
                let stream = try await bridges[0].run(sessionID: "follow-up", connection: connection,
                                                      credential: "fixture", prompt: "second", system: "test")
                for try await event in stream where event.type == "completed" { completed.fulfill() }
            } catch { XCTFail("Follow-up failed: \(error)") }
        }
        await fulfillment(of: [completed], timeout: 5)
        followUp.cancel()
        withExtendedLifetime(bridges) { }
    }

    func testAutomaticUsageRemainsConservativeForMissingAndIncompleteReports() throws {
        func usage(_ input: Int, _ output: Int, _ read: Int, _ write: Int, _ total: Int) throws -> AgentStreamEvent.Usage {
            try JSONDecoder().decode(AgentStreamEvent.Usage.self, from: JSONSerialization.data(withJSONObject:
                ["input": input, "output": output, "cacheRead": read, "cacheWrite": write, "totalTokens": total]))
        }
        let missing = AgentAIProvider.accountUsage(nil, instruction: "a", prompt: "b", text: "c", maxOutput: 500)
        XCTAssertTrue(missing.estimated)
        XCTAssertEqual(missing.total, 1526)
        let partial = AgentAIProvider.accountUsage(try usage(2, 3, 0, 0, 20), instruction: "", prompt: "", text: "", maxOutput: 100)
        XCTAssertTrue(partial.estimated)
        XCTAssertEqual(partial.total, 20)
        let complete = AgentAIProvider.accountUsage(try usage(10, 3, 2, 0, 15), instruction: "", prompt: "", text: "", maxOutput: 100)
        XCTAssertFalse(complete.estimated)
        XCTAssertEqual(complete.total, 15)
    }

    @MainActor
    func testFollowUpPassesPriorEvidenceToPi() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let node = environment["TRENDINGTAB_TEST_NODE"], let runtime = environment["TRENDINGTAB_TEST_RUNTIME"] else {
            throw XCTSkip("Set the Pi runtime paths to exercise follow-up context.")
        }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "agent-model", withExtension: "mjs"))
        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: node)
        server.arguments = [fixture.path]
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let port = try XCTUnwrap(String(data: output.fileHandleForReading.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1")),
                                      model: "mock", credentialAccount: "fixture")
        let chat = AnalysisChatModel(agentBridge: AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: URL(fileURLWithPath: runtime)))
        func waitForAnswer() async throws {
            for _ in 0..<500 {
                if !chat.session(for: "item").isStreaming { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Timed out waiting for Pi response")
        }
        chat.send("第一问", itemID: "item", evidence: "标题", connection: connection, credential: "fixture-token")
        try await waitForAnswer()
        XCTAssertEqual(chat.session(for: "item").messages.last?.text, "测试回答")
        var ledger = ResearchEvidenceLedger()
        _ = ledger.register(itemID: "item", runID: "first", title: "报道", url: URL(string: "https://example.com/story")!,
                            level: .pageText, content: "先前研究证据")
        chat.send("追问证据", itemID: "item", evidence: ledger.followUpContext(itemID: "item"), connection: connection, credential: "fixture-token")
        try await waitForAnswer()
        XCTAssertEqual(chat.session(for: "item").messages.last?.text, "证据已传递")
    }
    @MainActor
    func testCancelledRunHoldsItsLaneUntilRuntimeStops() async throws {
        guard let node = ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_NODE"] else {
            throw XCTSkip("Set TRENDINGTAB_TEST_NODE to exercise the bridge.")
        }
        let script = try XCTUnwrap(Bundle.module.url(forResource: "agent-delayed-cancel", withExtension: "mjs"))
        let bridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: script)
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!,
                                      model: "mock", credentialAccount: "fixture")
        let started = expectation(description: "first run started")
        let first = try await bridge.run(sessionID: "first", connection: connection, credential: "fixture", prompt: "first", system: "test")
        let consumer = Task {
            do {
                for try await event in first where event.type == "text_delta" { started.fulfill() }
            } catch { }
        }
        await fulfillment(of: [started], timeout: 3)
        consumer.cancel()
        let finished = expectation(description: "second run finished")
        var completed = false
        let next = Task {
            do {
                let second = try await bridge.run(sessionID: "second", connection: connection, credential: "fixture", prompt: "second", system: "test")
                for try await event in second where event.type == "completed" { completed = true }
            } catch { }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
        next.cancel()
        XCTAssertTrue(completed)
        await consumer.value
        await next.value
    }

    @MainActor
    func testUnresponsiveCancellationRestartsRuntimeAndReleasesLane() async throws {
        guard let node = ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_NODE"] else {
            throw XCTSkip("Set TRENDINGTAB_TEST_NODE to exercise the bridge.")
        }
        let script = try XCTUnwrap(Bundle.module.url(forResource: "agent-delayed-cancel", withExtension: "mjs"))
        let bridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: script)
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!,
                                      model: "mock", credentialAccount: "fixture")
        let started = expectation(description: "unresponsive run started")
        let first = try await bridge.run(sessionID: "stuck", connection: connection, credential: "fixture", prompt: "stuck", system: "test")
        let consumer = Task {
            do { for try await event in first where event.type == "text_delta" { started.fulfill() } }
            catch { }
        }
        await fulfillment(of: [started], timeout: 3)
        consumer.cancel()
        let finished = expectation(description: "replacement run finished")
        var completed = false
        let next = Task {
            do {
                let second = try await bridge.run(sessionID: "after-restart", connection: connection, credential: "fixture", prompt: "second", system: "test")
                for try await event in second where event.type == "completed" { completed = true }
            } catch { }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 9)
        next.cancel()
        XCTAssertTrue(completed)
        await consumer.value
        await next.value
    }

    func testBridgeRejectsRepeatedSequence() async throws {
        guard let node = ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_NODE"] else {
            throw XCTSkip("Set the Pi runtime test paths to exercise the bridge.")
        }
        let script = try XCTUnwrap(Bundle.module.url(forResource: "agent-invalid-sequence", withExtension: "mjs"))
        let bridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: script)
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: URL(string: "https://example.com/v1")!,
                                      model: "mock", credentialAccount: "fixture")
        let stream = try await bridge.run(sessionID: "test", connection: connection, credential: "fixture", prompt: "test", system: "test")
        do {
            for try await _ in stream { }
            XCTFail("Repeated sequence must fail the protocol")
        } catch AgentBridgeError.protocolViolation { }
    }
    @MainActor
    func testTaskCoordinatorAllowsForegroundAndBackgroundAndCancelsQueuedWork() async throws {
        let coordinator = AgentTaskCoordinator()
        let foreground = try await coordinator.acquire(.foreground)
        let background = try await coordinator.acquire(.background)
        let waiting = Task { try await coordinator.acquire(.foreground) }
        let cancelled = Task { try await coordinator.acquire(.foreground) }
        cancelled.cancel()
        do {
            let permit = try await cancelled.value
            await coordinator.release(permit)
            XCTFail("Cancelled work must not obtain a permit")
        } catch is CancellationError {
            // Expected: queued work never starts.
        }
        await coordinator.release(foreground)
        let next = try await waiting.value
        await coordinator.release(next)
        await coordinator.release(background)
    }

    @MainActor
    func testPiBridgeStreamsAndPreservesConversation() async throws {
        func checkpoint(_ name: String) {
            FileHandle.standardError.write(Data("Pi bridge integration: \(name)\n".utf8))
        }
        let environment = ProcessInfo.processInfo.environment
        guard let node = environment["TRENDINGTAB_TEST_NODE"],
              let runtime = environment["TRENDINGTAB_TEST_RUNTIME"] else {
            throw XCTSkip("Set TRENDINGTAB_TEST_NODE and TRENDINGTAB_TEST_RUNTIME to run the Pi integration test.")
        }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "agent-model", withExtension: "mjs"))
        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: node)
        server.arguments = [fixture.path]
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let portData = output.fileHandleForReading.availableData
        let port = try XCTUnwrap(String(data: portData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1"))
        let connection = AIConnection(name: "Fixture", kind: .openAIChat, baseURL: url,
                                      model: "mock", credentialAccount: "fixture")
        let bridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: URL(fileURLWithPath: runtime))
        func collect(_ prompt: String) async throws -> String {
            let stream = try await bridge.run(sessionID: "conversation", connection: connection,
                                              credential: "fixture-token", prompt: prompt, system: "测试")
            var text = ""
            var lastSequence = 0
            var completed = false
            for try await event in stream {
                XCTAssertGreaterThan(event.sequence, lastSequence)
                lastSequence = event.sequence
                if event.type == "text_delta" { text += event.text ?? "" }
                if event.type == "completed" {
                    completed = true
                    XCTAssertEqual(event.modelRequests, 1)
                    XCTAssertNotNil(event.usage)
                }
            }
            XCTAssertTrue(completed)
            return text
        }
        checkpoint("conversation")
        let first = try await collect("第一问")
        checkpoint("first answer received")
        await bridge.useRuntime(executable: URL(fileURLWithPath: node), script: URL(fileURLWithPath: runtime))
        checkpoint("same runtime selected")
        let second = try await collect("第二问")
        checkpoint("second answer received")
        XCTAssertEqual(first, "测试回答")
        XCTAssertEqual(second, "连续对话")
        try await bridge.closeSession("conversation")

        checkpoint("headers")
        let headerStream = try await bridge.run(sessionID: "headers", connection: connection, credential: "fixture-token",
                                                prompt: "检查请求头", system: "测试", headers: ["X-Fixture": "!literal-$HOME"], ephemeral: true)
        var headerAnswer = ""
        for try await event in headerStream where event.type == "text_delta" { headerAnswer += event.text ?? "" }
        XCTAssertEqual(headerAnswer, "请求头正确")

        checkpoint("native tool")
        let research = try await bridge.run(sessionID: "research", connection: connection,
                                            credential: "fixture-token", prompt: "调用工具", system: "测试",
                                            tools: [.openAIPage])
        var toolAnswer = ""
        var calledTool = false
        for try await event in research {
            if let request = event.toolRequest {
                calledTool = true
                XCTAssertEqual(request.name, "open_ai_page")
                XCTAssertEqual(request.arguments["url"], "https://example.com/")
                try await bridge.respondToTool(runID: event.runID, requestID: request.requestID, text: "来自原生端")
            }
            if event.type == "text_delta" { toolAnswer += event.text ?? "" }
        }
        XCTAssertTrue(calledTool)
        XCTAssertEqual(toolAnswer, "工具完成")

        checkpoint("concurrent runtime switch")
        let switchingBridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: URL(fileURLWithPath: runtime))
        let running = try await switchingBridge.run(sessionID: "switch", connection: connection,
            credential: "fixture-token", prompt: "调用工具", system: "测试", tools: [.openAIPage], ephemeral: true)
        let background = try await switchingBridge.run(sessionID: "switch-background", connection: connection,
            credential: "fixture-token", prompt: "调用工具", system: "测试", tools: [.openAIPage], ephemeral: true, lane: .background)
        var backgroundIterator = background.makeAsyncIterator()
        var backgroundRequest: AgentStreamEvent.ToolRequest?
        var backgroundRunID: String?
        while let event = try await backgroundIterator.next() {
            if let request = event.toolRequest {
                backgroundRequest = request
                backgroundRunID = event.runID
                break
            }
        }
        let heldRequest = try XCTUnwrap(backgroundRequest)
        let heldRunID = try XCTUnwrap(backgroundRunID)
        var completedWhileSwitchPending = false
        for try await event in running {
            if let request = event.toolRequest {
                await switchingBridge.useRuntime(executable: URL(fileURLWithPath: "/nonexistent/trendingtab-node"), script: URL(fileURLWithPath: runtime))
                try await switchingBridge.respondToTool(runID: event.runID, requestID: request.requestID, text: "来自原生端")
            }
            if event.type == "completed" { completedWhileSwitchPending = true }
        }
        XCTAssertTrue(completedWhileSwitchPending)
        // Finishing the foreground lane must not replace the runtime while the
        // background lane still owns an outstanding native tool request.
        try await switchingBridge.respondToTool(runID: heldRunID, requestID: heldRequest.requestID, text: "来自原生端")
        var backgroundCompleted = false
        while let event = try await backgroundIterator.next() {
            if event.type == "completed" { backgroundCompleted = true }
        }
        XCTAssertTrue(backgroundCompleted)
        do {
            _ = try await switchingBridge.run(sessionID: "after-switch", connection: connection,
                credential: "fixture-token", prompt: "第一问", system: "测试")
            XCTFail("The next task should use the newly selected runtime")
        } catch is AgentBridgeError { }

        checkpoint("runtime rollback")
        let rollbackBridge = AgentBridge(executableURL: URL(fileURLWithPath: node), scriptURL: URL(fileURLWithPath: runtime))
        let beforeRollback = try await rollbackBridge.run(sessionID: "rollback", connection: connection,
            credential: "fixture-token", prompt: "调用工具", system: "测试", tools: [.openAIPage], ephemeral: true)
        for try await event in beforeRollback {
            if let request = event.toolRequest {
                await rollbackBridge.useRuntime(executable: URL(fileURLWithPath: "/nonexistent/trendingtab-node"), script: URL(fileURLWithPath: runtime))
                await rollbackBridge.useRuntime(executable: URL(fileURLWithPath: node), script: URL(fileURLWithPath: runtime))
                try await rollbackBridge.respondToTool(runID: event.runID, requestID: request.requestID, text: "来自原生端")
            }
        }
        let afterRollback = try await rollbackBridge.run(sessionID: "after-rollback", connection: connection,
            credential: "fixture-token", prompt: "第一问", system: "测试", ephemeral: true)
        var rollbackAnswer = ""
        for try await event in afterRollback where event.type == "text_delta" { rollbackAnswer += event.text ?? "" }
        XCTAssertEqual(rollbackAnswer, "测试回答")

        checkpoint("MCP discovery and tools")
        let mcpFixture = URL(fileURLWithPath: runtime).deletingLastPathComponent().appendingPathComponent("test-mcp-server.mjs")
        let mcpServer = AgentMCPServer(id: "fixture", name: "测试服务",
            config: .init(type: "stdio", command: node, args: [mcpFixture.path], env: [:]), enabledTools: ["echo"])
        let discovered = try await bridge.discoverMCPTools(config: mcpServer.config)
        XCTAssertEqual(discovered.tools.map(\.name), ["echo", "disabled"])
        XCTAssertFalse(discovered.truncated)
        let slowConfig = AgentMCPServer.Configuration(type: "stdio", command: node,
            args: [mcpFixture.path], env: ["DELAY_INITIALIZE": "1"])
        let discoveryTask = Task { try await bridge.discoverMCPTools(config: slowConfig) }
        try await Task.sleep(for: .milliseconds(150))
        discoveryTask.cancel()
        do { _ = try await discoveryTask.value; XCTFail("Cancelled discovery must not succeed") }
        catch is CancellationError { }
        let mcpStream = try await bridge.run(sessionID: "mcp", connection: connection, credential: "fixture-token",
            prompt: "调用MCP", system: "测试", tools: [.mcpCallTool], mcpServers: [mcpServer], ephemeral: true)
        var mcpAnswer = ""
        var mcpApproval = false
        for try await event in mcpStream {
            if let request = event.toolRequest {
                XCTAssertEqual(request.name, "mcp_authorize")
                XCTAssertEqual(request.arguments["serverID"], "fixture")
                XCTAssertEqual(request.arguments["toolName"], "echo")
                mcpApproval = true
                try await bridge.respondToTool(runID: event.runID, requestID: request.requestID, text: "allow")
            }
            if event.type == "text_delta" { mcpAnswer += event.text ?? "" }
        }
        XCTAssertTrue(mcpApproval)
        XCTAssertEqual(mcpAnswer, "工具完成")

        checkpoint("chat and provider")
        let chat = AnalysisChatModel(agentBridge: bridge)
        chat.send("调用工具", itemID: "fixture", evidence: "测试材料", connection: connection,
                  credential: "fixture-token") { request, _ in
            XCTAssertEqual(request.name, "open_ai_page")
            return "来自原生端"
        }
        for _ in 0..<200 where chat.session(for: "fixture").isStreaming {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(chat.session(for: "fixture").error)
        XCTAssertEqual(chat.session(for: "fixture").messages.last?.text, "工具完成")
        XCTAssertEqual(chat.session(for: "fixture").modelRequests, 2)
        XCTAssertGreaterThan(chat.session(for: "fixture").usageTokens, 0)
        XCTAssertTrue(chat.session(for: "fixture").estimatedUsage)
        XCTAssertFalse(chat.session(for: "fixture").activityLog.isEmpty)

        chat.send("等待用量", itemID: "interrupted", evidence: "测试材料", connection: connection, credential: "fixture-token")
        for _ in 0..<200 where chat.session(for: "interrupted").modelRequests == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(chat.session(for: "interrupted").modelRequests, 1)
        XCTAssertGreaterThan(chat.session(for: "interrupted").usageTokens, 0)
        XCTAssertTrue(chat.session(for: "interrupted").estimatedUsage)
        chat.cancel(itemID: "interrupted")
        XCTAssertEqual(chat.session(for: "interrupted").modelRequests, 1)
        XCTAssertGreaterThan(chat.session(for: "interrupted").usageTokens, 0)

        chat.send("第一问", itemID: "typed", evidence: "测试材料", connection: connection, credential: "fixture-token")
        for _ in 0..<200 where chat.session(for: "typed").isStreaming { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(chat.session(for: "typed").messages.last?.text, "测试回答")
        XCTAssertEqual(chat.session(for: "typed").usageTokens, 15)
        XCTAssertFalse(chat.session(for: "typed").estimatedUsage)
        chat.send("第二问", itemID: "typed", evidence: "测试材料", connection: connection, credential: "fixture-token")
        for _ in 0..<200 where chat.session(for: "typed").isStreaming { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(chat.session(for: "typed").error)
        XCTAssertEqual(chat.session(for: "typed").messages.last?.text, "连续对话")
        XCTAssertEqual(chat.session(for: "typed").usageTokens, 30)
        XCTAssertEqual(chat.session(for: "typed").modelRequests, 2)
        XCTAssertFalse(chat.session(for: "typed").estimatedUsage)

        let provider = AgentAIProvider(connection: connection, credential: "fixture-token", bridge: bridge)
        let result = try await provider.generate(system: "测试", prompt: "第一问", json: false)
        XCTAssertEqual(result.text, "测试回答")
        XCTAssertGreaterThan(result.usage.total, 0)
        let now = Date()
        let topicItem = StoredItem(item: NormalizedItem(sourceID: "fixture", boardID: "fixture.hot", nativeID: "1",
                                                       title: "AI 产品发布", url: URL(string: "https://example.com/")!),
                                   firstSeenAt: now, lastSeenAt: now, previousRank: nil, contentHash: "1", historical: false)
        let batch = try SemanticTopicBatch(description: "AI 产品", items: [topicItem])
        let topicResult = try await AgentAIProvider(connection: connection, credential: "fixture-token", bridge: bridge, lane: .background)
            .generate(system: batch.system, prompt: batch.prompt, json: true)
        XCTAssertEqual(try batch.parse(topicResult.text), [topicItem.id])
        var continued = ""
        for try await delta in provider.stream(system: "测试", messages: [
            AIMessage(role: .user, text: "第一问"), AIMessage(role: .assistant, text: "测试回答"),
            AIMessage(role: .user, text: "第二问")
        ]) { continued += delta }
        XCTAssertEqual(continued, "连续对话")
        checkpoint("connection tests")
        let tester = AgentConnectionTester(bridge: bridge)
        for kind in AgentConnectionTest.allCases {
            let outcome = try await tester.test(kind, connection: connection, credential: "fixture-token")
            XCTAssertTrue(outcome.contains("成功"), outcome)
        }
    }
}
