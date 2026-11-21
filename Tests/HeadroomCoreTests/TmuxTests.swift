// TmuxClient: parsing of output captured from the real server (read-only list-panes/list-clients), and a
// live round trip against a PRIVATE server (`tmux -L headroom-test`) that this test starts and kills itself.
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomCore

@Suite struct TmuxParseTests {
    let panesText = try! String(contentsOf: Fixtures.url("tmux-panes.txt"), encoding: .utf8)
    let clientsText = try! String(contentsOf: Fixtures.url("tmux-clients.txt"), encoding: .utf8)

    @Test func parsesCapturedPanes() {
        let panes = TmuxClient.parsePanes(panesText)
        #expect(panes.count == 29)
        let p = panes.first { $0.paneId == "%115" }
        #expect(p?.panePid == 73336)
        #expect(p?.session == "quote-composer")
        #expect(p?.windowIndex == 1 && p?.paneIndex == 1)
        #expect(p?.paneTitle == "✳ workflow ideas for ops")
        #expect(p?.currentCommand == "2.1.283")
        #expect(p?.visible == true)                        // active pane, active window, attached session
        let unattached = panes.first { $0.paneId == "%149" }
        #expect(unattached?.sessionAttached == 0 && unattached?.visible == false)
        #expect(Set(panes.map(\.paneId)).count == panes.count)
    }

    @Test func parsesCapturedClients() {
        let clients = TmuxClient.parseClients(clientsText)
        #expect(clients.count == 6)
        #expect(clients.first?.tty == "/dev/ttys001")
        #expect(TmuxClient.currentSession(clients) == "misc")          // highest client_activity
        #expect(TmuxClient.jumpClient(for: "hub", clients: clients)?.tty == "/dev/ttys011")
        #expect(TmuxClient.jumpClient(for: "nope", clients: clients)?.session == "misc")
    }

    @Test func toleratesJunkAndTabsInTitles() {
        let text = "garbage line\n%1\t42\t1\t1\t2\tsess\t3\t0\tname\ttitle\twith\ttabs\tzsh\n%2\tx\t1\n\n"
        let panes = TmuxClient.parsePanes(text)
        #expect(panes.count == 1)
        #expect(panes[0].paneTitle == "title\twith\ttabs")
        #expect(panes[0].currentCommand == "zsh")
        #expect(panes[0].sessionAttached == 2)
        #expect(TmuxClient.parseClients("x\ty\n12\t/dev/ttys9\ta b\n").map(\.session) == ["a b"])
    }

    @Test func locationAndPaneLookup() {
        let panes = TmuxClient.parsePanes(panesText)
        let clients = TmuxClient.parseClients(clientsText)
        let misc = panes.first { $0.session == "misc" && $0.visible }!
        let loc = TmuxClient.location(of: misc, clients: clients)
        #expect(loc.current && loc.visible)
        #expect(loc.label == "misc:\(misc.windowIndex).\(misc.paneIndex)")
        let other = panes.first { $0.session == "quote-composer" && $0.visible }!
        #expect(TmuxClient.location(of: other, clients: clients).current == false)
        #expect(TmuxClient.pane(forParent: 73336, hint: nil, in: panes)?.paneId == "%115")
        #expect(TmuxClient.pane(forParent: 1, hint: "%115", in: panes)?.panePid == 73336)
        #expect(TmuxClient.pane(forParent: 1, hint: "%99999", in: panes) == nil)
    }

    @Test func socketSeamAddsDashL() {
        let env = HeadroomEnv(environment: ["HOME": "/tmp", "HEADROOM_TMUX_SOCKET": "headroom-test"])
        #expect(env.tmuxBaseArgs == ["-L", "headroom-test"])
        let c = TmuxClient(env: env)
        #expect(c.childEnvironment?["TMUX"] == nil)
        #expect(TmuxClient(env: HeadroomEnv(environment: ["HOME": "/tmp"])).childEnvironment == nil)
    }
}

/// Serialized: every test here shares the private `-L headroom-test` server.
@Suite(.serialized) struct TmuxLiveTests {
    static let socket = "headroom-test"
    let env: HeadroomEnv = {
        var e = HeadroomEnv(environment: ProcessInfo.processInfo.environment)
        e.tmuxSocket = TmuxLiveTests.socket          // never the default server
        return e
    }()

    func killPrivateServer() async {
        precondition(env.tmuxBaseArgs == ["-L", Self.socket])
        _ = await TmuxClient(env: env).run(["kill-server"])     // -L headroom-test only
    }

    @Test func roundTripOnPrivateServer() async throws {
        guard FileManager.default.isExecutableFile(atPath: env.tmuxPath) else { return }
        let tmux = TmuxClient(env: env)
        await killPrivateServer()
        let scratch = CoreSelfTest.realPath(NSTemporaryDirectory())
        #expect(await tmux.panes().isEmpty)                      // no server yet → []
        #expect(await tmux.hasSession("hr-a") == false)
        // Boot the private server with /bin/sh so the test does not run the user's zsh config in its panes.
        #expect(await tmux.run(["new-session", "-d", "-s", "hr-boot", "/bin/sh"]).ok)
        #expect(await tmux.run(["set-option", "-g", "default-shell", "/bin/sh"]).ok)

        // newWindow on a missing session creates it.
        let p1 = try #require(await tmux.newWindow(session: "hr-a", name: "first", cwd: scratch))
        #expect(p1.hasPrefix("%"))
        #expect(await tmux.hasSession("hr-a"))
        let p2 = try #require(await tmux.newWindow(session: "hr-a", name: "second win", cwd: scratch))
        #expect(p2 != p1)

        let panes = await tmux.panes().filter { $0.session == "hr-a" }
        #expect(panes.count == 2)
        #expect(Set(panes.map(\.windowName)) == ["first", "second win"])
        #expect(panes.allSatisfy { $0.session == "hr-a" && $0.panePid > 1 && $0.sessionAttached == 0 })

        // send-keys is literal, then Enter; capture-pane reads it back.
        #expect(await tmux.sendKeys(pane: p2, "echo headroom-$((40+2)) 'quoted \"x\"'"))
        var captured = ""
        for _ in 0..<40 {
            captured = await tmux.capture(pane: p2, lines: 20) ?? ""
            if captured.contains("headroom-42") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(captured.contains("headroom-42 quoted \"x\""))

        // No UTF-8 locale (an app opened from Finder has no LANG): tmux would turn the tabs of the -F format
        // into "_" without `-u`, and no pane would parse.
        var cLocale = tmux
        cLocale.extraEnvironment = ["LC_ALL": "C", "LANG": "C", "LC_CTYPE": "C"]
        #expect(cLocale.childEnvironment?["TMUX"] == nil)
        let plain = await cLocale.panes().filter { $0.session == "hr-a" }
        #expect(plain.count == 2)
        #expect(Set(plain.map(\.windowName)) == ["first", "second win"])

        #expect(await tmux.clients().isEmpty)
        #expect(await tmux.jump(paneId: p2) == .noClient(session: "hr-a"))
        #expect(await tmux.jump(paneId: p2).tty == nil)
        #expect(await tmux.jump(paneId: "%424242") == .noPane)

        await killPrivateServer()
        #expect(await tmux.panes().isEmpty)
    }

    @Test func missingBinaryIsHandled() async {
        var e = env
        e.tmuxPath = "/nonexistent/tmux"
        let t = TmuxClient(env: e)
        #expect(await t.panes().isEmpty)
        #expect(await t.clients().isEmpty)
        #expect(await t.run(["list-panes"]).status == 127)
    }
}
