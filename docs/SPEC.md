# Headroom: final design

Headroom is a Dock app for finding and closing Chrome tabs, Claude Code sessions and orphaned dev servers that use a lot of memory.

> This is the design document written before the code. [DECISIONS.md](DECISIONS.md) records later decisions that override it ("Q2", "Q3" and "Q4" below are its items 2, 3 and 4), and some details changed during the build. Where this file and the code disagree, the code is right. The README describes the app as it is.

This design was chosen from several alternatives. It drops features that measurement did not support:
- the "scheduled/headless" status taken from `kind`;
- busy status taken from the JSON field alone;
- ⌥ closing busy sessions without a prompt;
- Select & Close;
- a resident mode by default.

---

## 1. Decisions

| Topic | Decision |
|---|---|
| App | **Headroom**, bundle id `dev.adder.headroom`. Swift 6, **AppKit**. The list is an **`NSOutlineView`**; small SwiftUI views sit inside `NSHostingView` only where needed (strip, sheet, toast, peek). There is one window. **The app quits when the window closes** (see Q3). |
| Build | SwiftPM (verified: 6–9 s, `swift build -c release`). `scripts/build.sh` assembles and signs the `.app` by hand. SwiftPM is chosen over plain `swiftc` so `swift test` can run the fixture tests. |
| Memory figure | `proc_pid_rusage(RUSAGE_INFO_V6).ri_phys_footprint`, the same figure as Activity Monitor's Memory column. RSS appears only in tooltips. The app never starts `ps` or `footprint`. |
| Chrome per-tab memory | Unpacked MV3 extension with a fixed id (`key`) and permissions `tabs`, `webNavigation`, `sessions`, `nativeMessaging`, plus a native-messaging host `headroom-host` that relays over a Unix socket. The join key is `frames[].processId` to `--renderer-client-id=N`, **scoped per browser pid**. |
| Chrome without the extension | JXA through `/usr/bin/osascript`. It lists and closes tabs by id. Memory is shown for the Chrome section total and for the "Chrome itself" rows, and per tab as "—". It is offered on the first-run card **alongside** the extension setup, not hidden. |
| Claude sessions | `~/.claude/sessions/*.json`, checked against the live pid and `procStart` (UTC). Memory = claude plus its ppid tree plus background processes linked by environment. Context comes from transcript tails, tmux or Rex (resolved live; §5, §5.1) and `.git/HEAD`. |
| Leftovers | Process groups whose `CLAUDE_PID` points to a dead session, after strict exclusions. Always confirmed before closing and never undoable. |
| Automation browsers | Chrome instances that are not the user's main profile (headless, or with a non-default `--user-data-dir` or `--remote-debugging-*`), such as an agent-browser instance (pid 85291 in the ownership test fixture). Each belongs to the Claude session that owns it, or becomes a leftover. It is **never** mixed with the real tabs and **never** counted twice. |
| Close flow | Undo-first (see Q2). Items without confirmation reasons close at once and show an Undo toast. The sheet appears only for the triggers in §7. ⌥ skips the sheet **except** for busy sessions and leftovers. |
| Signing | Ad-hoc by default. `scripts/make-signing-cert.sh` (the user runs it once; see Q4) creates "Headroom Local Signing", so the Automation grants for Chrome and Ghostty survive rebuilds. `build.sh` warns when the certificate is missing. |
| Safety for builders | `HEADROOM_DRY_RUN=1` is the default in every dev and test run. Every signal and close is appended to `actions.jsonl`. There is a hard signal allowlist. SIGKILL is never sent automatically. |
| Project location | One repository. Build output goes to `build/` (the assembled app) and `.build/` (SwiftPM). |

---

## 2. Architecture

```
┌────────── Google Chrome (the user's profile) ──────────┐
│ Headroom helper extension (MV3 SW, ~150 lines JS)      │
│ tabs · webNavigation · sessions · nativeMessaging      │
└───────────────┬────────────────────────────────────────┘
                │ stdio: 4-byte native-endian length + JSON (Chrome starts host)
┌───────────────▼─────────────────┐
│ headroom-host (Foundation only, │  one per profile, ~2–4 MB
│ Contents/Helpers/)              │  sends ping to ext every 20 s
│ CLIENT of app.sock; stat() for  │  persistent mode: waits for app.sock (poll 2 s)
│ it every 2 s while absent       │  on-demand mode: exits if app.sock is absent
└───────────────▲─────────────────┘
                │ newline-delimited JSON over a Unix socket
                │ ~/Library/Application Support/Headroom/run/app.sock  (dir 0700)
┌───────────────┴──────────────────────────────────────────────────────────┐
│ Headroom.app (only while its window is open; unsandboxed; no hardened RT)│
│  actor Collector                                                         │
│   ├ SysKit: proc_listallpids, PROC_PIDTBSDINFO, rusage v6, pidpath,      │
│   │         KERN_PROCARGS2 (argv+env, cached per ProcKey), VNODEPATHINFO,│
│   │         host_statistics64, vm.swapusage, pressure level              │
│   ├ Ownership: assigns every pid to exactly one bucket (§3)              │
│   ├ ClaudeSource: sessions JSON, transcript tails, tmux, Rex, git HEAD   │
│   └ ChromeSource: ChromeBridge (socket server) + Attribution + JXA       │
│  ActionKit: plan → (sheet) → execute → verify → undo log (§7)            │
│  @MainActor UI: NSOutlineView + strip + footer + sheet + toast + peek    │
└──────────────────────────────────────────────────────────────────────────┘
```

**Why the app is the socket server.** An alternative design made the host the server. Here the host is the **client**, for three reasons:
1. The app listens on one socket and accepts one connection per Chrome profile.
2. An "on-demand" mode becomes possible. The host exits at once when the app is not running, so the extension's service worker can go idle. This is the mitigation for the extension's unmeasured memory cost.
3. There are no stale host sockets to clean up.

**Socket security:**
- The `run/` directory is created with mode 0700.
- The app checks `getpeereid()`, which must return the same uid, on every accepted connection.
- The host checks that `app.sock` is owned by its own uid before it connects.

**Helper connection mode** is set in the extension's `chrome.storage.local`, and the app can change it:
- **persistent** (default):
  - The host stays alive for as long as Chrome runs, and its 20 s ping keeps the service worker alive.
  - The host connects to the app within 2 s of the window opening.
- **on-demand:**
  - The extension wakes from `chrome.alarms` every 30 s (the minimum on Chrome 120+) and calls `connectNative`.
  - The host exits if `app.sock` is absent, so the worker can idle.
  - Tabs can take up to 30 s to appear after the window opens. In the meantime the app shows the JXA list if Automation permission is granted, or a "Waiting for Chrome helper…" row if not.
- **Switching rule:** if the helper's extension process on stable Chrome is above 40 MB (measured by Spike S, [spike-s.md](spike-s.md)), on-demand mode is the better default. The footer always shows Headroom's own cost: app + host + helper extension process.

---

## 3. Process ownership (the no-double-count pass)

Each refresh builds one `ProcessTable` and then runs a single `Ownership.assign(table, sessions, hosts, tmuxPanes)`. Every pid ends up in **at most one** bucket. `--selftest` asserts this. Rex needs no extra input: its servers and pane processes are found in the table itself (§5.1), with no rex call.

