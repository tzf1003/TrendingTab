import Foundation
import CryptoKit
import XCTest
import TrendingTabIntelligence
import TrendingTabCore

final class AgentRuntimeManifestTests: XCTestCase {
    private func plist(_ changes: [String: Any] = [:]) throws -> Data {
        var values: [String: Any] = ["CFBundleIdentifier": "dev.trendingtab.runtime", "CFBundleExecutable": "node",
            "CFBundleShortVersionString": "1.2.3", "TrendingTabPiVersion": "1.5.0", "LSMinimumSystemVersion": "14.0.0",
            "TrendingTabMinimumAppVersion": "0.2.0", "TrendingTabMaximumAppVersion": "0.9.0",
            "TrendingTabMinimumProtocol": 1, "TrendingTabMaximumProtocol": 1,
            "TrendingTabArchitectures": ["arm64", "x86_64"]]
        values.merge(changes) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    func testSignedMetadataCompatibilityChecks() throws {
        let manifest = try AgentRuntimeManifest.parse(plist())
        XCTAssertEqual(manifest.piVersion, "1.5.0")
        XCTAssertNoThrow(try manifest.validate(appVersion: "0.2.10", systemVersion: "15.0.0"))
        XCTAssertThrowsError(try manifest.validate(appVersion: "0.1.9", systemVersion: "15.0.0"))
        XCTAssertThrowsError(try manifest.validate(appVersion: "0.2.10", systemVersion: "13.9.0"))
        XCTAssertThrowsError(try manifest.validate(appVersion: "0.2.10", systemVersion: "15.0.0", protocolVersion: 2))
        XCTAssertThrowsError(try AgentRuntimeManifest.parse(plist(["TrendingTabArchitectures": ["arm64"]])))
        XCTAssertThrowsError(try AgentRuntimeManifest.parse(plist(["CFBundleIdentifier": "other.application"])))
        XCTAssertThrowsError(try AgentRuntimeManifest.parse(plist(["TrendingTabMinimumProtocol": 3])))
        XCTAssertThrowsError(try AgentRuntimeManifest.parse(plist(["CFBundleShortVersionString": "1.2.3/../../bad"])))
    }

    func testBundledRuntimeVersionComesFromItsOwnPackage() throws {
        let package = Data(#"{"name":"trendingtab-agent-runtime","version":"0.1.0"}"#.utf8)
        let version = try AgentRuntimeManifest.bundledVersion(package: package)
        XCTAssertEqual(version, "0.1.0")
        let name = "TrendingTab-AgentRuntime-0.1.1.dmg"
        let feed = try JSONSerialization.data(withJSONObject: ["assets": [["name": name,
            "browser_download_url": "https://github.com/tzf1003/TrendingTab/releases/download/runtime-v0.1.1/\(name)",
            "digest": "sha256:" + String(repeating: "a", count: 64)]]])
        XCTAssertEqual(try AgentRuntimeReleaseFeed.parse(feed, currentVersion: version)?.version, "0.1.1")
        XCTAssertThrowsError(try AgentRuntimeManifest.bundledVersion(package: Data(#"{"name":"other","version":"0.1.0"}"#.utf8)))
        XCTAssertThrowsError(try AgentRuntimeManifest.bundledVersion(package: Data(#"{"name":"trendingtab-agent-runtime","version":"../bad"}"#.utf8)))
    }

    func testNewsRuntimeRequiresCompatibleNativeSearchHost() throws {
        let manifest = try AgentRuntimeManifest.parse(plist(["TrendingTabMinimumAppVersion": "0.2.44"]))
        XCTAssertThrowsError(try manifest.validate(appVersion: "0.2.43", systemVersion: "15.0.0"))
        XCTAssertNoThrow(try manifest.validate(appVersion: "0.2.44", systemVersion: "15.0.0"))
        XCTAssertNoThrow(try manifest.validate(appVersion: "0.2.45", systemVersion: "15.0.0"))
    }

    func testBundledPiVersionUsesPinnedPackageMetadata() throws {
        let package = Data(#"{"name":"trendingtab-agent-runtime","version":"0.2.0","dependencies":{"@earendil-works/pi-coding-agent":"2.3.4"}}"#.utf8)
        XCTAssertEqual(try AgentRuntimeManifest.bundledPiVersion(package: package), "2.3.4")
        for value in ["^2.3.4", "latest", "2.3.4/../../bad"] {
            let malformed = try JSONSerialization.data(withJSONObject: ["name": "trendingtab-agent-runtime", "version": "0.2.0", "dependencies": ["@earendil-works/pi-coding-agent": value]])
            XCTAssertThrowsError(try AgentRuntimeManifest.bundledPiVersion(package: malformed))
        }
        XCTAssertThrowsError(try AgentRuntimeManifest.bundledPiVersion(package: Data(#"{"name":"trendingtab-agent-runtime","version":"0.2.0"}"#.utf8)))
    }

    func testFeedSelectsOnlyRuntimeAssetAndRequiresDigestAndExpectedOrigin() throws {
        func data(_ url: String, digest: String = "sha256:" + String(repeating: "a", count: 64)) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["assets": [
                ["name": "TrendingTab-1.2.3.dmg", "browser_download_url": "https://example.test/app.dmg"],
                ["name": "TrendingTab-AgentRuntime-1.2.3.dmg", "browser_download_url": url, "digest": digest]
            ]])
        }
        let url = "https://github.com/tzf1003/TrendingTab/releases/download/v1.2.3/TrendingTab-AgentRuntime-1.2.3.dmg"
        let release = try AgentRuntimeReleaseFeed.parse(data(url), currentVersion: "1.0.0")
        XCTAssertEqual(release?.version, "1.2.3")
        XCTAssertNil(try AgentRuntimeReleaseFeed.parse(data(url), currentVersion: "1.2.3"))
        XCTAssertThrowsError(try AgentRuntimeReleaseFeed.parse(data(url, digest: "sha256:bad"), currentVersion: "1.0.0"))
        XCTAssertThrowsError(try AgentRuntimeReleaseFeed.parse(data(url.replacingOccurrences(of: "github.com", with: "example.test")), currentVersion: "1.0.0"))
    }

    func testRuntimeFeedFindsIndependentReleaseAndIgnoresPrereleases() throws {
        func release(_ version: String, draft: Bool = false, prerelease: Bool = false, hash: String = String(repeating: "a", count: 64)) -> [String: Any] {
            let name = "TrendingTab-AgentRuntime-\(version).dmg"
            return ["draft": draft, "prerelease": prerelease, "assets": [["name": name,
                "browser_download_url": "https://github.com/tzf1003/TrendingTab/releases/download/runtime-v\(version)/\(name)",
                "digest": "sha256:" + hash]]]
        }
        let feed = try JSONSerialization.data(withJSONObject: [release("1.2.0"), release("1.4.0", prerelease: true), release("1.3.0")])
        XCTAssertEqual(try AgentRuntimeReleaseFeed.parse(feed, currentVersion: "1.0.0")?.version, "1.3.0")
        XCTAssertEqual(try AgentRuntimeReleaseFeed.parseCandidates(feed, currentVersion: "1.0.0").map(\.version), ["1.3.0", "1.2.0"])
        let conflict = try JSONSerialization.data(withJSONObject: [release("1.3.0"), release("1.3.0", hash: String(repeating: "b", count: 64))])
        XCTAssertThrowsError(try AgentRuntimeReleaseFeed.parse(conflict, currentVersion: "1.0.0"))
    }

    func testRuntimeSelectionContinuesAfterIncompatibleCandidateAndPropagatesOtherFailures() async throws {
        let assets = ["1.4.0", "1.3.0"].map { version in
            let name = "TrendingTab-AgentRuntime-\(version).dmg"
            return ["name": name, "browser_download_url": "https://github.com/tzf1003/TrendingTab/releases/download/runtime-v\(version)/\(name)",
                    "digest": "sha256:" + String(repeating: "a", count: 64)]
        }
        let candidates = try AgentRuntimeReleaseFeed.parseCandidates(JSONSerialization.data(withJSONObject: ["assets": assets]), currentVersion: "1.0.0")
        let selected = try await AgentRuntimeReleaseFeed.firstCompatible(candidates) { candidate in
            if candidate.version == "1.4.0" { throw AgentRuntimeManifestError.incompatible }
        }
        XCTAssertEqual(selected?.version, "1.3.0")
        let absent = try await AgentRuntimeReleaseFeed.firstCompatible(candidates) { _ in
            throw AgentRuntimeManifestError.incompatible
        }
        XCTAssertNil(absent)
        do {
            _ = try await AgentRuntimeReleaseFeed.firstCompatible(candidates) { _ in
                throw AgentRuntimeVerificationError.invalidSignature
            }
            XCTFail("A signature failure must stop the update")
        } catch AgentRuntimeVerificationError.invalidSignature { }
    }

    func testRuntimeUpdateChecksAllReleasePages() async throws {
        let name = "TrendingTab-AgentRuntime-1.3.0.dmg"
        let ordinary = [String: Any](dictionaryLiteral: ("assets", []))
        let newerName = "TrendingTab-AgentRuntime-1.4.0.dmg"
        let newer: [String: Any] = ["assets": [["name": newerName,
            "browser_download_url": "https://github.com/tzf1003/TrendingTab/releases/download/runtime-v1.4.0/\(newerName)",
            "digest": "sha256:" + String(repeating: "b", count: 64)]]]
        let first = try JSONSerialization.data(withJSONObject: Array(repeating: ordinary, count: 99) + [newer])
        let second = try JSONSerialization.data(withJSONObject: [["assets": [["name": name,
            "browser_download_url": "https://github.com/tzf1003/TrendingTab/releases/download/runtime-v1.3.0/\(name)",
            "digest": "sha256:" + String(repeating: "a", count: 64)]]]])
        let selected = try await AgentRuntimeReleaseFeed.latest(currentVersion: "1.0.0") { request in
            let url = try XCTUnwrap(request.url)
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (page == "1" ? first : second, response)
        }
        XCTAssertEqual(selected?.version, "1.4.0")
        let appReleases = try JSONSerialization.data(withJSONObject: Array(repeating: ordinary, count: 100))
        let older = try await AgentRuntimeReleaseFeed.latest(currentVersion: "1.0.0") { request in
            let url = try XCTUnwrap(request.url)
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value
            return (page == "1" ? appReleases : second,
                    try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        XCTAssertEqual(older?.version, "1.3.0")
    }

    func testCommittedRuntimeCandidateCompletesHandoffAfterCancellation() async throws {
        let name = "TrendingTab-AgentRuntime-1.3.0.dmg"
        let data = try JSONSerialization.data(withJSONObject: ["assets": [["name": name,
            "browser_download_url": "https://github.com/tzf1003/TrendingTab/releases/download/runtime-v1.3.0/\(name)",
            "digest": "sha256:" + String(repeating: "a", count: 64)]]])
        let candidates = try AgentRuntimeReleaseFeed.parseCandidates(data, currentVersion: "1.0.0")
        let task = Task {
            // Successful installation has committed selection before returning.
            let committed = try await AgentRuntimeReleaseFeed.firstCompatible(candidates) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return committed?.version
        }
        let version = try await task.value
        XCTAssertEqual(version, "1.3.0")
    }

    func testRuntimeUpdateReportsIncompleteOrFailedReleaseFeed() async throws {
        let fullPage = try JSONSerialization.data(withJSONObject: Array(repeating: ["assets": []], count: 100))
        do {
            _ = try await AgentRuntimeReleaseFeed.latest(currentVersion: "1.0.0") { request in
                let url = try XCTUnwrap(request.url)
                return (fullPage, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
            XCTFail("A truncated release feed must not be treated as current")
        } catch AgentRuntimeManifestError.incompleteFeed { }
        do {
            _ = try await AgentRuntimeReleaseFeed.latest(currentVersion: "1.0.0") { request in
                let url = try XCTUnwrap(request.url)
                let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value
                return (fullPage, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: page == "1" ? 200 : 429, httpVersion: nil, headerFields: nil)))
            }
            XCTFail("A failed later page must not be treated as current")
        } catch AppUpdateError.rateLimited { }
    }

    func testLiveRuntimeReleaseFeedWhenConfigured() async throws {
        guard ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_LIVE_RUNTIME_FEED"] == "1" else {
            throw XCTSkip("Set TRENDINGTAB_TEST_LIVE_RUNTIME_FEED to check the public GitHub release feed.")
        }
        let release = try await AgentRuntimeReleaseFeed.latest(currentVersion: "9999999.0.0") { request in
            try await URLSession.shared.data(for: request)
        }
        XCTAssertNil(release)
    }

    func testRuntimeHealthRunsToolLoopAndRejectsMismatchAndTimeout() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let node = environment["TRENDINGTAB_TEST_NODE"], let runtime = environment["TRENDINGTAB_TEST_RUNTIME"] else {
            throw XCTSkip("Set the Pi runtime test paths to exercise the health check.")
        }
        let executable = URL(fileURLWithPath: node)
        let health = URL(fileURLWithPath: runtime).deletingLastPathComponent().appendingPathComponent("runtime-health.mjs")
        try await AgentRuntimeHealth.verify(executable: executable, script: health, expectedPiVersion: "1.5.0")
        do {
            try await AgentRuntimeHealth.verify(executable: executable, script: health, expectedPiVersion: "9.9.9")
            XCTFail("Incorrect Pi version must fail health validation")
        } catch is AgentRuntimeHealthError { }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingTool = directory.appendingPathComponent("missing-tool.mjs")
        let missing = AgentToolName.allCases.filter { $0 != .openCurrentStory }.map(\.rawValue)
        let output = try JSONSerialization.data(withJSONObject: ["protocol": 1, "streaming": true, "tools": true,
                                                                  "piVersion": "1.5.0", "toolNames": missing])
        try "process.stdout.write(\(String(decoding: try JSONEncoder().encode(String(decoding: output, as: UTF8.self)), as: UTF8.self)))".write(to: missingTool, atomically: true, encoding: .utf8)
        do {
            try await AgentRuntimeHealth.verify(executable: executable, script: missingTool, expectedPiVersion: "1.5.0")
            XCTFail("A runtime missing a required tool must fail health validation")
        } catch is AgentRuntimeHealthError { }
        let hanging = directory.appendingPathComponent("hang.mjs")
        try "setInterval(() => {}, 1000)".write(to: hanging, atomically: true, encoding: .utf8)
        do {
            try await AgentRuntimeHealth.verify(executable: executable, script: hanging, expectedPiVersion: "1.5.0", timeout: 0.2)
            XCTFail("Timed-out process must not pass health validation")
        } catch is AgentRuntimeHealthError { }
    }

    func testRuntimeHealthRejectsBrokenEntryPointEvenWhenStandaloneCheckPasses() async throws {
        guard let node = ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_NODE"] else {
            throw XCTSkip("Set the Node path to exercise entry-point health validation.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let health = directory.appendingPathComponent("runtime-health.mjs")
        let output = try JSONSerialization.data(withJSONObject: ["protocol": 1, "streaming": true, "tools": true,
            "piVersion": "1.5.0", "toolNames": AgentToolName.allCases.map(\.rawValue)])
        let encoded = try JSONEncoder().encode(String(decoding: output, as: UTF8.self))
        try "process.stdout.write(\(String(decoding: encoded, as: UTF8.self)))".write(to: health, atomically: true, encoding: .utf8)
        try "process.exit(1)".write(to: directory.appendingPathComponent("runtime.mjs"), atomically: true, encoding: .utf8)
        do {
            try await AgentRuntimeHealth.verify(executable: URL(fileURLWithPath: node), script: health, expectedPiVersion: "1.5.0")
            XCTFail("A broken production entry point must be rejected before activation")
        } catch is AgentRuntimeHealthError { }
    }

    func testUntrustedRuntimeBundleIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try AgentRuntimeVerifier.verify(bundle: directory, appVersion: "0.2.10", systemVersion: "15.0.0"))
        if let path = ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_UNTRUSTED_RUNTIME"] {
            XCTAssertThrowsError(try AgentRuntimeVerifier.verify(bundle: URL(fileURLWithPath: path), appVersion: "0.2.10", systemVersion: "15.0.0"))
        }
        if let path = ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_TRUSTED_RUNTIME"] {
            let trusted = try AgentRuntimeVerifier.verify(bundle: URL(fileURLWithPath: path), appVersion: "0.2.44", systemVersion: "15.0.0")
            XCTAssertEqual(trusted.piVersion, "1.5.0")
        }
    }

    @MainActor
    func testInstallerRejectsCorruptImageAndInvalidSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("fixture.dmg")
        try Data("bad image".utf8).write(to: image)
        let asset = "TrendingTab-AgentRuntime-1.2.3.dmg"
        let payload = try JSONSerialization.data(withJSONObject: ["assets": [["name": asset,
            "browser_download_url": "https://github.com/tzf1003/TrendingTab/releases/download/v1.2.3/\(asset)",
            "digest": "sha256:" + String(repeating: "0", count: 64)]]])
        let release = try XCTUnwrap(AgentRuntimeReleaseFeed.parse(payload, currentVersion: "1.0.0"))
        let installer = AgentRuntimeInstaller(root: root, appVersion: "0.2.10", systemVersion: "15.0.0",
            bundledExecutable: URL(fileURLWithPath: "/invalid/node"), bundledHealthScript: URL(fileURLWithPath: "/invalid/health"), bundledPiVersion: "1.5.0")
        do { _ = try await installer.install(dmg: image, release: release); XCTFail("Corrupt image should be rejected") }
        catch AgentRuntimeInstallError.checksum { }
        let selection = try await installer.selection()
        XCTAssertNil(selection.active)
        XCTAssertNil(selection.previous)
        try Data(#"{"active":"../outside","previous":null}"#.utf8).write(to: root.appendingPathComponent("selection.json"))
        do { _ = try await installer.selection(); XCTFail("Invalid selection must not be read") }
        catch AgentRuntimeInstallError.invalidPackage { }
    }

    @MainActor
    func testCancelledRuntimeInstallLeavesSelectionUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("fixture.dmg")
        try Data("test".utf8).write(to: image)
        let asset = "TrendingTab-AgentRuntime-1.2.3.dmg"
        let payload = try JSONSerialization.data(withJSONObject: ["assets": [["name": asset,
            "browser_download_url": "https://github.com/tzf1003/TrendingTab/releases/download/runtime-v1.2.3/\(asset)",
            "digest": "sha256:" + String(repeating: "0", count: 64)]]])
        let release = try XCTUnwrap(AgentRuntimeReleaseFeed.parse(payload, currentVersion: "1.0.0"))
        let installer = AgentRuntimeInstaller(root: root, appVersion: "0.2.10", systemVersion: "15.0.0",
            bundledExecutable: URL(fileURLWithPath: "/invalid/node"), bundledHealthScript: URL(fileURLWithPath: "/invalid/health"), bundledPiVersion: "1.5.0")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await installer.install(dmg: image, release: release)
        }
        do { _ = try await task.value; XCTFail("Cancelled installation should stop") }
        catch is CancellationError { }
        let selection = try await installer.selection()
        XCTAssertNil(selection.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("versions").path))
    }

    @MainActor
    func testSignedImageStillRequiresNotarization() async throws {
        guard let path = ProcessInfo.processInfo.environment["TRENDINGTAB_TEST_SIGNED_RUNTIME_DMG"] else {
            throw XCTSkip("Set a signed, non-notarized runtime image to exercise notarization rejection.")
        }
        let image = URL(fileURLWithPath: path)
        let name = image.lastPathComponent
        let hash = SHA256.hash(data: try Data(contentsOf: image, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        let payload = try JSONSerialization.data(withJSONObject: ["assets": [["name": name,
            "browser_download_url": "https://github.com/tzf1003/TrendingTab/releases/download/test/\(name)",
            "digest": "sha256:" + hash]]])
        let release = try XCTUnwrap(AgentRuntimeReleaseFeed.parse(payload, currentVersion: "0.0.0"))
        let root = image.deletingLastPathComponent().appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AgentRuntimeInstaller(root: root, appVersion: "0.2.10", systemVersion: "15.0.0",
            bundledExecutable: URL(fileURLWithPath: "/invalid/node"), bundledHealthScript: URL(fileURLWithPath: "/invalid/health"), bundledPiVersion: "1.5.0")
        do { _ = try await installer.install(dmg: image, release: release); XCTFail("Image without a notarization ticket must fail") }
        catch AgentRuntimeInstallError.notarization { }
        let selection = try await installer.selection()
        XCTAssertNil(selection.active)
    }

    @MainActor
    func testNotarizedRuntimeInstallAndRollback() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TRENDINGTAB_TEST_NOTARIZED_RUNTIME_DMG"],
              let node = environment["TRENDINGTAB_TEST_NODE"], let runtime = environment["TRENDINGTAB_TEST_RUNTIME"] else {
            throw XCTSkip("Set the notarized runtime image and Pi test paths to exercise installation.")
        }
        let image = URL(fileURLWithPath: path)
        let name = image.lastPathComponent
        let digest = SHA256.hash(data: try Data(contentsOf: image, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        let payload = try JSONSerialization.data(withJSONObject: ["assets": [["name": name,
            "browser_download_url": "https://github.com/tzf1003/TrendingTab/releases/download/test/\(name)",
            "digest": "sha256:" + digest]]])
        let release = try XCTUnwrap(AgentRuntimeReleaseFeed.parse(payload, currentVersion: "0.0.1"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-install-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let health = URL(fileURLWithPath: runtime).deletingLastPathComponent().appendingPathComponent("runtime-health.mjs")
        let installer = AgentRuntimeInstaller(root: root, appVersion: "0.2.44", systemVersion: "15.0.0",
            bundledExecutable: URL(fileURLWithPath: node), bundledHealthScript: health, bundledPiVersion: "1.5.0")
        let installed = try await installer.install(dmg: image, release: release)
        XCTAssertEqual(installed.active, release.version)
        let active = try await installer.resolveActive()
        XCTAssertFalse(active.bundled)
        XCTAssertEqual(active.version, release.version)
        let rolledBack = try await installer.rollback()
        XCTAssertNil(rolledBack.active)
        XCTAssertEqual(rolledBack.previous, release.version)
        let bundled = try await installer.resolveActive()
        XCTAssertTrue(bundled.bundled)
        let reinstalled = try await installer.install(dmg: image, release: release)
        XCTAssertEqual(reinstalled.active, release.version)
        let reinstalling = Task { try await installer.install(dmg: image, release: release) }
        // Installation yields during hashing with its operation lock held.
        for _ in 0..<100 {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            if entries.contains(where: { $0.hasPrefix(".download-") }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let resolving = Task { try await installer.resolveActive() }
        let recovered: AgentRuntimeInstaller.Location?
        do { recovered = try await installer.recoverFailedRuntime(script: active.script) }
        catch {
            _ = try? await reinstalling.value
            throw error
        }
        _ = try await reinstalling.value
        _ = try await resolving.value
        XCTAssertTrue(try XCTUnwrap(recovered).bundled)
        let recoveredSelection = try await installer.selection()
        XCTAssertNil(recoveredSelection.active)
    }

    @MainActor
    func testStartupRecoversToHealthyBundledRuntime() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let node = environment["TRENDINGTAB_TEST_NODE"], let runtime = environment["TRENDINGTAB_TEST_RUNTIME"] else {
            throw XCTSkip("Set the Pi runtime test paths to exercise recovery.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selection.json")
        try Data(#"{"active":"2.0.0","previous":null}"#.utf8).write(to: selected)
        let health = URL(fileURLWithPath: runtime).deletingLastPathComponent().appendingPathComponent("runtime-health.mjs")
        let installer = AgentRuntimeInstaller(root: root, appVersion: "0.2.10", systemVersion: "15.0.0",
            bundledExecutable: URL(fileURLWithPath: node), bundledHealthScript: health, bundledPiVersion: "1.5.0")
        let location = try await installer.resolveActive()
        XCTAssertTrue(location.bundled)
        XCTAssertTrue(location.recovered)
        let selection = try await installer.selection()
        XCTAssertNil(selection.active)
        XCTAssertNil(selection.previous)

        try Data(#"{"active":"2.0.0","previous":"1.0.0"}"#.utf8).write(to: selected)
        let stale = try await installer.recoverFailedRuntime(script: URL(fileURLWithPath: "/old/runtime.mjs"))
        XCTAssertNil(stale)
        let unchangedSelection = try await installer.selection()
        XCTAssertEqual(unchangedSelection.active, "2.0.0")
        let failedScript = try await installer.bundle(for: "2.0.0").appendingPathComponent("Contents/Resources/runtime.mjs")
        let fallback = try await installer.recoverFailedRuntime(script: failedScript)
        XCTAssertTrue(try XCTUnwrap(fallback).bundled)
        let persisted = try await installer.selection()
        XCTAssertNil(persisted.active)
        XCTAssertNil(persisted.previous)
    }
}
