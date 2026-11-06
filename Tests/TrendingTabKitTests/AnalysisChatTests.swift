import Foundation
import XCTest
import TrendingTabCore
import TrendingTabIntelligence
import TrendingTabKit
import TrendingTabNetworking

final class AnalysisChatTests: XCTestCase {
    func testLegacyStreamRetainsBasePath() async throws {
        let fixture = ChatFixture([.init(Self.chat("回答"))])
        let provider = Self.provider(.openAIChat, fixture)
        let text = try await Self.collect(provider.stream(system: "system", prompt: "question"))
        XCTAssertEqual(text, "回答")
        XCTAssertEqual(fixture.requests.first?.url?.path, "/gateway/v1/chat/completions")
    }

    @MainActor
    func testRefusalIsVisibleAndEmptyCompletionOffersRetry() async throws {
        let refusal = "data: {\"choices\":[{\"delta\":{\"refusal\":\"无法回答此问题\"}}]}\n\ndata: [DONE]\n\n"
        let fixture = ChatFixture([.init(refusal), .init("data: [DONE]\n\n"), .init(Self.chat("已恢复"))])
        let text = try await Self.collect(Self.provider(.openAIChat, fixture).stream(system: "system", prompt: "question"))
        XCTAssertEqual(text, "无法回答此问题")
        let model = AnalysisChatModel(session: fixture.session)
        let connection = Self.connection(.openAIChat, fixture)
        model.send("问题", itemID: "a", evidence: "证据", connection: connection, credential: "fixture-token")
        try await waitUntil { !model.session(for: "a").isStreaming }
        XCTAssertNotNil(model.session(for: "a").error)
        model.retry(itemID: "a", evidence: "证据", connection: connection, credential: "fixture-token")
        try await waitUntil { !model.session(for: "a").isStreaming }
        XCTAssertEqual(model.session(for: "a").messages.map(\.text), ["问题", "已恢复"])
    }

