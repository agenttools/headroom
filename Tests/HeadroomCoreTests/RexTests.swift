// Rex: parsing of hand-written `rex … --json` fixtures (Tests/Fixtures/rex-*.json), the pure process walk that decides
// tmux vs Rex, RexClient's exact argv against RexStub (a fake rex that never talks to a server), and an opt-in round
// trip against a PRIVATE Rex server this test starts and stops itself (HEADROOM_REX_LIVE_TEST=1).
// Nothing here reaches the user's own Rex server.
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomCore

enum RexFixtures {
    static func text(_ name: String) -> String { try! String(contentsOf: Fixtures.url(name), encoding: .utf8) }
    static let alpha = "session:0190bbbb-0000-7000-8000-00000000000a"
    static let beta = "session:0190bbbb-0000-7000-8000-00000000000b"
    static func block(_ s: String) -> String { "block:0190bbbb-0000-7000-8000-0000000000\(s)" }
    static func window(_ s: String) -> String { "window:0190bbbb-0000-7000-8000-0000000000\(s)" }
    static let appClient = "client:0190bbbb-0000-7000-8000-0000000000c1"
    static let ls = RexClient.parseSessions(text("rex-ls.json"))!
    static let a = RexClient.parseInspect(text("rex-inspect-a.json"))!
    static let b = RexClient.parseInspect(text("rex-inspect-b.json"))!
    static let state = RexState(reachable: true, complete: true, sessions: ls, blocks: a.blocks + b.blocks,
                                appClients: [alpha: a.appClients, beta: b.appClients])

    /// A block in session `session`, tab `window` labelled `label` (for the recovery helpers).
    static func blk(_ id: String, window: String, label: String, pane: Int = 1, session: String = alpha) -> RexBlock {
        RexBlock(blockId: id, sessionId: session, sessionLabel: "alpha", windowId: window, windowLabel: label,
                 windowIndex: 1, paneIndex: pane, label: "shell", windowActive: false, zoomed: false,
                 windowZoomed: false, floating: false, minimized: false, sessionAttached: false)
    }
}

// MARK: - Parsing (pure)

@Suite struct RexParseTests {
    typealias F = RexFixtures

