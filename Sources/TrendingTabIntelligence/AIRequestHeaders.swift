import Foundation

/// Validation is shared by the settings form and callers constructing a request.
public enum AIRequestHeaders {
    public enum ValidationError: LocalizedError {
        case invalid
        public var errorDescription: String? { "请求头格式无效，请填写 JSON 对象，名称使用标准 HTTP 字符，值使用单行英文字符。" }
    }

    public static func parse(_ text: String) throws -> [String: String] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let data = text.data(using: .utf8), data.count <= 32_768,
              let headers = try? JSONDecoder().decode([String: String].self, from: data), valid(headers) else {
            throw ValidationError.invalid
        }
        return headers
    }

    public static func valid(_ headers: [String: String]) -> Bool {
        let forbidden = Set(["host", "content-length", "transfer-encoding", "connection", "cookie", "set-cookie", "proxy-authorization"])
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var names = Set<String>()
        guard headers.count <= 20 else { return false }
        for (name, value) in headers {
            let normalized = name.lowercased()
            guard !name.isEmpty, name.utf8.count <= 128, name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  !forbidden.contains(normalized), names.insert(normalized).inserted,
                  value.utf8.count <= 4096, value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { return false }
        }
        return true
    }
}
