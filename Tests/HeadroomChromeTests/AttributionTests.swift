// Attribution (SPEC §4.4) and process classification (§4.1). Pure functions, no I/O.
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomChrome

let MB: Bytes = 1 << 20

/// Test helpers: build processes and tabs compactly.
enum A {
    static func proc(_ pid: Int32, _ b: Int32, _ kind: ChromeProcKind, _ mb: Bytes) -> ChromeProc {
        ChromeProc(key: ProcKey(pid: pid, startSec: 1000), browserPid: b, kind: kind, footprint: mb * MB)
    }
    static func r(_ pid: Int32, _ b: Int32, client: Int?, _ mb: Bytes) -> ChromeProc { proc(pid, b, .renderer(clientId: client), mb) }
    static func frame(_ id: Int, _ process: Int, parent: Int = 0, _ lc: String = "active") -> ChromeFrame {
        ChromeFrame(frameId: id, parentFrameId: id == 0 ? -1 : parent, processId: process, lifecycle: lc)
    }
    static func tab(_ id: Int, _ frames: [ChromeFrame], b: Int32 = 100, win: Int = 1, discarded: Bool = false) -> ChromeTab {
        ChromeTab(browserPid: b, id: id, windowId: win, index: id, title: "t\(id)", url: "https://x\(id).test/",
                  host: "x\(id).test", discarded: discarded, frames: frames)
    }
    /// A browser 100 with the usual overhead processes.
    static func base(_ b: Int32 = 100) -> [ChromeProc] {
        [proc(b, b, .browser, 300), proc(b + 1, b, .gpu, 200), proc(b + 2, b, .utility, 50),
         proc(b + 3, b, .crashpad, 5), proc(b + 4, b, .extensionRenderer, 90)]
    }
    static func key(_ pid: Int32) -> ProcKey { ProcKey(pid: pid, startSec: 1000) }
    static func sumDisplay(_ r: Attribution.Result) -> Bytes { r.tabs.reduce(0) { $0 + ($1.display ?? 0) } }
    static func overhead(_ r: Attribution.Result) -> Bytes { r.overhead.values.reduce(0) { $0 + $1.bytes } }
}

@Suite struct ClassificationTests {
    @Test func argvClasses() {
        func k(_ a: [String]) -> ChromeProcKind { ChromeProcKind.classify(ProcArgs(argv: a)) }
        let chrome = KnownPaths.chromeExecutable
        #expect(k([chrome]) == .browser)
        #expect(k([chrome, "--type=gpu-process", "--foo"]) == .gpu)
        #expect(k([chrome + " Helper", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]) == .utility)
        #expect(k([chrome, "--type=crashpad-handler", "--database=/x"]) == .crashpad)
        // Chrome 154's reparented handler: no --type (captured read-only from the live system).
        #expect(k(["/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/154.0.8037.58/Helpers/chrome_crashpad_handler",
                   "--monitor-self-annotation=ptype=crashpad-handler", "--database=/Users/x/Library/Application Support/Google/Chrome/Crashpad"]) == .crashpad)
        #expect(k([chrome, "--type=renderer", "--extension-process", "--renderer-client-id=9"]) == .extensionRenderer)
        #expect(k([chrome, "--type=renderer", "--renderer-client-id=17"]) == .renderer(clientId: 17))
        #expect(k([chrome, "--type=renderer"]) == .renderer(clientId: nil))
        #expect(k([chrome, "--type=zygote"]) == .other("zygote"))
        #expect(ChromeProcKind.classify(nil) == .other("unreadable"))
        #expect(ChromeProcKind.other("x").overheadKind == .utility)
    }
}