1. **Chrome browser instances.** A browser is a pid whose `proc_pidpath` is `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` and whose argv has no `--type`.
   - Each browser owns its whole ppid subtree: helpers and crashpad.
   - **Main browser:**
     - its pid equals the `browserPid` from a connected host hello (the host's `getppid()`); or
     - if no host is connected: its argv has no `--headless`, no `--remote-debugging-port` and no `--remote-debugging-pipe`, and its `--user-data-dir` is absent or equals `~/Library/Application Support/Google/Chrome`.
   - **Automation browser:** any other browser instance. It is kept for step 4.
2. **Claude sessions.** A session is live when all of these hold:
   - the pid exists;
   - `proc_pidpath` contains `/claude/versions/`, or argv[0] == `claude`;
   - `pbi_start_tvsec` equals `procStart` within ±2 s. Parse `procStart` as UTC with `en_US_POSIX` `"EEE MMM d HH:mm:ss yyyy"`. On the Mac this design was measured on (24 live sessions), it matched to 0 s for every session. If `procStart` is missing, fall back to `|pbi_start_tvsec − startedAt/1000| ≤ 60`.

   The session owns its ppid descendants, which are its **children**.
3. **Environment-linked processes.** For each pid not yet owned whose environment (`KERN_PROCARGS2`) has `CLAUDE_PID`:
   - **Exclude it** if any of these hold:
     - its path is inside any `.app` bundle;
     - its argv0 is `tmux`, `limactl`, `colima`, `docker`, `ssh-agent`, or starts with `-` (a login shell);
     - its ppid chain to launchd passes through the tmux server, any tmux `pane_pid`, a Rex server, a Rex pane process (§5.1) or a live claude;
     - its `CLAUDE_PID` or `CLAUDE_CODE_SESSION_ID` equals one found in the environment of a tmux process, a tmux pane shell, a Rex server or a Rex pane process. That value was inherited from the terminal, not set by a claude Bash tool, so it still holds after the process is reparented to launchd.
   - Otherwise its **root** is the highest ancestor that is still env-linked and not excluded. The root and its whole ppid subtree form one unit. **An automation browser under that subtree comes with it**, which is how agent-browser's Chrome ends up attached to session 80876 in the ownership test fixture.
   - If `CLAUDE_PID` is a live session, the unit is that session's **background**.
   - If `CLAUDE_PID` is dead, or its start time does not match, the unit is a **leftover**, grouped by (dead CLAUDE_PID, pgid of root). The group's label comes from the root's argv, for example `bun run dev --port 3217`. The session title comes from `closed.jsonl`, or from the dead session's transcript `ai-title` found through `CLAUDE_CODE_SESSION_ID`.
4. **Automation browsers not claimed in step 3** appear as one locked row, "Other Chrome instances", under Chrome itself. It shows the user-data-dir and the flags.
5. **Unregistered claude.** A `/claude/versions/` process with no JSON file becomes its own row. Its cwd comes from `PROC_PIDVNODEPATHINFO`, and it always needs confirmation.
6. **Stale JSON.** A session file that fails the step-2 checks is hidden, counted in the footer and never deleted.

Unit tests replay the `ps.txt` and `psargs.txt` process-list fixtures in `Tests/Fixtures/`:
- The tmux server, pane shells (dead CLAUDE_PID 21630), AeroSpace, SwiftBar, Hammerspoon and limactl must be excluded.
- pgid 7164 (1.2 GB) and pgid 40363 (885 MB) must be found as leftovers.
- The agent-browser subtree must attach to 80876 and must not appear in the Chrome section.

The fixtures have no Rex processes. Synthetic tables in `OwnershipTests` cover Rex: a `CLAUDE_PID` inherited from a Rex server or Rex pane process does not link a process, and a dev server started in a Rex pane stays unowned.

---

## 4. Chrome data collection

### 4.1 Process classification (main browser subtree only)

| argv | Class |
|---|---|
| no `--type` | browser |
| `--type=gpu-process` | GPU |
| `--type=utility` | utility |
| `--type=crashpad-handler` | crashpad |
| `--type=renderer` with `--extension-process` | extension |
| `--type=renderer`, with `--renderer-client-id=N` | renderer N |

- The map is `clientMap[browserPid][N] = (pid, footprint)`. Client ids are small integers **per browser**, so they are always scoped by `browserPid`.
- argv is read once per `ProcKey(pid, startSec)` and cached.

### 4.2 Wire protocol v1

- **Extension ↔ host:** Chrome's native-messaging frame (4-byte native-endian length + JSON, with a 1 MB limit towards Chrome).
- **Host ↔ app:** one JSON object per line.
- The host handles `ping`/`pong` itself. It adds its own `host` line first and relays everything else unchanged.

| Direction | Message |
|---|---|
| host→app | `{"t":"host","v":1,"hostPid":…,"browserPid":<getppid()>,"hostVersion":"1.0.0"}` |
| ext→app | `{"t":"hello","v":1,"ext":"1.0.0","install":"<uuid in storage.local>","incognitoAllowed":bool,"mode":"persistent"\|"on-demand"}` |
| app→ext | `{"t":"snapshot","req":7}` |
| ext→app | `{"t":"snapshot","req":7,"at":ms,"windows":[{id,focused,incognito,type,state}],"tabs":[{id,windowId,index,title,url,favIconUrl?,active,audible,pinned,discarded,frozen,incognito,lastAccessed,frames:[{frameId,parentFrameId,processId,documentLifecycle}]}]}` |
| app→ext | `{"t":"close","req":8,"tabs":[{"id":123,"url":"<expected>"}]}` |
| ext→app | `{"t":"result","req":8,"results":{"123":"done"\|"changedSkipped"\|"gone"\|"failed:<msg>"},"restore":{"123":"<sessions.sessionId>"}}` |
| app→ext | `{"t":"discard","req":9,"tabIds":[…]}` → result |
| app→ext | `{"t":"activate","req":10,"tabId":…,"windowId":…}` → result |
| app→ext | `{"t":"restore","req":11,"items":[{"sessionId"?,"url","windowId","index"}]}` → `{"restored":[{url,newTabId,via:"sessions"\|"create"}]}` |
| app→ext | `{"t":"setMode","mode":"on-demand"}` / `{"t":"reload"}` |
| ext→app | `{"t":"dirty"}`, debounced 300 ms, sent on `tabs.onCreated`, `onRemoved`, `onUpdated` (status or title), `webNavigation.onCommitted` |
| host↔ext | `{"t":"ping"}`/`{"t":"pong"}` every 20 s. These are not forwarded. |

- `favIconUrl` is forwarded only when it is a `data:` URL under 8 KB. Other tabs get a monochrome letter tile. The app never fetches anything from the network.
- **Close precondition:**
  - The extension calls `tabs.get(id)` and compares the URL with the expected URL. On a mismatch it returns `changedSkipped`.
  - After `tabs.remove`, it reads `sessions.getRecentlyClosed({maxResults:25})` and matches each entry by url, windowId and `lastModified` within ±10 s, which gives a `sessionId` for Undo.

### 4.3 Extension (`Extension/`)

```json
{ "manifest_version": 3, "name": "Headroom helper", "version": "1.0.0",
  "key": "<committed base64 DER public key>",
  "permissions": ["tabs","webNavigation","sessions","nativeMessaging","alarms","storage"],
  "background": { "service_worker": "sw.js" }, "incognito": "spanning",
  "minimum_chrome_version": "120" }
```

- There are no host permissions and no content scripts, so the extension cannot read page content.
- `sw.js` calls `connect()` at top level, on `onStartup` and on `onInstalled`.
  - On disconnect it retries with backoff (1, 2, 4 … 60 s) in persistent mode, or waits for the next alarm in on-demand mode.
  - `chrome.alarms` fires every 30 s. In persistent mode it is a backstop; in on-demand mode it drives the connection.
- **Snapshot:** `tabs.query({})`, `windows.getAll()`, then `Promise.all(tabs.map(t => webNavigation.getAllFrames({tabId:t.id})))`. A discarded tab returns `[]`.

### 4.4 Attribution (a pure function; unit tested)

```
frames(tab)   = frames with processId > 0, ALL lifecycles (active, cached, prerender, pending)
                 // bfcache and prerender frames die with the tab
users[c]      = { tabId | tab has any frame in client c }          (c scoped to browserPid)
fp[c]         = footprint of clientMap[browserPid][c]
display(tab)  = Σ_{c ∈ procs(tab)} fp[c] / |users[c]|              // fair share; tab rows sum exactly
exclusive(tab)= Σ fp[c] where users[c] == {tab}
sharedWith    = |users[mainFrameProc]| − 1   → "≈" and a ⛓×N chip when > 0
freed(S)      = Σ fp[c] where users[c] ≠ ∅ and users[c] ⊆ S       // window rows expand to their tabs
discarded     → display 0, state "sleeping"
Chrome itself = browser + GPU + utility + crashpad + extension renderers + renderers with users = ∅
                + "Other Chrome instances" (automation browsers no session owns)
Section total = Σ over all main-browser pids (never a sum of tab values)
```

**Degraded mode** (`perTabUnavailable(reason)`) is set when the extension is connected and either:
- no renderer of that browser has `--renderer-client-id`, or
- more than 20% of the tabs' processIds find no match.

In degraded mode the Memory column shows "—", a banner explains why, and closing still works. A debug log line is written when `Σ tabs + overhead` differs from the process total by more than 5%.

### 4.5 JXA fallback

- **List** (one call, `Process`, 3 s timeout, off the main thread):
  ```js
  const c=Application("Google Chrome"); const w=c.windows;
  JSON.stringify({wid:w.id(),mode:w.mode(),idx:w.index(),active:w.activeTab.id(),ids:w.tabs.id(),titles:w.tabs.title(),urls:w.tabs.url()})
  ```
  The bulk form was measured at 0.1 s. `mode` (incognito) is confirmed in `chrome.sdef`.
- **Close:** one script per batch. It checks each tab's URL first, then runs `close (tab id T of window id W)`, always by id and never by index.
- **Jump:** set `active tab index`, set the window's index to 1, then `activate`.
- **Permission:**
  - The app checks with `AEDeterminePermissionToAutomateTarget(askUserIfNeeded:false)` and never prompts on its own.
  - The prompt is requested only from the first-run card's [Allow…] button.
  - If access is denied (-1743), the card links to `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`.

---

## 5. Claude Code data collection

- **Session registry:** watch `~/.claude/sessions/` with `DispatchSource`, and rescan every 10 s as a safety net. Decode leniently: every field is optional. Keep `pid, sessionId, cwd, startedAt, procStart, version, kind, entrypoint, tmux, name, nameSource, status, statusUpdatedAt, updatedAt, bridgeSessionId`.
- **Transcript tail:**
  - Path: `~/.claude/projects/<cwd with every non-alphanumeric → "-">/<sessionId>.jsonl`. If that is missing, glob `*/<sessionId>.jsonl`. If there is still no file, set `hasTranscript=false`.
  - Read from `size − 64 KB`, drop the first partial line, and scan backwards. Prefilter the first 200 bytes of each line for `"type":"user"`, `assistant`, `ai-title` or `last-prompt`. If nothing is found, grow the window ×4, up to 8 MB.
  - Take:
    - `lastActivity`: the timestamp of the last user or assistant entry;
    - `aiTitle`;
    - `lastPrompt`;
    - the last assistant text (300 characters);
    - the `system/away_summary` content.
  - Re-read only when the file size changes. **Never** use mtime or the last line.
- **Title:** `name` if `nameSource=="user"`, otherwise `aiTitle`, otherwise tmux `pane_title` without "✳ ", otherwise `name`. A session in Rex has no pane title (reading one would cost a rex call per pane), so it skips that step.
- **Where:** `tmuxSession:win.pane › repo ⎇ worktree`, or `rex <session>:<tab>.<pane> › repo ⎇ worktree` for a session in Rex (§5.1).
  - Branch: read `.git/HEAD`, following a worktree's `gitdir:` file and walking up to the repo root. Re-read every 30 s.
  - The worktree name comes from `/.claude/worktrees/<w>`.
- **tmux** (`/opt/homebrew/bin/tmux`, default socket; one call each per tick):
  - `list-panes -a -F '#{pane_id}\t#{pane_pid}\t#{pane_active}\t#{window_active}\t#{session_attached}\t#{session_name}\t#{window_index}\t#{pane_index}\t#{window_name}\t#{pane_title}\t#{pane_current_command}'`
  - `list-clients -F '#{client_activity}\t#{client_tty}\t#{client_session}'`
  - A session matches the pane whose `pane_pid` equals claude's ppid. The JSON `tmux` field is stale except for its `%pane` id, which is used only as a hint.
  - `visible` = pane_active, window_active and session_attached > 0.
  - `current` = visible in the session of the client with the highest `client_activity`.
  - A claude whose nearest multiplexer is a Rex server gets no tmux pane, even when tmux runs further up its ppid chain (§5.1).
- **Busy (combined evidence, because the JSON status alone is unreliable):**
  - busy if **any** of these hold:
    - `status` ∉ {`idle`};
    - a `caffeinate` child exists;
    - claude plus its children averaged more than 5% CPU over the last 3 samples.
  - An unknown `status` counts as busy.
  - The row shows `● busy 12m`, where the age is now − `statusUpdatedAt` (or − first busy observation).
- **Idle age** = now − max(`statusUpdatedAt`, `lastActivity`). It is used only when the session is not busy.
- **Memory** = claude footprint + children + background (§3). The background part is shown as a badge, `+885 MB bg`, and includes automation browsers.
- **Flags** (context only):
  - Remote Control (`bridgeSessionId` set): ⤳ glyph.
  - Git dirty/ahead: computed on Peek only, with `git status --porcelain=v1 -uno` and `git rev-list --count @{u}..HEAD`, a 2 s timeout, and at most 4 at once.
  - **Not in tmux or Rex.**
  - **cwd missing on disk.**

### 5.1 Rex

Rex is a second terminal multiplexer. Headroom supports it to the same depth as tmux: location, visibility, Peek, Jump and Undo. tmux behaviour is unchanged. Rex support was built on 2026-11-19 against a Rex 0.1.0-preview.20 server (API revision 16). Against a real server only the read-only calls were run (`selftest claude`); the mutating calls of Jump and Undo were tested against a fake `rex` only (§10, §11). Parsing is lenient and no minimum revision is enforced; `headroom selftest claude` prints the server's version and revision.

In Rex terms, a **session** holds **windows** (tabs), and a window holds **blocks** (panes). A window draws its blocks in layers: the first layer is tiled and fills the window, later layers float and can be minimized, and a zoomed block is drawn over the whole window.

- **Binary and server:**
  - The binary is `HEADROOM_REX`, else `~/.local/bin/rex`. Only when `HOME` is the account's own home (from the user database, not `$HOME`), the CLI inside `/Applications/Rex.app` or `/Applications/Rex Beta.app` is also tried. A GUI app's `PATH` lacks `~/.local/bin`, so the path is explicit.
  - The server is rex's own personal server. `HEADROOM_REX_SERVER=unix:///<absolute path>` adds `-S <address>` to every call (tests use a private server). Any other form makes every rex call refuse.
  - Every call is `rex --autostart=false [-S <address>] --timeout <n>s …`, so a call never starts a server. Every `REX_*` variable is removed from the child's environment, so rex never defaults to the server, session or pane that Headroom itself runs in. `rex server …` is refused unless `HEADROOM_REX_SERVER` is set.
- **Which multiplexer a claude runs in.** This is decided from the process table, with no rex call:
  - A **Rex server** is an executable named `rex` whose argv contains `server run`. When its argv cannot be read, a path that ends in `/Rex Server.app/Contents/MacOS/rex` counts. `rex server logs --follow`, which Rex.app runs, is not a server.
  - A block's process chain is: Rex server → `/usr/bin/login` (owned by root) → `-zsh` → claude. `scan()` leaves the root-owned `login` out, so `SysKit.parentPid` reads its parent with `PROC_PIDT_SHORTBSDINFO`, which works across users.
  - A **Rex pane process** (the counterpart of a tmux `pane_pid`) is a block's first process: the shell under `login`, or the command itself for a `rex run` block.
  - Headroom walks up the ppid chain from the claude. **The first boundary met wins:** a tmux `pane_pid` or a tmux process means tmux; a Rex server means Rex. So tmux inside a Rex pane is tmux, and tmux attribution is unchanged. A chain that reaches launchd, loops, or runs longer than 64 steps means neither.
- **Which pane.** It comes from the claude's own `REX_BLOCK` and `REX_SESSION` environment variables, which the env filter keeps. They are trusted only when the walk above reached a Rex server first, because daemons and nested terminals inherit them.
- **Discovery.** Rex is called only when at least one claude runs in Rex:
  - `rex ls --json`, then one `rex session inspect <id> --json` per session;
  - at most 8 calls at a time: the sessions that hold a claude (their `REX_SESSION`) first, then the others, 64 in all (a session that holds a claude is never left out);
  - a 2 s timeout per call, and a 3 s deadline for the whole pass, after which the remaining calls are cancelled.
- **Location label:** `<session>:<tab>.<pane>`, for example `foundry:2.1`. Both numbers are 1-based. The tab is the window's position in the session (Rex's own numbering, as in `rex focus 2`). The pane is the block's position across the window's layers, back to front, in layout order. A session without a label shows as `…` and the last 6 characters of its id. The Where column and the CLI's table show `rex foundry:2.1`; `list --json` has `"rex": "foundry:2.1"`.
- **visible** = all of these hold:
  - a client that may be showing the session is attached to it, in any connection state (a lost client still counts while Rex keeps it, about 60 s). Only clients of kind `cli` or `agent` are left out: an app client counts, with or without a `client_id`, and so does a client of kind `other`, of a kind Headroom does not know, or with no kind;
  - the block's tab is the session's `active_window_id`. When `active_window_id` is absent, null, or names no tab of the session, every tab counts as active;
  - the block is drawn: it is not in a minimized layer, and it floats, or nothing in the window is zoomed, or it is the zoomed block. A layer kind that Headroom does not know counts as floating.
