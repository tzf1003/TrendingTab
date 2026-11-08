import Foundation
import XCTest
@testable import TrendingTabIntelligence

final class AgentRuntimeArchitectureTests: XCTestCase {
    func testEveryNativeHelperMustSupportBothArchitectures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-architecture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.c")
        try Data("int fixture(void) { return 0; }\n".utf8).write(to: source)
        try compile(source, output: root.appendingPathComponent("node"), architectures: ["arm64", "x86_64"])
        try Data("ordinary resource".utf8).write(to: root.appendingPathComponent("resource.txt"))
        XCTAssertNoThrow(try AgentRuntimeVerifier.verifyNativeArchitectures(in: root))

        let helpers = root.appendingPathComponent("nested/.native", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let plugin = helpers.appendingPathComponent("platform.node")
        for architecture in ["x86_64", "arm64"] {
            try compile(source, output: plugin, architectures: [architecture])
            XCTAssertThrowsError(try AgentRuntimeVerifier.verifyNativeArchitectures(in: root)) { error in
                guard case AgentRuntimeVerificationError.invalidArchitecture = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        try compile(source, output: plugin, architectures: ["arm64", "x86_64"])
        XCTAssertNoThrow(try AgentRuntimeVerifier.verifyNativeArchitectures(in: root))
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: plugin)
        XCTAssertThrowsError(try AgentRuntimeVerifier.verifyNativeArchitectures(in: root))
    }

    func testEmptyRuntimeHasNoNativeCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try AgentRuntimeVerifier.verifyNativeArchitectures(in: root))
    }

    private func compile(_ source: URL, output: URL, architectures: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang", "-dynamiclib"] + architectures.flatMap { ["-arch", $0] }
            + [source.path, "-o", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(domain: "RuntimeArchitectureFixture", code: Int(process.terminationStatus))
        }
    }
}
