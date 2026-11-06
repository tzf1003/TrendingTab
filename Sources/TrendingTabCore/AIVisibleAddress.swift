import Foundation

/// Display a source address to a model without sending URL credentials or parameters.
public enum AIVisibleAddress {
    public static func string(for url: URL) -> String {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? ""
    }
}
