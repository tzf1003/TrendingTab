import Foundation
import TrendingTabCore

public enum AgentToolName: String, Encodable, CaseIterable, Sendable {
    case currentHotTopics = "current_hot_topics"
    case openCurrentStory = "open_current_story"
    case openAIPage = "open_ai_page"
    case listAIPages = "list_ai_pages"
    case readAIPage = "read_ai_page"
    case findAIPage = "find_ai_page"
    case observeAIPage = "observe_ai_page"
    case scrollAIPage = "scroll_ai_page"
    case expandAISection = "expand_ai_section"
    case openAIPageLink = "open_ai_page_link"
    case submitAIForm = "submit_ai_form"
    case clickAIButton = "click_ai_button"
    case fillAIField = "fill_ai_field"
    case readPublicArticle = "read_public_article"
    case searchWeb = "search_web"
    case openSearchResult = "open_search_result"
    case requestUserPage = "request_user_page"
    case waitForLogin = "wait_for_login"
    case mcpListTools = "mcp_list_tools"
    case mcpCallTool = "mcp_call_tool"
}

/// The caller constructs this from an explicitly configured connection. Sensitive
/// headers and environment values travel only through the private runtime pipe.
public struct AgentMCPServer: Codable, Sendable, Identifiable {
    public struct Configuration: Codable, Sendable {
        public var type: String
        public var url: String?
        public var headers: [String: String]?
        public var command: String?
        public var args: [String]?
        public var cwd: String?
        public var env: [String: String]?

        public init(type: String, url: String? = nil, headers: [String: String]? = nil,
                    command: String? = nil, args: [String]? = nil, cwd: String? = nil, env: [String: String]? = nil) {
            self.type = type; self.url = url; self.headers = headers; self.command = command
            self.args = args; self.cwd = cwd; self.env = env
        }
    }
    public var id: String
    public var name: String
    public var config: Configuration
    public var enabledTools: [String]

    public init(id: String, name: String, config: Configuration, enabledTools: [String]) {
        self.id = id; self.name = name; self.config = config; self.enabledTools = enabledTools
    }
}

public struct AgentMCPDiscovery: Decodable, Sendable {
    public struct Tool: Decodable, Sendable, Identifiable {
        public let name: String
        public let description: String
        public var id: String { name }
    }
    public let tools: [Tool]
    public let truncated: Bool
}

public struct AgentStreamEvent: Decodable, Sendable {
    public struct Usage: Decodable, Sendable {
        public let input: Int
        public let output: Int
        public let cacheRead: Int
        public let cacheWrite: Int
        public let totalTokens: Int
    }
    public struct ToolRequest: Decodable, Sendable {
        public let requestID: String
        public let toolCallID: String
        public let name: String
        public let arguments: [String: String]
    }
    public let runID: String
    public let sequence: Int
    public let type: String
    public let text: String?
    public let message: String?
    public let usage: Usage?
    public let modelRequests: Int?
    public let accountedTokens: Int?
    public let estimatedUsage: Bool?
    public let stopReason: String?
    public let toolRequest: ToolRequest?
}

public enum AgentBridgeError: LocalizedError {
    case unavailable(String), protocolViolation, processExited
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .protocolViolation: "Agent 通信数据无效。"
        case .processExited: "Agent 运行时已退出。"
        }
    }
}