@Suite struct AttributionTests {
    @Test func singleTabOwnRenderer() {
        let procs = A.base() + [A.r(110, 100, client: 7, 336)]
        let tabs = [A.tab(1, [A.frame(0, 7)])]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        #expect(r.tabs[0].display == 336 * MB)
        #expect(r.tabs[0].exclusive == 336 * MB)
        #expect(r.tabs[0].sharedWith == 0)
        #expect(r.tabs[0].procs == [A.key(110)])
        #expect(r.perTabUnavailable == nil)
        #expect(r.total == (300 + 200 + 50 + 5 + 90 + 336) * MB)
        #expect(A.sumDisplay(r) + A.overhead(r) == r.total)
        #expect(r.unaccounted == 0 && r.mismatchNote == nil)
        #expect(r.overhead["browser"]?.bytes == 300 * MB && r.overhead["gpu"]?.bytes == 200 * MB)
        #expect(r.overhead["utility"]?.bytes == 50 * MB && r.overhead["crashpad"]?.bytes == 5 * MB)
        #expect(r.overhead["extensions"]?.bytes == 90 * MB && r.overhead["background"] == nil)
    }

    @Test func sharedRendererFairShareAndFreed() {
        // Two Linear tabs share renderer 8 (300 MB); tab 3 has its own (100 MB).
        let procs = A.base() + [A.r(111, 100, client: 8, 300), A.r(112, 100, client: 9, 100)]
        let tabs = [A.tab(1, [A.frame(0, 8)]), A.tab(2, [A.frame(0, 8)]), A.tab(3, [A.frame(0, 9)])]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        #expect(r.tabs[0].display == 150 * MB && r.tabs[1].display == 150 * MB)
        #expect(r.tabs[0].sharedWith == 1 && r.tabs[1].sharedWith == 1 && r.tabs[2].sharedWith == 0)
        #expect(r.tabs[0].exclusive == 0 && r.tabs[2].exclusive == 100 * MB)
        #expect(r.procUsers[A.key(111)] == [TabRef(browserPid: 100, tabId: 1), TabRef(browserPid: 100, tabId: 2)])
        let snap = ChromeSnapshot(source: .helper(profiles: 1), tabs: r.tabs, procFootprint: r.procFootprint, procUsers: r.procUsers)
        // Closing one of the two frees nothing of the shared renderer; closing both frees it.
        #expect(snap.freed([TabRef(browserPid: 100, tabId: 1)]) == 0)
        #expect(snap.freed([TabRef(browserPid: 100, tabId: 1), TabRef(browserPid: 100, tabId: 2)]) == 300 * MB)
        #expect(A.sumDisplay(r) + A.overhead(r) == r.total)
    }

    @Test func fairShareRemainderKeepsExactSum() {
        // 100 bytes over 3 users: 34 + 33 + 33.
        let procs = [ChromeProc(key: A.key(100), browserPid: 100, kind: .browser, footprint: 7),
                     ChromeProc(key: A.key(120), browserPid: 100, kind: .renderer(clientId: 4), footprint: 100)]
        let tabs = [A.tab(3, [A.frame(0, 4)]), A.tab(1, [A.frame(0, 4)]), A.tab(2, [A.frame(0, 4)])]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        let byId = Dictionary(uniqueKeysWithValues: r.tabs.map { ($0.id, $0.display!) })
        #expect(byId == [1: 34, 2: 33, 3: 33])
        #expect(A.sumDisplay(r) + A.overhead(r) == r.total)
        #expect(r.tabs.allSatisfy { $0.sharedWith == 2 })
    }

