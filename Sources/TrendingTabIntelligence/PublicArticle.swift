import Foundation
import Darwin
import SwiftSoup

public struct PublicArticle: Sendable {
    public let url: URL
    public let title: String
    public let text: String
    public let truncated: Bool
}

public enum PublicArticleError: LocalizedError {
    case invalidURL, status(Int), unsupported, tooLarge, unreadable, network
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入公开网页的 HTTP 或 HTTPS 地址。"
        case .status(let code): "网页返回 HTTP \(code)，可以尝试在浏览器中打开。"
        case .unsupported: "该内容不是受支持的文字网页。"
        case .tooLarge: "网页内容超过读取上限。"
        case .unreadable: "网页没有可提取的正文。"
        case .network: "无法读取公开网页，请在浏览器中打开。"
        }
    }
}

public struct PublicArticleService: Sendable {
    public init() {}

    public func read(_ url: URL) async throws -> PublicArticle {
        guard Self.allowed(url) else { throw PublicArticleError.invalidURL }
        let host = url.host!.lowercased()
        let address = try await Task.detached(priority: .utility) { try Self.publicIPv4(for: host) }.value
        try Task.checkCancellation()
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trendingtab-article-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = directory.appendingPathComponent("body")
        let metadata = directory.appendingPathComponent("metadata")
        guard FileManager.default.createFile(atPath: metadata.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PublicArticleError.network }
        let output = try FileHandle(forWritingTo: metadata)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--disable", "--silent", "--globoff", "--noproxy", "*", "--proto", "=http,https",
            "--connect-timeout", "10", "--max-time", "15", "--max-filesize", "2000000", "--limit-rate", "512k",
            "--resolve", "\(host):\(port):\(address)", "--header", "Accept: text/html, text/plain;q=0.9",
            "--output", body.path, "--write-out", "%{http_code}\n%{content_type}\n", "--url", url.absoluteString]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let child = CancellableArticleProcess(process)
        let status = try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { try await child.run() }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(50))
                    if let size = (try? FileManager.default.attributesOfItem(atPath: body.path)[.size]) as? NSNumber,
                       size.intValue > 2_000_000 {
                        throw PublicArticleError.tooLarge
                    }
                }
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw PublicArticleError.network }
            return result
        }
        try Task.checkCancellation()
        guard status == 0 else { throw status == 63 ? PublicArticleError.tooLarge : PublicArticleError.network }
        let fields = try String(contentsOf: metadata, encoding: .utf8).components(separatedBy: "\n")
        guard let code = fields.first.flatMap(Int.init) else { throw PublicArticleError.network }
        guard (200...299).contains(code) else { throw PublicArticleError.status(code) }
        let mime = fields.dropFirst().first?.components(separatedBy: ";").first?.lowercased() ?? ""
        guard mime == "text/html" || mime == "text/plain" || mime == "application/xhtml+xml" else { throw PublicArticleError.unsupported }
        let data = try Data(contentsOf: body, options: .mappedIfSafe)
        guard data.count <= 2_000_000 else { throw PublicArticleError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw PublicArticleError.unsupported }
        return try Self.extract(text, mime: mime, url: url)
    }

    public static func extract(_ content: String, mime: String, url: URL) throws -> PublicArticle {
        let title: String
        let body: String
        if mime == "text/plain" {
            title = url.host ?? "网页"
            body = content
        } else {
            let document = try SwiftSoup.parse(content, url.absoluteString)
            try document.select("script, style, noscript, nav, footer, form, aside").remove()
            title = try document.title()
            let root = try document.select("article").first() ?? document.select("main").first() ?? document.body()
            body = try root?.text() ?? ""
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(trimmed.prefix(200_000))
        guard !text.isEmpty else { throw PublicArticleError.unreadable }
        return PublicArticle(url: url, title: String(title.prefix(300)), text: text, truncated: trimmed.count > 200_000)
    }

    private static func allowed(_ url: URL) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.absoluteString.count <= 4096,
              !host.contains(":"), !host.hasSuffix(".local"), host != "localhost",
              !host.hasSuffix(".localhost"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              host.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              (1...65535).contains(url.port ?? 443) else { return false }
        return host.contains(".")
    }

    private static func publicIPv4(for host: String) throws -> String {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { throw PublicArticleError.network }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var addresses: [String] = []
        while let info = cursor {
            let addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var bytes = addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &bytes, &buffer, socklen_t(buffer.count)) != nil else { throw PublicArticleError.network }
            let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard isPublicIPv4(value) else { throw PublicArticleError.invalidURL }
            addresses.append(value)
            cursor = info.pointee.ai_next
        }
        guard let address = addresses.first else { throw PublicArticleError.network }
        return address
    }

    public static func isPublicIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt8($0) != nil }),
              let a = UInt8(parts[0]), let b = UInt8(parts[1]), let c = UInt8(parts[2]) else { return false }
        if a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b)) ||
            (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) ||
            (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99))) ||
            (a == 198 && ((18...19).contains(b) || (b == 51 && c == 100))) ||
            (a == 203 && b == 0 && c == 113) { return false }
        return true
    }
}

private final class CancellableArticleProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false
    init(_ process: Process) { self.process = process }

    func run() async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
                do { try process.run(); lock.unlock() }
                catch { lock.unlock(); continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            if self.process.isRunning { self.process.terminate() }
            self.lock.unlock()
        }
    }
}
