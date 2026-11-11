import Foundation
import TrendingTabCore
import TrendingTabNetworking
import TrendingTabSources

public struct AIUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var estimated: Bool
    public var total: Int { inputTokens + outputTokens }
}

public struct AIResult: Sendable {
    public var text: String
    public var usage: AIUsage
    public var finishReason: String
}

public struct AIMessage: Equatable, Sendable, Encodable {
    public enum Role: String, Sendable, Encodable { case user, assistant }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public protocol AIProvider: Sendable {
    var connection: AIConnection { get }
    func generate(system: String, prompt: String, json: Bool) async throws -> AIResult
    func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error>
    func stream(system: String, messages: [AIMessage]) -> AsyncThrowingStream<String, Error>
}

public extension AIProvider {
    func stream(system: String, messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        guard messages.count == 1, let message = messages.first, message.role == .user else {
            return AsyncThrowingStream { $0.finish(throwing: SourceFailure.unavailable("此 AI 服务不支持多轮对话")) }
        }
        return stream(system: system, prompt: message.text)
    }
}

public struct AnyAIProvider: AIProvider {
    public var connection: AIConnection
    private let transport: any HTTPTransport
    private let credential: String
    private let session: URLSession
    private let additionalHeaders: [String: String]

    public init(connection: AIConnection, credential: String, transport: any HTTPTransport,
                session: URLSession = .shared, additionalHeaders: [String: String] = [:]) {
        self.connection = connection
        self.credential = credential
        self.transport = transport
        self.session = session
        self.additionalHeaders = additionalHeaders
    }

    public func generate(system: String, prompt: String, json: Bool) async throws -> AIResult {
        switch connection.kind {
        case .openAIResponses: try await openAIResponses(system: system, prompt: prompt, json: json)
        case .openAIChat: try await openAIChat(system: system, prompt: prompt, json: json)
        case .anthropicMessages: try await anthropic(system: system, prompt: prompt)
        }
    }

    public func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        stream(system: system, messages: [AIMessage(role: .user, text: prompt)])
    }