    @Test func crossSiteIframeCountsBothProcesses() {
        // Tab 1: main frame in renderer 10 (200 MB), cross-site iframe in renderer 11 (60 MB).
        // Tab 2 embeds the same cross-site origin, whose frame shares renderer 11.
        let procs = A.base() + [A.r(130, 100, client: 10, 200), A.r(131, 100, client: 11, 60), A.r(132, 100, client: 12, 40)]
        let tabs = [A.tab(1, [A.frame(0, 10), A.frame(5, 11)]), A.tab(2, [A.frame(0, 12), A.frame(6, 11)])]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        #expect(r.tabs[0].display == (200 + 30) * MB)
        #expect(r.tabs[1].display == (40 + 30) * MB)
        #expect(r.tabs[0].procs == [A.key(130), A.key(131)])
        #expect(r.tabs[0].exclusive == 200 * MB)
        #expect(r.tabs[0].sharedWith == 0)  // only the main frame's process decides "≈"
        let snap = ChromeSnapshot(source: .helper(profiles: 1), tabs: r.tabs, procFootprint: r.procFootprint, procUsers: r.procUsers)
        #expect(snap.freed([TabRef(browserPid: 100, tabId: 1)]) == 200 * MB)
        #expect(snap.freed([TabRef(browserPid: 100, tabId: 1), TabRef(browserPid: 100, tabId: 2)]) == 300 * MB)
        #expect(A.sumDisplay(r) + A.overhead(r) == r.total)
    }

    @Test func bfcacheOnlyProcessIsCountedInFreed() {
        // Tab 1 navigated from site A (renderer 20, now only a bfcache "cached" frame) to site B (renderer 21).
        let procs = A.base() + [A.r(140, 100, client: 20, 80), A.r(141, 100, client: 21, 120)]
        let tabs = [A.tab(1, [A.frame(0, 21), A.frame(0, 20, "cached")])]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        #expect(r.tabs[0].display == 200 * MB)
        #expect(r.tabs[0].procs == [A.key(140), A.key(141)])
        #expect(r.overhead["background"] == nil)  // the bfcache process is the tab's, not background
        let snap = ChromeSnapshot(source: .helper(profiles: 1), tabs: r.tabs, procFootprint: r.procFootprint, procUsers: r.procUsers)
        #expect(snap.freed([TabRef(browserPid: 100, tabId: 1)]) == 200 * MB)
        // Prerender frames count the same way.
        let r2 = Attribution.attribute(procs: procs, tabs: [A.tab(1, [A.frame(0, 21), A.frame(3, 20, "prerender")])], perTabBrowsers: [100])
        #expect(r2.tabs[0].display == 200 * MB)
    }

    @Test func discardedTabIsZeroAndSleeping() {
        let procs = A.base() + [A.r(150, 100, client: 30, 90), A.r(151, 100, client: 31, 25)]
        // Tab 2 is discarded (Chrome reports no frames); renderer 31 is a spare/background renderer.
        let tabs = [A.tab(1, [A.frame(0, 30)]), A.tab(2, [], discarded: true)]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        #expect(r.tabs[1].display == 0 && r.tabs[1].procs.isEmpty && r.tabs[1].discarded)
        #expect(r.overhead["background"] == OverheadStat(count: 1, bytes: 25 * MB))
        #expect(A.sumDisplay(r) + A.overhead(r) == r.total)
        // Frames reported for a discarded tab (should not happen) are ignored.
        let r2 = Attribution.attribute(procs: procs, tabs: [A.tab(1, [A.frame(0, 30)]), A.tab(2, [A.frame(0, 30)], discarded: true)],
                                       perTabBrowsers: [100])
        #expect(r2.tabs[0].display == 90 * MB && r2.tabs[1].display == 0)
    }

    @Test func missingClientIdIsDegraded() {
        // No renderer has --renderer-client-id: every tab shows "—" and a reason is given.
        let procs = A.base() + [A.r(160, 100, client: nil, 100), A.r(161, 100, client: nil, 100)]
        let tabs = [A.tab(1, [A.frame(0, 4)]), A.tab(2, [A.frame(0, 5)])]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        #expect(r.perTabUnavailable?.contains("renderer-client-id") == true)
        #expect(r.tabs.allSatisfy { $0.display == nil })
        #expect(r.total == (300 + 200 + 50 + 5 + 90 + 200) * MB)
        #expect(r.mismatchNote == nil)  // no debug line in degraded mode
    }

