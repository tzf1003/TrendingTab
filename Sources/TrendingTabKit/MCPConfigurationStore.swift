import Foundation
import TrendingTabIntelligence

public struct MCPProfile: Codable, Sendable, Identifiable {
    public var server: AgentMCPServer
    public var enabled: Bool
    public var id: String { server.id }

    public init(server: AgentMCPServer, enabled: Bool = true) {
        self.server = server
        self.enabled = enabled
    }
}

/// Connection configuration may contain access tokens or process environment
/// credentials, so the entire collection is stored in the application Keychain.
public enum MCPConfigurationStore {
    private static let account = "research-mcp-connections-v1"

    public static func load() -> [MCPProfile] {
        guard let value = KeychainStore.read(account: account), let data = value.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([MCPProfile].self, from: data) else { return [] }
        return profiles
    }

    @discardableResult public static func save(_ profiles: [MCPProfile]) -> Bool {
        guard profiles.count <= 8, Set(profiles.map(\.id)).count == profiles.count,
              let data = try? JSONEncoder().encode(profiles), data.count <= 256_000,
              let text = String(data: data, encoding: .utf8) else { return false }
        return KeychainStore.save(text, account: account)
    }
}
