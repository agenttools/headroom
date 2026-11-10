// Attribution (SPEC §4.4): a pure function from classified Chrome processes + tabs (with frames) to per-tab
// memory, "Chrome itself" overhead and the section total. No I/O, fully unit tested.
//
//   frames(tab)    = frames with processId > 0, ALL lifecycles (active, cached, prerender, pending)
//   users[c]       = { tab | tab has any frame in client c }                  (c scoped to browserPid)
//   display(tab)   = Σ_{c ∈ procs(tab)} fp[c] / |users[c]|     fair share; the remainder bytes go to the
//                                                              first users, so tab rows sum exactly
//   exclusive(tab) = Σ fp[c] where users[c] == {tab}
//   sharedWith     = |users[mainFrameProc]| − 1
//   discarded      → display 0
//   no matched frame (getAllFrames failed, renderer spawned after the scan, or a chrome-extension:// page whose
//                  frames live in an extension renderer) → display nil ("—"), never 0
//   Chrome itself  = browser + GPU + utility + crashpad + extension renderers + renderers with users = ∅
//                    + "Other Chrome instances". In a browser where the helper cannot see every tab (incognito
//                    without "Allow in Incognito", a profile without the helper: `blindBrowsers`), renderers with
//                    users = ∅ go to "Tabs the helper can't see" (.hiddenTabs) instead of background.
//   Section total  = Σ over all main-browser pids + other instances (never a sum of tab values)
//
// Only browsers whose tabs carry frame data (the helper extension) get per-tab numbers. For the others
// (AppleScript list, or no tab list at all) tabs show "—", and their renderers are not overhead: they are
// the tabs' memory, which is in the section total but cannot be split per tab.
//
// Degraded mode (per helper browser): no renderer of that browser has `--renderer-client-id`, or more than
// 20% of its tabs (not discarded, with a main frame) have a main-frame processId that matches no renderer.
// Then every tab of that browser shows "—" and `perTabUnavailable` explains why, and procUsers leaves that
// browser out (so freed() never relies on a join declared unreliable). Main frames in an extension renderer
// do not count as unmatched.

import Foundation
import HeadroomContracts

public enum Attribution {
    public static let degradedUnmatchedFraction = 0.20
    /// SPEC §4.4 debug check: Σ tabs + overhead vs the process total.
    public static let mismatchLogFraction = 0.05

    public struct Result: Sendable {
        public var tabs: [ChromeTab]
        public var overhead: [String: OverheadStat]
        public var total: Bytes
        public var procFootprint: [ProcKey: Bytes]
        public var procUsers: [ProcKey: Set<TabRef>]
        public var perTabUnavailable: String?
        /// Per helper browser: (tabs with a main frame, of which unmatched).
        public var joinStats: [Int32: (tabs: Int, unmatched: Int)]
        /// total − (Σ display + overhead); 0 when every browser has per-tab data and nothing is degraded.
        public var unaccounted: Int64
        /// Non-nil when |unaccounted| > 5% of the total while per-tab data is on (SPEC's debug log line).
        public var mismatchNote: String?
    }

