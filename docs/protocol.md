# Headroom native-messaging protocol, v1

Source of truth for the extension (`Extension/sw.js`), the host (`headroom-host`) and the app
(`HeadroomChrome.ChromeBridge`). Swift types: `HeadroomContracts.Wire` (`Sources/HeadroomContracts/Wire.swift`).
SPEC §2 and §4.2 give the reasons; this file gives the rules.

## Transport

```
Chrome extension ──stdio──▶ headroom-host ──Unix socket──▶ Headroom (app or CLI)
```

| Link | Framing |
|---|---|
| extension ↔ host | Chrome native messaging: 4-byte **native-endian** length, then UTF-8 JSON. Max 1 MB host→Chrome. |
| host ↔ app | One JSON object per line (`\n`-terminated), UTF-8. |

- Socket: `~/Library/Application Support/Headroom/run/app.sock` (`HeadroomEnv.socketPath`; moves with
  `HEADROOM_SUPPORT_DIR`). The `run/` directory is mode 0700.
- The **app is the server**; the host is the client. The app checks `getpeereid()` == its own uid on every
  accepted connection. The host checks that `app.sock` is owned by its own uid before connecting.
- One connection per Chrome profile (each profile starts its own host).
- The host writes its own `host` line first, answers `ping` itself, and relays every other message unchanged
  in both directions.
- Receivers ignore unknown fields and unknown `t` values. Every message has `t`. Requests from the app carry
  an integer `req`; the reply carries the same `req`. The app times a request out after 3 s.

## Host behaviour

| Mode | Host when `app.sock` is absent |
|---|---|
| `persistent` (default) | stays alive; `stat()`s the socket every 2 s; connects when it appears |
| `on-demand` | exits at once, so the service worker can go idle |

- The host sends `{"t":"ping"}` to the extension every 20 s (keeps the MV3 worker alive); the extension
  answers `{"t":"pong"}`. Neither is forwarded.
- The host exits on stdin EOF (Chrome closed the port or quit).
- `browserPid` in the host line is the host's `getppid()`: the Chrome browser process. The app uses it to
  identify the **main** browser for Ownership (SPEC §3 step 1).

## Messages

| Direction | Message |
|---|---|
| host→app | `{"t":"host","v":1,"hostPid":123,"browserPid":812,"hostVersion":"1.0.0"}` |
| ext→app | `{"t":"hello","v":1,"ext":"1.0.0","install":"<uuid in storage.local>","incognitoAllowed":false,"mode":"persistent","swStart":<ms>}` (`swStart`, optional: the worker's `performance.timeOrigin`; a new value means the worker restarted) |
| app→ext | `{"t":"snapshot","req":7}` |
| ext→app | `{"t":"snapshot","req":7,"at":<ms>,"windows":[…],"tabs":[…]}` (below) |
| app→ext | `{"t":"close","req":8,"tabs":[{"id":123,"url":"<expected url>"}]}` |
| ext→app | `{"t":"result","req":8,"results":{"123":"done"},"restore":{"123":"<sessions.sessionId>"}}` |
| app→ext | `{"t":"discard","req":9,"tabIds":[123,124]}` → `result` |
| app→ext | `{"t":"activate","req":10,"tabId":123,"windowId":45}` → `result` |
| app→ext | `{"t":"restore","req":11,"items":[{"sessionId":"…","url":"…","windowId":45,"index":3}]}` → `{"t":"result","req":11,"restored":[{"url":"…","newTabId":130,"via":"sessions"}]}` |
| app→ext | `{"t":"setMode","mode":"on-demand"}` and `{"t":"reload"}` (no reply) |
| ext→app | `{"t":"dirty"}` — debounced 300 ms; on `tabs.onCreated`, `onRemoved`, `onUpdated` (status or title), `webNavigation.onCommitted` |
| host↔ext | `{"t":"ping"}` / `{"t":"pong"}` every 20 s, not forwarded |
| ext→app | `{"t":"result","req":N,"error":"<msg>"}`: the extension handler threw. The app treats it as `failed:<msg>` for every tab in request N. |
| probe→ext | `{"t":"probeMark","req":N,"mb":M}` → `result`. Spike S only (`headroom-host --probe`, see `docs/spike-s.md`): the worker holds M MiB so the probe can find its process. The app never sends it. |

### Snapshot payload

```jsonc
{
  "t": "snapshot", "req": 7, "at": 1790786000000,
  "windows": [{ "id": 45, "focused": true, "incognito": false, "type": "normal", "state": "normal" }],
  "tabs": [{
    "id": 123, "windowId": 45, "index": 0, "title": "Inbox", "url": "https://mail.google.com/…",
    "favIconUrl": "data:image/png;base64,…",   // only data: URLs under 8 KB; otherwise omitted
    "active": true, "audible": false, "pinned": true, "discarded": false, "frozen": false,
    "incognito": false, "lastAccessed": 1790785990000,
    "frames": [{ "frameId": 0, "parentFrameId": -1, "processId": 17, "documentLifecycle": "active" }]
  }]
}
```

- `frames` comes from `webNavigation.getAllFrames`; a discarded tab has `[]`.
- `processId` equals the renderer's `--renderer-client-id=N`, which is only unique **per browser pid**.

### Result values

`results` maps a tab id (as a string) to one of:

| Value | Meaning | `Outcome` |
|---|---|---|
| `done` | closed / discarded / activated | `.done` |
| `changedSkipped` | `tabs.get(id).url` ≠ expected url; nothing done | `.changedSkipped` |
| `gone` | tab no longer exists | `.alreadyGone` |
| `failed:beforeunload` | the tab showed "Leave site?" and did not close within 1 s (verified in Chrome for Testing 151) | `.failed("beforeunload")`; offer Jump |
| `failed:<msg>` | Chrome API error | `.failed(msg)` |

A `discard` result may carry `replaced: {"<oldId>": <newId>}` (older Chrome gave a discarded tab a new id; Chrome 151
keeps the id, so it is normally absent). A `restore` result's `restored[].via` is `"sessions"`, `"create"`, or
`"failed"` with an `error` field.

### Close precondition and Undo

1. The extension calls `tabs.get(id)` and compares the URL with the expected one. Mismatch → `changedSkipped`.
2. After `tabs.remove`, it reads `sessions.getRecentlyClosed({maxResults:25})` and matches each entry by url
   and `lastModified` within ±10 s, comparing windowId only when it is non-zero (Chrome 151 reports `windowId: 0`
   for closed tabs). A match goes into `restore` (tab id → `sessionId`) for Undo. Chrome returns at most 25
   entries, so a close of more than 25 tabs has restore ids for the last 25 only; the others reopen with
   `tabs.create` (`via:"create"`, without history).
3. Restore uses `sessions.restore(sessionId)` (keeps history); on failure
   `tabs.create({windowId, index, url, active:false})`, using the front window if the original is gone
   (`via:"create"`, "reopened without history").

### Size limit

The host drops (and logs) an app→extension line longer than 1 MB instead of sending it, because Chrome would close
the port. There is no reply, so the app's 3 s timeout applies.

## Privacy

No host permissions and no content scripts: the extension never reads page content, cookies or history.
The app never fetches anything from the network. Incognito URLs are never written to disk.
