import XCTest
@testable import TrendingTabCore

final class WidgetExtensionMaintenanceTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/TrendingTab.app")

    func testLaunchRetiresOnlyExtensionsMappedFromUpdateBackups() {
        let old = "/Applications/.TrendingTab-backup-54DA4DEA-EE44-48E6-9D07-9FBDF07FA4D9.app"
        let listing = """
        p123
        n\(old)/Contents/PlugIns/TrendingTabWidget.appex/Contents/MacOS/TrendingTabWidget
        p124
        n/Applications/TrendingTab.app/Contents/PlugIns/TrendingTabWidget.appex/Contents/MacOS/TrendingTabWidget
        p125
        n/Volumes/Build/TrendingTab.app/Contents/PlugIns/TrendingTabWidget.appex/Contents/MacOS/TrendingTabWidget
        p126
        n/Applications/.TrendingTab-backup-other.app/Contents/PlugIns/TrendingTabWidget.appex/Contents/MacOS/TrendingTabWidget
        p127
        n/Applications/.TrendingTab-backup-54DA4DEA-EE44-48E6-9D07-9FBDF07FA4D9.app/Contents/MacOS/TrendingTab
        """
        XCTAssertEqual(WidgetExtensionMaintenance.processIDs(in: listing, app: app, includeCurrent: false), [123])
        XCTAssertEqual(WidgetExtensionMaintenance.processIDs(in: listing, app: app, includeCurrent: true), [123, 124])
    }

    func testRecoveryRegistersInstalledBundleAfterRetiringStaleExtension() throws {
        var commands: [String] = []
        try WidgetExtensionMaintenance.repairAfterLaunch(at: app) { path, arguments in
            commands.append(([path] + arguments).joined(separator: " "))
            if path == "/usr/bin/pgrep" { return .init(status: 0, output: "123\n") }
            if path == "/usr/sbin/lsof" {
                return .init(status: 0, output: "p123\nn/Applications/.TrendingTab-backup-54DA4DEA-EE44-48E6-9D07-9FBDF07FA4D9.app/Contents/PlugIns/TrendingTabWidget.appex/Contents/MacOS/TrendingTabWidget\n")
            }
            if arguments.first == "-0" { return .init(status: 1, output: "") }
            return .init(status: 0, output: "")
        }
        let stop = try XCTUnwrap(commands.firstIndex { $0 == "/bin/kill -TERM 123" })
        let registration = try XCTUnwrap(commands.firstIndex { $0.contains("lsregister -f /Applications/TrendingTab.app") })
        XCTAssertLessThan(stop, registration)
        XCTAssertTrue(commands.last?.contains("pluginkit -a /Applications/TrendingTab.app/Contents/PlugIns/TrendingTabWidget.appex") == true)
    }

    func testRegistrationFailureIsReported() {
        XCTAssertThrowsError(try WidgetExtensionMaintenance.repairAfterLaunch(at: app) { path, _ in
            .init(status: path == "/usr/bin/pgrep" ? 1 : 9, output: "registration failed")
        })
    }

    func testRetiresAnActualUnlinkedBackupExecutableAndPreservesAnotherCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent(".TrendingTab-backup-\(UUID().uuidString).app")
        let unrelated = root.appendingPathComponent("Other/TrendingTab.app")
        var processes: [Process] = []
        defer { for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() } }
        for app in [backup, unrelated] {
            let executable = app.appendingPathComponent("Contents/PlugIns/TrendingTabWidget.appex/Contents/MacOS/TrendingTabWidget")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
            let process = Process()
            process.executableURL = executable
            process.arguments = ["30"]
            try process.run()
            processes.append(process)
        }
        // Reproduce the updater deleting its backup while the extension stays mapped.
        try FileManager.default.removeItem(at: backup)
        let probe = Process()
        let output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        probe.arguments = ["-a", "-p", String(processes[0].processIdentifier), "-d", "txt", "-Fn"]
        probe.standardOutput = output
        try probe.run()
        let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        XCTAssertEqual(WidgetExtensionMaintenance.processIDs(in: listing, app: root.appendingPathComponent("TrendingTab.app"), includeCurrent: false), [processes[0].processIdentifier], listing)
        try WidgetExtensionMaintenance.retireExtensions(at: root.appendingPathComponent("TrendingTab.app"), includeCurrent: false)
        XCTAssertFalse(processes[0].isRunning)
        XCTAssertTrue(processes[1].isRunning)
    }

    func testReplacementRetainsOriginalWhenExtensionCannotExit() throws {
        try withApplicationCopies { staged, destination, backup in
            XCTAssertThrowsError(try AppInstaller.replaceApplication(staged: staged, destination: destination, backup: backup,
                prepare: { _ in throw AppUpdateError.installFailed("busy") }, register: { _ in XCTFail("unexpected registration") }))
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    func testRegistrationFailureRestoresOriginalApplication() throws {
        try withApplicationCopies { staged, destination, backup in
            var registeredVersions: [String] = []
            XCTAssertThrowsError(try AppInstaller.replaceApplication(staged: staged, destination: destination, backup: backup,
                prepare: { _ in }, register: { url in
                    let version = try String(contentsOf: url, encoding: .utf8)
                    registeredVersions.append(version)
                    if version == "new" { throw AppUpdateError.installFailed("registration") }
                }))
            XCTAssertEqual(registeredVersions, ["new", "old"])
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        }
    }

    func testReplacementRegistersBeforeRemovingBackup() throws {
        try withApplicationCopies { staged, destination, backup in
            var prepared = false
            try AppInstaller.replaceApplication(staged: staged, destination: destination, backup: backup,
                prepare: { url in
                    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
                    prepared = true
                }, register: { url in
                    XCTAssertTrue(prepared)
                    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
                    XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old")
                })
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    private func withApplicationCopies(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged")
        let destination = root.appendingPathComponent("installed")
        try "new".write(to: staged, atomically: true, encoding: .utf8)
        try "old".write(to: destination, atomically: true, encoding: .utf8)
        try body(staged, destination, root.appendingPathComponent("backup"))
    }
}
