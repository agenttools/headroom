// Wire (helper extension) → ChromeTab / ChromeWindow.

import Foundation
import HeadroomContracts

public enum WireMapping {
    /// Only data: URLs under 8 KB are kept (SPEC §4.2); the app never fetches icons.
    public static let maxFavIconBytes = 8 * 1024

    public static func host(of url: String) -> String {
        guard let u = URL(string: url) else { return "" }
        if let h = u.host(percentEncoded: false), !h.isEmpty { return h }
        return ""
    }

    public static func tab(_ t: Wire.Tab, browserPid: Int32) -> ChromeTab {
        let url = t.url ?? ""
        let frames = (t.frames ?? []).map {
            ChromeFrame(frameId: $0.frameId, parentFrameId: $0.parentFrameId, processId: $0.processId,
                        lifecycle: $0.documentLifecycle ?? "active")
        }
        return ChromeTab(browserPid: browserPid, id: t.id, windowId: t.windowId, index: t.index,
                         title: t.title ?? "", url: url, host: host(of: url), active: t.active,
                         audible: t.audible ?? false, pinned: t.pinned, discarded: t.discarded ?? false,
                         incognito: t.incognito,
                         lastAccessed: t.lastAccessed.map { Date(timeIntervalSince1970: $0 / 1000) },
                         frames: frames)
    }

    /// Merges replies from every connection of one browser (one per Chrome profile). Tab and window ids are
    /// unique per browser, so duplicates (should not happen) keep the first.
    public static func merge(_ replies: [Wire.SnapshotReply], browserPid: Int32) -> (windows: [ChromeWindow], tabs: [ChromeTab]) {
        var tabs: [ChromeTab] = []
        var seenTabs = Set<Int>()
        var windows: [Int: ChromeWindow] = [:]
        var windowOrder: [Int] = []
        for r in replies {
            for w in r.windows where windows[w.id] == nil {
                // Only normal and popup windows hold tabs the user sees; devtools/app windows are kept too,
                // since their tabs are real tabs the extension reported.
                windows[w.id] = ChromeWindow(browserPid: browserPid, id: w.id, focused: w.focused, incognito: w.incognito)
                windowOrder.append(w.id)
            }
            for t in r.tabs where seenTabs.insert(t.id).inserted {
                tabs.append(tab(t, browserPid: browserPid))
            }
        }
        // A tab whose window was not reported still gets a window row.
        for t in tabs where windows[t.windowId] == nil {
            windows[t.windowId] = ChromeWindow(browserPid: browserPid, id: t.windowId, incognito: t.incognito)
            windowOrder.append(t.windowId)
        }
        for t in tabs.sorted(by: { $0.index < $1.index }) { windows[t.windowId]?.tabIds.append(t.id) }
        let ws = windowOrder.compactMap { windows[$0] }.filter { !$0.tabIds.isEmpty }
        return (ws, tabs)
    }
}