    func testTypedHistoryUsesEachProtocolAndPreservesHeadersAndTokenLimit() async throws {
        let cases: [(AIProtocolKind, String, String, String, String)] = [
            (.openAIResponses, "responses", "input", "max_output_tokens",
             "event: response.output_text.delta\r\ndata: {\"delta\":\r\ndata: \" 后\"}\r\n\r\n" +
             "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"hidden\"}\n\n" +
             "data: {\"type\":\"response.completed\"}\n\n"),
            (.openAIChat, "chat/completions", "messages", "max_tokens", Self.chat(" 后")),
            (.anthropicMessages, "messages", "messages", "max_tokens",
             "event: ping\ndata: {\"type\":\"ping\"}\n\n" +
             "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" 后\"}}\n\n" +
             "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"),
        ]
        for (kind, path, historyKey, limitKey, payload) in cases {
            let fixture = ChatFixture([.init(payload)])
            let provider = Self.provider(kind, fixture, trailingSlash: kind == .anthropicMessages)
            let stream = provider.stream(system: "evidence", messages: [
                .init(role: .user, text: "first"), .init(role: .assistant, text: "answer"),
                .init(role: .user, text: "next"),
            ])
            let text = try await Self.collect(stream)
            XCTAssertEqual(text, " 后", "\(kind)")
            let request = try XCTUnwrap(fixture.requests.first)
            XCTAssertEqual(request.url?.path, "/gateway/v1/\(path)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test-Routing"), "chat")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            let body = try Self.body(request)
            XCTAssertEqual(body[limitKey] as? Int, 321)
            let history = try XCTUnwrap(body[historyKey] as? [[String: String]])
            if kind == .anthropicMessages {
                XCTAssertEqual(body["system"] as? String, "evidence")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(history.compactMap { $0["role"] }, ["user", "assistant", "user"])
                XCTAssertEqual(history.compactMap { $0["content"] }, ["first", "answer", "next"])
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
                XCTAssertEqual(body["store"] as? Bool, false)
                XCTAssertEqual(history.compactMap { $0["role"] }, ["system", "user", "assistant", "user"])
                XCTAssertEqual(history.compactMap { $0["content"] }, ["evidence", "first", "answer", "next"])
            }
        }
    }

    func testLegacyStreamFailsAfterPartialTextWhenServerSendsError() async throws {
        let fixture = ChatFixture([.init(
            Self.delta("部分") + "event: error\ndata: {\"error\":{\"message\":\"fixture-token\"}}\n\n"
        )])
        let provider = Self.provider(.openAIChat, fixture)
        var text = ""
        do {
            for try await delta in provider.stream(system: "system", prompt: "question") { text += delta }
            XCTFail("Expected an SSE error")
        } catch let failure as SourceFailure {
            XCTAssertEqual(text, "部分")
            XCTAssertFalse(failure.message.contains("fixture-token"))
        }
    }

    func testProtocolTruncationAndMissingTerminalEventFail() async throws {
        let cases: [(AIProtocolKind, String)] = [
            (.openAIResponses, "data: {\"type\":\"response.incomplete\"}\n\n"),
            (.openAIChat, Self.delta("partial")),
            (.openAIChat, "data: {\"choices\":[{\"finish_reason\":\"length\",\"delta\":{}}]}\n\ndata: [DONE]\n\n"),
            (.anthropicMessages, "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\n" +
             "event: message_stop\ndata: {}\n\n"),
        ]
        for (kind, payload) in cases {
            let fixture = ChatFixture([.init(payload)])
            do {
                _ = try await Self.collect(Self.provider(kind, fixture).stream(system: "system", prompt: "question"))
                XCTFail("Expected a truncated stream for \(kind)")
            } catch let failure as SourceFailure {
                XCTAssertFalse(failure.message.isEmpty)
            }
        }
    }

    @MainActor
    func testItemsStreamIndependentlyAndRetryReplacesCanceledPartial() async throws {
        let fixture = ChatFixture([
            .init(Self.delta("甲的部分"), open: true), .init(Self.chat("乙的回答")),
            .init(Self.chat("甲的回答")), .init(Self.chat("追问的回答")),
            .init(Self.delta("榜外的部分"), open: true),
        ])
        let model = AnalysisChatModel(session: fixture.session)
        let connection = Self.connection(.openAIChat, fixture)
        func send(_ text: String, _ id: String, evidence: String = "甲的证据") {
            model.send(text, itemID: id, evidence: evidence, connection: connection, credential: "fixture-token")
        }

        send("甲的问题", "a")
        try await waitUntil { model.session(for: "a").messages.last?.text == "甲的部分" }
        XCTAssertTrue(model.session(for: "a").isStreaming)
        send("重复发送", "a")
        send("乙的问题", "b", evidence: "乙的证据")
        try await waitUntil { !model.session(for: "b").isStreaming }
        XCTAssertTrue(model.session(for: "a").isStreaming)
        XCTAssertEqual(model.session(for: "b").messages.map(\.text), ["乙的问题", "乙的回答"])
        let bHistory = try Self.history(XCTUnwrap(fixture.requests.dropFirst(1).first))
        XCTAssertEqual(bHistory.dropFirst().compactMap { $0["content"] }, ["乙的问题"])
        XCTAssertTrue(bHistory.first?["content"]?.contains("乙的证据") == true)
        XCTAssertEqual(fixture.requests.count, 2)

        model.cancel(itemID: "a")
        XCTAssertFalse(model.session(for: "a").isStreaming)
        XCTAssertNotNil(model.session(for: "a").error, "The chat UI needs a status to offer retry after stopping")
        XCTAssertEqual(model.session(for: "a").messages.map(\.text), ["甲的问题", "甲的部分"])
        try await waitUntil { fixture.stoppedOpenRequests == 1 }

        model.retry(itemID: "a", evidence: "甲的证据", connection: connection, credential: "fixture-token")
        try await waitUntil { !model.session(for: "a").isStreaming }
        XCTAssertEqual(model.session(for: "a").messages.map(\.text), ["甲的问题", "甲的回答"])
        XCTAssertEqual(try Self.history(XCTUnwrap(fixture.requests.dropFirst(2).first)).dropFirst().compactMap { $0["content"] }, ["甲的问题"])
        send("甲的追问", "a", evidence: "甲的新证据")
        try await waitUntil { !model.session(for: "a").isStreaming }
        XCTAssertEqual(model.session(for: "a").messages.map(\.role), [.user, .assistant, .user, .assistant])
        let followup = try Self.history(XCTUnwrap(fixture.requests.dropFirst(3).first))
        XCTAssertTrue(followup.first?["content"]?.contains("甲的新证据") == true)
        XCTAssertEqual(followup.dropFirst().compactMap { $0["content"] }, ["甲的问题", "甲的回答", "甲的追问"])

        send("榜外的问题", "c")
        try await waitUntil { model.session(for: "c").messages.last?.text == "榜外的部分" }
        model.retain(itemIDs: ["a"])
        try await waitUntil { fixture.stoppedOpenRequests == 2 }
        XCTAssertEqual(Set(model.sessions.keys), ["a"])
        XCTAssertTrue(model.session(for: "b").messages.isEmpty)
        model.clearAll()
        XCTAssertTrue(model.sessions.isEmpty)
    }

    @MainActor
    func testConfigurationAndStreamErrorsCanRetryWithoutAddingMessages() async throws {
        let fixture = ChatFixture([.init(Self.delta("部分")), .init(Self.chat("已恢复"))])
        let model = AnalysisChatModel(session: fixture.session)
        let connection = Self.connection(.openAIChat, fixture)
        model.send("问题", itemID: "a", evidence: "证据", connection: nil, credential: nil)
        XCTAssertFalse(model.session(for: "a").isStreaming)
        XCTAssertNotNil(model.session(for: "a").error)
        XCTAssertEqual(model.session(for: "a").messages.map(\.role), [.user])
        XCTAssertTrue(fixture.requests.isEmpty)

        model.retry(itemID: "a", evidence: "证据", connection: connection, credential: "fixture-token")
        try await waitUntil { !model.session(for: "a").isStreaming }
        XCTAssertNotNil(model.session(for: "a").error)
        XCTAssertEqual(model.session(for: "a").messages.map(\.text), ["问题", "部分"])

        model.retry(itemID: "a", evidence: "证据", connection: connection, credential: "fixture-token")
        try await waitUntil { !model.session(for: "a").isStreaming }
        XCTAssertNil(model.session(for: "a").error)
        XCTAssertEqual(model.session(for: "a").messages.map(\.text), ["问题", "已恢复"])
        XCTAssertEqual(fixture.requests.count, 2)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestTimeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct TestTimeout: Error {}

    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await delta in stream { text += delta }
        return text
    }

    private static func provider(_ kind: AIProtocolKind, _ fixture: ChatFixture, trailingSlash: Bool = false) -> AnyAIProvider {
        AnyAIProvider(connection: connection(kind, fixture, trailingSlash: trailingSlash), credential: "fixture-token",
                      transport: URLSessionTransport(), session: fixture.session,
                      additionalHeaders: ["X-Test-Routing": "chat"])
    }

    private static func connection(_ kind: AIProtocolKind, _ fixture: ChatFixture, trailingSlash: Bool = false) -> AIConnection {
        let url = URL(string: "https://\(fixture.host)/gateway/v1\(trailingSlash ? "/" : "")")!
        return AIConnection(name: "Test", kind: kind, baseURL: url, model: "test-model",
                            credentialAccount: "test", maxOutputTokens: 321)
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private static func history(_ request: URLRequest) throws -> [[String: String]] {
        try XCTUnwrap(body(request)["messages"] as? [[String: String]])
    }

    private static func delta(_ text: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\n"
    }

    private static func chat(_ text: String) -> String {
        delta(text) + "data: [DONE]\n\n"
    }
}