    @Test func parsesSessions() {
        #expect(F.ls == [RexSessionRef(sessionId: F.alpha, label: "alpha"), RexSessionRef(sessionId: F.beta, label: "beta")])
        #expect(RexClient.parseSessions(#"{"sessions": []}"#) == [])
        #expect(RexClient.parseSessions(#"{"sessions":[{"label":"no id"},{"session_id":"session:x"},7]}"#)
                == [RexSessionRef(sessionId: "session:x", label: "")])
        for junk in ["", "not json", "[]", "null", #"{"sessions":{}}"#, #"{"other":[]}"#] {
            #expect(RexClient.parseSessions(junk) == nil, "\(junk)")
        }
    }

    @Test func inspectIndexesInTabAndLayoutOrder() {
        let a = F.a
        #expect(a.sessionId == F.alpha && a.label == "alpha")
        #expect(a.blocks.map(\.blockId) == [F.block("a1"), F.block("a2"), F.block("a3"), F.block("a4")])
        #expect(a.blocks.map(\.windowIndex) == [1, 2, 2, 3])
        #expect(a.blocks.map(\.paneIndex) == [1, 1, 2, 1])                       // restarts in every tab
        #expect(a.blocks.map(\.windowId) == [F.window("a1"), F.window("a2"), F.window("a2"), F.window("a4")])
        #expect(a.blocks.map(\.windowLabel) == ["first tab", "split tab", "split tab", "Window 000000a4"])
        #expect(a.blocks.map(\.label) == ["shell", "shell", "logs", "shell"])
        #expect(a.blocks.allSatisfy { $0.sessionId == F.alpha && $0.sessionLabel == "alpha" })
        #expect(a.blocks.map(\.windowActive) == [false, true, true, false])
    }

    @Test func splitTabBothPanesVisible() {
        // The active tab is split in two tiled blocks with no zoomed_block_id key: both are drawn, focus does not
        // matter. Inactive tabs are not visible.
        let a = F.a
        #expect(a.blocks.filter(\.visible).map(\.blockId) == [F.block("a2"), F.block("a3")])
        #expect(a.blocks.allSatisfy { $0.sessionAttached && !$0.windowZoomed && !$0.zoomed && !$0.floating && !$0.minimized })
        #expect(a.blocks.allSatisfy { $0.drawn })
        let loc = RexClient.location(of: a.blocks[2])
        #expect(loc == RexLoc(blockId: F.block("a3"), sessionId: F.alpha, sessionLabel: "alpha", windowId: F.window("a2"),
                              windowLabel: "split tab", windowIndex: 2, paneIndex: 2, visible: true))
        #expect(loc.label == "alpha:2.2" && loc.placed)
        #expect(RexClient.location(of: a.blocks[0]).visible == false)
    }

    @Test func zoomFloatingAndMinimized() {
        let b = F.b
        #expect(b.blocks.map(\.blockId) == [F.block("b1"), F.block("b2"), F.block("b3"), F.block("b4")])
        #expect(b.blocks.map(\.paneIndex) == [1, 2, 3, 4])                       // across layers, back to front
        #expect(b.blocks.allSatisfy { $0.windowIndex == 1 && $0.windowActive && $0.windowZoomed && $0.sessionAttached })
        #expect(b.blocks.map(\.zoomed) == [false, true, false, false])
        #expect(b.blocks.map(\.floating) == [false, false, true, true])
        #expect(b.blocks.map(\.minimized) == [false, false, false, true])
        // The zoomed block (not the focused one) and the floating block over it are drawn; the focused tiled block
        // under the zoom and the minimized floating block are not.
        #expect(b.blocks.filter(\.visible).map(\.blockId) == [F.block("b2"), F.block("b3")])
    }

    @Test func clientsAppOnlyLostCountsAsAttached() throws {
        #expect(F.a.appClients.count == 1)                                      // the cli client is dropped
        let c = F.a.appClients[0]
        #expect(c.clientId == F.appClient && c.local && c.connected)
        let at = try #require(c.connectedAt)
        let whole = try #require(RexClient.parseDate("2026-11-19T10:29:51Z"))
        #expect(abs(at.timeIntervalSince(whole) - 0.900082) < 0.001)
        let lost = try #require(F.b.appClients.first)
        #expect(F.b.appClients.count == 1 && !lost.connected && lost.local)     // no transport counts as local
        #expect(lost.connectedAt == RexClient.parseDate("2026-11-19T09:00:00Z") && lost.connectedAt != nil)
        #expect(F.b.blocks.allSatisfy { $0.sessionAttached })
    }

    @Test func lenientInspect() {
        // An app client without a client_id is no Jump target, but it may be showing the session: attached, so the
        // drawn blocks of the active tab are visible. A layer without a kind is tiled; an unknown kind floats. A window
        // without an id is skipped but still counted; a block without an id is skipped and not counted.
        let json = #"""
        {"session_id":"session:x","active_window_id":"window:w","windows":[
          {"window_id":"window:w","layers":[{"blocks":[{"block_id":"block:1"}]},{"kind":"popover","blocks":[{"block_id":"block:2"}]}]},
          {"label":"no id","layers":[{"blocks":[{"block_id":"block:3"}]}]},
          {"window_id":"window:z","zoomed_block_id":null,"layers":[{"kind":null,"blocks":[{"label":"no id"},{"block_id":"block:4"}]}]}],
         "clients":[{"client_id":"client:c","info":{"kind":"cli"},"connection_state":"connected"},{"info":{"kind":"app"}}]}
        """#
        let i = RexClient.parseInspect(json)
        #expect(i?.label == "" && i?.appClients == [])
        #expect(i?.blocks.map(\.blockId) == ["block:1", "block:2", "block:4"])
        #expect(i?.blocks.map(\.windowIndex) == [1, 1, 3])
        #expect(i?.blocks.map(\.paneIndex) == [1, 2, 1])
        #expect(i?.blocks.map(\.floating) == [false, true, false])
        #expect(i?.blocks.map(\.windowActive) == [true, true, false])
        #expect(i?.blocks.allSatisfy(\.sessionAttached) == true)
        #expect(i?.blocks.filter(\.visible).map(\.blockId) == ["block:1", "block:2"])
        // Only cli (and agent) clients: nothing is attached, so nothing is visible.
        let cliOnly = json.replacingOccurrences(of: #",{"info":{"kind":"app"}}"#,
                                                with: #",{"client_id":"client:a","info":{"kind":"agent"}}"#)
        let c = RexClient.parseInspect(cliOnly)
        #expect(c?.blocks.count == 3 && c?.appClients == [])
        #expect(c?.blocks.contains(where: \.visible) == false && c?.blocks.contains(where: \.sessionAttached) == false)
        #expect(RexClient.parseInspect(#"{"session_id":"session:y"}"#)?.blocks == [])
        for junk in ["", "{}", "[]", "nope", #"{"label":"x","windows":[]}"#, #"{"session_id":5}"#] {
            #expect(RexClient.parseInspect(junk) == nil, "\(junk)")
        }
    }

    /// One app client, two tabs; `active` is the raw JSON for active_window_id ("" leaves the key out).
    static func twoTabs(active: String) -> String {
        let a = active.isEmpty ? "" : #""active_window_id":\#(active),"#
        return #"""
        {"session_id":"session:t",\#(a)"windows":[
          {"window_id":"window:1","layers":[{"kind":"tiled","blocks":[{"block_id":"block:1"}]}]},
          {"window_id":"window:2","layers":[{"kind":"tiled","blocks":[{"block_id":"block:2"}]}]}],
         "clients":[{"client_id":"client:c","info":{"kind":"app"},"connection_state":"connected"}]}
        """#
    }

    @Test func unknownActiveTabCountsEveryTabAsActive() throws {
        // Unknown means protected: absent, null, not a string, or naming no listed tab.
        for active in ["", "null", "7", #""window:gone""#] {
            let i = try #require(RexClient.parseInspect(Self.twoTabs(active: active)), "\(active)")
            #expect(i.blocks.map(\.windowActive) == [true, true], "\(active)")
            #expect(i.blocks.allSatisfy { $0.visible }, "\(active)")
        }
        // A known active tab still decides.
        let known = try #require(RexClient.parseInspect(Self.twoTabs(active: #""window:2""#)))
        #expect(known.blocks.map(\.windowActive) == [false, true])
        #expect(known.blocks.filter(\.visible).map(\.blockId) == ["block:2"])
    }

    @Test func clientOfUnknownKindCountsAsAttached() throws {
        // A client with no info, with kind "other", or with a kind Headroom does not know may be showing the session.
        for client in [#"{"client_id":"client:n"}"#, #"{"client_id":"client:o","info":{"kind":"other"}}"#,
                       #"{"client_id":"client:v","info":{"kind":"visor"}}"#, #"{"client_id":"client:x","info":{}}"#] {
            let json = #"""
            {"session_id":"session:k","active_window_id":"window:1","windows":[
              {"window_id":"window:1","layers":[{"kind":"tiled","blocks":[{"block_id":"block:1"}]}]}],
             "clients":[\#(client)]}
            """#
            let i = try #require(RexClient.parseInspect(json), "\(client)")
            #expect(i.blocks.allSatisfy { $0.sessionAttached && $0.visible }, "\(client)")
            #expect(i.appClients.isEmpty, "\(client)")                       // no Jump target
        }
    }

    @Test func appClientWithoutAnIdCountsAsAttached() throws {
        let json = #"""
        {"session_id":"session:k","active_window_id":"window:1","windows":[
          {"window_id":"window:1","layers":[{"kind":"tiled","blocks":[{"block_id":"block:1"}]}]}],
         "clients":[{"info":{"kind":"app"},"connection_state":"connected"}]}
        """#
        let i = try #require(RexClient.parseInspect(json))
        #expect(i.blocks.allSatisfy { $0.sessionAttached && $0.visible })
        #expect(i.appClients.isEmpty)
    }

    @Test func selectFailureReasons() {
        func r(_ status: Int32, _ stderr: String, timedOut: Bool = false) -> Shell.Result {
            Shell.Result(status: status, stdout: "", stderr: stderr, timedOut: timedOut)
        }
        #expect(RexClient.errorLine(r(3, "\n  Error: client target default not found: no app client is connected\nmore"))
                == "client target default not found: no app client is connected")
        #expect(RexClient.errorLine(r(1, " \n")) == nil)
        #expect(RexClient.errorLine(r(1, "Error: ")) == nil)
        // Exit 3: the client target was not found (Rex.app not connected yet, or it reconnected). Not Remote Control.
        let notFound = RexClient.selectFailureReason(
            r(3, "Error: client target default not found: no app client is connected\n"), action: "Jump")
        #expect(notFound == "Rex.app is not connected to the Rex server (client target default not found: no app client is connected).")
        #expect(RexClient.selectFailureReason(r(3, ""), action: "Jump") == "Rex.app is not connected to the Rex server.")
        // The app's own refusal is shown as it is.
        let refusal = "Rex.app is not accepting actions. Turn on Remote Control in Settings"
        #expect(RexClient.selectFailureReason(r(1, "Error: \(refusal)\n"), action: "Jump") == refusal + ".")
        #expect(RexClient.selectFailureReason(r(1, "Error: \(refusal).\n"), action: "Jump") == refusal + ".")
        // Nothing more specific: Remote Control.
        #expect(RexClient.selectFailureReason(r(1, ""), action: "Jump")
                == "Turn on Remote Control in Rex so Jump can switch sessions.")
        #expect(RexClient.selectFailureReason(r(1, ""), action: "Undo")
                == "Turn on Remote Control in Rex so Undo can switch sessions.")
        #expect(RexClient.selectFailureReason(r(-1, "", timedOut: true), action: "Jump")
                == "Rex.app did not answer. Make sure it has a window open.")
    }

    @Test func whoamiAndCreatedTerminals() {
        #expect(RexClient.parseWhoami(F.text("rex-whoami.json"))
                == RexServerInfo(pid: 4242, version: "0.1.0-preview.20", apiRevision: 16))
        #expect(RexClient.parseWhoami(#"{"pid":1,"rex_version":"v"}"#) == nil)
        #expect(RexClient.parseWhoami(#"{"pid":"1","rex_version":"v","api_revision":3}"#) == nil)
        #expect(RexClient.parseWhoami("junk") == nil)

        #expect(RexClient.parseNewWindow(#"{"window_id":"window:n","block_ids":["block:n1"],"revision":2}"#, sessionId: "session:s")
                == RexNewTerminal(sessionId: "session:s", windowId: "window:n", blockId: "block:n1"))
        #expect(RexClient.parseNewWindow(#"{"window_id":"window:n","block_ids":[]}"#, sessionId: "session:s") == nil)
        #expect(RexClient.parseNewWindow(#"{"block_ids":["block:n1"]}"#, sessionId: "session:s") == nil)

        let made = #"{"session_id":"session:n","initial_windows":[{"window_id":"window:n","block_ids":["block:n1"],"revision":1}]}"#
        #expect(RexClient.parseNewSession(made) == RexNewTerminal(sessionId: "session:n", windowId: "window:n", blockId: "block:n1"))
        #expect(RexClient.parseNewSession(#"{"session_id":"session:n","initial_windows":[]}"#) == nil)
        #expect(RexClient.parseNewSession(#"{"initial_windows":[{"window_id":"window:n","block_ids":["block:n1"]}]}"#) == nil)
        #expect(RexClient.parseNewSession("") == nil)
    }

    @Test func tailAndPositional() {
        #expect(RexClient.tail("a\nb\nc\n", lines: 2) == "b\nc\n")
        #expect(RexClient.tail("a\nb\nc", lines: 2) == "b\nc")
        #expect(RexClient.tail("a\nb\n", lines: 60) == "a\nb\n")
        #expect(RexClient.tail("a\n\nb\n", lines: 2) == "\nb\n")                 // a blank line is a line
        #expect(RexClient.tail("", lines: 3) == "")
        #expect(RexClient.tail("x\n", lines: 0) == "")
        let long = (1...300).map(String.init).joined(separator: "\n") + "\n"
        #expect(RexClient.tail(long, lines: 60).split(separator: "\n").first == "241")

        #expect(RexClient.positional("--x", "fb") == "x")
        #expect(RexClient.positional("-", "fb") == "fb")
        #expect(RexClient.positional("", "fb") == "fb")
        #expect(RexClient.positional("  \n", "fb") == "fb")
        #expect(RexClient.positional(" - -y ", "fb") == "y")                     // never starts with "-"
        #expect(RexClient.positional("  plain name\n", "fb") == "plain name")
        #expect(RexClient.positional("a-b --c", "fb") == "a-b --c")
    }

    @Test func recoverNewWindow() {
        let before = F.a.blocks
        let w = "window:new"
        let new1 = F.blk("block:n1", window: w, label: "claude", pane: 1)
        let new2 = F.blk("block:n2", window: w, label: "claude", pane: 2)
        let expected = RexNewTerminal(sessionId: F.alpha, windowId: w, blockId: "block:n1")
        #expect(RexClient.recoverNewWindow(before: before, after: before + [new2, new1], sessionId: F.alpha,
                                           name: "claude") == expected)                // first block by pane
        #expect(RexClient.recoverNewWindow(before: before, after: before + [new1], sessionId: F.alpha,
                                           name: "  --claude") == expected)            // name as passed to rex
        // Zero candidates: nothing new, or the new tab has another label.
        #expect(RexClient.recoverNewWindow(before: before, after: before, sessionId: F.alpha, name: "claude") == nil)
        #expect(RexClient.recoverNewWindow(before: before, after: before + [new1], sessionId: F.alpha, name: "other") == nil)
        // Several candidates: two new tabs with the label.
        let other = F.blk("block:n3", window: "window:new2", label: "claude")
        #expect(RexClient.recoverNewWindow(before: before, after: before + [new1, other], sessionId: F.alpha,
                                           name: "claude") == nil)
        // An existing tab with the same label is never adopted.
        let old = F.blk("block:o1", window: "window:old", label: "claude")
        #expect(RexClient.recoverNewWindow(before: before + [old], after: before + [old], sessionId: F.alpha,
                                           name: "claude") == nil)
        // Another session's new tab does not count.
        let elsewhere = F.blk("block:e1", window: "window:else", label: "claude", session: F.beta)
        #expect(RexClient.recoverNewWindow(before: before, after: before + [elsewhere], sessionId: F.alpha,
                                           name: "claude") == nil)
    }

    @Test func recoverNewSession() {
        let before = F.ls
        let made = RexSessionRef(sessionId: "session:new", label: "headroom")
        #expect(RexClient.recoverNewSession(before: before, after: before + [made], label: "headroom") == "session:new")
        #expect(RexClient.recoverNewSession(before: before, after: before + [made], label: " -headroom") == "session:new")
        #expect(RexClient.recoverNewSession(before: before, after: before + [made], label: "") == "session:new")
        #expect(RexClient.recoverNewSession(before: before, after: before, label: "headroom") == nil)
        #expect(RexClient.recoverNewSession(before: before, after: before + [made], label: "alpha") == nil)
        let twin = RexSessionRef(sessionId: "session:new2", label: "headroom")
        #expect(RexClient.recoverNewSession(before: before, after: before + [made, twin], label: "headroom") == nil)
        // An existing session with the label is not "new".
        #expect(RexClient.recoverNewSession(before: before + [made], after: before + [made], label: "headroom") == nil)
    }
}

// MARK: - Placement and client choice (pure)

@Suite struct RexPlacementTests {
    typealias F = RexFixtures

    @Test func locateFoundIsPlaced() {
        let loc = RexClient.locate(blockEnv: F.block("a3"), sessionEnv: F.alpha, state: F.state)
        #expect(loc?.label == "alpha:2.2" && loc?.placed == true && loc?.visible == true)
        let hidden = RexClient.locate(blockEnv: F.block("a4"), sessionEnv: F.alpha, state: F.state)
        #expect(hidden?.label == "alpha:3.1" && hidden?.visible == false)
        // The discovered block wins over a stale REX_SESSION.
        #expect(RexClient.locate(blockEnv: F.block("b2"), sessionEnv: F.alpha, state: F.state)?.sessionId == F.beta)
    }

    @Test func locateNotFoundIsUnplacedAndVisible() {
        let loc = RexClient.locate(blockEnv: "block:0190bbbb-0000-7000-8000-0000000000ff", sessionEnv: F.beta, state: F.state)
        #expect(loc?.placed == false && loc?.visible == true && loc?.sessionLabel == "beta" && loc?.label == "beta:?")
        #expect(loc?.windowId == nil && loc?.windowLabel == nil)
        let unknownSession = RexClient.locate(blockEnv: "block:x", sessionEnv: "session:0190cccc-0000-7000-8000-00000000abcd",
                                              state: F.state)
        #expect(unknownSession?.sessionLabel == "" && unknownSession?.label == "…00abcd:?" && unknownSession?.visible == true)
        // Discovery failed altogether (rex not running, timed out): still placed in Rex, fail-closed.
        let failed = RexClient.locate(blockEnv: F.block("a3"), sessionEnv: F.alpha, state: .empty)
        #expect(failed == RexLoc(blockId: F.block("a3"), sessionId: F.alpha, sessionLabel: "", visible: true))
    }

    @Test func locateNeedsRexIds() {
        #expect(RexClient.locate(blockEnv: nil, sessionEnv: F.alpha, state: F.state) == nil)
        #expect(RexClient.locate(blockEnv: "%3", sessionEnv: F.alpha, state: F.state) == nil)
        #expect(RexClient.locate(blockEnv: "a3", sessionEnv: F.alpha, state: F.state) == nil)
        #expect(RexClient.locate(blockEnv: "block:zz", sessionEnv: nil, state: F.state) == nil)
        #expect(RexClient.locate(blockEnv: "block:zz", sessionEnv: "alpha", state: F.state) == nil)
    }

    func client(_ id: String, local: Bool = true, connected: Bool = true, at: TimeInterval) -> RexAppClient {
        RexAppClient(clientId: id, local: local, connected: connected, connectedAt: Date(timeIntervalSince1970: at))
    }

    @Test func jumpClientPrefersTheSessionsLocalLatest() {
        let s = RexState(reachable: true, complete: true,
                         sessions: [RexSessionRef(sessionId: "session:1", label: "one"),
                                    RexSessionRef(sessionId: "session:2", label: "two"),
                                    RexSessionRef(sessionId: "session:3", label: "three")],
                         blocks: [],
                         appClients: ["session:1": [client("c1", at: 100), client("c2", local: false, at: 300),
                                                    client("c3", at: 200), client("c4", connected: false, at: 400)],
                                      "session:2": [client("c4", connected: false, at: 400)],
                                      "session:3": [client("c5", local: false, at: 50)]])
        #expect(RexClient.jumpClient(session: "session:1", state: s)?.clientId == "c3")
        // No connected client in the session: any connected local one.
        #expect(RexClient.jumpClient(session: "session:2", state: s)?.clientId == "c3")
        #expect(RexClient.jumpClient(session: "session:9", state: s)?.clientId == "c3")
        // session:3's only client is another device's: never chosen, so this Mac's c3 is used.
        #expect(RexClient.jumpClient(session: "session:3", state: s)?.clientId == "c3")
        #expect(RexClient.remoteAppConnected(s))
        #expect(s.allAppClients.map(\.clientId) == ["c1", "c2", "c3", "c4", "c5"])     // de-duplicated
        let onlyLost = RexState(reachable: true, complete: true, sessions: [], blocks: [],
                                appClients: ["session:1": [client("c4", connected: false, at: 400)]])
        #expect(RexClient.jumpClient(session: "session:1", state: onlyLost) == nil)
        #expect(!RexClient.remoteAppConnected(onlyLost))
        #expect(RexClient.jumpClient(session: "session:1", state: .empty) == nil)
        #expect(!RexClient.remoteAppConnected(.empty))
        // Only another device's app is connected (a lost remote one does not count): no client, and a remote app.
        let onlyRemote = RexState(reachable: true, complete: true, sessions: [], blocks: [],
                                  appClients: ["session:1": [client("r1", local: false, at: 500),
                                                             client("r2", local: false, connected: false, at: 600)]])
        #expect(RexClient.jumpClient(session: "session:1", state: onlyRemote) == nil)
        #expect(RexClient.remoteAppConnected(onlyRemote))
        let lostRemote = RexState(reachable: true, complete: true, sessions: [], blocks: [],
                                  appClients: ["session:1": [client("r2", local: false, connected: false, at: 600)]])
        #expect(!RexClient.remoteAppConnected(lostRemote))
        // Fixtures: alpha's app client; beta's only client is lost, so alpha's is used.
        #expect(RexClient.jumpClient(session: F.alpha, state: F.state)?.clientId == F.appClient)
        #expect(RexClient.jumpClient(session: F.beta, state: F.state)?.clientId == F.appClient)
    }
}

// MARK: - Process rules (pure)

/// Live-like: Rex server 700 → root-owned `login` 701 (not in the table; parentPid knows it) → `-zsh` 702 → claude
/// 703, plus a `rex run` block whose command 710 is the server's direct child, and Rex.app's `rex server logs`.
struct RexProcWorld {
    static let serverPath = "/Users/t/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    static let cliPath = "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
    static let claudePath = "/Users/t/.local/share/claude/versions/2.1.0"
    var samples: [ProcSample] = []
    var args: [Int32: ProcArgs] = [:]
    var parents: [Int32: Int32] = [701: 700]
    var panePids: Set<Int32> = []

    mutating func proc(_ pid: Int32, ppid: Int32, path: String, argv: [String]? = nil, uid: UInt32 = 501) {
        samples.append(ProcSample(key: ProcKey(pid: pid, startSec: 1_790_000_000), ppid: ppid, pgid: pid, uid: uid,
                                  path: path, footprint: 1, rss: 1))
        if let argv { args[pid] = ProcArgs(argv: argv) }
    }
    init(withServer: Bool = true) {
        proc(600, ppid: 1, path: "/Applications/Rex Beta.app/Contents/MacOS/Rex", argv: ["Rex"])
        if withServer {
            proc(700, ppid: 1, path: Self.serverPath, argv: [Self.serverPath, "server", "run", "--listen", "unix:///x/server.sock"])
        }
        proc(702, ppid: 701, path: "/bin/zsh", argv: ["-zsh"])
        proc(703, ppid: 702, path: Self.claudePath, argv: ["claude"])
        proc(710, ppid: 700, path: "/opt/homebrew/bin/bun", argv: ["bun", "run", "dev"])
        proc(720, ppid: 600, path: Self.cliPath, argv: [Self.cliPath, "server", "logs", "--follow"])
    }
    var table: ProcessTable { ProcessTable(samples: samples) }
    var sys: StaticSysKit { StaticSysKit(table: table, args: args, parents: parents) }
    func boundary(_ pid: Int32) -> RexBoundary {
        let t = table, s = sys
        return RexProcess.boundary(of: pid, in: t, topology: RexProcess.topology(in: t, sys: s), sys: s,
                                   tmuxPanePids: panePids)
    }
}

@Suite struct RexProcessTests {
    @Test func isServer() {
        let p = RexProcWorld.serverPath
        #expect(RexProcess.isServer(path: p, argv: [p, "server", "run"]))
        #expect(RexProcess.isServer(path: p, argv: ["rex", "--x", "server", "run", "--listen", "unix:///x"]))
        #expect(!RexProcess.isServer(path: p, argv: [p, "server", "logs", "--follow"]))
        #expect(!RexProcess.isServer(path: p, argv: [p, "ls"]))
        #expect(!RexProcess.isServer(path: p, argv: ["server", "run"]))         // argv[0] does not count
        #expect(RexProcess.isServer(path: p, argv: nil))                         // unreadable: Rex Server.app path
        #expect(!RexProcess.isServer(path: RexProcWorld.cliPath, argv: nil))
        #expect(!RexProcess.isServer(path: "/opt/x/rexx", argv: ["rexx", "server", "run"]))
        #expect(!RexProcess.isServer(path: "", argv: ["rex", "server", "run"]))
    }

    @Test func topologyLiveLike() {
        let w = RexProcWorld()
        var argvReads: [Int32] = []
        var parentAsks: [Int32] = []
        let topo = RexProcess.topology(in: w.table, argv: { argvReads.append($0.pid); return w.sys.args($0)?.argv },
                                       parentPid: { parentAsks.append($0); return w.sys.parentPid($0) })
        #expect(topo.servers == [700])
        #expect(topo.blockRoots == [702, 710])
        #expect(Set(argvReads) == [700, 720])                                     // only executables named rex
        #expect(parentAsks == [701])                                              // only the missing parent
        #expect(RexProcess.topology(in: w.table, sys: w.sys) == topo)
    }

    @Test func topologyFixtureLikeWithLoginInTheTable() {
        // A fixture can list `login` itself: it is the block's first process in the table, and its shell is a root
        // too (the counterpart of a tmux pane_pid).
        var w = RexProcWorld()
        w.parents = [:]
        w.proc(701, ppid: 700, path: "/usr/bin/login", argv: ["login", "-pfl", "t", "/bin/zsh"], uid: 0)
        let topo = RexProcess.topology(in: w.table, sys: w.sys)
        #expect(topo.servers == [700])
        #expect(topo.blockRoots.isSuperset(of: [701, 702]) && !topo.blockRoots.contains(703))
        #expect(topo.blockRoots == [701, 702, 710])
    }

    @Test func topologyMemoisesMissingParents() {
        var w = RexProcWorld()
        w.proc(704, ppid: 799, path: "/bin/zsh", argv: ["zsh"])
        w.proc(705, ppid: 799, path: "/bin/zsh", argv: ["zsh"])
        w.parents[799] = 700
        var asks: [Int32] = []
        let topo = RexProcess.topology(in: w.table, argv: { w.sys.args($0)?.argv },
                                       parentPid: { asks.append($0); return w.sys.parentPid($0) })
        #expect(topo.blockRoots == [702, 704, 705, 710])
        #expect(asks.sorted() == [701, 799])
    }

    @Test func noServerIsNone() {
        let w = RexProcWorld(withServer: false)
        var parentAsks = 0
        let topo = RexProcess.topology(in: w.table, argv: { w.sys.args($0)?.argv }, parentPid: { _ in parentAsks += 1; return nil })
        #expect(topo == .none && parentAsks == 0)
        #expect(w.boundary(703) == .none)
    }

    @Test func boundaryWalk() {
        var w = RexProcWorld()
        #expect(w.boundary(703) == .rex(server: 700))                            // through the hidden login
        w.proc(730, ppid: 700, path: RexProcWorld.claudePath, argv: ["claude"])  // direct child of the server
        #expect(w.boundary(730) == .rex(server: 700))
        // tmux started inside a Rex block: the tmux process is nearer than the server.
        w.proc(740, ppid: 702, path: "/opt/homebrew/bin/tmux", argv: ["tmux", "new-session", "-A"])
        w.proc(741, ppid: 740, path: "/bin/zsh", argv: ["-zsh"])
        w.proc(742, ppid: 741, path: RexProcWorld.claudePath, argv: ["claude"])
        #expect(w.boundary(742) == .tmux)
        // Only the pane pid tells: a pane shell directly under a block shell.
        w.proc(751, ppid: 702, path: "/bin/zsh", argv: ["zsh"])
        w.proc(752, ppid: 751, path: RexProcWorld.claudePath, argv: ["claude"])
        #expect(w.boundary(752) == .rex(server: 700))
        w.panePids = [751]
        #expect(w.boundary(752) == .tmux)
        #expect(w.boundary(751) == .tmux)                                        // the process itself is a pane pid
        // A tmux client whose argv0 was renamed ("tmux: client") still counts.
        w.proc(760, ppid: 702, path: "/opt/homebrew/Cellar/tmux/3.5/bin/tmux-wrapper", argv: ["tmux: client"])
        w.proc(761, ppid: 760, path: RexProcWorld.claudePath, argv: ["claude"])
        #expect(w.boundary(761) == .tmux)
        // Reparented to launchd.
        w.proc(770, ppid: 1, path: RexProcWorld.claudePath, argv: ["claude"])
        #expect(w.boundary(770) == .none)
        // The login is missing and nothing knows its parent.
        w.parents = [:]
        #expect(w.boundary(703) == .none)
    }

    @Test func boundaryStopsOnACycle() {
        var w = RexProcWorld()
        w.proc(780, ppid: 781, path: RexProcWorld.claudePath, argv: ["claude"])
        w.proc(781, ppid: 780, path: "/bin/zsh", argv: ["zsh"])
        #expect(w.boundary(780) == .none)
        var steps = 0
        let r = RexProcess.boundary(of: 780, in: w.table, servers: [700], parentPid: { _ in nil },
                                    isTmux: { _ in steps += 1; return false })
        #expect(r == .none && steps <= 3)
    }

    @Test func isTmuxProcess() {
        #expect(TmuxClient.isTmuxProcess(path: "/opt/homebrew/bin/tmux", argv0: nil))
        #expect(TmuxClient.isTmuxProcess(path: "/x/y", argv0: "tmux: server"))
        #expect(TmuxClient.isTmuxProcess(path: "/x/y", argv0: "/usr/local/bin/tmux"))
        #expect(!TmuxClient.isTmuxProcess(path: "/bin/zsh", argv0: "-zsh"))
        #expect(!TmuxClient.isTmuxProcess(path: "/bin/zsh", argv0: nil))
        #expect(!TmuxClient.isTmuxProcess(path: "/bin/zsh", argv0: ""))
    }
}

// MARK: - RexClient against RexStub (a fake rex; no server is ever reached)

@Suite struct RexClientStubTests {
    typealias F = RexFixtures

    func env(_ stub: RexStub, server: String? = nil) -> HeadroomEnv {
        var e = ["HOME": "/nonexistent", "HEADROOM_REX": stub.path]
        if let server { e["HEADROOM_REX_SERVER"] = server }
        return HeadroomEnv(environment: e)
    }

    @Test func childEnvironmentHasNoRexKeys() {
        let c = RexClient(env: HeadroomEnv(environment: ["HOME": "/nonexistent"]))
        #expect(!c.childEnvironment.keys.contains { $0.hasPrefix("REX_") })
        #expect(c.childEnvironment["PATH"] == ProcessInfo.processInfo.environment["PATH"])
    }

    @Test func everyCallStartsWithTheBaseArgs() async {
        let stub = RexStub(); defer { stub.remove() }
        stub.respond("ls", stdout: F.text("rex-ls.json"))
        #expect(await RexClient(env: env(stub)).sessions() == F.ls)
        #expect(stub.calls() == [["--autostart=false", "--timeout", "2s", "ls", "--json"]])

        let priv = RexStub(); defer { priv.remove() }
        let c = RexClient(env: env(priv, server: "unix:///tmp/hrx/s.sock"))
        _ = await c.sessions()
        #expect(await c.select(session: "session:s", window: "window:w", client: "client:c1").ok)
        #expect(priv.calls() == [
            ["--autostart=false", "-S", "unix:///tmp/hrx/s.sock", "--timeout", "2s", "ls", "--json"],
            ["--autostart=false", "-S", "unix:///tmp/hrx/s.sock", "--timeout", "5s", "-C", "client:c1",
             "do", "session.select", "session_id=session:s", "window_id=window:w"],
        ])
    }

    @Test func refusals() async {
        let stub = RexStub(); defer { stub.remove() }
        for bad in ["tcp://127.0.0.1:7777", "unix://relative/s.sock", "/tmp/hrx/s.sock", "laptop"] {
            let c = RexClient(env: env(stub, server: bad))
            #expect(await c.run(["ls", "--json"]).status == 2, "\(bad)")
            #expect(await c.sessions() == nil)
        }
        // `server …` would reach the user's own server unless a private one is named.
        let plain = RexClient(env: env(stub))
        let r = await plain.run(["server", "stop"])
        #expect(r.status == 2 && !r.ok)
        #expect(stub.calls().isEmpty)
        // With a private address it runs (here: against the stub).
        let priv = RexClient(env: env(stub, server: "unix:///tmp/hrx-none/s.sock"))
        #expect(await priv.run(["server", "stop"]).ok)
        #expect(stub.commands() == [["server", "stop"]])
    }

    @Test func missingBinary() async {
        let c = RexClient(env: HeadroomEnv(environment: ["HOME": "/nonexistent", "HEADROOM_REX": "/nonexistent/rex"]))
        #expect(await c.run(["ls"]).status == 127)
        #expect(await c.sessions() == nil)
        #expect(await c.state() == .empty)
        #expect(await c.whoami() == nil)
        // The default under a test HOME is <HOME>/.local/bin/rex, which does not exist either.
        let d = RexClient(env: HeadroomEnv(environment: ["HOME": "/nonexistent"]))
        #expect(await d.run(["ls"]).status == 127)
    }

    @Test func stateRunsLsThenOneInspectPerSession() async {
        let stub = RexStub(); defer { stub.remove() }
        stub.respond("ls", stdout: F.text("rex-ls.json"))
        stub.respond("inspect \(F.alpha)", stdout: F.text("rex-inspect-a.json"))
        stub.respond("inspect \(F.beta)", stdout: F.text("rex-inspect-b.json"))
        let s = await RexClient(env: env(stub)).state()
        #expect(s == F.state)
        #expect(s.reachable && s.complete)
        let cmds = stub.commands()
        #expect(cmds.first == ["ls", "--json"])
        #expect(Set(cmds.dropFirst()) == [["session", "inspect", F.alpha, "--json"], ["session", "inspect", F.beta, "--json"]])
        #expect(cmds.count == 3)
        #expect(stub.calls().allSatisfy { Array($0.prefix(3)) == ["--autostart=false", "--timeout", "2s"] })
    }

    @Test func stateIsIncompleteWhenAnInspectFails() async {
        let stub = RexStub(); defer { stub.remove() }
        stub.respond("ls", stdout: F.text("rex-ls.json"))
        stub.respond("inspect \(F.alpha)", stdout: "", exit: 3)
        stub.respond("inspect \(F.beta)", stdout: F.text("rex-inspect-b.json"))
        let s = await RexClient(env: env(stub)).state()
        #expect(s.reachable && !s.complete)
        #expect(s.sessions == F.ls && s.blocks == F.b.blocks && s.appClients.keys.sorted() == [F.beta])
        // ls fails (no server): nothing is reachable.
        let down = RexStub(); defer { down.remove() }
        down.respond("ls", stdout: "", exit: 4)
        #expect(await RexClient(env: env(down)).state() == .empty)
        #expect(down.commands() == [["ls", "--json"]])
        // No sessions at all: reachable and complete, nothing else runs.
        let none = RexStub(); defer { none.remove() }
        none.respond("ls", stdout: #"{"sessions":[]}"#)
        let n = await RexClient(env: env(none)).state()
        #expect(n.reachable && n.complete && n.blocks.isEmpty && none.commands().count == 1)
    }

    @Test func stateStopsAtTheDeadline() async {
        let stub = RexStub(); defer { stub.remove() }
        stub.respond("ls", stdout: F.text("rex-ls.json"))
        stub.respond("inspect \(F.alpha)", stdout: F.text("rex-inspect-a.json"), delay: 5)
        stub.respond("inspect \(F.beta)", stdout: F.text("rex-inspect-b.json"))
        let t0 = Date()
        let s = await RexClient(env: env(stub)).state(deadline: 1)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < 3, "state took \(elapsed) s")
        #expect(s.reachable && !s.complete)
        #expect(s.blocks == F.b.blocks)
        #expect(s.sessions == F.ls)
    }

    @Test func sessionsThatHoldAClaudeAreInspectedFirstAndNeverCapped() async throws {
        // 70 sessions; only the 70th answers its inspect. The others print nothing (which does not parse) after
        // 0.1 s, so no 9th inspect can start before the first 8 have logged their calls.
        let stub = RexStub(); defer { stub.remove() }
        func id(_ n: Int) -> String { String(format: "session:0190dddd-0000-7000-8000-%012d", n) }
        let refs = (1...70).map { ["session_id": id($0), "label": "s\($0)"] }
        let ls = String(data: try JSONSerialization.data(withJSONObject: ["sessions": refs]), encoding: .utf8)!
        stub.respond("ls", stdout: ls)
        for n in 1...69 { stub.respond("inspect \(id(n))", stdout: "", delay: 0.1) }
        let blk = "block:0190dddd-0000-7000-8000-000000000070"
        stub.respond("inspect \(id(70))", stdout: #"""
            {"session_id":"\#(id(70))","label":"s70","active_window_id":"window:70",
             "windows":[{"window_id":"window:70","layers":[{"kind":"tiled","blocks":[{"block_id":"\#(blk)"}]}]}],
             "clients":[]}
            """#)
        func inspected() -> [String] {
            stub.commands().filter { $0.first == "session" }.map { $0[2] }
        }
        let c = RexClient(env: env(stub))
        let s = await c.state(sessionsFirst: [id(70), "session:not-listed"], deadline: 30)
        #expect(s.blocks.map(\.blockId) == [blk])
        #expect(s.reachable && !s.complete)
        #expect(s.sessions.count == 70 && s.appClients.keys.sorted() == [id(70)])
        let first = inspected()
        #expect(first.count == 64)                                    // 64 in all, the wanted one included
        #expect(Array(first.prefix(RexClient.maxConcurrent)).contains(id(70)))
        #expect(Set(first) == Set((1...63).map(id) + [id(70)]))
        // Without a wanted set, the first 64 in `ls` order, as before.
        let n = stub.calls().count
        let plain = await c.state(deadline: 30)
        #expect(plain.blocks.isEmpty && !plain.complete)
        let second = Array(stub.commands().dropFirst(n)).filter { $0.first == "session" }.map { $0[2] }
        #expect(Set(second) == Set((1...64).map(id)))
    }

    @Test func readOnlyCommands() async {
        let stub = RexStub(); defer { stub.remove() }
        let c = RexClient(env: env(stub))
        stub.respond("capture", stdout: "l1\nl2\nl3\n")
        #expect(await c.capture(session: F.alpha, block: F.block("a3"), lines: 2) == "l2\nl3\n")
        #expect(stub.commands().last == ["capture", "-s", F.alpha, "-b", F.block("a3"), "--trim"])
        #expect(stub.calls().last.map { Array($0.prefix(3)) } == ["--autostart=false", "--timeout", "4s"])
        stub.respond("capture", stdout: "", exit: 3)
        #expect(await c.capture(session: F.alpha, block: F.block("a3")) == nil)
        stub.respond("whoami", stdout: F.text("rex-whoami.json"))
        #expect(await c.whoami()?.pid == 4242)
        #expect(stub.commands().last == ["whoami", "--json"])
    }

    @Test func captureAtTheOutputCapIsNil() async throws {
        let stub = RexStub(); defer { stub.remove() }
        let line = String(repeating: "x", count: 1023) + "\n"
        stub.respond("capture", stdout: String(repeating: line, count: (Shell.defaultMaxOutput / 1024) + 64))
        #expect(await RexClient(env: env(stub)).capture(session: "session:s", block: "block:b") == nil)
    }

    @Test func jumpCommands() async {
        let stub = RexStub(); defer { stub.remove() }
        let c = RexClient(env: env(stub))
        #expect(await c.focus(session: F.alpha, block: F.block("a3")))
        #expect(await c.select(session: F.alpha, window: F.window("a2"), client: nil).ok)
        #expect(stub.commands() == [["focus", "-s", F.alpha, F.block("a3")],
                                    ["do", "session.select", "session_id=\(F.alpha)", "window_id=\(F.window("a2"))"]])
        #expect(stub.calls().allSatisfy { Array($0.prefix(3)) == ["--autostart=false", "--timeout", "5s"] })
        #expect(!stub.calls()[1].contains("-C"))
        stub.respond("do", stdout: "", exit: 1)                                  // Remote Control off, say
        #expect(await c.select(session: F.alpha, window: F.window("a2"), client: F.appClient).ok == false)
        // The whole result comes back, stderr included, so the caller can say why.
        stub.respond("do", stdout: "", stderr: "Error: client target default not found: no app client is connected\n",
                     exit: 3)
        let r = await c.select(session: F.alpha, window: F.window("a2"), client: nil)
        #expect(r.status == 3 && !r.ok && r.stderr.contains("no app client is connected"))
        #expect(RexClient.selectFailureReason(r, action: "Jump").contains("not connected"))
        stub.respond("focus", stdout: "", exit: 3)
        #expect(await c.focus(session: F.alpha, block: "block:gone") == false)
    }

    @Test func undoCommands() async {
        let stub = RexStub(); defer { stub.remove() }
        let c = RexClient(env: env(stub))
        stub.respond("window-new", stdout: #"{"window_id":"window:n","block_ids":["block:n1"],"revision":2}"#)
        #expect(await c.newWindow(session: F.alpha, name: "--fix: the \"bug\"", cwd: "/tmp/a b")
                == RexNewTerminal(sessionId: F.alpha, windowId: "window:n", blockId: "block:n1"))
        stub.respond("new", stdout: #"{"session_id":"session:n","initial_windows":[{"window_id":"window:m","block_ids":["block:m1"]}]}"#)
        #expect(await c.newSession(label: "-proj", cwd: "/tmp/a b", windowName: "")
                == RexNewTerminal(sessionId: "session:n", windowId: "window:m", blockId: "block:m1"))
        #expect(await c.newSession(label: "", cwd: "/w", windowName: "tab one") != nil)
        #expect(await c.sendLine(session: "session:n", block: "block:m1", "claude --resume abc-123"))
        #expect(stub.commands() == [
            ["window", "new", "-s", F.alpha, "fix: the \"bug\"", "-c", "/tmp/a b", "--focus=false", "--json"],
            ["new", "proj", "-c", "/tmp/a b", "--window=claude", "--json"],
            ["new", "headroom", "-c", "/w", "--window=tab one", "--json"],
            ["send", "-s", "session:n", "-b", "block:m1", "claude --resume abc-123"],
            ["send-key", "-s", "session:n", "-b", "block:m1", "enter"],
        ])
        #expect(stub.calls().allSatisfy { Array($0.prefix(3)) == ["--autostart=false", "--timeout", "10s"] })
        // Failures: nil / false, and send-key never follows a failed send.
        stub.respond("window-new", stdout: "", exit: 3)
        #expect(await c.newWindow(session: F.alpha, name: "x", cwd: "/w") == nil)
        stub.respond("new", stdout: "not json")
        #expect(await c.newSession(label: "x", cwd: "/w", windowName: "y") == nil)
        let n = stub.calls().count
        stub.respond("send", stdout: "", exit: 3)
        #expect(await c.sendLine(session: "session:n", block: "block:m1", "claude --resume abc") == false)
        #expect(stub.commands().count == n + 1 && stub.commands().last?.first == "send")
    }

    @Test func sendLineRefusesFlagsAndLineBreaks() async {
        let stub = RexStub(); defer { stub.remove() }
        let c = RexClient(env: env(stub))
        #expect(await c.sendLine(session: "session:s", block: "block:b", "-x") == false)
        #expect(await c.sendLine(session: "session:s", block: "block:b", "echo a\nrm -rf b") == false)
        #expect(await c.sendLine(session: "session:s", block: "block:b", "echo a\r") == false)
        #expect(stub.calls().isEmpty)
    }

    @Test func stubRoutesAndLog() async {
        let stub = RexStub(); defer { stub.remove() }
        #expect(stub.path.hasSuffix("/rex") && FileManager.default.isExecutableFile(atPath: stub.path))
        let r = await Shell.run(stub.path, ["--autostart=false", "--timeout", "2s", "-C", "client:x", "-S", "unix:///s",
                                            "window", "new", "a b", ""])
        #expect(r.ok && r.stdout.isEmpty)                                         // unset route: no output, exit 0
        #expect(stub.calls() == [["--autostart=false", "--timeout", "2s", "-C", "client:x", "-S", "unix:///s",
                                  "window", "new", "a b", ""]])
        #expect(stub.commands() == [["window", "new", "a b", ""]])
        stub.respond("window-new", stdout: "made\n", exit: 7)
        let r2 = await Shell.run(stub.path, ["window", "new"])
        #expect(r2.status == 7 && r2.stdout == "made\n" && r2.stderr.isEmpty)
        stub.respond("window-new", stdout: "", stderr: "Error: nope\n", exit: 3)
        let r3 = await Shell.run(stub.path, ["window", "new"])
        #expect(r3.status == 3 && r3.stdout.isEmpty && r3.stderr == "Error: nope\n")
        stub.respond("window-new", stdout: "again\n")                          // a later answer drops the stderr
        let r4 = await Shell.run(stub.path, ["window", "new"])
        #expect(r4.ok && r4.stderr.isEmpty)
        stub.remove()
        #expect(!FileManager.default.fileExists(atPath: stub.dir))
    }
}

// MARK: - Opt-in: a PRIVATE Rex server

/// Opt-in: `HEADROOM_REX_LIVE_TEST=1 swift test --filter RexLiveTests`. Starts a private Rex server (its own socket
/// under /tmp and its own state directory), runs every RexClient call against it, then stops it. The user's own
/// server is never reached: every call carries `--autostart=false -S unix:///tmp/hrx-<pid>/s.sock`, and nothing
/// mutating runs until `whoami` reports the pid of the server this test started. Rex still creates an empty
/// `start.lock` under ~/Library/Application Support/rex/servers; new entries are printed, never deleted.
@Suite(.serialized) struct RexLiveTests {
    static let binary: String? = KnownPaths.rexCandidates(home: KnownPaths.accountHome)
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    static let enabled = ProcessInfo.processInfo.environment["HEADROOM_REX_LIVE_TEST"] == "1" && binary != nil

    @Test(.enabled(if: RexLiveTests.enabled)) func roundTripOnPrivateServer() async throws {
        let bin = try #require(Self.binary)
        let fm = FileManager.default
        let pid = getpid()
        let sockDir = "/tmp/hrx-\(pid)"
        let addr = "unix://" + sockDir + "/s.sock"
        try #require((sockDir + "/s.sock").utf8.count < 100)                    // macOS socket paths: 104 bytes
        try fm.createDirectory(atPath: sockDir, withIntermediateDirectories: true)
        let stateDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("hrx-state-\(pid)")
        try fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let config = stateDir + "/init.lua"
        fm.createFile(atPath: config, contents: Data())
        let serversDir = KnownPaths.accountHome + "/Library/Application Support/rex/servers"
        let before = Set((try? fm.contentsOfDirectory(atPath: serversDir)) ?? [])

        let server = Process()
        server.executableURL = URL(fileURLWithPath: bin)
        server.arguments = ["server", "run", "--listen", addr, "--state-dir", stateDir, "--restore=false",
                            "--config", config]
        server.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("REX_") }
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()

        let env = HeadroomEnv(environment: ["HOME": KnownPaths.accountHome, "HEADROOM_REX": bin,
                                            "HEADROOM_REX_SERVER": addr])
        let rex = RexClient(env: env)
        var confirmed = false
        var failure: (any Error)?
        do {
            var who: RexServerInfo?
            for _ in 0..<50 where who == nil {
                who = await rex.whoami()
                if who == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            let info = try #require(who, "the private server did not answer within 5 s")
            try #require(info.pid == server.processIdentifier, "whoami answered from pid \(info.pid), not our server")
            confirmed = true
            try await Self.exercise(rex)
        } catch {
            failure = error
        }

        // Teardown: only ever the server this test started.
        if env.rexServer == addr, confirmed {
            _ = await rex.run(["server", "stop"])
        } else if env.rexServer != addr {
            Issue.record("HEADROOM_REX_SERVER is not the private address; not stopping anything through rex")
        }
        for _ in 0..<50 where server.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        if server.isRunning { server.terminate() }                              // SIGTERM our own child only
        for _ in 0..<50 where server.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        try? fm.removeItem(atPath: sockDir)
        try? fm.removeItem(atPath: stateDir)
        let added = Set((try? fm.contentsOfDirectory(atPath: serversDir)) ?? []).subtracting(before)
        if !added.isEmpty { print("RexLiveTests: new entries in \(serversDir) (left in place): \(added.sorted())") }
        if let failure { throw failure }
    }

    static func exercise(_ rex: RexClient) async throws {
        let scratch = CoreSelfTest.realPath(NSTemporaryDirectory())
        let made = try #require(await rex.newSession(label: "hr-live", cwd: scratch, windowName: "first"))
        let refs = try #require(await rex.sessions())
        #expect(refs.contains(RexSessionRef(sessionId: made.sessionId, label: "hr-live")))
        let ins = try #require(await rex.inspect(made.sessionId))
        #expect(ins.blocks.map(\.blockId) == [made.blockId])
        #expect(ins.blocks.first?.windowLabel == "first" && ins.blocks.first?.windowActive == true)
        #expect(ins.appClients.isEmpty && ins.blocks.allSatisfy { !$0.visible })

        // A new tab does not take focus.
        let second = try #require(await rex.newWindow(session: made.sessionId, name: "second", cwd: scratch))
        let after = try #require(await rex.inspect(made.sessionId))
        #expect(after.blocks.count == 2)
        #expect(after.blocks.first { $0.blockId == made.blockId }?.windowActive == true)
        #expect(after.blocks.first { $0.blockId == second.blockId }?.windowActive == false)
        #expect(after.blocks.first { $0.blockId == second.blockId }?.windowLabel == "second")

        // Type a line, then read it back.
        #expect(await rex.sendLine(session: made.sessionId, block: second.blockId, "echo headroom-$((40+2))"))
        var captured = ""
        for _ in 0..<50 {
            captured = await rex.capture(session: made.sessionId, block: second.blockId) ?? ""
            if captured.contains("headroom-42") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(captured.contains("headroom-42"))

        // Jump: the server side works; no app is connected, so there is no client and session.select fails.
        #expect(await rex.focus(session: made.sessionId, block: second.blockId))
        let st = await rex.state()
        #expect(st.reachable && st.complete && st.sessions.contains { $0.sessionId == made.sessionId })
        #expect(st.blocks.first { $0.blockId == second.blockId }?.windowActive == true)
        #expect(RexClient.jumpClient(session: made.sessionId, state: st) == nil)
        #expect(await rex.select(session: made.sessionId, window: second.windowId, client: nil).ok == false)
    }
}
