// Native-messaging wire protocol v1 (SPEC §4.2, docs/protocol.md). Foundation-only so headroom-host
// can use it. Extension ↔ host: 4-byte native-endian length + JSON. Host ↔ app: one JSON object per line.
// Unknown fields must be ignored; decoding is lenient (optionals) wherever Chrome may omit a field.

import Foundation

public enum Wire {
    public static let version = 1

    /// Peek at `t` (and `req`) before decoding the full message.
    public struct Envelope: Codable, Sendable, Hashable {
        public let t: String
        public let req: Int?
        public init(t: String, req: Int? = nil) { self.t = t; self.req = req }
    }

    /// host→app, always the first line on a connection.
    public struct HostHello: Codable, Sendable, Hashable {
        public var t = "host"
        public var v: Int
        public var hostPid: Int32
        /// getppid() of the host = the Chrome browser process that started it.
        public var browserPid: Int32
        public var hostVersion: String
        public init(v: Int = Wire.version, hostPid: Int32, browserPid: Int32, hostVersion: String) {
            self.v = v; self.hostPid = hostPid; self.browserPid = browserPid; self.hostVersion = hostVersion
        }
    }

    /// ext→app
    public struct ExtHello: Codable, Sendable, Hashable {
        public var t = "hello"
        public var v: Int
        public var ext: String
        public var install: String
        public var incognitoAllowed: Bool
        /// "persistent" | "on-demand"
        public var mode: String
        /// The service worker's `performance.timeOrigin` (ms). A change between two hellos means the worker restarted.
        public var swStart: Double?
        public init(v: Int = Wire.version, ext: String, install: String, incognitoAllowed: Bool, mode: String,
                    swStart: Double? = nil) {
            self.v = v; self.ext = ext; self.install = install; self.incognitoAllowed = incognitoAllowed; self.mode = mode
            self.swStart = swStart
        }
    }

    public struct Frame: Codable, Sendable, Hashable {
        public var frameId: Int
        public var parentFrameId: Int
        public var processId: Int
        public var documentLifecycle: String?
        public init(frameId: Int, parentFrameId: Int, processId: Int, documentLifecycle: String?) {
            self.frameId = frameId; self.parentFrameId = parentFrameId
            self.processId = processId; self.documentLifecycle = documentLifecycle
        }
    }

    public struct Window: Codable, Sendable, Hashable {
        public var id: Int
        public var focused: Bool
        public var incognito: Bool
        public var type: String?
        public var state: String?
        public init(id: Int, focused: Bool, incognito: Bool, type: String? = nil, state: String? = nil) {
            self.id = id; self.focused = focused; self.incognito = incognito; self.type = type; self.state = state
        }
    }

    public struct Tab: Codable, Sendable, Hashable {
        public var id: Int
        public var windowId: Int
        public var index: Int
        public var title: String?
        public var url: String?
        /// Only data: URLs under 8 KB are forwarded.
        public var favIconUrl: String?
        public var active: Bool
        public var audible: Bool?
        public var pinned: Bool
        public var discarded: Bool?
        public var frozen: Bool?
        public var incognito: Bool
        /// ms since 1970
        public var lastAccessed: Double?
        public var frames: [Frame]?
        public init(id: Int, windowId: Int, index: Int, title: String?, url: String?, favIconUrl: String? = nil,
                    active: Bool, audible: Bool? = nil, pinned: Bool, discarded: Bool? = nil, frozen: Bool? = nil,
                    incognito: Bool, lastAccessed: Double? = nil, frames: [Frame]? = nil) {
            self.id = id; self.windowId = windowId; self.index = index; self.title = title; self.url = url
            self.favIconUrl = favIconUrl; self.active = active; self.audible = audible; self.pinned = pinned
            self.discarded = discarded; self.frozen = frozen; self.incognito = incognito
            self.lastAccessed = lastAccessed; self.frames = frames
        }
    }

    /// app→ext `{"t":"snapshot","req":7}`
    public struct SnapshotRequest: Codable, Sendable, Hashable {
        public var t = "snapshot"
        public var req: Int
        public init(req: Int) { self.req = req }
    }

