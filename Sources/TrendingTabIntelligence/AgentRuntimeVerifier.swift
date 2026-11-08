import Foundation
import Security

public enum AgentRuntimeVerificationError: Error, LocalizedError {
    case invalidSignature, invalidLayout, invalidArchitecture
    public var errorDescription: String? {
        switch self {
        case .invalidSignature: "Agent 运行时签名无效。"
        case .invalidLayout: "Agent 运行时文件结构无效。"
        case .invalidArchitecture: "Agent 运行时缺少所需的处理器架构。"
        }
    }
}

public enum AgentRuntimeVerifier {
    public static func signatureIdentity(bundle: URL) throws -> Data {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data,
              !hash.isEmpty else { throw AgentRuntimeVerificationError.invalidSignature }
        return hash
    }
    /// Pin the Developer ID identity and verify the sealed resources before reading metadata.
    public static func verify(bundle: URL, appVersion: String, systemVersion: String) throws -> AgentRuntimeManifest {
        guard bundle.pathExtension == "app", try isRegularDirectory(bundle) else { throw AgentRuntimeVerificationError.invalidLayout }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw AgentRuntimeVerificationError.invalidSignature
        }
        let expression = """
        anchor apple generic and identifier "dev.trendingtab.runtime" and certificate leaf[subject.OU] = "GJUT2BVM7R" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw AgentRuntimeVerificationError.invalidSignature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw AgentRuntimeVerificationError.invalidSignature
        }
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/node")
        let runtime = contents.appendingPathComponent("Resources/runtime.mjs")
        let health = contents.appendingPathComponent("Resources/runtime-health.mjs")
        let info = contents.appendingPathComponent("Info.plist")
        guard try [executable, runtime, health, info].allSatisfy({ try isRegularFile($0, inside: bundle) }) else {
            throw AgentRuntimeVerificationError.invalidLayout
        }
        let manifest = try AgentRuntimeManifest.parse(Data(contentsOf: info))
        try manifest.validate(appVersion: appVersion, systemVersion: systemVersion)
        guard try architectures(at: executable) == Set(["arm64", "x86_64"]) else {
            throw AgentRuntimeVerificationError.invalidArchitecture
        }
        try verifyNativeArchitectures(in: bundle)
        return manifest
    }

    /// Apply the distribution architecture requirement to downloaded and
    /// previously selected components, including dynamically loaded helpers.
    static func verifyNativeArchitectures(in root: URL) throws {
        let magic: Set<Data> = [
            Data([0xfe, 0xed, 0xfa, 0xce]), Data([0xce, 0xfa, 0xed, 0xfe]),
            Data([0xfe, 0xed, 0xfa, 0xcf]), Data([0xcf, 0xfa, 0xed, 0xfe]),
            Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca]),
            Data([0xca, 0xfe, 0xba, 0xbf]), Data([0xbf, 0xba, 0xfe, 0xca]),
        ]
        var directories = [root]
        var nativeFiles = 0
        while let directory = directories.popLast() {
            let children = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            for child in children {
                let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { continue }
                if values.isDirectory == true { directories.append(child); continue }
                guard values.isRegularFile == true else { continue }
                let handle = try FileHandle(forReadingFrom: child)
                let header: Data
                do { header = try handle.read(upToCount: 4) ?? Data(); try handle.close() }
                catch { try? handle.close(); throw error }
                guard magic.contains(header) else { continue }
                guard try Set(["arm64", "x86_64"]).isSubset(of: architectures(at: child)) else {
                    throw AgentRuntimeVerificationError.invalidArchitecture
                }
                nativeFiles += 1
            }
        }
        guard nativeFiles > 0 else { throw AgentRuntimeVerificationError.invalidArchitecture }
    }

    private static func isRegularDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularFile(_ url: URL, inside bundle: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let root = bundle.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return values.isRegularFile == true && values.isSymbolicLink != true &&
            url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root)
    }

    private static func architectures(at url: URL) throws -> Set<String> {
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        child.arguments = [url.path, "-archs"]
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { throw AgentRuntimeVerificationError.invalidArchitecture }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        guard child.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw AgentRuntimeVerificationError.invalidArchitecture
        }
        return Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