    @Test func unmatchedOverTwentyPercentIsDegraded() {
        // 5 tabs, 2 main frames match no renderer (40% > 20%).
        let procs = A.base() + (0..<3).map { A.r(170 + Int32($0), 100, client: 40 + $0, 50) }
        let tabs = [A.tab(1, [A.frame(0, 40)]), A.tab(2, [A.frame(0, 41)]), A.tab(3, [A.frame(0, 42)]),
                    A.tab(4, [A.frame(0, 99)]), A.tab(5, [A.frame(0, 98)])]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        #expect(r.perTabUnavailable?.contains("2 of 5 tabs") == true)
        #expect(r.tabs.allSatisfy { $0.display == nil })
        #expect(r.joinStats[100]! == (tabs: 5, unmatched: 2))
        // 1 of 5 (20%) is not degraded.
        let r2 = Attribution.attribute(procs: procs, tabs: Array(tabs.prefix(4)) + [A.tab(5, [A.frame(0, 40)])], perTabBrowsers: [100])
        #expect(r2.perTabUnavailable == nil)
        #expect(r2.tabs.first { $0.id == 4 }?.display == nil)      // unmatched: unknown ("—"), never 0
    }

    /// Review findings: unknown is "—", never 0; extension pages are not "unmatched"; tabs the helper cannot see
    /// get their own bucket; a degraded browser's join is not used by freed().
    @Test func unknownTabsAreNilAndExtensionPagesAreNotUnmatched() {
        let ext = ChromeProc(key: A.key(150), browserPid: 100, kind: .extensionRenderer, footprint: 60 * MB,
                             extensionClientId: 77)
        let procs = [A.proc(100, 100, .browser, 300), ext] + (0..<3).map { A.r(170 + Int32($0), 100, client: 40 + $0, 50) }
        let tabs = [A.tab(1, [A.frame(0, 40)]), A.tab(2, [A.frame(0, 41)]), A.tab(3, [A.frame(0, 42)]),
                    A.tab(4, [A.frame(0, 77)]), A.tab(5, [A.frame(0, 77)]),     // chrome-extension:// pages
                    A.tab(6, [])]                                              // getAllFrames failed
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        #expect(r.perTabUnavailable == nil)                     // 2 extension pages of 5 do not degrade the browser
        #expect(r.joinStats[100]! == (tabs: 3, unmatched: 0))
        #expect(r.tabs.first { $0.id == 1 }?.display == 50 * MB)
        for id in [4, 5, 6] { #expect(r.tabs.first { $0.id == id }?.display == nil, "tab \(id)") }
        #expect(r.procUsers[ext.key] == nil)                    // closing the page does not free the extension
    }

    @Test func blindBrowserRenderersAreHiddenTabsNotBackground() {
        let procs = A.base() + [A.r(170, 100, client: 40, 50), A.r(171, 100, client: 41, 80)]
        let tabs = [A.tab(1, [A.frame(0, 40)]), A.tab(9, [])]  // tab 9: an incognito tab listed by JXA only
        let seen = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        #expect(seen.overhead[ChromeOverheadKind.background.rawValue]?.bytes == 80 * MB)
        let blind = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100], blindBrowsers: [100])
        #expect(blind.overhead[ChromeOverheadKind.background.rawValue] == nil)
        #expect(blind.overhead[ChromeOverheadKind.hiddenTabs.rawValue]?.bytes == 80 * MB)
    }

    @Test func degradedBrowserHasNoProcUsers() {
        let procs = A.base() + (0..<3).map { A.r(170 + Int32($0), 100, client: 40 + $0, 50) }
        let tabs = [A.tab(1, [A.frame(0, 40)]), A.tab(2, [A.frame(0, 41)]), A.tab(3, [A.frame(0, 42)]),
                    A.tab(4, [A.frame(0, 99)]), A.tab(5, [A.frame(0, 98)])]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100])
        #expect(r.perTabUnavailable != nil)
        #expect(r.procUsers.isEmpty)
    }

    @Test func twoBrowsersWithCollidingClientIds() {
        // Browser 100 and browser 200 (a second main instance) both have renderer client id 7.
        let procs = A.base(100) + A.base(200) + [A.r(110, 100, client: 7, 100), A.r(210, 200, client: 7, 400)]
        let tabs = [A.tab(1, [A.frame(0, 7)], b: 100), A.tab(1, [A.frame(0, 7)], b: 200)]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [100, 200])
        let t100 = r.tabs.first { $0.browserPid == 100 }!, t200 = r.tabs.first { $0.browserPid == 200 }!
        #expect(t100.display == 100 * MB && t200.display == 400 * MB)
        #expect(t100.sharedWith == 0 && t200.sharedWith == 0)
        #expect(r.procUsers[A.key(110)] == [TabRef(browserPid: 100, tabId: 1)])
        #expect(r.procUsers[A.key(210)] == [TabRef(browserPid: 200, tabId: 1)])
        #expect(r.overhead["browser"] == OverheadStat(count: 2, bytes: 600 * MB))
        #expect(A.sumDisplay(r) + A.overhead(r) == r.total)
    }

    @Test func appleScriptTabsShowDashAndRenderersAreNotOverhead() {
        let procs = A.base() + [A.r(180, 100, client: 50, 400)]
        let tabs = [A.tab(1, [])]
        let r = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [])
        #expect(r.tabs[0].display == nil)
        #expect(r.overhead["background"] == nil)
        #expect(A.overhead(r) == (300 + 200 + 50 + 5 + 90) * MB)
        #expect(r.total == A.overhead(r) + 400 * MB)
        #expect(r.perTabUnavailable == nil)
    }

    @Test func otherInstancesAddToOverheadAndTotal() {
        let procs = A.base() + [A.r(110, 100, client: 7, 10)]
        let r = Attribution.attribute(procs: procs, tabs: [A.tab(1, [A.frame(0, 7)])], perTabBrowsers: [100],
                                      otherInstances: OverheadStat(count: 1, bytes: 1280 * MB))
        #expect(r.overhead["otherInstances"] == OverheadStat(count: 1, bytes: 1280 * MB))
        #expect(r.total == (300 + 200 + 50 + 5 + 90 + 10 + 1280) * MB)
        #expect(A.sumDisplay(r) + A.overhead(r) == r.total)
        let none = Attribution.attribute(procs: [], tabs: [], perTabBrowsers: [], otherInstances: OverheadStat(count: 2, bytes: 5))
        #expect(none.total == 5 && none.overhead["otherInstances"]?.count == 2)
    }

    @Test func unusedRendererIsBackgroundAndIncognitoWithoutAccessToo() {
        // Renderer 60 serves no reported tab (a service worker, or an incognito tab the helper cannot see).
        let procs = A.base() + [A.r(190, 100, client: 60, 70), A.r(191, 100, client: 61, 30)]
        let r = Attribution.attribute(procs: procs, tabs: [A.tab(1, [A.frame(0, 61)])], perTabBrowsers: [100])
        #expect(r.overhead["background"] == OverheadStat(count: 1, bytes: 70 * MB))
        #expect(r.procFootprint[A.key(190)] == 70 * MB)
        #expect(A.sumDisplay(r) + A.overhead(r) == r.total)
    }

    @Test func framesWithoutProcessAreIgnored() {
        let procs = A.base() + [A.r(110, 100, client: 7, 10)]
        let r = Attribution.attribute(procs: procs, tabs: [A.tab(1, [A.frame(0, 7), A.frame(2, 0), A.frame(3, -1)])], perTabBrowsers: [100])
        #expect(r.tabs[0].display == 10 * MB && r.tabs[0].procs == [A.key(110)])
    }
}

