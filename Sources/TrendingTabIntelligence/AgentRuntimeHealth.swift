import Foundation
import Darwin

public enum AgentRuntimeHealthError: Error, LocalizedError {
    case failed
    public var errorDescription: String? { "Agent 运行时自检失败。" }
}

/// Runs the candidate's local mock-model/tool loop without any configured credentials.
public enum AgentRuntimeHealth {
    private struct Result: Decodable {
        let protocolVersion: Int
        let streaming, tools: Bool
        let piVersion: String
        let toolNames: [String]
        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol", streaming, tools, piVersion, toolNames
        }
    }

    public static func verify(executable: URL, script: URL, expectedPiVersion: String,
                              timeout: TimeInterval = 15) async throws {
        guard timeout > 0, timeout <= 60 else { throw AgentRuntimeHealthError.failed }
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let outputURL = manager.temporaryDirectory.appendingPathComponent("trendingtab-health-\(UUID().uuidString)")
            guard manager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw AgentRuntimeHealthError.failed
            }
            defer { try? manager.removeItem(at: outputURL) }
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            let child = Process()
            child.executableURL = executable
            child.arguments = [script.path]
            child.currentDirectoryURL = script.deletingLastPathComponent()
            child.environment = ["PATH": "/usr/bin:/bin", "PI_OFFLINE": "1"]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            do { try child.run() } catch { throw AgentRuntimeHealthError.failed }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) } }
            timer.resume()
            child.waitUntilExit()
            timer.cancel()
            guard child.terminationReason == .exit, child.terminationStatus == 0,
                  let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32_768,
                  let data = try? Data(contentsOf: outputURL),
                  let result = try? JSONDecoder().decode(Result.self, from: data),
                  result.protocolVersion == AgentRuntimeManifest.bridgeProtocol,
                  result.piVersion == expectedPiVersion, result.streaming, result.tools,
                  Set(AgentToolName.allCases.map(\.rawValue)).isSubset(of: Set(result.toolNames)) else {
                throw AgentRuntimeHealthError.failed
            }
        }.value
    }
}
