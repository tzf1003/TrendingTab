import CryptoKit
import Foundation

public struct AppRelease: Equatable, Sendable {
    public var version: String
    public var tag: String
    public var notes: String
    public var assetName: String
    public var downloadURL: URL
    public var digest: String?

    public init(
        version: String,
        tag: String,
        notes: String,
        assetName: String,
        downloadURL: URL,
        digest: String? = nil
    ) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.assetName = assetName
        self.downloadURL = downloadURL
        self.digest = digest
    }
}

public enum AppUpdateError: Error, Equatable, LocalizedError {
    case unavailable
    case invalidPackage
    case checksumMismatch
    case invalidSignature
    case installFailed(String)

    public var message: String {
        switch self {
        case .unavailable: "无法读取更新信息"
        case .invalidPackage: "更新包缺少应用"
        case .checksumMismatch: "更新包完整性校验失败"
        case .invalidSignature: "更新包的应用签名无效"
        case .installFailed(let detail): detail
        }
    }

    public var errorDescription: String? { message }
}

public enum ReleaseFeed {
    public static let latest = URL(string: "https://api.github.com/repos/tzf1003/TrendingTab/releases/latest")!

    public static func parse(_ data: Data, currentVersion: String) throws -> AppRelease? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object,
              let tag = object["tag_name"] as? String,
              let assets = object["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let name = asset["name"] as? String,
              let address = asset["browser_download_url"] as? String,
              let url = URL(string: address) else {
            throw AppUpdateError.unavailable
        }
        let version = semanticVersion(in: name) ?? semanticVersion(in: tag) ?? tag
        guard isNewer(version, than: currentVersion) else { return nil }
        return AppRelease(
            version: version,
            tag: tag,
            notes: object["body"] as? String ?? "",
            assetName: name,
            downloadURL: url,
            digest: asset["digest"] as? String
        )
    }

    public static func semanticVersion(in text: String) -> String? {
        let pattern = #"(\d+\.\d+(?:\.\d+)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(candidate)
        let right = components(current)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let difference = (left[safe: index] ?? 0) - (right[safe: index] ?? 0)
            if difference != 0 { return difference > 0 }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public enum AppInstaller {
    public static func install(
        dmg: URL,
        expectedVersion: String? = nil,
        expectedSHA256: String? = nil,
        applicationName: String = "TrendingTab.app"
    ) throws -> URL {
        if let expectedSHA256 {
            let payload = try Data(contentsOf: dmg, options: .mappedIfSafe)
            let actual = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let expected = expectedSHA256.lowercased().replacingOccurrences(of: "sha256:", with: "")
            guard actual == expected else { throw AppUpdateError.checksumMismatch }
        }

        let output = try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-plist"])
        guard let data = output.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw AppUpdateError.invalidPackage
        }
        let mountedApp = URL(fileURLWithPath: mount).appendingPathComponent(applicationName)
        let fileManager = FileManager.default
        let installDirectory: URL
        if fileManager.isWritableFile(atPath: "/Applications") {
            installDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)
        } else {
            installDirectory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
            try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        }
        let destination = installDirectory.appendingPathComponent(applicationName, isDirectory: true)
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-quiet"]) }
        guard fileManager.fileExists(atPath: mountedApp.path) else { throw AppUpdateError.invalidPackage }
        try validateApplication(at: mountedApp, expectedVersion: expectedVersion)

        let token = UUID().uuidString
        let staged = installDirectory.appendingPathComponent(".TrendingTab-update-\(token).app")
        let backup = installDirectory.appendingPathComponent(".TrendingTab-backup-\(token).app")
        try? fileManager.removeItem(at: staged)
        try? fileManager.removeItem(at: backup)
        try fileManager.copyItem(at: mountedApp, to: staged)
        try validateApplication(at: staged, expectedVersion: expectedVersion)

        var movedExistingApp = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                movedExistingApp = true
            }
            try fileManager.moveItem(at: staged, to: destination)
            if movedExistingApp {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if movedExistingApp, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            try? fileManager.removeItem(at: staged)
            throw AppUpdateError.installFailed(error.localizedDescription)
        }
        return destination
    }

    public static func relaunch(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$1\"", "TrendingTabRelaunch", app.path]
        try process.run()
    }

    private static func validateApplication(at app: URL, expectedVersion: String?) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              object["CFBundleIdentifier"] as? String == "dev.trendingtab.app" else {
            throw AppUpdateError.invalidPackage
        }
        if let expectedVersion,
           object["CFBundleShortVersionString"] as? String != expectedVersion {
            throw AppUpdateError.invalidPackage
        }
        do {
            _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw AppUpdateError.invalidSignature
        }

        let currentTeam = teamIdentifier(for: Bundle.main.bundleURL)
        let candidateTeam = teamIdentifier(for: app)
        if let currentTeam, !currentTeam.isEmpty, currentTeam != candidateTeam {
            throw AppUpdateError.invalidSignature
        }
    }

    private static func teamIdentifier(for app: URL) -> String? {
        guard let details = try? run(
            "/bin/sh",
            ["-c", "/usr/bin/codesign -dv --verbose=4 \"$1\" 2>&1", "TrendingTabCodesign", app.path]
        ) else {
            return nil
        }
        return details.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "安装失败"
            throw AppUpdateError.installFailed(message)
        }
        return text
    }
}
