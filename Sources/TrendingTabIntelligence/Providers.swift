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

public protocol AIProvider: Sendable {
    var connection: AIConnection { get }
    func generate(system: String, prompt: String, json: Bool) async throws -> AIResult
    func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error>
}

public struct AnyAIProvider: AIProvider {
    public var connection: AIConnection
    private let transport: any HTTPTransport
    private let credential: String

    public init(connection: AIConnection, credential: String, transport: any HTTPTransport) {
        self.connection = connection
        self.credential = credential
        self.transport = transport
    }

    public func generate(system: String, prompt: String, json: Bool) async throws -> AIResult {
        switch connection.kind {
        case .openAIResponses: try await openAIResponses(system: system, prompt: prompt, json: json)
        case .openAIChat: try await openAIChat(system: system, prompt: prompt, json: json)
        case .anthropicMessages: try await anthropic(system: system, prompt: prompt)
        }
    }

    public func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.streamRequest(system: system, prompt: prompt)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        throw SourceFailure.network("流式请求失败")
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let text = Self.streamText(Data(payload.utf8), kind: self.connection.kind) {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
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
        let root = connection.baseURL.absoluteString.hasSuffix("/") ? connection.baseURL : connection.baseURL.appendingPathComponent("")
        let url = URL(string: path, relativeTo: root)!.absoluteURL
        var headers = ["Authorization": "Bearer \(credential)", "Content-Type": "application/json"]
        headers.merge(extraHeaders) { _, new in new }
        let response = try await transport.send(HTTPRequest(url: url, method: "POST", headers: headers, body: try JSONSerialization.data(withJSONObject: body), timeout: connection.timeout, includeConditionalHeaders: false))
        if let failure = HTTPMapping.failure(for: response) { throw failure }
        return response
    }

    private func streamRequest(system: String, prompt: String) throws -> URLRequest {
        let path: String
        let body: [String: Any]
        switch connection.kind {
        case .openAIResponses:
            path = "responses"
            body = ["model": connection.model, "stream": true, "store": false, "input": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        case .openAIChat:
            path = "chat/completions"
            body = ["model": connection.model, "stream": true, "store": false, "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        case .anthropicMessages:
            path = "messages"
            body = ["model": connection.model, "stream": true, "max_tokens": connection.maxOutputTokens, "system": system, "messages": [["role": "user", "content": prompt]]]
        }
        let url = URL(string: path, relativeTo: connection.baseURL)!.absoluteURL
        var request = URLRequest(url: url, timeoutInterval: connection.timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if connection.kind == .anthropicMessages {
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
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

    static func streamText(_ data: Data, kind: AIProtocolKind) -> String? {
        guard let root = try? JSONValues.object(data) else { return nil }
        switch kind {
        case .openAIResponses:
            return JSONValues.string(root["delta"]) ?? JSONValues.string((root["delta"] as? [String: Any])?["text"])
        case .openAIChat:
            let choice = (root["choices"] as? [[String: Any]])?.first
            return JSONValues.string((choice?["delta"] as? [String: Any])?["content"])
        case .anthropicMessages:
            return JSONValues.string((root["delta"] as? [String: Any])?["text"]) ?? JSONValues.string(root["delta"])
        }
    }
}

public enum AssessmentParser {
    public static func parse(_ text: String, allowedEvidence: Set<String>, allowedTopics: Set<UUID>) throws -> ModelAssessment {
        guard let data = text.data(using: .utf8), let root = try? JSONValues.object(data) else {
            throw SourceFailure.schemaChanged("模型输出不是 JSON")
        }
        guard let importance = JSONValues.double(root["importance"]), let confidence = JSONValues.double(root["confidence"]), let summary = JSONValues.string(root["summary"]) else {
            throw SourceFailure.schemaChanged("模型输出缺少必要字段")
        }
        let evidence = (root["evidenceIDs"] as? [String] ?? []).filter(allowedEvidence.contains)
        guard evidence.count == (root["evidenceIDs"] as? [String] ?? []).count else {
            throw SourceFailure.schemaChanged("模型引用了未知证据")
        }
        let topics = (root["matchedTopicIDs"] as? [String] ?? []).compactMap(UUID.init).filter(allowedTopics.contains)
        return ModelAssessment(importance: Int(importance), confidence: confidence, category: JSONValues.string(root["category"]) ?? "未分类", summary: summary, reason: JSONValues.string(root["reason"]) ?? "", evidenceIDs: evidence, matchedTopicIDs: topics)
    }
}