    public func stream(system: String, messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let request = try streamRequest(system: system, messages: messages)
                    let (bytes, response) = try await session.bytes(for: request)
                    defer { bytes.task.cancel() }
                    guard let http = response as? HTTPURLResponse else {
                        throw SourceFailure.network("AI 流式响应类型无效")
                    }
                    guard (200...299).contains(http.statusCode) else {
                        throw SourceFailure.network("AI 流式请求失败（HTTP \(http.statusCode)）")
                    }
                    // AsyncBytes.lines omits the blank lines that delimit SSE events.
                    var parser = SSEParser()
                    var hasText = false
                    for try await byte in bytes {
                        guard let event = parser.consume(byte) else { continue }
                        try Task.checkCancellation()
                        switch try Self.streamEvent(event, kind: connection.kind) {
                        case .text(let text):
                            hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            if case .terminated = continuation.yield(text) { return }
                        case .finished:
                            guard hasText else { throw SourceFailure.network("AI 未返回可显示的内容，请重试") }
                            continuation.finish()
                            return
                        case .ignored:
                            continue
                        }
                    }
                    try Task.checkCancellation()
                    throw SourceFailure.network("AI 响应提前结束，请重试")
                } catch let failure as SourceFailure {
                    continuation.finish(throwing: failure)
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else if (error as? URLError)?.code == .timedOut {
                        continuation.finish(throwing: SourceFailure.timeout)
                    } else {
                        continuation.finish(throwing: SourceFailure.network("AI 连接中断，请重试"))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func openAIResponses(system: String, prompt: String, json: Bool) async throws -> AIResult {
        var body: [String: Any] = [
            "model": connection.model,
            "store": false,
            "max_output_tokens": connection.maxOutputTokens,
            "input": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ]
        if json { body["text"] = ["format": ["type": "json_object"]] }
        let response = try await send(path: "responses", body: body)
        let root = try JSONValues.object(response.data)
        let text = JSONValues.string(root["output_text"]) ?? Self.collectResponses(root)
        return AIResult(text: text, usage: Self.usage(root["usage"]), finishReason: JSONValues.string(root["status"]) ?? "completed")
    }

    private func openAIChat(system: String, prompt: String, json: Bool) async throws -> AIResult {
        var body: [String: Any] = [
            "model": connection.model,
            "store": false,
            "max_tokens": connection.maxOutputTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        let response = try await send(path: "chat/completions", body: body)
        let root = try JSONValues.object(response.data)
        let choice = (root["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        return AIResult(text: JSONValues.string(message?["content"]) ?? "", usage: Self.usage(root["usage"]), finishReason: JSONValues.string(choice?["finish_reason"]) ?? "stop")
    }

    private func anthropic(system: String, prompt: String) async throws -> AIResult {
        let body: [String: Any] = [
            "model": connection.model,
            "max_tokens": connection.maxOutputTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        let response = try await send(path: "messages", body: body, extraHeaders: ["x-api-key": credential, "anthropic-version": "2023-06-01"])
        let root = try JSONValues.object(response.data)
        let blocks = root["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { JSONValues.string($0["text"]) }.joined()
        return AIResult(text: text, usage: Self.usage(root["usage"]), finishReason: JSONValues.string(root["stop_reason"]) ?? "end_turn")
    }

    private func send(path: String, body: [String: Any], extraHeaders: [String: String] = [:]) async throws -> HTTPResponse {
        var headers = ["Authorization": "Bearer \(credential)", "Content-Type": "application/json"]
        headers.merge(extraHeaders) { _, new in new }
        let response = try await transport.send(HTTPRequest(url: endpoint(path), method: "POST", headers: mergedHeaders(headers), body: try JSONSerialization.data(withJSONObject: body), timeout: connection.timeout, includeConditionalHeaders: false))
        if let failure = HTTPMapping.failure(for: response) { throw failure }
        return response
    }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(connection.baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    private func mergedHeaders(_ defaults: [String: String]) -> [String: String] {
        var headers = defaults
        for (name, value) in additionalHeaders {
            if let key = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                headers.removeValue(forKey: key)
            }
            headers[name] = value
        }
        return headers
    }

    private func streamRequest(system: String, messages: [AIMessage]) throws -> URLRequest {
        let history = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let systemHistory = [["role": "system", "content": system]] + history
        let path: String
        var body: [String: Any] = ["model": connection.model, "stream": true]
        var headers = ["Content-Type": "application/json", "Accept": "text/event-stream"]
        switch connection.kind {
        case .openAIResponses:
            path = "responses"
            body["store"] = false
            body["max_output_tokens"] = connection.maxOutputTokens
            body["input"] = systemHistory
        case .openAIChat:
            path = "chat/completions"
            body["store"] = false
            body["max_tokens"] = connection.maxOutputTokens
            body["messages"] = systemHistory
        case .anthropicMessages:
            path = "messages"
            body["max_tokens"] = connection.maxOutputTokens
            body["system"] = system
            body["messages"] = history
        }
        if connection.kind == .anthropicMessages {
            headers["x-api-key"] = credential
            headers["anthropic-version"] = "2023-06-01"
        } else {
            headers["Authorization"] = "Bearer \(credential)"
        }
        var request = URLRequest(url: endpoint(path), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: connection.timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (name, value) in mergedHeaders(headers) { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    static func usage(_ value: Any?) -> AIUsage {
        guard let usage = value as? [String: Any] else { return AIUsage(inputTokens: 800, outputTokens: 400, estimated: true) }
        let input = JSONValues.double(usage["input_tokens"] ?? usage["prompt_tokens"])
        let output = JSONValues.double(usage["output_tokens"] ?? usage["completion_tokens"])
        guard let input, let output else { return AIUsage(inputTokens: 800, outputTokens: 400, estimated: true) }
        return AIUsage(inputTokens: Int(input), outputTokens: Int(output), estimated: false)
    }

    static func collectResponses(_ root: [String: Any]) -> String {
        let output = root["output"] as? [[String: Any]] ?? []
        return output.flatMap { item in
            (item["content"] as? [[String: Any]] ?? []).compactMap { JSONValues.string($0["text"]) }
        }.joined()
    }

    private enum StreamEvent {
        case text(String)
        case finished
        case ignored
    }

    private static func streamEvent(_ event: SSEParser.Event, kind: AIProtocolKind) throws -> StreamEvent {
        if event.name == "error" { throw SourceFailure.network("AI 服务返回流式错误") }
        if event.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return .finished }
        guard let root = try? JSONValues.object(Data(event.data.utf8)) else {
            throw SourceFailure.schemaChanged("AI 流式事件格式无效")
        }
        let type = (root["type"] as? String) ?? event.name
        if type == "error" || type == "response.failed" || (root["error"] != nil && !(root["error"] is NSNull)) {
            throw SourceFailure.network("AI 服务返回流式错误")
        }

        let text: String?
        switch kind {
        case .openAIResponses:
            switch type {
            case "response.completed": return .finished
            case "response.incomplete": throw SourceFailure.network("AI 回答被截断")
            case "response.output_text.delta", "response.refusal.delta", nil:
                text = root["delta"] as? String ?? (root["delta"] as? [String: Any])?["text"] as? String
            default: return .ignored
            }
        case .openAIChat:
            let choice = (root["choices"] as? [[String: Any]])?.first
            switch choice?["finish_reason"] as? String {
            case "length": throw SourceFailure.network("AI 回答达到输出长度上限")
            case "content_filter": throw SourceFailure.network("AI 服务过滤了回答")
            default: break
            }
            let delta = choice?["delta"] as? [String: Any]
            text = [delta?["content"] as? String, delta?["refusal"] as? String].compactMap { $0 }.joined()
        case .anthropicMessages:
            let delta = root["delta"] as? [String: Any]
            switch type {
            case "message_stop": return .finished
            case "message_delta":
                let reason = delta?["stop_reason"] as? String
                if reason == "max_tokens" || reason == "model_context_window_exceeded" {
                    throw SourceFailure.network("AI 回答达到长度上限")
                }
                return .ignored
            case "content_block_delta", nil:
                text = delta?["text"] as? String
            default: return .ignored
            }
        }
        guard let text, !text.isEmpty else { return .ignored }
        return .text(text)
    }
}

private struct SSEParser {
    struct Event {
        let name: String?
        let data: String
    }

    private var line: [UInt8] = []
    private var name: String?
    private var data: [String] = []
    private var skipLF = false

    mutating func consume(_ byte: UInt8) -> Event? {
        if skipLF {
            skipLF = false
            if byte == 0x0A { return nil }
        }
        guard byte == 0x0A || byte == 0x0D else {
            line.append(byte)
            return nil
        }
        skipLF = byte == 0x0D
        if line.isEmpty {
            defer {
                name = nil
                data.removeAll(keepingCapacity: true)
            }
            return data.isEmpty ? nil : Event(name: name, data: data.joined(separator: "\n"))
        }

        let value = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        let colon = value.firstIndex(of: ":") ?? value.endIndex
        let field = value[..<colon]
        var content = colon == value.endIndex ? "" : value[value.index(after: colon)...]
        if content.first == " " { content = content.dropFirst() }
        switch field {
        case "event": name = String(content)
        case "data": data.append(String(content))
        default: break
        }
        return nil
    }
}

public enum AssessmentParser {
    public static func parse(_ text: String, allowedEvidence: Set<String>, allowedTopics: Set<UUID>) throws -> ModelAssessment {
        guard let root = try? JSONValues.object(ModelJSON.data(text)) else {
            throw SourceFailure.schemaChanged("模型输出不是 JSON")
        }
        guard let importance = JSONValues.double(root["importance"]), importance.isFinite, (0...100).contains(importance),
              let confidence = JSONValues.double(root["confidence"]), confidence.isFinite, (0...1).contains(confidence),
              let summary = JSONValues.string(root["summary"]), !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceFailure.schemaChanged("模型输出缺少必要字段")
        }
        guard let evidence = root["evidenceIDs"] as? [String], !evidence.isEmpty,
              evidence.allSatisfy(allowedEvidence.contains) else {
            throw SourceFailure.schemaChanged("模型引用了未知证据")
        }
        let topics = (root["matchedTopicIDs"] as? [String] ?? []).compactMap(UUID.init).filter(allowedTopics.contains)
        return ModelAssessment(importance: Int(importance), confidence: confidence, category: JSONValues.string(root["category"]) ?? "未分类", summary: summary, reason: JSONValues.string(root["reason"]) ?? "", evidenceIDs: evidence, matchedTopicIDs: topics)
    }

    public static func qualifiesAsMajor(_ assessment: ModelAssessment, evidenceSources: [String: String],
                                        authoritativeSources: Set<String>) -> Bool {
        let citedSources = Set(assessment.evidenceIDs.compactMap { evidenceSources[$0] })
        return qualifiesAsMajor(importance: assessment.importance, confidence: assessment.confidence,
                                citedSources: citedSources, authoritativeSources: authoritativeSources)
    }

    public static func qualifiesAsMajor(importance: Int?, confidence: Double?, citedSources: Set<String>,
                                        authoritativeSources: Set<String>) -> Bool {
        (importance ?? 0) >= 75 && (confidence ?? 0) >= 0.8 &&
            (citedSources.count >= 2 || !citedSources.isDisjoint(with: authoritativeSources))
    }
}
