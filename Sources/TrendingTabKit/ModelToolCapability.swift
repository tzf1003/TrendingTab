import Foundation

public struct ModelToolCapability: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case verified, notVerified
    }

    public let state: State
    public let checkedAt: Date
    // The digest binds a result to the tested route and credentials. Raw
    // credentials and headers remain in Keychain.
    let fingerprint: String
}
