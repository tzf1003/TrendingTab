import CryptoKit
import Darwin
import Foundation

public enum AgentRuntimeInstallError: Error, LocalizedError {
    case busy, checksum, notarization, invalidPackage, versionConflict, missingPrevious
    public var errorDescription: String? {
        switch self {
        case .busy: "Agent 运行时正在更新。"
        case .checksum: "Agent 运行时更新包完整性校验失败。"
        case .notarization: "Agent 运行时公证验证失败。"
        case .invalidPackage: "Agent 运行时更新包无效。"
        case .versionConflict: "本地已有相同版本的 Agent 运行时。"
        case .missingPrevious: "没有可回退的 Agent 运行时。"
        }
    }
}

/// The app owns this directory; the signed bundle is immutable once installed.
public actor AgentRuntimeInstaller {
    public struct Location: Sendable {
        public let executable: URL
        public let script: URL
        public let version: String
        public let piVersion: String
        public let bundled: Bool
        public let recovered: Bool
    }
    public struct Selection: Codable, Equatable, Sendable {
        public let active: String?
        public let previous: String?
    }
    private let root: URL
    private let appVersion: String
    private let systemVersion: String
    private let bundledExecutable: URL
    private let bundledHealthScript: URL
    private let bundledPiVersion: String
    private let bundledVersion: String
    private var installing = false

    public init(root: URL, appVersion: String, systemVersion: String, bundledExecutable: URL, bundledHealthScript: URL,
                bundledPiVersion: String, bundledVersion: String = "0.1.0") {
        self.root = root
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.bundledExecutable = bundledExecutable
        self.bundledHealthScript = bundledHealthScript
        self.bundledPiVersion = bundledPiVersion
        self.bundledVersion = bundledVersion
    }

    public func selection() throws -> Selection {
        let url = root.appendingPathComponent("selection.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Selection(active: nil, previous: nil) }
        let data = try Data(contentsOf: url)
        guard data.count <= 4096, let result = try? JSONDecoder().decode(Selection.self, from: data),
              [result.active, result.previous].compactMap({ $0 }).allSatisfy(AgentRuntimeManifest.validVersion),
              result.active == nil || result.active != result.previous else {
            throw AgentRuntimeInstallError.invalidPackage
        }
        return result
    }

    public func bundle(for version: String) throws -> URL {
        guard AgentRuntimeManifest.validVersion(version) else { throw AgentRuntimeInstallError.invalidPackage }
        return root.appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true).appendingPathComponent("AgentRuntime.app", isDirectory: true)
    }

    /// On launch, revalidate the selected component; recover to the previous
    /// verified version or the app's bundled runtime if it is no longer usable.
    public func resolveActive() async throws -> Location {
        guard !installing else { throw AgentRuntimeInstallError.busy }
        installing = true
        defer { installing = false }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        let stored: Selection
        do { stored = try selection() }
        catch {
            let fallback = try await bundledLocation(recovered: true)
            try write(Selection(active: nil, previous: nil))
            return fallback
        }
        guard let active = stored.active else { return try await bundledLocation(recovered: false) }
        do { return try await verifiedLocation(version: active, recovered: false) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if let previous = stored.previous {
                do {
                    let fallback = try await verifiedLocation(version: previous, recovered: true)
                    try write(Selection(active: previous, previous: nil))
                    return fallback
                } catch is CancellationError { throw CancellationError() }
                catch { }
            }
            let fallback = try await bundledLocation(recovered: true)
            try write(Selection(active: nil, previous: nil))
            return fallback
        }
    }

    private func bundledLocation(recovered: Bool) async throws -> Location {
        try await AgentRuntimeHealth.verify(executable: bundledExecutable, script: bundledHealthScript, expectedPiVersion: bundledPiVersion)
        try Task.checkCancellation()
        return Location(executable: bundledExecutable, script: bundledHealthScript.deletingLastPathComponent().appendingPathComponent("runtime.mjs"),
                        version: bundledVersion, piVersion: bundledPiVersion, bundled: true, recovered: recovered)
    }

    private func verifiedLocation(version: String, recovered: Bool) async throws -> Location {
        let candidate = try bundle(for: version)
        let manifest = try AgentRuntimeVerifier.verify(bundle: candidate, appVersion: appVersion, systemVersion: systemVersion)
        guard manifest.version == version else { throw AgentRuntimeInstallError.invalidPackage }
        let executable = candidate.appendingPathComponent("Contents/MacOS/node")
        let resources = candidate.appendingPathComponent("Contents/Resources", isDirectory: true)
        try await AgentRuntimeHealth.verify(executable: executable, script: resources.appendingPathComponent("runtime-health.mjs"), expectedPiVersion: manifest.piVersion)
        try Task.checkCancellation()
        return Location(executable: executable, script: resources.appendingPathComponent("runtime.mjs"), version: version,
                        piVersion: manifest.piVersion, bundled: false, recovered: recovered)
    }

    /// A notarized disk image is verified, copied to the same volume, checked again,
    /// and activated by an atomic pointer update only after a live self-test.
    public func install(dmg: URL, release: AgentRuntimeRelease) async throws -> Selection {
        try Task.checkCancellation()
        guard !installing else { throw AgentRuntimeInstallError.busy }
        installing = true
        defer { installing = false }
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("versions"), withIntermediateDirectories: true)
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        let attributes = try dmg.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= 1_073_741_824 else { throw AgentRuntimeInstallError.invalidPackage }
        let work = root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: work) }
        let localImage = work.appendingPathComponent("runtime.dmg")
        try manager.copyItem(at: dmg, to: localImage)
        let digest = try await Task.detached(priority: .utility) { try Self.sha256(localImage) }.value
        try Task.checkCancellation()
        guard digest == release.sha256 else { throw AgentRuntimeInstallError.checksum }
        let imageRequirement = "=anchor apple generic and certificate leaf[subject.OU] = \"GJUT2BVM7R\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        do { _ = try Self.run("/usr/bin/codesign", ["--verify", "--strict", "-R", imageRequirement, localImage.path], timeout: 30) }
        catch { throw AgentRuntimeVerificationError.invalidSignature }
        try Task.checkCancellation()
        do { _ = try Self.runWithRetry("/usr/bin/xcrun", ["stapler", "validate", localImage.path], timeout: 30) }
        catch { throw AgentRuntimeInstallError.notarization }
        try Task.checkCancellation()
        let output = try Self.run("/usr/bin/hdiutil", ["attach", localImage.path, "-readonly", "-nobrowse", "-plist"], timeout: 60)
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw AgentRuntimeInstallError.invalidPackage
        }
        guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            if let device = entities.compactMap({ $0["dev-entry"] as? String }).first {
                _ = try? Self.run("/usr/bin/hdiutil", ["detach", device, "-quiet"], timeout: 30)
            }
            throw AgentRuntimeInstallError.invalidPackage
        }
        defer { _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount, "-quiet"], timeout: 30) }
        try Task.checkCancellation()
        let source = URL(fileURLWithPath: mount, isDirectory: true).appendingPathComponent("AgentRuntime.app", isDirectory: true)
        let sourceManifest = try AgentRuntimeVerifier.verify(bundle: source, appVersion: appVersion, systemVersion: systemVersion)
        guard sourceManifest.version == release.version else { throw AgentRuntimeInstallError.invalidPackage }
        do { _ = try Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", source.path], timeout: 30) }
        catch { throw AgentRuntimeInstallError.notarization }
        let current = try selection()
        let destination = try bundle(for: release.version)
        if manager.fileExists(atPath: destination.deletingLastPathComponent().path) {
            let existing = try AgentRuntimeVerifier.verify(bundle: destination, appVersion: appVersion, systemVersion: systemVersion)
            guard existing == sourceManifest,
                  try AgentRuntimeVerifier.signatureIdentity(bundle: destination) == AgentRuntimeVerifier.signatureIdentity(bundle: source) else {
                throw AgentRuntimeInstallError.versionConflict
            }
            try await AgentRuntimeHealth.verify(executable: destination.appendingPathComponent("Contents/MacOS/node"),
                script: destination.appendingPathComponent("Contents/Resources/runtime-health.mjs"), expectedPiVersion: existing.piVersion)
            try Task.checkCancellation()
            if current.active == release.version { return current }
            let next = Selection(active: release.version, previous: current.active)
            try write(next)
            return next
        }
        let stage = root.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        let stagedBundle = stage.appendingPathComponent("AgentRuntime.app", isDirectory: true)
        try manager.copyItem(at: source, to: stagedBundle)
        let verified = try AgentRuntimeVerifier.verify(bundle: stagedBundle, appVersion: appVersion, systemVersion: systemVersion)
        guard verified == sourceManifest else { throw AgentRuntimeInstallError.invalidPackage }
        try await AgentRuntimeHealth.verify(executable: stagedBundle.appendingPathComponent("Contents/MacOS/node"),
            script: stagedBundle.appendingPathComponent("Contents/Resources/runtime-health.mjs"), expectedPiVersion: verified.piVersion)
        try Task.checkCancellation()
        try manager.moveItem(at: stage, to: destination.deletingLastPathComponent())
        let next = Selection(active: release.version, previous: current.active)
        do {
            try Task.checkCancellation()
            try write(next)
        }
        catch { try? manager.removeItem(at: destination.deletingLastPathComponent()); throw error }
        return next
    }

    /// A nil previous selection represents the trusted runtime bundled in the application.
    public func rollback() async throws -> Selection {
        guard !installing else { throw AgentRuntimeInstallError.busy }
        installing = true
        defer { installing = false }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        let current = try selection()
        guard current.active != nil else { throw AgentRuntimeInstallError.missingPrevious }
        if let previous = current.previous {
            let candidate = try bundle(for: previous)
            let manifest = try AgentRuntimeVerifier.verify(bundle: candidate, appVersion: appVersion, systemVersion: systemVersion)
            guard manifest.version == previous else { throw AgentRuntimeInstallError.invalidPackage }
            try await AgentRuntimeHealth.verify(executable: candidate.appendingPathComponent("Contents/MacOS/node"),
                script: candidate.appendingPathComponent("Contents/Resources/runtime-health.mjs"), expectedPiVersion: manifest.piVersion)
        } else {
            try await AgentRuntimeHealth.verify(executable: bundledExecutable, script: bundledHealthScript, expectedPiVersion: bundledPiVersion)
        }
        try Task.checkCancellation()
        let next = Selection(active: current.previous, previous: current.active)
        try write(next)
        return next
    }

    private func write(_ selection: Selection) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(selection).write(to: root.appendingPathComponent("selection.json"), options: .atomic)
    }

    private func acquireLock() throws -> Int32 {
        let path = root.appendingPathComponent(".update.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AgentRuntimeInstallError.invalidPackage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw AgentRuntimeInstallError.busy }
        return descriptor
    }

    private func releaseLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var total = 0
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            total += data.count
            guard total <= 1_073_741_824 else { throw AgentRuntimeInstallError.invalidPackage }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        // Opt-in diagnostics help identify failures in CI without putting tool
        // output in normal application logs.
        child.standardError = ProcessInfo.processInfo.environment["TRENDINGTAB_RUNTIME_DIAGNOSTICS"] == "1"
            ? FileHandle.standardError : FileHandle.nullDevice
        try child.run()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) } }
        timer.resume()
        defer {
            timer.cancel()
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
        }
        var data = Data()
        var exceededLimit = false
        while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            if data.count + chunk.count > 1_048_576 {
                exceededLimit = true
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
                break
            }
            data.append(chunk)
        }
        child.waitUntilExit()
        guard !exceededLimit, child.terminationReason == .exit, child.terminationStatus == 0 else {
            if ProcessInfo.processInfo.environment["TRENDINGTAB_RUNTIME_DIAGNOSTICS"] == "1" {
                let diagnostic = "Runtime verification command failed (status \(child.terminationStatus)): "
                    + String(decoding: data, as: UTF8.self) + "\n"
                FileHandle.standardError.write(Data(diagnostic.utf8))
            }
            throw AgentRuntimeInstallError.invalidPackage
        }
        return data
    }

    private static func runWithRetry(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        var lastError: Error?
        for attempt in 1...3 {
            do { return try run(executable, arguments, timeout: timeout) }
            catch {
                lastError = error
                if attempt < 3 {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: Double(attempt) * 5)
                }
            }
        }
        throw lastError ?? AgentRuntimeInstallError.notarization
    }
}