- **current:** Rex has none. Clients have no activity time, and no read-only call reports which session the app is showing. So every drawn block in the active tab of every attached session counts as visible. This adds confirmations; it never removes one.
- **Unknown means protected.** A claude that is in Rex but whose block Headroom cannot place gets the location `<session>:?` and counts as **visible**. This happens when discovery failed or timed out, or when its block belongs to a second Rex server (a private or test server). Closing it asks first, and `suggest` skips it. In the same way, viewer state that Headroom cannot read (an unknown active tab, a client of an unknown kind) counts as visible, never as hidden.
- **A claude in Rex without a usable `REX_BLOCK`** (or with a `REX_BLOCK` that discovery did not find and no `REX_SESSION`) gets no Rex location. It counts as "not in tmux or Rex" (closing it asks first), Undo treats it as a session that ran in neither (§7.7), and `selftest claude` fails and lists its pid.
- A session has a tmux location or a Rex location, never both.
- **Known gap:** Rex.app can have several windows, and a tab can be torn off into its own window. Such a window may show a tab other than the session's `active_window_id`, and Headroom would then call a pane that is on screen "not visible". Checking this needs a mutating Rex action, so it is not verified (§10).

### 5.2 Docker (read-only)

Headroom shows what Docker costs, and changes nothing in it: no container is stopped, started or removed, and
nothing is pruned. Docker rows have no `ItemID`, so they cannot be selected, closed or undone.

- **Source.** The Docker Engine API on the engine's unix socket, with HTTP/1.0 `GET` requests only. Headroom does
  not use the `docker` CLI (an app opened from Finder has no `PATH`). The socket is found the way the CLI finds it:
  1. `HEADROOM_DOCKER_SOCKET=<path>` (a test seam and an override; `off` turns Docker off).
  2. `DOCKER_HOST=unix://<path>`. A `tcp://` or `ssh://` engine is not on this Mac and is ignored.
  3. The current context: `DOCKER_CONTEXT`, else `currentContext` in `~/.docker/config.json`, resolved through
     `~/.docker/contexts/meta/*/meta.json`.
  4. The first socket that exists: colima, Docker Desktop, OrbStack, Rancher Desktop, `/var/run/docker.sock`.
- **Containers.** `/containers/json` (running containers) and `/info` (the VM's memory and CPUs, the stopped
  count), then one `/containers/<id>/stats?stream=false&one-shot=true` per container, 8 at a time. Memory is
  cgroup usage minus inactive file cache, the number `docker stats` shows. CPU% is computed from two reads.
- **The VM on this Mac.** Container memory is memory inside the VM. What the Mac pays is the footprint of the
  VM's own processes, and the two differ: the VM also holds its kernel and file cache, and it does not always
  give memory back to macOS when a container stops. Headroom finds the VM's processes in the process table:
  - colima and lima: the Virtualization.framework VM process that has the same responsible process as the Lima
    host agent (`ha.pid`) and started just after it, or a `qemu-system-*` child of the host agent. When macOS
    does not report a responsible process, a lone VM process is taken; with several, none is.
  - Docker Desktop and OrbStack: their VM processes inside the app bundle.
  - Otherwise the VM is not identified, and the section's number is the sum of the containers.
- **Disk.** `/system/df?type=image|container|volume|build-cache`, read at the same time. This takes tens of
  seconds on a large store, so it runs in the background at most every 15 minutes, is saved in
  `<support>/docker-disk.json`, and is shown with its age. Sizes are decimal, as `docker system df` prints them.
