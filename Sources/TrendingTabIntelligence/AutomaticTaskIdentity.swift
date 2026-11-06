import CryptoKit
import Foundation
import TrendingTabCore

/// Identifies the exact automatic request and its rules without storing the materials.
public enum AutomaticTaskIdentity {
    public static func make(kind: String, connection: AIConnection, headers: [String: String],
                            system: String, prompt: String, rule: String, promptVersion: Int) throws -> String {
        let config = String(decoding: try TrendingJSON.data(connection), as: UTF8.self)
        let encodedHeaders = String(decoding: try TrendingJSON.data(headers), as: UTF8.self)
        let data = try TrendingJSON.data([kind, config, encodedHeaders, system, prompt, rule, String(promptVersion)])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