/// Owns one application-scoped Pi process; credentials travel only over its private stdin.
public actor AgentBridge {
    private struct Request<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: String
        let method: String
        let params: Params
    }
    private struct RunParams: Encodable {
        struct Limits: Encodable { let maxRequests: Int }
        let runID, sessionID: String
        let connection: AIConnection
        let apiKey, prompt, system: String
        let headers: [String: String]
        let history: [AIMessage]
        let tools: [AgentToolName]
        let mcpServers: [AgentMCPServer]
        let ephemeral: Bool
        let limits: Limits
    }
    private struct CancelParams: Encodable { let runID: String }
    private struct CloseParams: Encodable { let sessionID: String }
    private struct ToolResultParams: Encodable { let runID, requestID, text: String }
    private struct DiscoverParams: Encodable { let config: AgentMCPServer.Configuration }
    private struct DiscoverCancelParams: Encodable { let requestID: String }
    private struct DiscoveryReply: Decodable { let result: AgentMCPDiscovery }
    private struct Message: Decodable {
        struct Failure: Decodable { let message: String }
        let id: String?
        let method: String?
        let params: AgentStreamEvent?
        let error: Failure?
    }

    private var executableURL: URL
    private var scriptURL: URL
    private var pendingRuntime: (executable: URL, script: URL)?
    private var runtimeRecovery: (@Sendable (URL) async -> (executable: URL, script: URL)?)?
    private var recoveryTask: Task<Void, Never>?
    private let coordinator = AgentTaskCoordinator()
    private var process: Process?
    private var stdin: FileHandle?
    private var generation: UUID?
    private var streams: [String: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation] = [:]
    private var permits: [String: AgentTaskCoordinator.Permit] = [:]
    private var cancellationWatchdogs: [String: Task<Void, Never>] = [:]
    private var lastSequences: [String: Int] = [:]
    private var requestRuns: [String: String] = [:]
    private var discoveryRequests: [String: CheckedContinuation<AgentMCPDiscovery, Error>] = [:]
    private let maximumFrame = 4 * 1024 * 1024

    public init(executableURL: URL, scriptURL: URL) {
        self.executableURL = executableURL
        self.scriptURL = scriptURL
    }

    deinit {
        recoveryTask?.cancel()
        if process?.isRunning == true { process?.terminate() }
    }

    public func setRuntimeRecovery(_ recovery: @escaping @Sendable (URL) async -> (executable: URL, script: URL)?) {
        runtimeRecovery = recovery
    }

    /// New tasks continue using the current process until existing work finishes.
    public func useRuntime(executable: URL, script: URL) {
        // Re-selecting the active runtime must not discard its in-memory sessions.
        // It also cancels an earlier pending switch, such as an update followed by
        // a rollback while a task is still running.
        if executable.standardizedFileURL == executableURL.standardizedFileURL,
           script.standardizedFileURL == scriptURL.standardizedFileURL {
            pendingRuntime = nil
            return
        }
        pendingRuntime = (executable, script)
        activatePendingRuntimeIfIdle()
    }

    private func activatePendingRuntimeIfIdle() {
        guard streams.isEmpty, discoveryRequests.isEmpty, let pending = pendingRuntime else { return }
        pendingRuntime = nil
        if let generation { disconnected(error: AgentBridgeError.processExited, generation: generation, recover: false) }
        executableURL = pending.executable
        scriptURL = pending.script
    }

    public func run(sessionID: String, connection: AIConnection, credential: String,
                    prompt: String, system: String, headers: [String: String] = [:], history: [AIMessage] = [], tools: [AgentToolName] = [], mcpServers: [AgentMCPServer] = [], ephemeral: Bool = false,
                    lane: AgentTaskCoordinator.Lane = .foreground, maxModelRequests: Int = 12) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        guard AIRequestHeaders.valid(headers) else { throw AIRequestHeaders.ValidationError.invalid }
        guard (1...12).contains(maxModelRequests) else { throw AgentBridgeError.protocolViolation }
        let permit = try await coordinator.acquire(lane)
        do {
            await recoveryTask?.value
            try Task.checkCancellation()
            try ensureStarted()
        } catch {
            await coordinator.release(permit)
            throw error
        }
        let runID = UUID().uuidString
        let requestID = UUID().uuidString
        let (stream, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
        streams[runID] = continuation
        permits[runID] = permit
        lastSequences[runID] = 0
        requestRuns[requestID] = runID
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel(runID: runID) }
        }
        do {
            try send(Request(id: requestID, method: "run", params: RunParams(
                runID: runID, sessionID: sessionID, connection: connection,
                apiKey: credential, prompt: prompt, system: system, headers: headers, history: history, tools: tools, mcpServers: mcpServers,
                ephemeral: ephemeral, limits: RunParams.Limits(maxRequests: maxModelRequests))))
        } catch {
            finishRun(runID, error: error)
        }
        return stream
    }

    /// Answers a pending request only while its owning run is still active.
    public func respondToTool(runID: String, requestID: String, text: String) throws {
        guard streams[runID] != nil else { throw CancellationError() }
        try send(Request(id: UUID().uuidString, method: "toolResult",
                         params: ToolResultParams(runID: runID, requestID: requestID, text: text)))
    }

    public func closeSession(_ sessionID: String) throws {
        guard process?.isRunning == true, recoveryTask == nil else { return }
        try send(Request(id: UUID().uuidString, method: "closeSession", params: CloseParams(sessionID: sessionID)))
    }

    public func discoverMCPTools(config: AgentMCPServer.Configuration) async throws -> AgentMCPDiscovery {
        await recoveryTask?.value
        try Task.checkCancellation()
        try ensureStarted()
        let requestID = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                discoveryRequests[requestID] = continuation
                do { try send(Request(id: requestID, method: "mcpDiscover", params: DiscoverParams(config: config))) }
                catch { discoveryRequests.removeValue(forKey: requestID)?.resume(throwing: error) }
            }
        } onCancel: {
            Task { await self.cancelDiscovery(requestID) }
        }
    }

    private func cancelDiscovery(_ requestID: String) {
        guard let continuation = discoveryRequests.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: CancellationError())
        try? send(Request(id: UUID().uuidString, method: "mcpDiscoverCancel", params: DiscoverCancelParams(requestID: requestID)))
        activatePendingRuntimeIfIdle()
    }

    private func cancel(runID: String) {
        guard streams[runID] != nil, cancellationWatchdogs[runID] == nil, let generation else { return }
        do { try send(Request(id: UUID().uuidString, method: "cancel", params: CancelParams(runID: runID))) }
        catch { disconnected(error: error, generation: generation); return }
        // Keep the permit until the process acknowledges termination. If it cannot
        // respond, stop the process so another task cannot overlap with a stuck run.
        cancellationWatchdogs[runID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.cancelTimedOut(runID: runID, generation: generation)
        }
    }

    private func cancelTimedOut(runID: String, generation: UUID) {
        guard self.generation == generation, streams[runID] != nil else { return }
        disconnected(error: AgentBridgeError.processExited, generation: generation)
    }

    private func finishRun(_ runID: String, error: Error? = nil) {
        let stream = streams.removeValue(forKey: runID)
        lastSequences.removeValue(forKey: runID)
        requestRuns = requestRuns.filter { $0.value != runID }
        cancellationWatchdogs.removeValue(forKey: runID)?.cancel()
        if let error { stream?.finish(throwing: error) } else { stream?.finish() }
        if let permit = permits.removeValue(forKey: runID) {
            Task { await coordinator.release(permit) }
        }
        activatePendingRuntimeIfIdle()
    }

    private func ensureStarted() throws {
        if process?.isRunning == true { return }
        if let generation {
            disconnected(error: AgentBridgeError.processExited, generation: generation)
            throw AgentBridgeError.processExited
        }
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.executableURL = executableURL
        child.arguments = [scriptURL.path]
        child.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.environment = ["PATH": "/usr/bin:/bin", "PI_OFFLINE": "1"]
        do { try child.run() }
        catch {
            beginRuntimeRecovery()
            throw AgentBridgeError.unavailable("无法启动 Agent 运行时。")
        }
        process = child
        let generation = UUID()
        self.generation = generation
        stdin = input.fileHandleForWriting
        let handle = output.fileHandleForReading
        let limit = maximumFrame
        // FileHandle's pipe reads are blocking. Give each process a dedicated
        // thread so idle runtimes cannot exhaust Swift's cooperative executor.
        Thread.detachNewThread { [weak self] in
            func deliver(_ operation: @escaping @Sendable (AgentBridge) async -> Void) {
                let delivered = DispatchSemaphore(value: 0)
                Task { [weak self] in
                    if let self { await operation(self) }
                    delivered.signal()
                }
                delivered.wait()
            }
            do {
                while true {
                    guard let header = try Self.readExactly(4, from: handle) else { break }
                    let length = header.reduce(0) { ($0 << 8) | Int($1) }
                    guard length > 0, length <= limit, let data = try Self.readExactly(length, from: handle) else {
                        throw AgentBridgeError.protocolViolation
                    }
                    deliver { await $0.receive(data, generation: generation) }
                }
                deliver { await $0.disconnected(error: AgentBridgeError.processExited, generation: generation) }
            } catch {
                deliver { await $0.disconnected(error: error, generation: generation) }
            }
        }
    }

    private nonisolated static func readExactly(_ length: Int, from file: FileHandle) throws -> Data? {
        var result = Data()
        while result.count < length {
            guard let part = try file.read(upToCount: length - result.count), !part.isEmpty else {
                if result.isEmpty { return nil }
                throw AgentBridgeError.protocolViolation
            }
            result.append(part)
        }
        return result
    }

    private func send<P: Encodable>(_ request: Request<P>) throws {
        let body = try JSONEncoder().encode(request)
        guard !body.isEmpty, body.count <= maximumFrame, let stdin else { throw AgentBridgeError.protocolViolation }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        try stdin.write(contentsOf: frame)
    }

    private func receive(_ data: Data, generation: UUID) {
        guard self.generation == generation else { return }
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else {
            disconnected(error: AgentBridgeError.protocolViolation, generation: generation)
            return
        }
        if let id = message.id, let discovery = discoveryRequests.removeValue(forKey: id) {
            if let failure = message.error { discovery.resume(throwing: AgentBridgeError.unavailable(failure.message)) }
            else if let result = try? JSONDecoder().decode(DiscoveryReply.self, from: data).result { discovery.resume(returning: result) }
            else { discovery.resume(throwing: AgentBridgeError.protocolViolation) }
            activatePendingRuntimeIfIdle()
            return
        }
        if let id = message.id, let runID = requestRuns.removeValue(forKey: id), let failure = message.error {
            finishRun(runID, error: AgentBridgeError.unavailable(failure.message))
            return
        }
        guard message.method == "event", let event = message.params, let stream = streams[event.runID] else { return }
        guard let last = lastSequences[event.runID], event.sequence > last else {
            disconnected(error: AgentBridgeError.protocolViolation, generation: generation)
            return
        }
        lastSequences[event.runID] = event.sequence
        switch event.type {
        case "completed":
            stream.yield(event)
            finishRun(event.runID)
        case "cancelled":
            finishRun(event.runID, error: CancellationError())
        case "error":
            finishRun(event.runID, error: AgentBridgeError.unavailable(event.message ?? "Agent 运行失败。"))
        default: stream.yield(event)
        }
    }

    private func disconnected(error: Error, generation: UUID, recover: Bool = true) {
        guard self.generation == generation else { return }
        self.generation = nil
        for stream in streams.values { stream.finish(throwing: error) }
        for watchdog in cancellationWatchdogs.values { watchdog.cancel() }
        cancellationWatchdogs.removeAll()
        let pendingPermits = Array(permits.values)
        permits.removeAll()
        Task { for permit in pendingPermits { await coordinator.release(permit) } }
        for discovery in discoveryRequests.values { discovery.resume(throwing: error) }
        discoveryRequests.removeAll()
        streams.removeAll()
        lastSequences.removeAll()
        requestRuns.removeAll()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        stdin = nil
        if recover && pendingRuntime == nil { beginRuntimeRecovery() }
        activatePendingRuntimeIfIdle()
    }

    private func beginRuntimeRecovery() {
        guard recoveryTask == nil, let runtimeRecovery else { return }
        let failedScript = scriptURL
        recoveryTask = Task { [weak self] in
            let fallback = await runtimeRecovery(failedScript)
            await self?.completeRuntimeRecovery(fallback, failedScript: failedScript)
        }
    }

    private func completeRuntimeRecovery(_ fallback: (executable: URL, script: URL)?, failedScript: URL) {
        recoveryTask = nil
        guard scriptURL == failedScript, let fallback else { return }
        useRuntime(executable: fallback.executable, script: fallback.script)
    }
}
