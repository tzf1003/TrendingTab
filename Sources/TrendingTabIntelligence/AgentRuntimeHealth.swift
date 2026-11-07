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
            try verifyEntryPoint(executable: executable,
                script: script.deletingLastPathComponent().appendingPathComponent("runtime.mjs"),
                expectedPiVersion: expectedPiVersion, timeout: timeout)
        }.value
    }

    /// Validate the production JSON-RPC entry point before persisting a selection.
    /// A separate health script can pass even when runtime.mjs cannot load.
    private static func verifyEntryPoint(executable: URL, script: URL, expectedPiVersion: String,
                                         timeout: TimeInterval) throws {
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.executableURL = executable
        child.arguments = [script.path]
        child.currentDirectoryURL = script.deletingLastPathComponent()
        child.environment = ["PATH": "/usr/bin:/bin", "PI_OFFLINE": "1"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { throw AgentRuntimeHealthError.failed }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) } }
        timer.resume()
        defer {
            timer.cancel()
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        do {
            let hello = try exchange("hello", input: input.fileHandleForWriting, output: output.fileHandleForReading)
            guard hello["protocol"] as? Int == AgentRuntimeManifest.bridgeProtocol,
                  hello["pi"] as? String == expectedPiVersion,
                  let version = hello["runtime"] as? String, AgentRuntimeManifest.validVersion(version) else {
                throw AgentRuntimeHealthError.failed
            }
            let result = try exchange("selfTest", input: input.fileHandleForWriting, output: output.fileHandleForReading)
            guard result["protocol"] as? Int == AgentRuntimeManifest.bridgeProtocol,
                  result["streaming"] as? Bool == true, result["tools"] as? Bool == true else {
                throw AgentRuntimeHealthError.failed
            }
        } catch { throw AgentRuntimeHealthError.failed }
    }

    private static func exchange(_ method: String, input: FileHandle, output: FileHandle) throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": method, "method": method, "params": [:]])
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        try input.write(contentsOf: frame)
        let header = try readExactly(4, from: output)
        let responseLength = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...32_768).contains(responseLength) else { throw AgentRuntimeHealthError.failed }
        let data = try readExactly(responseLength, from: output)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["jsonrpc"] as? String == "2.0", response["id"] as? String == method,
              response["error"] == nil, let result = response["result"] as? [String: Any] else {
            throw AgentRuntimeHealthError.failed
        }
        return result
    }

    private static func readExactly(_ length: Int, from file: FileHandle) throws -> Data {
        var data = Data()
        while data.count < length {
            guard let part = try file.read(upToCount: length - data.count), !part.isEmpty else {
                throw AgentRuntimeHealthError.failed
            }
            data.append(part)
        }
        return data
    }
}
