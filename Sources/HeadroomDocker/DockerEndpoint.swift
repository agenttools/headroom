// Where the Docker engine listens, and which runtime owns it (SPEC §5.2).
//
// Headroom talks to the engine's unix socket directly (read-only GETs), so it needs neither the `docker` CLI nor a
// PATH: an app opened from Finder has neither. The socket is found the way the CLI finds it:
//
//   1. HEADROOM_DOCKER_SOCKET=<path>   test seam and override; "off" turns Docker off
//   2. DOCKER_HOST=unix://<path>
//   3. the current context: DOCKER_CONTEXT, else "currentContext" in ~/.docker/config.json, resolved through
//      ~/.docker/contexts/meta/*/meta.json
//   4. the first socket that exists: colima, Docker Desktop, OrbStack, Rancher Desktop, /var/run/docker.sock

import Foundation
import HeadroomContracts

public struct DockerEndpoint: Sendable, Hashable {
    public enum Runtime: String, Sendable {
        case colima, lima
        case dockerDesktop = "Docker Desktop"
        case orbstack = "OrbStack"
        case rancher = "Rancher Desktop"
        case podman
        case docker = "Docker"
    }

    public let socketPath: String
    public let runtime: Runtime
    /// The docker context that named this socket, if one did.
    public let context: String?

    public init(socketPath: String, runtime: Runtime? = nil, context: String? = nil) {
        self.socketPath = socketPath
        self.runtime = runtime ?? Self.runtime(forSocket: socketPath)
        self.context = context
    }

    /// nil = no Docker on this Mac (or turned off).
    public static func resolve(environment e: [String: String], home: String,
                               fileManager fm: FileManager = .default) -> DockerEndpoint? {
        func value(_ k: String) -> String? { e[k].flatMap { $0.isEmpty ? nil : $0 } }
        if let o = value("HEADROOM_DOCKER_SOCKET") {
            return ["off", "none", "0"].contains(o.lowercased()) ? nil : DockerEndpoint(socketPath: o)
        }
        if let h = value("DOCKER_HOST") {
            // tcp:// and ssh:// engines are not on this Mac; Headroom has nothing to say about their memory.
            return unixPath(h).map { DockerEndpoint(socketPath: $0) }
        }
        let dockerDir = value("DOCKER_CONFIG") ?? home + "/.docker"
        if let ctx = value("DOCKER_CONTEXT") ?? currentContext(configPath: dockerDir + "/config.json"),
           ctx != "default", let host = contextHost(ctx, metaDir: dockerDir + "/contexts/meta", fileManager: fm) {
            return unixPath(host).map { DockerEndpoint(socketPath: $0, context: ctx) }
        }
        for p in candidates(home: home) where isSocket(p) { return DockerEndpoint(socketPath: p) }
        return nil
    }

    /// Default socket of each runtime, most specific first; /var/run/docker.sock (a symlink any of them may own) last.
    public static func candidates(home: String) -> [String] {
        [home + "/.colima/default/docker.sock",
         home + "/.docker/run/docker.sock",
         home + "/.orbstack/run/docker.sock",
         home + "/.rd/docker.sock",
         "/var/run/docker.sock"]
    }

    static func unixPath(_ host: String) -> String? {
        guard host.hasPrefix("unix://") else { return nil }
        let p = String(host.dropFirst("unix://".count))
        return p.hasPrefix("/") ? p : nil
    }

    static func isSocket(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    static func currentContext(configPath: String) -> String? {
        guard let d = FileManager.default.contents(atPath: configPath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let c = o["currentContext"] as? String, !c.isEmpty else { return nil }
        return c
    }

    /// Endpoints.docker.Host of the context called `name` (the meta directories are named by a hash of the name,
    /// so every meta.json is read and matched on its "Name").
    static func contextHost(_ name: String, metaDir: String, fileManager fm: FileManager) -> String? {
        guard let dirs = try? fm.contentsOfDirectory(atPath: metaDir) else { return nil }
        for d in dirs.sorted() {
            guard let data = fm.contents(atPath: metaDir + "/" + d + "/meta.json"),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  o["Name"] as? String == name,
                  let eps = o["Endpoints"] as? [String: Any], let dk = eps["docker"] as? [String: Any],
                  let host = dk["Host"] as? String else { continue }
            return host
        }
        return nil
    }

    /// The runtime, from where its socket lives (/var/run/docker.sock is followed to its target).
    public static func runtime(forSocket path: String) -> Runtime {
        var p = path
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) { p = target }
        let l = p.lowercased()
        if l.contains("/.colima/") { return .colima }
        if l.contains("/.orbstack/") { return .orbstack }
        if l.contains("/.rd/") || l.contains("rancher-desktop") { return .rancher }
        if l.contains("/.docker/") || l.contains("com.docker.docker") { return .dockerDesktop }
        if l.contains("/.lima/") { return .lima }
        if l.contains("podman") { return .podman }
        return .docker
    }

    /// colima and lima only: the Lima instance directory that holds `ha.pid` (the host agent that owns the VM).
    /// ~/.colima/<profile>/docker.sock → ~/.colima/_lima/colima (profile "default") or colima-<profile>;
    /// ~/.lima/<instance>/sock/docker.sock → ~/.lima/<instance>.
    public var limaInstanceDir: String? {
        let parts = socketPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch runtime {
        case .colima:
            guard let i = parts.lastIndex(of: ".colima"), i + 1 < parts.count else { return nil }
            let profile = parts[i + 1]
            let root = "/" + parts[...i].joined(separator: "/")
            return root + "/_lima/" + (profile == "default" ? "colima" : "colima-" + profile)
        case .lima:
            guard let i = parts.lastIndex(of: ".lima"), i + 1 < parts.count else { return nil }
            return "/" + parts[...(i + 1)].joined(separator: "/")
        default:
            return nil
        }
    }
}
