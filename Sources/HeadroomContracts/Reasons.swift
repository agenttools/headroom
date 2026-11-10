// Stable codes and plain-English text for Reason (used by the sheet, Peek, `headroom list/suggest`).

import Foundation

extension Reason {
    /// Stable machine code (docs/cli.md). Never change existing values.
    public var code: String {
        switch self {
        case .busy: "busy"
        case .recentActivity: "recentActivity"
        case .visiblePane: "visiblePane"
        case .notInTmux: "notInTmux"
        case .hasBackground: "hasBackground"
        case .noTranscript: "noTranscript"
        case .cwdMissing: "cwdMissing"
        case .unregistered: "unregistered"
        case .audible: "audible"
        case .pinned: "pinned"
        case .emptiesWindow: "emptiesWindow"
        case .closesAllWindows: "closesAllWindows"
        case .leftover: "leftover"
        case .manyItems: "manyItems"
        case .launcher: "launcher"
        case .pidMismatch: "pidMismatch"
        case .chromeCore: "chromeCore"
        case .childProcess: "childProcess"
        }
    }

    public var text: String {
        switch self {
        case .busy(let s): s.map { "busy (\($0))" } ?? "busy or unknown status"
        case .recentActivity: "active in the last 10 minutes"
        case .visiblePane: "visible or current tmux pane"
        case .notInTmux: "not in tmux (Undo cannot put it back into tmux)"
        case let .hasBackground(n, b): "has \(n) background process\(n == 1 ? "" : "es") (\(ByteFormat.short(b)))"
        case .noTranscript: "no transcript yet (nothing to resume; closing discards it)"
        case .cwdMissing: "working directory is missing on disk"
        case .unregistered: "claude process with no session file"
        case .audible: "playing audio"
        case .pinned: "pinned tab"
        case .emptiesWindow(let n): "closes a whole window of \(n) tabs"
        case .closesAllWindows: "closes every normal Chrome window"
        case .leftover: "leftover process group (cannot be undone)"
        case .manyItems: "more than 15 items"
        case .launcher: "the session that launched Headroom"
        case .pidMismatch: "process changed since the snapshot"
        case .chromeCore: "part of Chrome itself"
        case .childProcess: "part of a live session; close the session instead"
        }
    }
}

public enum ByteFormat {
    /// "684 MB" below 1 GB, "1.24 GB" from 1 GB up (decimal-ish binary units as in the SPEC mock-ups).
    public static func short(_ b: Bytes) -> String {
        let mb = Double(b) / 1_048_576
        if mb < 1 { return b == 0 ? "0 MB" : "<1 MB" }
        if mb < 1024 { return "\(Int(mb.rounded())) MB" }
        return String(format: "%.2f GB", mb / 1024)
    }
}

public extension Bytes {
    static func mb(_ v: Double) -> Bytes { Bytes(v * 1_048_576) }
    static func gb(_ v: Double) -> Bytes { Bytes(v * 1_073_741_824) }
}