- **UI.** A `DOCKER` section after `LEFTOVERS`, in the `All` scope, while the engine answers:
  - The section's number is the VM's footprint. Its text names the runtime, the running and stopped counts, and
    the containers' sum against the VM's memory.
  - Compose projects are group rows with their containers below; other containers stand beside them. A row
    shows the service or container name, the image, Docker's status text and the memory. The CPU column works.
  - A last line gives disk use and what is reclaimable.
  - The memory strip gets a `Docker` segment (the VM's footprint), taken out of `Other`.
  - Filter words match the name, image, compose project and runtime. `is:container` (or `is:docker`) shows
    only this section.
- **Refresh.** A snapshot never waits for Docker: it uses the last background read. Containers are read every
  5 s while the window is key and every 15 s while it is visible. The CLI reads once before its snapshot.

---

## 6. UI

### 6.1 Main window (about 980×660, minimum 680×440; frame, columns, sort, grouping, scope, filter and collapsed state all persist)

```
╭────────────────────────────────────────────────────────────────────────────────────────────────╮
│ ● ● ●  Headroom    ⟨ All │ Chrome │ Claude ⟩   Select ▾   ⌕ idle>2h !busy        [ Close 5 · ≈3.4 GB ] │
├────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 39.8 of 48 GB used  ● Normal   Swap 3.0/4.0 GB   Compressed 6.1 GB            ⓘ  updated 2s ago │
│ ████Chrome████▨▨▨▓▓▓Claude▓▓▓▨▨▒Leftovers▒░░░░░░Other apps░░░░░░░ System ····Free····             │
│ ■ Chrome 3.9  ■ Claude 7.1  ■ Leftovers 2.2  ▨ selection frees ≈3.4  ■ Other 17.2  □ Free 8.2    │
├────────────────────────────────────────────────────────────────────────────────────────────────┤
│    Name                                 Where                         State          Memory ▼   │
│ ▾ CHROME  7 tabs · 3 windows · helper connected                                     3.94 GB     │
│   ▾ Window 1 — Oakfield onboarding (front) · 4 tabs                                 1.71 GB     │
│▌     F Oakfield onboarding – Figma      figma.com                  active           1.02 GB ██  │
│▌     Y Swift concurrency deep dive      youtube.com                ♪ audible         412 MB █   │
│     ┌L ENG-412 Ledger sync – Linear     linear.app                 ⛓ ×2           ≈ 140 MB ▌   │
│     └L My issues – Linear               linear.app                 ⛓ ×2           ≈ 140 MB ▌   │
│   ▸ Window 2 — Inbox · 2 tabs                                                        220 MB     │
│   ▸ Window 3 — Incognito · 1 tab                                                      72 MB     │
│   ▸ 🔒 Chrome itself — browser · GPU · utility · 7 extensions · 3 background        1.94 GB     │
│ ▾ CLAUDE CODE  22 sessions · 5 busy                                                 8.4 GB      │
│   ▸ ⌗ clip generation  +1.3 GB bg       hub:3.1 › learning         ● busy 11m       1.83 GB ██▋ │
│      ⌗ workflow ideas for ops           quote-composer:2.0 ⎇ jiggly ● busy 2m        480 MB █   │
│▌     ⌗ map directions                   hub:5.0 › work               idle 30h        403 MB ▊   │
│▌     ⌗ mutable-sprouting-bird        ⤳  misc:158.0 › hammer          idle 2d         380 MB ▊   │
│▌     ⌗ weekly update skill  +12 MB bg ◉ misc:7.0 › learning          idle 3d         333 MB ▋   │
│      ⌗ ram  🔒 launched Headroom        hub:1.0 › ~                  ● busy 1m        356 MB ▋   │
│      …                                                                                          │
│ ▾ LEFTOVERS  from sessions that already ended · 3 groups                            2.24 GB     │
│      ⚙ bun run dev --port 3217          harbour-tours · "tour landing" · pgid 7164   1.20 GB ██  │
│      ⚙ doppler run … next dev           compass ⎇ bubbly-discovering-clock · 40363   885 MB █▊  │
│      ⚙ next-server + bun start          monthly-budget-tool-wt · 2 groups            156 MB ▎   │
├────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 5 selected — 2 tabs, 3 sessions · 1 needs a look (audible) · frees ≈3.4 GB    ⌫ Close ↩ Jump ␣ Peek │
│ Headroom 31 MB (+ helper 24 MB in Chrome)                                                        │
╰────────────────────────────────────────────────────────────────────────────────────────────────╯
```

- Expanding `clip generation` shows its children and background, including `⌬ Automation browser (agent-browser, headless) 1.28 GB`.
- The section rows (CHROME, CLAUDE CODE, LEFTOVERS) are floating **group rows and cannot be selected**. Window rows can be selected and mean "all their tabs".
- **Memory column:**
  - `684 MB` below 1 GB and `1.24 GB` from 1 GB up; monospaced digits, right-aligned.
  - A 48 px bar scaled to the largest visible row: grey under 300 MB, amber from 300 MB to 1 GB, red-orange above 1 GB. The number is always shown.
- **Hidden columns you can turn on:** Age, PID, RSS, CPU%, Last active.
- **Glyphs:**

  | Glyph | Meaning |
  |---|---|
  | 🔒 | locked |
  | ◉ | visible or current tmux pane, or visible Rex pane (§5.1) |
  | ● | busy (soft pulse, paused when occluded) |
  | ⤳ | Remote Control |
  | ⛓×N | shared renderer; a gutter bracket joins the siblings |

  All glyphs are SF Symbols in the app.
- **Strip:**
  - `host_statistics64` with 16 KB pages: used = app memory (internal − purgeable) + wired + compressed.
  - `vm.swapusage`, `kern.memorystatus_vm_pressure_level`, plus `DispatchSource.makeMemoryPressureSource`.
  - The selection's "frees" figure is drawn as a hatched overlay inside the Chrome, Claude and Leftovers segments.
- **ⓘ popover text:** "Memory is each process's footprint, the same as Activity Monitor's Memory column. It includes compressed and swapped memory and excludes shared read-only code. 'Frees ≈' counts only processes that would exit completely. After closing, Headroom shows the measured drop."
- **Grouping:**
  - Chrome: Window (default) or None.
  - Claude: None (default) or tmux session. With Rex support this menu item reads "tmux or Rex Session": it also groups sessions in Rex, by Rex session ("Rex: foundry", keyed by the Rex session id because labels need not be unique). Sessions in neither go into "Not in tmux or Rex", listed last.
  - Site and Process grouping for Chrome come in v1.1.
- **Empty and error states** appear inline in their section and are never modal:
  - Chrome not running;
  - helper not set up (the card in §8);
  - helper disconnected (the data from 40 s ago is kept and the strip freshness turns amber);
  - per-tab memory unavailable;
  - no sessions;
  - filter has no matches, with a Clear button.

### 6.2 Peek (Space; the popover follows ↑/↓)

- **Tab:**
  - full URL, window and index, `lastAccessed`;
  - a process table: pid, clientId, role (main, iframe or shared), lifecycle, footprint, and the other tabs using it.
- **Session:**
  - sessionId, cwd (flagged if missing), branch plus git dirty/ahead, started time, idle-since or busy-since, version, Remote Control;
  - last prompt, last assistant line, away summary;
  - the child and background tree with footprints;
  - a read-only `tmux capture-pane -p -t %ID -S -15` in a monospaced box. For a session in Rex: the place (`Rex foundry:2.1 · <tab label>`, plus "(visible)") and a read-only `rex capture -s <session> -b <block> --trim`, of which Headroom keeps the last 60 lines (Rex has no line limit; nothing is shown when the output reaches Headroom's 8 MB cap, because the tail would be wrong);
  - the resume command `cd '<cwd>' && claude --resume <sid>`.
- **Leftover:**
  - the process tree with argv and cwd;
  - listening ports from `lsof -nP -iTCP -sTCP:LISTEN -a -p <pids>`, run only when Peek opens;
  - the dead session's title and resume command.

### 6.3 Toast

`✓ Closed 2 tabs, 3 sessions · freeing…  Undo ⌘Z`

- After two refreshes, "freeing…" becomes `3.1 GB freed (measured)`, which is the drop in section footprints.
- The toast lasts 8 s and pauses on hover.
- Extra lines appear only when relevant:
  - "1 tab changed since you selected it — skipped"
  - "1 tab asked to stay open [Jump]"
  - "1 session didn't quit [Force Quit]"
  - "Leftovers stopped (not undoable)"

---

## 7. Interactions and safety

### 7.1 Selection (native `NSOutlineView`, `allowsMultipleSelection`, type-select)

| Input | Effect |
|---|---|
| Click | Select this row only and set the anchor |
| ⌘-click | Toggle the row and move the anchor to it |
| ⇧-click | Select the range from the anchor, keeping earlier ⌘-picks |
| ↑/↓ | Move the selection |
| ⇧↑/⇧↓ | Extend or shrink from the anchor |
| ⌥↑/⌥↓ | Jump to the first or last row |
| →/← and ⌥→ | Expand or collapse; ⌥→ expands recursively |
| ⌘A | Select all **visible** rows (respects the filter and scope) |
| Esc, or a click on empty space | Deselect |

- **Selection is keyed by `ItemID`**, so it survives refreshes. A row whose object disappears fades out of the selection.
- **Right-click on a selected row** acts on the whole selection. **On an unselected row** it acts on that row only (`clickedRow` focus ring), as in Finder.
- **Locked rows** can be selected for Peek. Close skips them, and the footer says "2 selected rows can't be closed".
- **Sort freeze:** while the pointer is over the list or anything is selected, row order does not change and only the numbers and bars tween (150 ms).
  - A chip, "↕ Order out of date", appears in the Memory header.
  - Rows reorder 1 s after the pointer leaves with nothing selected, when the chip is clicked, or on ⌘R.

### 7.2 Keys and actions

| Keys | Action |
|---|---|
| ⌫ / ⌘⌫ / toolbar "Close N · ≈X" | Close. The sheet appears only if something has a confirm reason (§7.3). |
| ⌥⌫ (button reads "Close Now") | Skips the sheet, **except** when the selection has a busy session, a leftover or an unregistered claude. For those the sheet always appears, with a line explaining why. |
| ⌃⌫ / context "Sleep tab" | `tabs.discard` (extension only). Frees an unshared renderer and keeps the tab. The active tab is skipped with a note. |
| ↩ / double-click | Jump (§7.6) |
| Space | Peek |
| ⌘C | Copy URLs, or `cd '<cwd>' && claude --resume <sid>` lines, or the leftover argv and cwd |
| ⌘⇧R / ⌘O | Reveal cwd in Finder / open the transcript |
| ⌘F | Filter (§7.5) |
| ⌘R | Refresh now |
| ⌘Z / ⇧⌘Z | Undo or redo the last close batch |
| ⌘Y | Recently Closed |
| ⌘1/2/3 | Scope All / Chrome / Claude (Claude includes Leftovers) |

⌘W closes Headroom's own window and never closes an item.

**Select ▾ menu** (these items only select; there is no Select & Close):
- **Idle sessions older than 30m / 1h / 2h / 6h / 1d**, with a live count and GB. These rules exclude busy, on-screen (visible or current tmux pane, visible or unplaced Rex pane), not-in-tmux-or-Rex, no-transcript, cwd-missing and background-owning sessions, and the launcher.
- Sessions in tmux session ▸ …
- Sessions in Rex session ▸ … (only when a session runs in Rex; each item selects by the Rex session id, and two Rex sessions with the same label are told apart by the end of their ids)
- Tabs over 500 MB
- Sessions over 500 MB
- Duplicate tabs (keeps the one with the most recent `lastAccessed`)
- Tabs on the same site as the selection (⌘⇧S)
- Tabs in background windows
- All leftovers (this selects them for review; closing them still shows the sheet)

### 7.3 Protection levels (computed by ActionKit, shown by the UI)

**Locked (never closed):**
- Chrome itself and all of its sub-rows;
- "Other Chrome instances";
- the session that launched Headroom (`getenv("CLAUDE_PID")` or an ancestor-pid match; only when Headroom was launched from a terminal);
- any row whose pid or start time fails revalidation;
- child rows that are tool shells.

**Confirm** (the sheet names each item and its reason):

| Kind | Reasons |
|---|---|
| Sessions | busy (combined evidence) or unknown status; last activity less than 10 min ago; visible or current tmux pane, or visible Rex pane (a Rex pane Headroom cannot place counts as visible, §5.1); not in tmux or Rex (Undo cannot put it back where it ran); has background processes (checkbox, see below); no transcript yet ("nothing to resume, closing discards it"); cwd missing on disk; unregistered claude |
| Tabs | audible; pinned; the selection empties a window with more than 5 tabs; the selection closes every normal window |
| Leftovers | always (they cannot be undone) |
| Any | more than 15 items |

**Context only (shown in the sheet and Peek, never a reason on its own):**
- Remote Control (5 of 24 sessions had it on the Mac this design was measured on, so making it a trigger would make the sheet appear too often);
- git dirty/ahead;
- incognito (the toast notes "not restorable" if the extension is not allowed in incognito).

**Sheet layout:**
- Title: "Close 5 items and free about 3.4 GB?"
- Items grouped by kind.
- Checkbox "☑ Also stop 1 background process it started (`bun run dev --port 3217`, 885 MB)", ticked by default. Each command and pid is listed.
- With busy sessions, the buttons are `[Cancel] [Close All 6] [[Skip Busy — Close 5]]`, and the safe option is the default for Return. Otherwise the buttons are `[Cancel] [[Close N]]`.

### 7.4 Execution (the `CloseCoordinator` in ActionKit)

**Signal allowlist**, enforced in `Signaller`, with no exceptions. A signal is sent only to:
- (a) a live, revalidated claude session pid;
- (b) a pgid or pid recorded as that session's background, or as a leftover group, that passes the §3 exclusions **again**, contains no live claude, no tmux server and no `pane_pid`/pane pgid, contains no Rex server or Rex pane process, is not a Rex pane's process group, does not run under a Rex server or Rex pane process (§5.1; found from the live process table, so this holds even when Rex discovery fails), and whose members still have their recorded `startSec`;
- (c) an automation browser pid owned by (a) or (b) (Chrome process, `--headless` or `--remote-debugging-*`, non-default `--user-data-dir`, not a host's `browserPid`). Only SIGTERM is sent, to the browser pid only.

**Never** signal:
- pid ≤ 1;
- Headroom itself or its ancestors;
- the main Chrome;
- any other `.app` process.

With `HEADROOM_DRY_RUN=1`, every call logs and returns `.dryRun`.

**Steps:**
1. **Plan:** expand window rows, de-duplicate, drop locked rows, and compute reasons and the `freed()` estimate.
2. **Tabs:** one `close` per browser, with the expected URLs. Fallback: JXA with the same URL check. After 1 s, re-snapshot. Tabs still present are reported as "asked to stay open" with [Jump].
3. **Sessions:**
   - Revalidate (pid, `procStart`, `/claude/versions/` path).
   - Record the tree and background units with `ProcKey`s.
   - Append the intent to `actions.jsonl`.
   - Right before the SIGTERM, check each session again on fresh state (tmux and Rex read anew, never from the refresh cache). A session that became busy, visible or recently active since the plan is skipped as `changedSkipped`. A Rex pane that can no longer be placed counts as visible.
   - `kill(pid, SIGTERM)` for all sessions in parallel.
   - Poll every 100 ms for up to 5 s. Sessions still alive get **[Force Quit]** in the toast. SIGKILL is never sent automatically.
   - Once a session has exited, if the box is ticked, send SIGTERM to each surviving recorded background unit (`kill(-pgid)`, or the pid for automation browsers).
   - Survivors after 2 s are listed in the toast with [Force Quit].
4. **Leftovers:** revalidate the members' `startSec` immediately before `kill(-pgid, SIGTERM)`. Survivors after 2 s are offered Force Quit.
5. **Log:** one `closed.jsonl` line per item (incognito URLs are never written), one `actions.jsonl` line per signal or close `{ts, kind, pid, startSec, pgid, signal, reason, result}`, and an entry on NSUndoManager.

### 7.5 Filter (⌘F)

- Plain words match title, URL, name, cwd, branch, tmux session, and Rex session and tab label.
- Tokens:

  | Token | Matches |
  |---|---|
  | `>500mb`, `<100mb` | memory above or below the size |
  | `idle>2h` | idle longer than the duration |
  | `busy`, `!busy` | busy or not busy |
  | `is:tab`, `is:session`, `is:leftover`, `is:container` | row kind (`is:docker` = `is:container`; Docker rows are read-only, §5.2) |
  | `site:<host>` | tabs on that host |
  | `tmux:<session>` | sessions in that tmux session |
  | `rex:<session>` | sessions in that Rex session (its label; a prefix matches) |
  | `bg` | sessions with background processes |
  | `shared` | tabs sharing a renderer |
  | `sleeping` | discarded tabs |

- Tokens are ANDed, and `!` negates a token.
- The fast sweep is `idle>2h !busy`, then ⌘A, then ⌫. The sheet still appears for protected rows.

### 7.6 Jump

- **Tab:** extension `activate` (`tabs.update` active + `windows.update` focused), then `NSRunningApplication` activates Chrome. Fallback: JXA.
- **Session in tmux:**
  1. Resolve `%pane` to its session.
  2. Pick the client with the highest `client_activity` attached to that session, or any client if none is.
  3. Run `switch-client -c <tty> -t <sess>; select-window -t %P; select-pane -t %P`.
  4. Bring that client's terminal forward. A tmux client's `client_tty` is the tty of the Ghostty terminal that shows it, and Ghostty's AppleScript dictionary has it (Ghostty 1.3 or later). So, if Ghostty Automation is granted: `osascript` `tell application id "com.mitchellh.ghostty" to focus (first terminal whose tty is "<client tty>")`. Then, in every case, activate Ghostty with `NSRunningApplication`; if Ghostty is not the active app within 0.5 s, run `open -b com.mitchellh.ghostty`. The terminal is not found by its title: the title is the tmux window name, which two clients on one session share and which changes while Claude works.
     - Automation not decided yet: the app asks first (the macOS prompt, once; §8.5). The CLI never asks.
     - If the terminal could not be focused, Ghostty still comes forward, with the window used last, and the app shows a toast that starts "tmux switched to “<session>”, but" and gives the reason:
       - Automation not granted: "Ghostty may show another window. To fix this, allow Headroom to control Ghostty in System Settings ▸ Privacy & Security ▸ Automation.";
       - no Ghostty terminal has that tty (the client runs in another terminal app, or Ghostty is not running): "its terminal (<tty>) is not a Ghostty window, so Ghostty was only brought forward.";
       - any other failure: "Ghostty may show another window (<reason>)."
  5. If no client is attached, copy `tmux attach -t <sess>` to the clipboard and run `open -b com.mitchellh.ghostty`, with the toast "No terminal is attached to tmux. Copied “tmux attach -t <sess>”: paste it in Ghostty." `open -na Ghostty --args -e` is not used because it is unverified.

  If tmux refuses step 3 (for example, the pane went away), Ghostty is activated and the toast is "tmux could not switch to “<session>” (<tmux's message>), so Ghostty was only brought forward." Nothing is copied.

  A session in neither tmux nor Rex: Ghostty is activated, as in step 4, with no toast.

  Jump on a child process row of a session jumps to that session. Rows with nowhere to go (leftovers, Chrome overhead) beep.
- **Session in Rex** (§5.1):
  1. Find the block: the one the last refresh placed the session in, or, when no refresh has placed it, the claude's `REX_BLOCK` when its ppid chain reaches a Rex server first. A fresh discovery pass gives the block's session and tab.
  2. `rex focus -s <session> <block>` on the server. This makes the block's tab the session's active tab and focuses the block. It changes shared session state, as `select-window` does in tmux.
  3. Bring Rex.app forward with `open -b com.superlogical.rex`, which needs no Automation permission and opens a window when Rex has none. Then wait up to 1 s for Rex to become the active app.
  4. `rex [-C <client>] do session.select session_id=<session> window_id=<tab>`, which makes the app show that session's tab. The client is a connected LOCAL app client (`principal.transport` `unix`) of that session, else any connected local app client, most recently connected first. If there is none, the state is read again after Rex.app comes forward (it may have just connected). If there is still none, `-C` is left out and rex picks its default app client, except when an app client from another device is connected: then step 4 is skipped and the note is shown, because rex's default client would be that device. This is a Rex client action: it needs **Remote Control** turned on in Rex (off by default) and the app in front.
  5. If step 4 fails or is skipped, the app shows a toast: "If Rex shows another session, open “<session>”." followed by the reason:
     - exit 3 (the client target was not found, for example Rex.app has not connected yet, or reconnected with a new client id): "Rex.app is not connected to the Rex server (<rex's message>).";
     - another failure with a message from rex or the app (an app that refuses names Remote Control itself): that message;
     - a failure with no message: "Turn on Remote Control in Rex so Jump can switch sessions.";
     - the rex call timed out: "Rex.app did not answer. Make sure it has a window open.";
     - step 4 skipped: "Rex.app on this Mac is not connected to the Rex server, and Headroom does not switch Rex on another device."

     If the block is not found in step 1, Rex is only brought forward, with the toast "Rex could not find this session's pane, so Rex was only brought forward."

  Rex has no counterpart of `tmux attach`, so there is nothing to copy to the clipboard. Jump is not gated by `HEADROOM_DRY_RUN`, for tmux or Rex: it changes what is shown, never what runs.

### 7.7 Undo and Recently Closed

- **Tab:** extension `restore` through `sessions.restore(sessionId)`, which keeps history. If that fails, `tabs.create({windowId, index, url, active:false})`, using the front window if the original is gone. The toast says "reopened without history" when the fallback was used.
- **Session in tmux:**
  1. `tmux new-window -d -t '<sess>:' -n '<title>' -c '<cwd>'`
  2. `tmux send-keys -t <newPane> 'claude --resume <sid>' Enter`
  3. If the tmux session is gone: `tmux new-session -d -s <sess> -c <cwd>` and the same `send-keys`, then Jump.
  4. The help text notes that an unsent draft in the prompt box is lost.

  A session that ran in tmux is recorded with `tmuxSession`, and one that ran in Rex with `rexSessionId` and `rexSessionLabel` (§11). A record with either Rex field reopens in Rex. A record with neither multiplexer reopens in the tmux session `headroom`, or in the Rex session `headroom` when tmux is not installed and rex is.
- **Session in Rex** (§5.1):
  1. Rex must be running: Headroom never starts it. If `rex ls` fails, the outcome is `failed: Rex is not running (open Rex, then Undo again)`; with no rex binary it is `failed: rex is not installed (<path>)`. The record stays restorable.
  2. Pick the target: the session with the recorded id, else the first session with the recorded label (`headroom` when no label was recorded), else a new session with that label.
  3. Existing session: `rex window new -s <session> '<title>' -c '<cwd>' --focus=false --json`, a new tab that does not take focus. New session: `rex new '<label>' -c '<cwd>' --window='<title>' --json`. The tab name follows the tmux window-name rule.
  4. Each call has a 10 s timeout. A call that failed or timed out may still have worked, so Headroom compares the session's tabs (or the session list) before and after, and adopts the one new tab (or session) with that name. So a tab that was opened after all is used, instead of Undo failing and a later Undo opening a second one. If the session's tabs could not be read before the call, nothing is adopted and Undo fails.
  5. `rex send -s <session> -b <block> 'claude --resume <sid>'`, then `rex send-key -s <session> -b <block> enter`.
  6. A new session is then shown: Rex.app is brought forward and asked to show it, as in Jump steps 3–4. If `session.select` fails or is skipped, the outcome stays `done` (the session was resumed), and the Undo toast (and `headroom undo`) adds a note: "Resumed in the new Rex session “<label>”; open it in Rex." followed by the reason, as in Jump step 5 (with "Undo" in place of "Jump").
  7. As in tmux, an unsent draft is lost. In dry run, the refusals (still running, cwd missing) still apply and no rex command runs.
- **Leftovers:** cannot be undone. ⌘C gives the argv and cwd so they can be restarted by hand.
- **⌘Y Recently Closed:** today's batches, with [Restore] per item and "Restore all from 14:32". `closed.jsonl` is pruned after 7 days.

---

## 8. Packaging, permissions and first run

### 8.1 Repository layout (as planned; the README has the final targets)

```
Package.swift
Sources/HeadroomCore/     Contracts.swift (now its own HeadroomContracts target), SysKit/, Ownership.swift, Shell.swift, Tmux.swift, Rex.swift, Git.swift
Sources/HeadroomClaude/   SessionStore, TranscriptTail, ClaudeSource
Sources/HeadroomChrome/   ChromeBridge, Attribution, JXAFallback, ChromeSource
Sources/HeadroomActions/  Planner, CloseCoordinator, Signaller, Journal (closed/actions.jsonl), Undo
Sources/HeadroomApp/      main.swift, AppDelegate, WindowController, Outline*, Strip, Sheet, Toast, Peek, Setup
Sources/headroom-host/    main.swift
Extension/                manifest.json, sw.js
Tests/                    fixtures (ps.txt, psargs.txt, fake ~/.claude, captured tmux output, hand-written rex JSON, snapshot JSON)
scripts/                  build.sh, install.sh, uninstall.sh, make-signing-cert.sh, mkicon.swift
```

### 8.2 build.sh

1. `swift build -c release --arch arm64`. The package targets macOS 15 with `-swift-version 6`.
2. Compute the extension id from the committed `key`: take `sha256(DER)`, keep the first 32 hex characters, and map 0–f to a–p.
3. Assemble `build/Headroom.app/Contents/{MacOS/Headroom, Helpers/headroom-host, Resources/{AppIcon.icns, ChromeExtension/}, Info.plist}`.
4. Write Info.plist with PlistBuddy:
   - `CFBundleIdentifier=dev.adder.headroom`, `CFBundleExecutable=Headroom`, `CFBundleIconFile=AppIcon`, `CFBundlePackageType=APPL`;
   - the two version keys, `LSMinimumSystemVersion=15.0`, `NSHighResolutionCapable`, `NSPrincipalClass=NSApplication`;
   - `NSAppleEventsUsageDescription="Headroom lists and closes Chrome tabs when its helper extension isn't set up, and brings the right Ghostty window forward when you jump to a Claude session."`;
   - **no `LSUIElement`**.
5. Sign `Helpers/headroom-host` first, then the app: `codesign --force --sign "${SIGN_ID:--}" --timestamp=none`. There is no hardened runtime and no sandbox. If `SIGN_ID` is unset and no "Headroom Local Signing" identity exists, print: "Ad-hoc signed: macOS will ask for Chrome/Ghostty permission again after each rebuild. Run scripts/make-signing-cert.sh once."
6. `--run` launches with `open -n`. `--mock` launches with the fixture world and `HEADROOM_DRY_RUN=1`.

### 8.3 make-signing-cert.sh (run it once)

- It uses the verified openssl steps: EKU `critical,codeSigning`, keyUsage `digitalSignature`, 3650 days, `pkcs12 -legacy`.
- Then `security import cs.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`.
- It prints the SHA-1 to use as `SIGN_ID`.
- It removes the temporary key and p12 files afterwards.

### 8.4 install.sh (the user runs it; each step asks first)

1. `ditto build/Headroom.app ~/Applications/Headroom.app`.
2. Copy `Extension/` to `~/Library/Application Support/Headroom/ChromeExtension/`, a stable path for Load unpacked.
3. Write `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/dev.adder.headroom.json`:
   ```json
   {"name":"dev.adder.headroom","description":"Headroom tab memory bridge",
    "path":"/Users/jappleseed/Applications/Headroom.app/Contents/Helpers/headroom-host",
    "type":"stdio","allowed_origins":["chrome-extension://<FIXED_ID>/"]}
   ```
   The app also checks this file at every launch and repairs it if the path or id is wrong.
4. `--dock`:
   - back up with `defaults export com.apple.dock "…/Headroom/dock-backup-install-<ts>.plist"`;
   - append a `persistent-apps` file-tile for `file:///Users/jappleseed/Applications/Headroom.app/` to the exported copy, with `scripts/dock-tile.py` (it edits plist files only);
   - `defaults import`, then `killall Dock`.

   Without `--dock`, the script prints "Open Headroom, then right-click its Dock icon ▸ Options ▸ Keep in Dock".
5. Offer to append this AeroSpace rule (only if it is missing): `[[on-window-detected]] if.app-id='dev.adder.headroom' run='layout floating'`.
6. `uninstall.sh` reverses steps 1–4 and restores the Dock from the backup if asked.

### 8.5 Permissions

| Capability | Needs | Without it |
|---|---|---|
| Claude sessions, leftovers, all memory figures, signals, tmux, Rex, git | nothing | – |
| Chrome process totals and Chrome itself | nothing | – |
| Per-tab memory, Sleep, restore with history, precise tab jump | helper extension (Developer mode + Load unpacked, once per profile) | "—" per tab |
| Tab list and close without the extension | Automation ▸ Google Chrome | Totals only |
| Jump into the exact Ghostty window | Automation ▸ Ghostty. The app asks at the first Jump to a session in tmux (the macOS prompt, which says why); the CLI never asks. | tmux still switches; Ghostty is activated generically, and a toast says the window may be another one and where to allow it (§7.6) |
| Jump into another Rex session | Remote Control turned on in Rex (a Rex setting, not a macOS permission). Rex.app is brought forward with `open -b`, so no Automation is needed. | Rex still focuses the pane and comes forward; a toast asks you to open the session |
| Show a session that Undo created in Rex | The same as Jump into another Rex session | The session is still resumed; the Undo toast (and `headroom undo`) names the new Rex session to open |
| Accessibility | never used | – |

### 8.6 First run

1. The window opens at once. The Claude and Leftovers sections and the strip work with no prompts.
2. The Chrome section shows totals by process type and a card:
   ```
   Chrome is using 3.9 GB. To see and close individual tabs, choose one or both:
    ① Headroom helper extension — memory per tab, Sleep, Undo with history.  [Set up…]
    ② Let Headroom control Chrome — lists and closes tabs, no per-tab memory. [Allow…]
   Headroom never reads page content, cookies or history.
   ```
   - **[Set up…]** opens a sheet with three steps that tick themselves off:
     1. Bridge file installed (automatic).
     2. [Copy "chrome://extensions"], turn on Developer mode, Load unpacked, press ⌘⇧G and paste ([Copy folder path]).
     3. "Waiting for the helper…" becomes ✓ when the `hello` arrives.

     The sheet says Chrome may show a developer-mode extensions notice, and that the helper must be added once per profile.
   - **[Allow…]** calls `AEDeterminePermissionToAutomateTarget(askUserIfNeeded:true)`.
3. When the helper connects, the card disappears. The app shows a one-time banner, "Memory per tab is on", and the helper's own measured cost.

### 8.7 Lifecycle

- `applicationShouldTerminateAfterLastWindowClosed = true`, with one window, so a Dock click relaunches the app in under 1 s.
- `applicationShouldHandleReopen` brings the window back.
- The Dock tile is the static icon, a gauge drawn by `mkicon.swift`.
- The resident Dock gauge, badge and Dock menu come in v1.1, behind a setting (see Q3).

### 8.8 Headless modes

- `Headroom --dump-json` prints the full `WorldSnapshot` and exits.
- `Headroom --selftest [sys|claude|chrome|ownership]` prints its checks and exits. The checks cover:
  - footprint vs `footprint -p`;
  - `KERN_PROCARGS2`;
  - session parse and liveness;
  - transcript tail;
  - tmux;
  - Rex, when a Rex server runs: no session is in both tmux and Rex; when a claude runs in Rex, discovery is also complete and every claude in Rex is placed in its pane. It runs only the read-only `rex ls`, `session inspect` and `whoami`, and prints the server's version, API revision, and whether discovery was reachable and complete;
  - socket bind;
  - host manifest present and matching the id;
  - the ownership invariant.

---

## 9. Refresh model and budget

| Data | Window key | Visible, not key | Occluded, minimised or closed |
|---|---|---|---|
| Process table and footprints (`proc_*`; measured at about 2 ms for 815 pids) | 2 s | 10 s | paused |
| argv and env (`KERN_PROCARGS2`) | only for new `ProcKey`s (Chrome-bundle pids, non-`.app` pids, claude), and again after a process execs (same `ProcKey`, new command name) | same | – |
| Chrome snapshot (extension) | on `didBecomeKey`, on `dirty`, and a safety poll every 5 s | 10 s | paused |
| JXA fallback (3 s timeout) | 5 s + on `didBecomeKey` | 30 s | paused |
| Session JSON | DispatchSource + a 10 s rescan | same | – |
| Transcript tails | when the file size changes | same | – |
| tmux panes and clients | 3 s | 10 s | paused |
| Rex discovery (`rex ls` + one `session inspect` per session), only while a claude runs in Rex | 3 s | 10 s | paused |
| Docker containers and memory (engine socket, §5.2), in the background | 5 s | 15 s | paused |
| Docker disk use (`/system/df`), in the background | when older than 15 min | same | paused |
| git HEAD | when first seen, then every 30 s | – | – |
| System strip | 2 s + on memory-pressure events | 10 s | paused |

- All collection runs in `actor Collector`, which publishes a `Sendable` `WorldSnapshot`. The UI diffs rows by `ItemID`: values change with `reloadData(forRowIndexes:columnIndexes:)`, and structural changes use insert and remove with a 0.2 s fade.
- Every subprocess runs off the main thread with a timeout.
- **Rex cost per refresh** (§5.1):
  - No rex process runs when no Rex server is in the process table, or when no claude runs in Rex. That check is pure, and argv is read only for executables named `rex`.
  - Otherwise: 1 `ls` plus 1 `session inspect` per session (8 at a time): the sessions that hold a claude (their `REX_SESSION`) first, then the others, 64 in all. This runs after the ownership pass and alongside the Chrome snapshot. On the Mac this was measured on, `ls` took 10–19 ms and each `inspect` 20–25 ms.
  - Each read has a 2 s rex timeout, and the whole pass a 3 s deadline. A result is cached for the TTL even when it failed, so a Rex server that does not answer costs one bounded pass per TTL. A cached pass that neither put first nor inspected a session that now holds a claude is fetched again at once.
  - Finding a claude's pane costs nothing extra: `REX_BLOCK` comes from the environment that SysKit already reads.
  - The close-time re-check (§7.4) never uses the cache.
  - User actions: Peek runs 1 `capture` (4 s timeout). Jump runs a discovery pass, then `focus` and `do` (5 s timeout each), and a second discovery pass when the first found no local app client. Undo runs `ls`, then `inspect` and `window new` (existing session) or `new` (new session), then `send` and `send-key`; the four mutating calls have 10 s timeouts. Recovering from a failed `window new` or `new` adds up to 2 calls, and showing a new session adds a discovery pass and `do`.
- **Budget:** under 1% average CPU and under 45 MB for the app. The footer shows the app, host and helper-extension footprints.

---

## 10. Things to verify (built into the plan, not assumed)

| Item | Where it is verified | Fallback if it fails |
|---|---|---|
| **Stable Chrome 154:** Load unpacked works, `connectNative` works, `processId == --renderer-client-id`, the worker stays alive for 10 min or more, and the footprint of the helper's extension process | **Spike S** ([spike-s.md](spike-s.md)): you load the real fixed-id extension once and run `headroom-host --probe`, which reads data and logs only | Use the JXA (AppleScript) tab list; per-tab memory is not available |
| Helper extension footprint (other extension renderers on the Mac this was measured on averaged about 94 MB) | Spike S | Above 40 MB: on-demand mode is the better default |
| `sessions.restore` keeps history, and matching recently-closed entries is reliable | Chrome for Testing with a throwaway profile (`Tests/e2e-chrome/`) | `tabs.create` by URL |
| `tabs.remove` or AppleScript close vs `beforeunload`; `tabs.discard` on the active tab | Chrome for Testing (`Tests/e2e-chrome/`) | 1 s verification plus [Jump]; Sleep skips the active tab |
| An `osascript` child's TCC prompt is attributed to Headroom | `scripts/tcc-probe.sh`, run by hand (a throwaway test app aimed at Ghostty) | Use `NSAppleScript` on a dedicated serial thread |
| Ghostty: `focus (first terminal whose tty is …)` puts that terminal's window in front, also when another app is active | Verified on 2026-11-21 with Ghostty 1.4.0, six tmux clients in six windows: `HEADROOM_LIVE_FOCUS_TTY=/dev/ttysNNN swift test --filter HeadroomClaudeTests.LiveGhosttyFocus` (by hand; it changes what is on screen, then puts it back). **Not verified:** the macOS prompt that Headroom.app itself shows at the first Jump (the test ran from a terminal, which already had the permission) | The toast in §7.6 step 4 |
| Writing to NativeMessagingHosts from install.sh | `install.sh` in a scratch HOME; the real write happens in your own install run | Print the JSON for the user to copy |
| Rex: a Rex.app window that shows a tab other than the session's `active_window_id` (several workspace windows, a torn-off tab) | **Not verified** (checking needs a mutating Rex action). By hand: tear a tab off once, run `headroom selftest claude`, and compare the `visible` flags with the screen | None yet: such a pane may show as not visible (§5.1) |
| Rex: `do session.select` switches Rex.app to the session (Remote Control on) | **Not verified live** during the build (tests use a fake `rex`). By hand: Jump to a session in another Rex session | Jump's toast asks you to open the session (§7.6) |

---

## 11. Core types and test rules

The shared types every module builds on, as first sketched. The code in `Sources/HeadroomContracts/Contracts.swift` has since grown and differs in places (its header lists how); where they differ, the code is right.

**Rules for contributors and tests:**
- Set `HEADROOM_DRY_RUN=1` for every dev and test run.
- Never signal your real processes, never touch your live Chrome beyond read-only JXA, and never edit your Dock, keychain, AeroSpace config or Chrome settings from a test.
- Signal tests use spawned dummies: copy `/bin/sleep` to `<scratch>/claude/versions/9.9.9` and add a fake sessions JSON under `HEADROOM_CLAUDE_DIR`.
- Chrome tests use Chrome for Testing with a scratch `--user-data-dir` (see `Tests/e2e-chrome/`). Stop only the processes you started, matched by the scratch path.
- tmux tests use a private server: `HEADROOM_TMUX_SOCKET=headroom-test`.
- Rex tests never reach your own Rex server:
  - Default tests point `HEADROOM_REX` at `RexStub` (a fake `rex` script in a temp folder that logs each call and never talks to a server) or at `/nonexistent/rex`. Claude tests get Rex state from a test seam, and the tmux-or-Rex decision is a pure process walk.
  - With a fake `HOME` and no `HEADROOM_REX`, the binary resolves to `<HOME>/.local/bin/rex`, which does not exist, so nothing runs. The CLIs in `/Applications` are tried only when `HOME` is the account's own home.
  - The round trip against a real Rex binary is opt-in (`HEADROOM_REX_LIVE_TEST=1`). It starts its own server on a private socket, makes no mutating call until `whoami` reports that server's pid, and stops only that server. Rex still creates an empty `start.lock` under `~/Library/Application Support/rex/servers`; the test prints new entries and never deletes them.
  - Never point `HEADROOM_REX_SERVER` at your own server's socket.

```swift
public typealias Bytes = UInt64
public struct ProcKey: Hashable, Sendable, Codable { public let pid: Int32; public let startSec: Int }
public struct ProcSample: Sendable { public let key: ProcKey; public let ppid, pgid: Int32; public let path: String
  public let footprint, rss: Bytes; public let cpuNs: UInt64 }
public struct ProcArgs: Sendable { public let argv: [String]; public let env: [String: String] } // env filtered to CLAUDE_* keys
public struct ProcessTable: Sendable { public let byPid: [Int32: ProcSample]; public let children: [Int32: [Int32]]; public let takenAt: Date }
public enum Pressure: Int, Sendable { case normal = 1, warning = 2, critical = 4 }
public struct SystemMemory: Sendable { public let total, used, appMemory, wired, compressed, free, swapUsed, swapTotal: Bytes; public let pressure: Pressure }
public enum SignalResult: Sendable, Equatable { case sent, gone, mismatch, refused(String), dryRun, failed(Int32) }
public protocol SysKit: Sendable {
  func scan() -> ProcessTable
  func args(_ k: ProcKey) -> ProcArgs?                  // cached per key
  func cwd(_ pid: Int32) -> String?
  func systemMemory() -> SystemMemory
  func isAlive(_ k: ProcKey) -> Bool
  func parentPid(_ pid: Int32) -> Int32? }          // Rex: works for other users' processes scan() leaves out; default nil

// Ownership (§3)
public enum Owner: Sendable, Hashable { case chrome(browserPid: Int32), claudeChild(ProcKey), claudeBackground(ProcKey),
  leftover(pgid: Int32, deadClaudePid: Int32), otherChrome(browserPid: Int32), unowned }
public struct BrowserInstance: Sendable { public let key: ProcKey; public let isMain: Bool; public let userDataDir: String?; public let headless: Bool }
public struct OwnershipMap: Sendable { public let owner: [Int32: Owner]; public let browsers: [BrowserInstance] }

public enum ItemID: Hashable, Sendable, Codable {
  case chromeWindow(browserPid: Int32, windowId: Int)
  case chromeTab(browserPid: Int32, tabId: Int)
  case chromeOverhead(browserPid: Int32, kind: String)      // browser,gpu,utility,extensions,background,otherInstances
  case process(ProcKey)                                      // children, background, automation browser, overhead procs
  case session(ProcKey)
  case leftover(pgid: Int32, leaderStartSec: Int) }

// Chrome
public struct ChromeFrame: Sendable { public let frameId, parentFrameId, processId: Int; public let lifecycle: String }
public struct ChromeTab: Sendable { public let browserPid: Int32; public let id, windowId, index: Int
  public let title, url, host: String; public let active, audible, pinned, discarded, incognito: Bool
  public let lastAccessed: Date?; public let frames: [ChromeFrame]
  public var display: Bytes?; public var exclusive: Bytes; public var sharedWith: Int; public var procs: [ProcKey] }
public struct ChromeWindow: Sendable { public let browserPid: Int32; public let id: Int; public let focused, incognito: Bool; public var tabIds: [Int] }
public enum ChromeSource: Sendable, Equatable { case notRunning, helper(profiles: Int), appleScript, processesOnly, waiting }
public struct ChromeSnapshot: Sendable { public var source: ChromeSource; public var windows: [ChromeWindow]; public var tabs: [ChromeTab]
  public var overhead: [String: (count: Int, bytes: Bytes)]; public var total: Bytes
  public var procFootprint: [ProcKey: Bytes]; public var procUsers: [ProcKey: Set<Int>]   // users scoped by browser via ProcKey
  public var perTabUnavailable: String?; public var staleSince: Date?
  public func freed(_ tabs: Set<Int>) -> Bytes }
public protocol ChromeProvider: Sendable {
  func snapshot(_ t: ProcessTable, _ o: OwnershipMap, _ sys: SysKit) async -> ChromeSnapshot
  func close(_ tabs: [(browserPid: Int32, id: Int, expectedURL: String)]) async -> [ItemID: Outcome]
  func discard(_ tabs: [ItemID]) async -> [ItemID: Outcome]
  func activate(_ tab: ItemID) async
  func restore(_ r: [ClosedRecord]) async -> [ClosedRecord: Outcome]
  func setMode(_ m: String) async }

// Claude
public struct TmuxLoc: Sendable { public let paneId, session, windowName: String; public let windowIndex, paneIndex: Int; public let visible, current: Bool }
public struct RexLoc: Sendable { public let blockId, sessionId, sessionLabel: String   // full Rex ids; labels need not be unique
  public let windowId, windowLabel: String?; public let windowIndex, paneIndex: Int?   // nil = not placed (§5.1)
  public let visible: Bool                                                             // true when not placed
  public var label: String { get } }                                                   // "foundry:2.1" / "foundry:?"
public struct LinkedUnit: Sendable { public let root: ProcKey; public let pgid: Int32; public let command: String
  public let members: [ProcKey]; public let footprint: Bytes; public let isAutomationBrowser: Bool }
public struct ClaudeSession: Sendable { public let key: ProcKey; public let sessionId, cwd, title, project: String
  public let worktree, branch: String?; public let cwdExists, hasTranscript, busy, remoteControl, isLauncher, unregistered: Bool
  public let status: String; public let statusSince, lastActivity: Date?; public let startedAt: Date; public let cpuPercent: Double
  public let lastPrompt, lastAssistant, awaySummary: String?; public let tmux: TmuxLoc?
  public let rex: RexLoc?                                   // never set together with tmux
  public let kind, version: String
  public let selfFootprint, selfRSS: Bytes; public let children: [LinkedUnit]; public let background: [LinkedUnit]
  public var total: Bytes { get } }
public struct LeftoverGroup: Sendable { public let id: ItemID; public let unit: LinkedUnit; public let deadClaudePid: Int32
  public let sessionId, sessionTitle, cwd: String?; public let startedAt: Date }
public struct ClaudeSnapshot: Sendable { public var sessions: [ClaudeSession]; public var leftovers: [LeftoverGroup]; public var staleFiles: [String] }
public protocol ClaudeProvider: Sendable {
  func snapshot(_ t: ProcessTable, _ o: OwnershipMap, _ sys: SysKit) async -> ClaudeSnapshot
  func jump(_ s: ProcKey) async
  func reopen(_ r: [ClosedRecord]) async -> [ClosedRecord: Outcome] }

public struct WorldSnapshot: Sendable { public let system: SystemMemory; public let chrome: ChromeSnapshot; public let claude: ClaudeSnapshot
  public let ownership: OwnershipMap; public let selfBytes: Bytes; public let at: Date }

// Actions
public enum Reason: Sendable, Hashable { case busy(String?), recentActivity, visiblePane, notInTmux, hasBackground(Int, Bytes),
  noTranscript, cwdMissing, unregistered, audible, pinned, emptiesWindow(Int), closesAllWindows, leftover, manyItems,
  launcher, pidMismatch, chromeCore }
public enum Protection: Sendable { case none, confirm([Reason]), locked(Reason) }
public enum Outcome: Sendable, Hashable { case done, alreadyGone, changedSkipped, stayedOpen, stillAlive, dryRun, failed(String) }
public struct ClosePlan: Sendable { public let items: [(ItemID, Protection, Bytes)]; public let locked: [(ItemID, Reason)]
  public let estimate: Bytes; public var stopBackground = true; public var skipBusy = true
  public var needsSheet: Bool { get }; public var sheetMandatory: Bool { get } }   // mandatory = busy / leftover / unregistered
public struct ClosedRecord: Codable, Sendable, Hashable { public let kind: String; public let closedAt: Date; public let title: String
  public let bytes: Bytes; public var url: String?; public var windowId, index: Int?; public var chromeSessionId: String?
  public var sessionId, cwd, tmuxSession: String?; public var argv: [String]?
  public var rexSessionId, rexSessionLabel: String? }      // Rex Undo target; absent in older records
public enum ActionEvent: Sendable { case progress(ItemID, Outcome), needsForce([ItemID]), finished([ClosedRecord]) }
public protocol ActionExecutor: Sendable {
  func plan(_ sel: Set<ItemID>, _ w: WorldSnapshot) -> ClosePlan
  func execute(_ p: ClosePlan) -> AsyncStream<ActionEvent>
  func forceQuit(_ ids: [ItemID]) async
  func sleep(_ tabs: [ItemID]) async -> [ItemID: Outcome]
  func undo(_ r: [ClosedRecord]) async -> [ClosedRecord: Outcome]
  func jump(_ id: ItemID) async
  func jumpNote(_ id: ItemID) async -> String? }           // Jump + the tmux or Rex note for a toast (§7.6); default: jump, nil
```

`ClaudeSession` also has helpers that treat tmux and Rex alike: `inMultiplexer` (in tmux or Rex), `onScreen` (tmux visible or current, or Rex visible) and `placeLabel` (`hub:3.1`, `rex foundry:2.1` or nil). Rex support adds no new reason codes: `visiblePane` and `notInTmux` keep their names and cover Rex.

**Test seams:** `HEADROOM_CLAUDE_DIR`, `HEADROOM_TMUX`, `HEADROOM_TMUX_SOCKET` (adds `-L <name>` to every tmux call; tests use `headroom-test`), `HEADROOM_REX` (the rex CLI; tests use `RexStub` or `/nonexistent/rex`), `HEADROOM_REX_SERVER` (a private Rex server, `unix:///<absolute path>`), `HEADROOM_SUPPORT_DIR`, `HEADROOM_DRY_RUN`, and `HEADROOM_CLAUDE_VERSIONS_GLOB` (so the fake `claude/versions` path is accepted). Opt-in live tests: `HEADROOM_REX_LIVE_TEST=1` (a private Rex server, see above) and `HEADROOM_LIVE_SELFTEST=1` (read-only self-tests against your own system; with a Rex server running they run `rex ls`, `session inspect` and `whoami` against it).

### What the tests and checks cover

Spike S, an optional check that the helper works in your own Chrome, is described in [spike-s.md](spike-s.md).

- **Core (SysKit, Ownership, Shell, Tmux, Rex, Git):**
  - footprint within 1% of `footprint -p` for 3 of its own child processes;
  - a scan of 800 pids in under 5 ms;
  - the ownership fixture tests (§3) pass, with no pid in two buckets, and agent-browser is attached to session 80876;
  - tmux parsing works on captured output;
  - tmux Jump on a private server with pty clients: no client (the attach command and its toast), a client on another session (it is switched, and the terminal on its tty is focused), a client already on the session (it is used, the others stay), and the toast for each way the terminal could not be focused; the Ghostty focus script and how `osascript`'s answer is read;
  - Rex parsing works on hand-written `rex … --json` fixtures (`Tests/Fixtures/rex-*.json`: tab and pane numbering, zoomed, floating and minimized layers, app and CLI clients), and viewer state it cannot read (an unknown active tab, clients of unknown kind or without an id) counts as visible;
  - the tmux-or-Rex process walk (§5.1), including tmux inside Rex, a hidden `login`, launchd and ppid cycles;
  - `RexClient` sends exactly the expected argv to `RexStub`, refuses `server …` and malformed server addresses without running anything, stops discovery at its deadline, and inspects the sessions that hold a claude first even beyond the 64th;
  - `LiveSysKit` reads argv and env again after a process execs (`exec claude` in a pane shell).
- **Claude sessions in Rex:** placement (placed, unplaced, stale `REX_BLOCK`, tmux inside Rex), Jump (the call order, the local client, never another device's, the notes and their reasons, and the live fallback without a snapshot) and Undo (by id, by label, a new session and its note when Rex.app cannot show it, recovery after a failed call, Rex not running, dry run) against `RexStub`; the `selftest claude` `rex` check with and without a claude in Rex.
- **Claude sessions:**
  - live `--selftest claude` lists every session with no false stale entries, and the footprint total is within 2% of a separate `ps`-based sum of the same process trees;
  - 22 transcript tails read in under 20 ms (cold cache);
  - a fixture of `~/.claude` covers the title rules, a missing transcript and a missing cwd.
- **Chrome, extension and host:**
  - attribution unit tests: shared renderer, cross-site iframe, a bfcache-only process counted in `freed`, a discarded tab, a missing client id (degraded), and two browsers with colliding client ids;
  - a framing round-trip test;
  - Chrome for Testing: a 320 MB page shows about 336 MB; close with a changed URL returns `changedSkipped`; discard works; whether restore keeps history is recorded (the results are in `Extension/README.md` and `docs/protocol.md`);
  - the host exits when that Chrome quits.
- **App and actions:**
  - unit tests for window expansion, locked skipping, every confirm trigger, `sheetMandatory` holding under ⌥, the filter parser, and the Signaller refusing pid ≤ 1, self, ancestors, `.app` and main-Chrome targets, a mismatched start time, a pgid that contains a pane, and a Rex pane's process group or a group under a Rex pane process;
  - the close sequence tested against fake-claude dummies that leave a background pgid;
  - a manual check of the selection behaviour against Finder;
  - no row moves while the pointer is over the list;
  - footprint under 45 MB with 40 rows.
- **Packaging:**
  - `HOME=<scratch> ./install.sh` produces the right bundle, host JSON and extension folder;
  - `--dock` tested on a copied plist only;
  - `codesign --verify --deep` passes;
  - two rebuilds with a scratch-keychain certificate keep the same designated requirement;
  - launched from a scratch `~/Applications`, the app reopens on a Dock click and leaves no Headroom process after quitting (apart from the Chrome-owned host).

**Later (v1.1):**
- a resident mode with the Dock ring gauge, a badge at Warning or above, and a Dock menu ("Close idle sessions > 2h…" opens the window with them selected);
- Site and Process grouping for Chrome;
- Δ growth arrows;
- a `headroom ls/close --idle 2h --dry-run` CLI over the same providers;
- an optional "close tmux pane after exit".