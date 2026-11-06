import Foundation
import TrendingTabCore

public enum AgentConnectionTest: String, CaseIterable, Sendable {
    case streaming, structured, tools
}

/// Each check sends one manual model request through the same Pi bridge used by the app.
public struct AgentConnectionTester: Sendable {
    private let bridge: AgentBridge
    public init(bridge: AgentBridge) { self.bridge = bridge }

    public func test(_ kind: AgentConnectionTest, connection: AIConnection, credential: String, headers: [String: String] = [:]) async throws -> String {
        let prompt: String
        switch kind {
        case .streaming: prompt = "请只回复：连接成功"
        case .structured: prompt = "请只输出 JSON 对象：{\"ok\":true}，不要添加其他内容。"
        case .tools: prompt = "请调用 open_ai_page 工具，地址为 https://example.com/；收到结果后简短回复。"
        }
        let stream = try await bridge.run(sessionID: UUID().uuidString, connection: connection, credential: credential,
                                          prompt: prompt, system: "这是连接测试，请按用户要求操作。", headers: headers,
                                          tools: kind == .tools ? [.openAIPage] : [], ephemeral: true)
        var text = ""
        var invoked = false
        for try await event in stream {
            try Task.checkCancellation()
            if event.type == "text_delta" { text += event.text ?? "" }
            if let request = event.toolRequest {
                guard kind == .tools, request.name == AgentToolName.openAIPage.rawValue else { throw TestError.invalidTool }
                invoked = true
                try await bridge.respondToTool(runID: event.runID, requestID: request.requestID, text: "连接测试已收到工具调用。")
            }
            if event.type == "completed", event.stopReason == "length" { throw TestError.truncated }
        }
        switch kind {
        case .streaming:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TestError.empty }
            return "流式连接成功。"
        case .structured:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == true else { throw TestError.invalidStructure }
            return "结构化输出测试成功。"
        case .tools:
            guard invoked else { throw TestError.missingTool }
            return "工具调用测试成功。"
        }
    }

    public enum TestError: LocalizedError {
        case invalidTool, missingTool, invalidStructure, truncated, empty
        public var errorDescription: String? {
            switch self {
            case .invalidTool: "模型请求了未提供的测试工具。"
            case .missingTool: "模型未调用测试工具，请检查模型是否支持工具调用。"
            case .invalidStructure: "模型未返回预期的 JSON 结构。"
            case .truncated: "测试输出被截断。"
            case .empty: "模型未返回文本。"
            }
        }
    }
}
