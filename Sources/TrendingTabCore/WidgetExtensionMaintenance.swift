import Foundation

/// App replacement must retire the old extension before its executable is removed.
/// Otherwise WidgetKit can keep serving requests from the unlinked backup bundle.
public enum WidgetExtensionMaintenance {
    private static let executableSuffix = "/Contents/PlugIns/TrendingTabWidget.appex/Contents/MacOS/TrendingTabWidget"
    private static let registrar = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    struct CommandResult {
        var status: Int32
        var output: String
    }

    typealias Runner = (String, [String]) throws -> CommandResult

    public static func prepareForReplacement(at app: URL) throws {
        try retireExtensions(at: app, includeCurrent: true)
    }

    public static func register(at app: URL) throws {
        try register(at: app, run: execute)
    }

    public static func repairAfterLaunch(at app: URL) throws {
        try repairAfterLaunch(at: app, run: execute)
    }

    static func repairAfterLaunch(at app: URL, run: Runner) throws {
        try retireExtensions(at: app, includeCurrent: false, run: run)
        try register(at: app, run: run)
    }

    static func retireExtensions(at app: URL, includeCurrent: Bool) throws {
        try retireExtensions(at: app, includeCurrent: includeCurrent, run: execute)
    }

    private static func register(at app: URL, run: Runner) throws {
        try requireSuccess(run(registrar, ["-f", app.path]))
        let widget = app.appendingPathComponent("Contents/PlugIns/TrendingTabWidget.appex")
        try requireSuccess(run("/usr/bin/pluginkit", ["-a", widget.path]))
    }

    private static func retireExtensions(at app: URL, includeCurrent: Bool, run: Runner) throws {
        // Limit discovery to this login and the exact extension executable name.
        let found = try run("/usr/bin/pgrep", ["-u", String(getuid()), "-x", "TrendingTabWidget"])
        if found.status == 1 { return }
        try requireSuccess(found)
        let candidates = found.output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }.filter { $0 > 0 }
        guard !candidates.isEmpty else { return }
        let listing = try run("/usr/sbin/lsof", ["-a", "-p", candidates.map(String.init).joined(separator: ","), "-d", "txt", "-Fn"])
        // All candidates may have exited between discovery and inspection.
        if listing.status == 1 && listing.output.isEmpty { return }
        try requireSuccess(listing)
        let owned = Set(processIDs(in: listing.output, app: app, includeCurrent: includeCurrent)).intersection(candidates).sorted()
        guard !owned.isEmpty else { return }
        try requireSuccess(run("/bin/kill", ["-TERM"] + owned.map(String.init)))
        for _ in 0..<40 {
            let alive = try owned.filter { try run("/bin/kill", ["-0", String($0)]).status == 0 }
            if alive.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw AppUpdateError.installFailed("旧版小组件仍在退出，请稍后重试。")
    }

    static func processIDs(in listing: String, app: URL, includeCurrent: Bool) -> [Int32] {
        let directory = app.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let appPath = directory.appendingPathComponent(app.lastPathComponent).path
        var pid: Int32?
        var result = Set<Int32>()
        for line in listing.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()); continue }
            guard line.first == "n", let pid, pid > 0 else { continue }
            let path = String(line.dropFirst())
            guard path.hasSuffix(executableSuffix) else { continue }
            let bundle = URL(fileURLWithPath: String(path.dropLast(executableSuffix.count))).standardizedFileURL
            if includeCurrent && bundle.path == appPath { result.insert(pid); continue }
            guard bundle.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.path else { continue }
            let name = bundle.lastPathComponent
            let prefix = ".TrendingTab-backup-"
            guard name.hasPrefix(prefix), name.hasSuffix(".app"),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil else { continue }
            result.insert(pid)
        }
        return result.sorted()
    }

    private static func requireSuccess(_ result: CommandResult) throws {
        guard result.status == 0 else {
            throw AppUpdateError.installFailed("小组件注册或重启失败（\(result.status)）：\(result.output.prefix(300))")
        }
    }

    private static func execute(_ path: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
