import Foundation
import TrendingTabCore

public struct AgentRuntimeRelease: Equatable, Sendable {
    public let version: String
    public let downloadURL: URL
    public let sha256: String
}

public enum AgentRuntimeManifestError: Error, LocalizedError {
    case invalid, incompatible, incompleteFeed
    public var errorDescription: String? {
        switch self {
        case .invalid: "Agent 运行时更新信息无效。"
        case .incompatible: "Agent 运行时与当前应用或系统不兼容。"
        case .incompleteFeed: "运行时发布列表过长，无法完成更新检查。"
        }
    }
}

/// Feed metadata locates a candidate; trust comes from the signed component itself.
public enum AgentRuntimeReleaseFeed {
    private static let pageSize = 100
    private static let maximumPages = 10
    private static let maximumPageBytes = 4_000_000

    /// Inspect every page in the bounded release feed so that app releases do
    /// not hide older, independently published runtime components.
    public static func latest(currentVersion: String,
                              fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws -> AgentRuntimeRelease? {
        var allReleases: [[String: Any]] = []
        for page in 1...maximumPages {
            try Task.checkCancellation()
            let url = URL(string: "https://api.github.com/repos/tzf1003/TrendingTab/releases?per_page=\(pageSize)&page=\(page)")!
            var request = URLRequest(url: url)
            request.setValue("TrendingTab", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url == url, data.count <= maximumPageBytes,
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  entries.count <= pageSize else { throw AgentRuntimeManifestError.invalid }
            allReleases.append(contentsOf: entries)
            if entries.count < pageSize {
                return try parse(JSONSerialization.data(withJSONObject: allReleases), currentVersion: currentVersion)
            }
        }
        throw AgentRuntimeManifestError.incompleteFeed
    }

    public static func parse(_ data: Data, currentVersion: String) throws -> AgentRuntimeRelease? {
        guard AgentRuntimeManifest.validVersion(currentVersion),
              let object = try? JSONSerialization.jsonObject(with: data) else { throw AgentRuntimeManifestError.invalid }
        let releases: [[String: Any]]
        if let list = object as? [[String: Any]] { releases = list }
        else if let single = object as? [String: Any] { releases = [single] }
        else { throw AgentRuntimeManifestError.invalid }
        var assets: [[String: Any]] = []
        for release in releases where release["draft"] as? Bool != true && release["prerelease"] as? Bool != true {
            guard let entries = release["assets"] as? [[String: Any]] else { throw AgentRuntimeManifestError.invalid }
            assets.append(contentsOf: entries)
        }
        let runtimeAssets = assets.filter { asset in
            guard let name = asset["name"] as? String else { return false }
            return name.hasPrefix("TrendingTab-AgentRuntime-") && name.hasSuffix(".dmg")
        }
        let candidates = runtimeAssets.compactMap { asset -> AgentRuntimeRelease? in
            guard let name = asset["name"] as? String,
                  name.hasPrefix("TrendingTab-AgentRuntime-"), name.hasSuffix(".dmg") else { return nil }
            let version = String(name.dropFirst("TrendingTab-AgentRuntime-".count).dropLast(".dmg".count))
            guard AgentRuntimeManifest.validVersion(version),
                  let raw = asset["browser_download_url"] as? String, let url = URL(string: raw),
                  url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
                  url.port == nil, url.query == nil, url.fragment == nil,
                  url.pathComponents.count == 7,
                  Array(url.pathComponents.prefix(5)) == ["/", "tzf1003", "TrendingTab", "releases", "download"],
                  url.lastPathComponent == name,
                  let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") else { return nil }
            let hash = String(digest.dropFirst("sha256:".count)).lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            return AgentRuntimeRelease(version: version, downloadURL: url, sha256: hash)
        }
        guard runtimeAssets.count == candidates.count else { throw AgentRuntimeManifestError.invalid }
        let grouped = Dictionary(grouping: candidates, by: \.version)
        guard grouped.values.allSatisfy({ Set($0.map(\.sha256)).count == 1 }) else { throw AgentRuntimeManifestError.invalid }
        guard let candidate = candidates.filter({ ReleaseFeed.isNewer($0.version, than: currentVersion) })
            .sorted(by: { ReleaseFeed.isNewer($0.version, than: $1.version) }).first else { return nil }
        return candidate
    }
}

/// This metadata is read only after the component bundle passes signature validation.
public struct AgentRuntimeManifest: Equatable, Sendable {
    public static let identifier = "dev.trendingtab.runtime"
    public static let bridgeProtocol = 1
    public let version, piVersion, minimumAppVersion, maximumAppVersion: String
    public let minimumSystemVersion: String
    public let minimumProtocol, maximumProtocol: Int
    public let architectures: [String]

    public static func parse(_ data: Data) throws -> AgentRuntimeManifest {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              object["CFBundleIdentifier"] as? String == identifier,
              object["CFBundleExecutable"] as? String == "node",
              let version = object["CFBundleShortVersionString"] as? String, validVersion(version),
              let piVersion = object["TrendingTabPiVersion"] as? String, validVersion(piVersion),
              let minApp = object["TrendingTabMinimumAppVersion"] as? String, validVersion(minApp),
              let maxApp = object["TrendingTabMaximumAppVersion"] as? String, validVersion(maxApp),
              let minSystem = object["LSMinimumSystemVersion"] as? String, validVersion(minSystem),
              let minProtocol = object["TrendingTabMinimumProtocol"] as? Int,
              let maxProtocol = object["TrendingTabMaximumProtocol"] as? Int,
              (1...1000).contains(minProtocol), (minProtocol...1000).contains(maxProtocol),
              let architectures = object["TrendingTabArchitectures"] as? [String],
              Set(architectures) == Set(["arm64", "x86_64"]), architectures.count == 2,
              !ReleaseFeed.isNewer(minApp, than: maxApp) else { throw AgentRuntimeManifestError.invalid }
        return AgentRuntimeManifest(version: version, piVersion: piVersion, minimumAppVersion: minApp,
            maximumAppVersion: maxApp, minimumSystemVersion: minSystem,
            minimumProtocol: minProtocol, maximumProtocol: maxProtocol, architectures: architectures)
    }

    public func validate(appVersion: String, systemVersion: String, protocolVersion: Int = bridgeProtocol) throws {
        guard Self.validVersion(appVersion), Self.validVersion(systemVersion),
              !ReleaseFeed.isNewer(minimumAppVersion, than: appVersion),
              !ReleaseFeed.isNewer(appVersion, than: maximumAppVersion),
              !ReleaseFeed.isNewer(minimumSystemVersion, than: systemVersion),
              (minimumProtocol...maximumProtocol).contains(protocolVersion) else { throw AgentRuntimeManifestError.incompatible }
    }

    public static func validVersion(_ text: String) -> Bool {
        text.range(of: #"^[0-9]{1,7}\.[0-9]{1,7}\.[0-9]{1,7}$"#, options: .regularExpression) != nil
    }

    /// The baseline runtime has its own version, independent of the host app.
    public static func bundledVersion(package: Data) throws -> String {
        guard package.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: package) as? [String: Any],
              object["name"] as? String == "trendingtab-agent-runtime",
              let version = object["version"] as? String, validVersion(version) else {
            throw AgentRuntimeManifestError.invalid
        }
        return version
    }

    public static func bundledPiVersion(package: Data) throws -> String {
        _ = try bundledVersion(package: package)
        guard let object = try? JSONSerialization.jsonObject(with: package) as? [String: Any],
              let dependencies = object["dependencies"] as? [String: Any],
              let version = dependencies["@earendil-works/pi-coding-agent"] as? String,
              validVersion(version) else { throw AgentRuntimeManifestError.invalid }
        return version
    }
}
