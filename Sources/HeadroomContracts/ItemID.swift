// ItemID <-> stable string codec. These strings are the CLI's public ids (docs/cli.md) and the
// `itemId` in closed.jsonl, so the format is frozen:
//
//   tab:<browserPid>:<tabId>
//   window:<browserPid>:<windowId>
//   overhead:<browserPid>:<kind>          kind = ChromeOverheadKind raw value
//   session:<pid>:<startSec>
//   leftover:<pgid>:<leaderStartSec>
//   proc:<pid>:<startSec>

import Foundation

extension ItemID: LosslessStringConvertible, Codable, Comparable {
    public var stringValue: String {
        switch self {
        case let .chromeTab(b, t): "tab:\(b):\(t)"
        case let .chromeWindow(b, w): "window:\(b):\(w)"
        case let .chromeOverhead(b, k): "overhead:\(b):\(k)"
        case let .session(k): "session:\(k.pid):\(k.startSec)"
        case let .leftover(g, s): "leftover:\(g):\(s)"
        case let .process(k): "proc:\(k.pid):\(k.startSec)"
        }
    }

    public var description: String { stringValue }

    public init?(_ description: String) { self.init(string: description) }

    public init?(string: String) {
        let parts = string.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let a = Int32(parts[1]) else { return nil }
        let rest = parts[2]
        switch parts[0] {
        case "overhead":
            guard ChromeOverheadKind(rawValue: rest) != nil else { return nil }
            self = .chromeOverhead(browserPid: a, kind: rest)
            return
        default: break
        }
        guard let b = Int(rest) else { return nil }
        switch parts[0] {
        case "tab": self = .chromeTab(browserPid: a, tabId: b)
        case "window": self = .chromeWindow(browserPid: a, windowId: b)
        case "session": self = .session(ProcKey(pid: a, startSec: b))
        case "leftover": self = .leftover(pgid: a, leaderStartSec: b)
        case "proc": self = .process(ProcKey(pid: a, startSec: b))
        default: return nil
        }
    }

    public var kind: ItemKind {
        switch self {
        case .chromeTab: .tab
        case .chromeWindow: .window
        case .chromeOverhead: .overhead
        case .session: .session
        case .leftover: .leftover
        case .process: .process
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = ItemID(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad ItemID '\(s)'")
        }
        self = v
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stringValue)
    }

    public static func < (a: ItemID, b: ItemID) -> Bool { a.stringValue < b.stringValue }
}

// Dictionaries keyed by ItemID encode as JSON objects keyed by the id string.
extension ItemID: CodingKeyRepresentable {
    public var codingKey: any CodingKey { ItemIDKey(stringValue: stringValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(string: codingKey.stringValue) }
}

private struct ItemIDKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