@Suite struct ChromeProcessesTests {
    func sample(_ pid: Int32, _ ppid: Int32, _ mb: Bytes, path: String = KnownPaths.chromeExecutable) -> ProcSample {
        ProcSample(key: ProcKey(pid: pid, startSec: 1000), ppid: ppid, pgid: pid, path: path, footprint: mb * MB, rss: mb * MB)
    }

    @Test func collectsOwnedPidsAndHostOnlyBrowsers() {
        let cft = "/scratch/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        let t = ProcessTable(samples: [
            sample(1, 0, 1, path: "/sbin/launchd"),
            sample(100, 1, 300), sample(101, 100, 200), sample(102, 100, 90), sample(103, 1, 5),  // 103: reparented crashpad
            sample(500, 1, 100, path: cft), sample(501, 500, 50, path: cft), sample(502, 500, 20, path: cft),
            sample(503, 500, 4, path: "/x/Headroom.app/Contents/Helpers/headroom-host"),   // a host: not Chrome
            sample(504, 500, 3, path: "/usr/bin/some-other-child"), sample(505, 500, 6, path: cft),
            sample(600, 1, 400), sample(601, 600, 80),  // an automation browser owned by a session
            sample(700, 1, 250), sample(701, 700, 30),  // other Chrome instance
        ])
        let args: [Int32: [String]] = [
            100: [KnownPaths.chromeExecutable], 101: ["x", "--type=gpu-process"], 102: ["x", "--type=renderer", "--renderer-client-id=4"],
            103: ["x", "--type=crashpad-handler"], 500: [cft], 501: ["x", "--type=renderer", "--renderer-client-id=4"],
            502: ["x", "--type=utility"], 505: [cft, "--no-type-flag"],
        ]
        let s = ProcKey(pid: 900, startSec: 1)
        let o = OwnershipMap(owner: [100: .chrome(browserPid: 100), 101: .chrome(browserPid: 100), 102: .chrome(browserPid: 100),
                                     103: .chrome(browserPid: 100), 502: .claudeChild(s),
                                     600: .claudeBackground(s), 601: .claudeBackground(s),
                                     700: .otherChrome(browserPid: 700), 701: .otherChrome(browserPid: 700)],
                             browsers: [BrowserInstance(key: ProcKey(pid: 100, startSec: 1000), isMain: true, userDataDir: nil, headless: false),
                                        BrowserInstance(key: ProcKey(pid: 600, startSec: 1000), isMain: false, userDataDir: "/x", headless: true),
                                        BrowserInstance(key: ProcKey(pid: 700, startSec: 1000), isMain: false, userDataDir: "/y", headless: true)])
        // 500 is named by a host but unknown to Ownership; 600 is named by a host but owned by a session.
        let mains = ChromeProcesses.mainBrowserPids(t, o, hostBrowserPids: [500, 600, 999])
        #expect(mains == [100, 500])
        let procs = ChromeProcesses.collect(t, o, mainBrowsers: mains, args: { k in args[k.pid].map { ProcArgs(argv: $0) } })
        // 502 is owned elsewhere (never counted twice); 503 (a host) and 504 are not the browser's own binaries.
        #expect(procs.map(\.key.pid) == [100, 101, 102, 103, 500, 501, 505])
        #expect(procs.first { $0.key.pid == 505 }?.kind == .other("no --type"))
        let noHost = ChromeProcesses.collect(t, o, mainBrowsers: mains, excluding: [505], args: { k in args[k.pid].map { ProcArgs(argv: $0) } })
        #expect(!noHost.contains { $0.key.pid == 505 })
        #expect(procs.first { $0.key.pid == 103 }?.kind == .crashpad)
        #expect(procs.first { $0.key.pid == 501 }?.browserPid == 500)
        #expect(procs.first { $0.key.pid == 500 }?.kind == .browser)
        #expect(ChromeProcesses.otherInstances(t, o) == OverheadStat(count: 1, bytes: 280 * MB))
    }
}
