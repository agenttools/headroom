// Native-messaging host manifest: check, write and repair (SPEC §8.4, §8.6).
//
// The file is `<HOME>/Library/Application Support/Google/Chrome/NativeMessagingHosts/dev.adder.headroom.json`
// (`HeadroomEnv.nativeHostManifest`, so tests move it with HOME). Chrome for Testing reads
// `<user-data-dir>/NativeMessagingHosts/` instead: use `HostManifest(directory:)`.
//
// The content matches what install.sh writes:
//   {"name":"dev.adder.headroom","description":"Headroom tab memory bridge","path":"<…/Contents/Helpers/headroom-host>",
//    "type":"stdio","allowed_origins":["chrome-extension://<id>/"]}
//
// `repair` rewrites the file only when it is missing, unreadable, or names another host path or extension id
// (for example after Headroom.app moved). It never touches any other file in that folder.

import CryptoKit
import Foundation
import HeadroomContracts

public struct HostManifest: Sendable {
    public static let fileName = "\(HeadroomIDs.nativeHostName).json"
    public static let description = "Headroom tab memory bridge"

    /// Absolute path of the manifest file.
    public let path: String

    public init(env: HeadroomEnv) { path = env.nativeHostManifest }
    public init(directory: String) { path = (directory as NSString).appendingPathComponent(Self.fileName) }

    public struct Contents: Codable, Sendable, Hashable {
        public var name: String
        public var description: String
        public var path: String
        public var type: String
        public var allowed_origins: [String]
        public init(hostPath: String, extensionId: String) {
            name = HeadroomIDs.nativeHostName
            description = HostManifest.description
            path = hostPath
            type = "stdio"
            allowed_origins = [HostManifest.origin(extensionId)]
        }
    }

    public enum Status: Sendable, Equatable, CustomStringConvertible {
        case ok
        case missing
        case invalid(String)
        /// The file exists but differs: each string names one problem.
        case mismatch([String])
        public var isOK: Bool { self == .ok }
        public var description: String {
            switch self {
            case .ok: "installed"
            case .missing: "missing"
            case .invalid(let s): "unreadable (\(s))"
            case .mismatch(let p): "wrong: " + p.joined(separator: "; ")
            }
        }
    }

    public static func origin(_ extensionId: String) -> String { "chrome-extension://\(extensionId)/" }

    public func read() -> Contents? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: d)
    }

    /// Compares the file with what it should be. `hostPath` nil skips the host-path check.
    public func status(hostPath: String?, extensionId: String) -> Status {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let d = FileManager.default.contents(atPath: path) else { return .invalid("cannot read the file") }
        let c: Contents
        do { c = try JSONDecoder().decode(Contents.self, from: d) } catch { return .invalid("not a host manifest") }
        var problems: [String] = []
        if c.name != HeadroomIDs.nativeHostName { problems.append("name is \(c.name)") }
        if c.type != "stdio" { problems.append("type is \(c.type)") }
        if !c.allowed_origins.contains(Self.origin(extensionId)) {
            problems.append("does not allow extension \(extensionId)")
        }
        if let hostPath, c.path != hostPath { problems.append("host path is \(c.path), expected \(hostPath)") }
        if !FileManager.default.isExecutableFile(atPath: c.path) { problems.append("host \(c.path) is not an executable file") }
        return problems.isEmpty ? .ok : .mismatch(problems)
    }

    public static func encode(_ c: Contents) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var d = (try? enc.encode(c)) ?? Data()
        d.append(0x0A)
        return d
    }

    /// Writes the manifest atomically (mode 0644), creating the folder if needed.
    public func write(hostPath: String, extensionId: String) throws {
        guard hostPath.hasPrefix("/") else { throw ManifestError("host path must be absolute: \(hostPath)") }
        guard Self.isValidExtensionId(extensionId) else { throw ManifestError("not an extension id: \(extensionId)") }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: path)
        try Self.encode(Contents(hostPath: hostPath, extensionId: extensionId)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }

    /// Writes the manifest if `status` is not OK. Returns true if it wrote the file.
    @discardableResult
    public func repair(hostPath: String, extensionId: String) throws -> Bool {
        if status(hostPath: hostPath, extensionId: extensionId).isOK { return false }
        try write(hostPath: hostPath, extensionId: extensionId)
        return true
    }

    public struct ManifestError: Error, CustomStringConvertible {
        public let description: String
        init(_ s: String) { description = s }
    }

    // MARK: - Extension id and host path

    public static func isValidExtensionId(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { ("a"..."p").contains($0) }
    }

    /// Chrome's rule: sha256 of the DER public key, first 32 hex digits, each 0-f mapped to a-p.
    public static func extensionId(publicKeyBase64: String) -> String? {
        guard let der = Data(base64Encoded: publicKeyBase64.filter { !$0.isWhitespace }), !der.isEmpty else { return nil }
        let hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined().prefix(32)
        return String(hex.map { c -> Character in
            let v = Int(String(c), radix: 16)!
            return Character(UnicodeScalar(UInt8(97 + v)))
        })
    }

    /// The id that follows from `manifest.json`'s "key".
    public static func extensionId(manifestAt path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let key = o["key"] as? String else { return nil }
        return extensionId(publicKeyBase64: key)
    }

    /// The install location (`install.sh`): ~/Applications/Headroom.app.
    public static func installedAppPath(env: HeadroomEnv) -> String { env.home + "/Applications/Headroom.app" }

    /// bundleDefaults(), but only when this process runs from the installed bundle. A build/ or QA copy of the
    /// app must never point Chrome's bridge file at itself (build.sh deletes build/Headroom.app on the next build).
    public static func installedBundleDefaults(env: HeadroomEnv, _ bundle: Bundle = .main) -> (hostPath: String, extensionId: String)? {
        let me = (bundle.bundlePath as NSString).resolvingSymlinksInPath
        let installed = (installedAppPath(env: env) as NSString).resolvingSymlinksInPath
        guard me == installed else { return nil }
        return bundleDefaults(bundle)
    }

    /// What the running app should use: host = `<Headroom.app>/Contents/Helpers/headroom-host`; extension id =
    /// Info.plist `HeadroomExtensionID` (set by build.sh), else computed from the bundled
    /// `Contents/Resources/ChromeExtension/manifest.json`. nil when not running from an app bundle.
    public static func bundleDefaults(_ bundle: Bundle = .main) -> (hostPath: String, extensionId: String)? {
        let app = bundle.bundlePath
        guard app.hasSuffix(".app") else { return nil }
        let host = app + "/Contents/Helpers/headroom-host"
        guard FileManager.default.isExecutableFile(atPath: host) else { return nil }
        if let id = bundle.object(forInfoDictionaryKey: "HeadroomExtensionID") as? String, isValidExtensionId(id) {
            return (host, id)
        }
        if let id = extensionId(manifestAt: app + "/Contents/Resources/ChromeExtension/manifest.json") { return (host, id) }
        return nil
    }
}