    /// ext→app
    public struct SnapshotReply: Codable, Sendable, Hashable {
        public var t = "snapshot"
        public var req: Int
        /// ms since 1970
        public var at: Double
        public var windows: [Window]
        public var tabs: [Tab]
        public init(req: Int, at: Double, windows: [Window], tabs: [Tab]) {
            self.req = req; self.at = at; self.windows = windows; self.tabs = tabs
        }
    }

    public struct CloseTab: Codable, Sendable, Hashable {
        public var id: Int
        /// Expected URL; mismatch → "changedSkipped".
        public var url: String
        public init(id: Int, url: String) { self.id = id; self.url = url }
    }

    /// app→ext
    public struct CloseRequest: Codable, Sendable, Hashable {
        public var t = "close"
        public var req: Int
        public var tabs: [CloseTab]
        public init(req: Int, tabs: [CloseTab]) { self.req = req; self.tabs = tabs }
    }

    /// app→ext
    public struct DiscardRequest: Codable, Sendable, Hashable {
        public var t = "discard"
        public var req: Int
        public var tabIds: [Int]
        public init(req: Int, tabIds: [Int]) { self.req = req; self.tabIds = tabIds }
    }

    /// app→ext
    public struct ActivateRequest: Codable, Sendable, Hashable {
        public var t = "activate"
        public var req: Int
        public var tabId: Int
        public var windowId: Int
        public init(req: Int, tabId: Int, windowId: Int) { self.req = req; self.tabId = tabId; self.windowId = windowId }
    }

    public struct RestoreItem: Codable, Sendable, Hashable {
        public var sessionId: String?
        public var url: String
        public var windowId: Int?
        public var index: Int?
        public init(sessionId: String?, url: String, windowId: Int?, index: Int?) {
            self.sessionId = sessionId; self.url = url; self.windowId = windowId; self.index = index
        }
    }

    /// app→ext
    public struct RestoreRequest: Codable, Sendable, Hashable {
        public var t = "restore"
        public var req: Int
        public var items: [RestoreItem]
        public init(req: Int, items: [RestoreItem]) { self.req = req; self.items = items }
    }

    public struct Restored: Codable, Sendable, Hashable {
        public var url: String
        public var newTabId: Int?
        /// "sessions" | "create"
        public var via: String
        public init(url: String, newTabId: Int?, via: String) { self.url = url; self.newTabId = newTabId; self.via = via }
    }

    /// ext→app reply to close / discard / activate / restore.
    /// results values: "done" | "changedSkipped" | "gone" | "failed:<msg>"
    public struct ResultReply: Codable, Sendable, Hashable {
        public var t = "result"
        public var req: Int
        /// Keyed by tab id as a string.
        public var results: [String: String]?
        /// tab id string → sessions.sessionId for Undo.
        public var restore: [String: String]?
        public var restored: [Restored]?
        public init(req: Int, results: [String: String]? = nil, restore: [String: String]? = nil,
                    restored: [Restored]? = nil) {
            self.req = req; self.results = results; self.restore = restore; self.restored = restored
        }
    }

    /// app→ext `{"t":"setMode","mode":"on-demand"}`
    public struct SetMode: Codable, Sendable, Hashable {
        public var t = "setMode"
        public var mode: String
        public init(mode: String) { self.mode = mode }
    }

    /// Single-field messages: {"t":"reload"}, {"t":"dirty"}, {"t":"ping"}, {"t":"pong"}.
    public struct Bare: Codable, Sendable, Hashable {
        public var t: String
        public init(_ t: String) { self.t = t }
        public static let reload = Bare("reload"), dirty = Bare("dirty"), ping = Bare("ping"), pong = Bare("pong")
    }

    /// Maps a result string to an Outcome.
    public static func outcome(_ s: String) -> Outcome {
        switch s {
        case "done": .done
        case "changedSkipped": .changedSkipped
        case "gone": .alreadyGone
        default: s.hasPrefix("failed:") ? .failed(String(s.dropFirst(7))) : .failed(s)
        }
    }
}
