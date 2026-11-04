import CryptoKit
import Foundation

public extension String {
    var sha256Prefix: String {
        SHA256.hash(data: Data(utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func trimmedNonEmpty() -> String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum TrendingJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func data<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func value<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

public enum TrendingPaths {
    public static let appGroup = "group.dev.trendingtab.shared"

    public static func supportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("TrendingTab", isDirectory: true)
    }

    public static func sharedDirectory(fileManager: FileManager = .default) -> URL {
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group
        }
        return supportDirectory(fileManager: fileManager)
    }
}