    /// - Parameters:
    ///   - procs: every process of the main browsers (`ChromeProcesses.collect`).
    ///   - tabs: every tab of those browsers (display/exclusive/sharedWith/procs are recomputed).
    ///   - perTabBrowsers: browsers whose tabs came from the helper (frames are meaningful).
    ///   - otherInstances: "Other Chrome instances" (automation browsers no session owns).
    ///   - blindBrowsers: helper browsers with tabs the helper cannot see (see the file header).
    public static func attribute(procs: [ChromeProc], tabs input: [ChromeTab], perTabBrowsers: Set<Int32>,
                                 otherInstances: OverheadStat? = nil, blindBrowsers: Set<Int32> = []) -> Result {
        // Renderer map, scoped per browser: clientMap[browserPid][clientId] = proc.
        var clientMap: [Int32: [Int: ChromeProc]] = [:]
        var extMap: [Int32: [Int: ChromeProc]] = [:]
        var renderersWithId: [Int32: Int] = [:]
        for p in procs {
            if case .renderer(let c?) = p.kind {
                clientMap[p.browserPid, default: [:]][c] = p
                renderersWithId[p.browserPid, default: 0] += 1
            }
            if let c = p.extensionClientId { extMap[p.browserPid, default: [:]][c] = p }
        }

        // users[c] from every frame of every non-discarded helper tab.
        var users: [ProcKey: Set<TabRef>] = [:]
        var tabProcs: [TabRef: Set<ProcKey>] = [:]
        var joinStats: [Int32: (tabs: Int, unmatched: Int)] = [:]
        for t in input where perTabBrowsers.contains(t.browserPid) && !t.discarded {
            let map = clientMap[t.browserPid] ?? [:]
            let ext = extMap[t.browserPid] ?? [:]
            var mine = Set<ProcKey>()
            for f in t.frames where f.processId > 0 {
                if let p = map[f.processId] { mine.insert(p.key); users[p.key, default: []].insert(t.ref) }
            }
            tabProcs[t.ref] = mine
            if let main = t.frames.first(where: { $0.frameId == 0 }) ?? t.frames.first, main.processId > 0,
               ext[main.processId] == nil {                    // an extension page: shared with the extension
                var s = joinStats[t.browserPid] ?? (0, 0)
                s.tabs += 1
                if map[main.processId] == nil { s.unmatched += 1 }
                joinStats[t.browserPid] = s
            }
        }

        // Degraded browsers.
        var degraded: [Int32: String] = [:]
        for b in perTabBrowsers {
            let tabsOfB = input.filter { $0.browserPid == b && !$0.discarded && !$0.frames.isEmpty }
            if (renderersWithId[b] ?? 0) == 0 && !tabsOfB.isEmpty {
                degraded[b] = "Chrome does not report renderer ids (--renderer-client-id), so memory per tab is unavailable"
            } else if let s = joinStats[b], s.tabs > 0,
                      Double(s.unmatched) / Double(s.tabs) > degradedUnmatchedFraction {
                degraded[b] = "\(s.unmatched) of \(s.tabs) tabs could not be matched to a Chrome process, so memory per tab is unavailable"
            }
        }

        // Fair shares, exact: base = fp / n, the first (fp % n) users (sorted) get one extra byte.
        var share: [TabRef: Bytes] = [:]
        var exclusive: [TabRef: Bytes] = [:]
        var procFootprint: [ProcKey: Bytes] = [:]
        let byKey = Dictionary(procs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for p in procs where p.clientId != nil { procFootprint[p.key] = p.footprint }
        for (k, us) in users {
            let fp = byKey[k]?.footprint ?? 0
            let n = Bytes(us.count)
            let base = fp / n, rem = fp % n
            for (i, r) in us.sorted().enumerated() { share[r, default: 0] += base + (Bytes(i) < rem ? 1 : 0) }
            if us.count == 1, let only = us.first { exclusive[only, default: 0] += fp }
        }

        // Tabs.
        var tabs = input
        for i in tabs.indices {
            let r = tabs[i].ref
            guard perTabBrowsers.contains(r.browserPid) else {
                tabs[i].display = nil; tabs[i].exclusive = 0; tabs[i].sharedWith = 0; tabs[i].procs = []
                continue
            }
            if tabs[i].discarded {
                tabs[i].display = 0; tabs[i].exclusive = 0; tabs[i].sharedWith = 0; tabs[i].procs = []
                continue
            }
            let mine = tabProcs[r] ?? []
            tabs[i].procs = mine.sorted()
            tabs[i].exclusive = exclusive[r] ?? 0
            // No frame matched a tab renderer: the memory is unknown, not zero.
            tabs[i].display = degraded[r.browserPid] == nil && !mine.isEmpty ? (share[r] ?? 0) : nil
            let map = clientMap[r.browserPid] ?? [:]
            if let main = tabs[i].frames.first(where: { $0.frameId == 0 }), let p = map[main.processId] {
                tabs[i].sharedWith = max(0, (users[p.key]?.count ?? 1) - 1)
            } else {
                tabs[i].sharedWith = 0
            }
        }

        // Overhead ("Chrome itself") and total.
        var overhead: [ChromeOverheadKind: OverheadStat] = [:]
        func add(_ k: ChromeOverheadKind, _ b: Bytes, count: Int = 1) {
            var s = overhead[k] ?? OverheadStat(count: 0, bytes: 0)
            s.count += count; s.bytes += b
            overhead[k] = s
        }
        var total: Bytes = 0
        for p in procs {
            total += p.footprint
            if let k = p.kind.overheadKind { add(k, p.footprint); continue }
            // A renderer. With per-tab data, a renderer no tab uses is a background page / worker / spare.
            if perTabBrowsers.contains(p.browserPid), users[p.key]?.isEmpty ?? true {
                add(blindBrowsers.contains(p.browserPid) ? .hiddenTabs : .background, p.footprint)
            }
        }
        if let o = otherInstances, o.count > 0 || o.bytes > 0 {
            add(.otherInstances, o.bytes, count: o.count)
            total += o.bytes
        }
        let overheadOut = Dictionary(uniqueKeysWithValues: overhead.map { ($0.key.rawValue, $0.value) })

        let tabSum = tabs.reduce(Bytes(0)) { $0 + ($1.display ?? 0) }
        let ohSum = overheadOut.values.reduce(Bytes(0)) { $0 + $1.bytes }
        let unaccounted = Int64(bitPattern: total &- (tabSum + ohSum))
        var note: String?
        let perTabOn = !perTabBrowsers.isEmpty && degraded.isEmpty
        if perTabOn, total > 0, Double(abs(unaccounted)) > Double(total) * mismatchLogFraction {
            note = "Σ tabs + overhead differs from the Chrome process total by \(ByteFormat.short(Bytes(abs(unaccounted))))"
        }

        let reasons = Set(degraded.values).sorted()
        // freed() must not rely on a degraded browser's join.
        if !degraded.isEmpty {
            users = users.filter { k, _ in byKey[k].map { degraded[$0.browserPid] == nil } ?? true }
        }
        return Result(tabs: tabs, overhead: overheadOut, total: total, procFootprint: procFootprint,
                      procUsers: users, perTabUnavailable: reasons.isEmpty ? nil : reasons.joined(separator: "; "),
                      joinStats: joinStats, unaccounted: unaccounted, mismatchNote: note)
    }
}
