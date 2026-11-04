import Foundation
import TrendingTabCore
import TrendingTabNetworking

public struct FetchContext: Sendable {
    public var transport: any HTTPTransport
    public var now: Date
    public var cache: ConditionalCache
    public var remoteBaseURL: URL?
    public var remoteCredential: String?

    public init(transport: any HTTPTransport, now: Date = Date(), cache: ConditionalCache = ConditionalCache(), remoteBaseURL: URL? = nil, remoteCredential: String? = nil) {
        self.transport = transport
        self.now = now
        self.cache = cache
        self.remoteBaseURL = remoteBaseURL
        self.remoteCredential = remoteCredential
    }
}

public protocol SourceProvider: Sendable {
    var descriptor: SourceDescriptor { get }
    func boards() async throws -> [BoardDescriptor]
    func fetch(board: String, context: FetchContext) async throws -> FetchResult
}

public protocol DetailProvider: Sendable {
    func fetchDetail(for item: NormalizedItem, context: FetchContext) async throws -> String
}

public enum ProviderError: Error {
    case unknownBoard(String)
}

public enum JSONValues {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceFailure.schemaChanged("根节点不是对象")
        }
        return value
    }

    public static func array(_ value: Any?, path: String) throws -> [[String: Any]] {
        guard let array = value as? [[String: Any]] else {
            throw SourceFailure.schemaChanged("缺少 \(path)")
        }
        return array
    }

    public static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text.trimmedNonEmpty()
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    public static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String {
            let digits = text.replacingOccurrences(of: ",", with: "")
            return Double(digits.filter { "0123456789.".contains($0) })
        }
        return nil
    }

    public static func url(_ value: String, base: URL? = nil) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        if let base { return URL(string: value, relativeTo: base)?.absoluteURL }
        return nil
    }
}
