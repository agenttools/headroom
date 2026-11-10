// The relay's decisions, without any I/O (SPEC §2, §4.2; docs/protocol.md "Host behaviour").
//
// - The host answers ping/pong itself; neither is forwarded.
// - The first line on every app connection is the host's own `host` line. The extension's last
//   `hello` is cached and replayed right after it, because the extension says hello once, usually
//   before the app is running.
// - Everything else is relayed unchanged. Messages from the extension are dropped while no app
//   is connected (the requests they answer belonged to a previous connection).
// - Mode comes from the extension's hello, updated by `setMode` from the app.
//   persistent: stay alive and poll for app.sock. on-demand: exit when app.sock is absent or the
//   app disconnects, so the extension's service worker can go idle.

import Foundation

struct Router {
    enum Action: Equatable {
        case toExt(Data)       // one JSON message, to be framed for Chrome
        case toApp(Data)       // one newline-terminated line
        case exit(String)
        case log(String)
        case connectNow        // try app.sock at once (after the mode becomes known)
    }

    static let modes: Set<String> = ["persistent", "on-demand"]
    static let ping = Data(#"{"t":"ping"}"#.utf8)
    static let pong = Data(#"{"t":"pong"}"#.utf8)

    /// nil until the extension's hello arrives; treated as persistent until then.
    private(set) var mode: String?
    private(set) var extHello: Data?
    private(set) var appConnected = false
    private(set) var dropped = 0

    var isOnDemand: Bool { mode == "on-demand" }

    /// The first things the host does: ping the extension (this also tells it the host is up).
    func startup() -> [Action] { [.toExt(Router.ping)] }

    func keepalive() -> [Action] { [.toExt(Router.ping)] }

    mutating func fromExt(_ msg: Data) -> [Action] {
        guard let o = JSONLine.object(msg), let t = o["t"] as? String else {
            return [.log("dropped a non-object message from the extension")]
        }
        switch t {
        case "ping":
            return [.toExt(Router.pong)]
        case "pong":
            return []
        case "hello":
            extHello = msg
            if let m = o["mode"] as? String, Router.modes.contains(m) { mode = m }
            var out: [Action] = []
            if appConnected, let l = JSONLine.line(msg) { out.append(.toApp(l)) }
            out.append(.connectNow)
            return out
        default:
            guard appConnected else { dropped += 1; return [] }
            guard let l = JSONLine.line(msg) else { return [.log("dropped an unreadable message from the extension")] }
            return [.toApp(l)]
        }
    }

    mutating func fromApp(_ line: Data) -> [Action] {
        guard let o = JSONLine.object(line), let t = o["t"] as? String else {
            return [.log("dropped a non-object line from the app")]
        }
        if t == "setMode", let m = o["mode"] as? String, Router.modes.contains(m) { mode = m }
        if t == "ping" { return [] } // the host owns keepalive with the extension
        guard line.count <= NativeFraming.maxToChrome else {
            return [.log("dropped a \(line.count)-byte message from the app (Chrome's limit is 1 MB)")]
        }
        return [.toExt(line)]
    }

    /// Called once the socket is connected and the peer uid checked.
    mutating func appDidConnect(hostLine: Data) -> [Action] {
        appConnected = true
        var out: [Action] = [.toApp(hostLine)]
        if let h = extHello, let l = JSONLine.line(h) { out.append(.toApp(l)) }
        return out
    }

    mutating func appDidDisconnect() -> [Action] {
        guard appConnected else { return [] }
        appConnected = false
        return isOnDemand ? [.exit("app disconnected (on-demand mode)")] : [.log("app disconnected; waiting for app.sock")]
    }

    /// Called when app.sock is absent, refused, or unsafe.
    func appSocketAbsent() -> [Action] {
        isOnDemand ? [.exit("app.sock is absent (on-demand mode)")] : []
    }
}
