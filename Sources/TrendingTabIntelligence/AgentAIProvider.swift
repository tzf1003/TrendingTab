import Foundation
import TrendingTabCore

/// Adapts a Pi runtime to the existing application task interface.
public struct AgentAIProvider: AIProvider {
    public let connection: AIConnection
    private let credential: String
    private let bridge: AgentBridge
    private let lane: AgentTaskCoordinator.Lane
    private let headers: [String: String]

    public init(connection: AIConnection, credential: String, bridge: AgentBridge, headers: [String: String] = [:], lane: AgentTaskCoordinator.Lane = .foreground) {
        self.connection = connection
        self.credential = credential
        self.bridge = bridge
        self.headers = headers
        self.lane = lane
    }

    public func generate(system: String, prompt: String, json: Bool) async throws -> AIResult {
        let instruction = json ? system + "\n请仅输出有效 JSON。" : system
        let events = try await bridge.run(sessionID: UUID().uuidString, connection: connection,
                                          credential: credential, prompt: prompt, system: instruction, headers: headers, ephemeral: true,
                                          lane: lane, maxModelRequests: lane == .background ? 1 : 12)
        var text = ""
        var usage: AgentStreamEvent.Usage?
        var stopReason = ""
        for try await event in events {
            try Task.checkCancellation()
            if event.type == "text_delta" { text += event.text ?? "" }
            if event.type == "completed" {
                usage = event.usage
                stopReason = event.stopReason ?? ""
            }
        }
        guard !text.isEmpty, stopReason != "length" else { throw SourceFailure.unavailable("模型输出为空或已截断。") }
        return AIResult(text: text, usage: Self.accountUsage(usage, instruction: instruction, prompt: prompt,
                                                             text: text, maxOutput: connection.maxOutputTokens), finishReason: stopReason)
    }

    static func accountUsage(_ usage: AgentStreamEvent.Usage?, instruction: String, prompt: String,
                             text: String, maxOutput: Int) -> AIUsage {
        if let usage, usage.totalTokens > 0, [usage.input, usage.output, usage.cacheRead, usage.cacheWrite].allSatisfy({ $0 >= 0 }) {
            let (first, overflow1) = usage.input.addingReportingOverflow(usage.cacheRead)
            let (input, overflow2) = first.addingReportingOverflow(usage.cacheWrite)
            let (sum, overflow3) = input.addingReportingOverflow(usage.output)
            if !overflow1 && !overflow2 && !overflow3 {
                // Preserve a reported total even if a compatible gateway omits a component.
                return AIUsage(inputTokens: max(input, usage.totalTokens - usage.output), outputTokens: usage.output,
                               estimated: sum != usage.totalTokens)
            }
        }
        return AIUsage(inputTokens: prompt.utf8.count + 1024 + instruction.utf8.count,
                       outputTokens: max(1, maxOutput, text.utf8.count), estimated: true)
    }

    public func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        stream(system: system, messages: [AIMessage(role: .user, text: prompt)])
    }

    public func stream(system: String, messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let last = messages.last, last.role == .user else {
                        throw SourceFailure.unavailable("对话内容无效，请重新提问。")
                    }
                    let events = try await bridge.run(sessionID: UUID().uuidString, connection: connection,
                                                      credential: credential, prompt: last.text, system: system, headers: headers,
                                                      history: Array(messages.dropLast()), ephemeral: true, lane: lane)
                    var sawText = false
                    for try await event in events {
                        try Task.checkCancellation()
                        if event.type == "text_delta", let text = event.text {
                            sawText = sawText || !text.isEmpty
                            continuation.yield(text)
                        }
                        if event.type == "completed", event.stopReason == "length" {
                            throw SourceFailure.unavailable("模型输出已截断。")
                        }
                    }
                    guard sawText else { throw SourceFailure.unavailable("模型未返回文本。") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