private final class ChatFixture: @unchecked Sendable {
    struct Response {
        let payload: String
        let open: Bool

        init(_ payload: String, open: Bool = false) {
            self.payload = payload
            self.open = open
        }
    }

    let host = "\(UUID().uuidString.lowercased()).example.test"
    let session: URLSession
    private let responses: [Response]
    private let lock = NSLock()
    private var received: [URLRequest] = []
    private var stopped = 0
    var requests: [URLRequest] { lock.withLock { received } }
    var stoppedOpenRequests: Int { lock.withLock { stopped } }

    init(_ responses: [Response]) {
        self.responses = responses
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatURLProtocol.self]
        session = URLSession(configuration: configuration)
        ChatURLProtocol.registry.add(self)
    }

    deinit {
        session.invalidateAndCancel()
        ChatURLProtocol.registry.remove(host)
    }

    func response(to request: URLRequest) -> Response? {
        lock.withLock {
            let index = received.count
            received.append(request)
            return responses.indices.contains(index) ? responses[index] : nil
        }
    }

    func stopOpenRequest() { lock.withLock { stopped += 1 } }
}

private final class ChatURLProtocol: URLProtocol, @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        private struct Entry { weak var fixture: ChatFixture? }
        private let lock = NSLock()
        private var fixtures: [String: Entry] = [:]
        func add(_ fixture: ChatFixture) { lock.withLock { fixtures[fixture.host] = Entry(fixture: fixture) } }
        func remove(_ host: String) { lock.withLock { _ = fixtures.removeValue(forKey: host) } }
        func fixture(for host: String) -> ChatFixture? { lock.withLock { fixtures[host]?.fixture } }
    }

    static let registry = Registry()
    private let stateLock = NSLock()
    private var open = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".example.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let client,
              let fixture = Self.registry.fixture(for: host),
              let response = fixture.response(to: Self.captureBody(request)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        stateLock.withLock { open = response.open }
        client.urlProtocol(self, didReceive: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]
        )!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(response.payload.utf8))
        if !response.open { client.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        if stateLock.withLock({ open }), let host = request.url?.host {
            Self.registry.fixture(for: host)?.stopOpenRequest()
        }
    }

    private static func captureBody(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var copy = request
        copy.httpBody = data
        return copy
    }
}
