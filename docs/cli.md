# `headroom` CLI

`headroom` is the command-line side of Headroom. It uses the same providers, Planner, CloseCoordinator
and Signaller as the app (`Headroom.context()` in HeadroomActions). It has no separate collection or
close logic. `install.sh` links it to `~/bin/headroom`. You can also run it from `Headroom.app/Contents/Helpers/headroom`.

The CLI's code is in `Sources/HeadroomCLI/`. The `list --json` and `suggest --json` models are stable
contracts (`Sources/HeadroomContracts/CLIModel.swift`). The `close --json` and `undo --json` models live in
the CLI (`CloseCommand.swift`, `UndoCommand.swift`). For all of them: fields can be added, but never renamed or
removed. `schema` changes only on a breaking change. It is `1` now.

```
headroom [--mock] list     [--json] [--kind tabs|sessions|leftovers|all]
headroom [--mock] suggest  [--json] [--min-mb N] [--ask [--model M] [--timeout S]]
headroom [--mock] close    <ids…> [--dry-run] [--yes] [--force-confirm [--include-busy]] [--keep-background] [--json]
headroom [--mock] undo     [--last | <id>] [--list] [--dry-run] [--json]
headroom          selftest [sys|ownership|claude|chrome]
headroom          --version | --help
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | OK. For `close`, every item closed (or would close in dry run). |
| `1` | Error: bad arguments, a bad id, `claude -p` failed, nothing to undo, or some items did not close. |
| `2` | Needs confirmation or refused: a locked item, an item that needs `--force-confirm`, no TTY and no `--yes`, or you answered "n". Nothing was closed. |

## Environment

| Variable | Effect |
|---|---|
| `HEADROOM_DRY_RUN=1` | Every close, signal and restore is a logged no-op (`dryRun`). Prompts and refusals stay the same as in a real run, as in the app. |
| `HEADROOM_MOCK=1` (or `--mock`) | Uses the built-in MockWorld and a mock executor. Nothing is touched. Mock state is per process, so a `--mock close` is not seen by a later `--mock undo`. |
| `HEADROOM_SUPPORT_DIR` | Replaces `~/Library/Application Support/Headroom` (`actions.jsonl`, `closed.jsonl`, `run/`). |
| `HEADROOM_CLAUDE_DIR`, `HEADROOM_TMUX`, `HEADROOM_TMUX_SOCKET`, `HEADROOM_CLAUDE_VERSIONS_GLOB` | Test seams shared with the app (see `Env.swift`). |
| `HEADROOM_REX` | Path of the `rex` CLI. The default is `~/.local/bin/rex`; when `HOME` is your account's home, also the CLI inside `/Applications/Rex.app` or `/Applications/Rex Beta.app`. Tests use a fake script here. |
| `HEADROOM_REX_SERVER` | A private Rex server, as `unix:///<absolute path>` (tests). Every rex call gets `-S <address>`; any other form makes every rex call refuse. Without it, rex uses your own server. Headroom never starts a Rex server either way (`--autostart=false`). |
| `HEADROOM_ASK_CLAUDE` | Path of the `claude` binary for `suggest --ask`. The default is `claude` on `PATH`, then `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin` and `/usr/local/bin`. Tests use a fake script here. |
| `CLAUDE_PID` | Set by Claude Code. The session that ran `headroom` is locked (`launcher`), as are Headroom's own ancestors. |

## Item ids

The id format is frozen. `closed.jsonl` uses the same strings.

| Kind | Format | Example |
|---|---|---|
| Chrome tab | `tab:<browserPid>:<tabId>` | `tab:812:1101007` |
| Chrome window (`close` expands it to its tabs) | `window:<browserPid>:<windowId>` | `window:812:1100001` |
| Claude session | `session:<pid>:<startSec>` | `session:41000:1790694600` |
| Leftover group | `leftover:<pgid>:<leaderStartSec>` | `leftover:7164:1790613600` |
| Process (child or background; always locked) | `proc:<pid>:<startSec>` | `proc:85291:1790694720` |
| Chrome itself (always locked) | `overhead:<browserPid>:<kind>` | `overhead:812:gpu` |

`startSec` is the process start time in seconds since 1970. An id therefore never matches a reused pid:
after a restart the old id is "not found" and `close` refuses it.

## `list`

This command prints system memory (pressure, swap), then the Chrome tabs, Claude sessions and leftovers, largest first.

The human table has these columns: id, memory, idle time, status, protection, title and where. Where is the host for a tab and the cwd for a leftover. For a session it is `session:window.pane` in tmux (`hub:5.0`), `rex session:tab.pane` in Rex (`rex foundry:2.1`) or `not in tmux or Rex`, then the cwd. The protection reason codes are in parentheses. `—` means unknown. For example, per-tab memory is unknown when Chrome is read through AppleScript instead of the helper extension.

### `list --json`

Keys that do not apply to a kind are omitted. A `null` value is omitted too. Incognito tab URLs are never printed.
Below is the real `--mock` output, cut to 5 items:

```json
{
  "dryRun": true,
  "generatedAt": "2026-09-30T17:55:21Z",
  "mock": true,
  "schema": 1,
  "system": {
    "compressedBytes": 6549825126, "freeBytes": 8804682956, "pressure": "warning",
    "swapTotalBytes": 4294967296, "swapUsedBytes": 3221225472,
    "totalBytes": 51539607552, "usedBytes": 42734924595, "wiredBytes": 3435973836
  },
  "totals": {
    "chromeBytes": 6773800960, "chromeOverheadBytes": 2357198848, "chromeSource": "helper",
    "headroomBytes": 32505856, "leftoversBytes": 2349858816, "sessionsBytes": 9171894272,
    "staleSessionFiles": 1
  },
  "items": [
    {
      "id": "session:41000:1790694600", "kind": "session", "title": "clip generation",
      "bytes": 1974468608, "backgroundBytes": 1382023168,
      "cwd": "/Users/jappleseed/learning", "tmux": "hub:3.1", "pid": 41000,
      "sessionId": "c5d50000-0000-4000-8000-000000001000",
      "status": "busy", "lastActivity": "2026-09-30T17:44:21Z",
      "lastPrompt": "render the next 5 clips and upload them", "remoteControl": false,
      "protection": "confirm",
      "reasons": [
        { "code": "busy", "text": "busy or unknown status" },
        { "code": "hasBackground", "text": "has 2 background processes (1.29 GB)" }
      ],
      "resumeCommand": "cd '/Users/jappleseed/learning' && claude --resume c5d50000-0000-4000-8000-000000001000"
    },
    {
      "id": "leftover:7164:1790613600", "kind": "leftover", "title": "tour landing",
      "bytes": 1258291200, "command": "bun run dev --port 3217", "pgid": 7164, "deadClaudePid": 21630,
      "cwd": "/Users/jappleseed/work/harbour-tours", "sessionId": "dead0000-0000-4000-8000-000000000000",
      "status": "orphaned", "protection": "confirm",
      "reasons": [{ "code": "leftover", "text": "leftover process group (cannot be undone)" }]
    },
    {
      "id": "session:41194:1790590080", "kind": "session", "title": "map directions",
      "bytes": 422576128, "backgroundBytes": 0, "cwd": "/Users/jappleseed/work", "tmux": "hub:5.0",
      "pid": 41194, "sessionId": "c5d50002-0000-4000-8000-000000001002",
      "status": "idle", "idleSeconds": 108000, "lastActivity": "2026-09-29T11:55:21Z",
      "lastPrompt": "continue with map directions", "remoteControl": false,
      "protection": "none", "reasons": [],
      "resumeCommand": "cd '/Users/jappleseed/work' && claude --resume c5d50002-0000-4000-8000-000000001002"
    },
    {
      "id": "tab:812:1101014", "kind": "tab", "title": "Boston to Cambridge – Google Maps",
      "bytes": 404750336, "url": "https://www.google.com/maps/dir/Boston/Cambridge",
      "browserPid": 812, "windowId": 1100001, "status": "background",
      "idleSeconds": 11400, "lastActivity": "2026-09-30T14:45:21Z",
      "pinned": false, "audible": false, "incognito": false, "sharedWith": 0,
      "protection": "none", "reasons": []
    },
    {
      "id": "session:43037:1790691540", "kind": "session", "title": "rex docs pass",
      "bytes": 304087040, "backgroundBytes": 0, "cwd": "/Users/jappleseed/work/foundry", "rex": "foundry:2.1",
      "branch": "docs", "pid": 43037, "sessionId": "c5d50015-0000-4000-8000-000000001015",
      "status": "idle", "idleSeconds": 5400, "lastActivity": "2026-09-30T16:25:21Z",
      "lastPrompt": "continue with rex docs pass", "remoteControl": false,
      "protection": "confirm",
      "reasons": [{ "code": "visiblePane", "text": "visible or current tmux pane, or visible Rex pane" }],
      "resumeCommand": "cd '/Users/jappleseed/work/foundry' && claude --resume c5d50015-0000-4000-8000-000000001015"
    }
  ]
}
```

| Field | Notes |
|---|---|
| `bytes` | Footprint (Activity Monitor "Memory"). Tabs: fair share of their renderers (`null` = unknown). Sessions: claude + children + background. |
| `idleSeconds` | Tabs: since `lastAccessed` (0 for the active tab). Sessions: since `max(statusUpdatedAt, last transcript activity)`; omitted while busy. |
| `startedAt`, `runningSeconds` | Leftovers only: when the group's leader started and how long it has run. |
| `tmux`, `rex` | Sessions: where the session runs. `tmux` is a tmux location, `session:window.pane` (`hub:3.1`). `rex` is a Rex location, `session:tab.pane` with both numbers 1-based (`foundry:2.1`), or `session:?` when Headroom cannot place the pane (it then counts as visible). A session has at most one of the two; with neither, it runs in neither multiplexer (reason `notInTmux`). `tmux` never holds a Rex location. |
| `status` | tab: `active` \| `audible` \| `sleeping` \| `background`; session: `busy` \| `idle`; leftover: `orphaned` |
| `protection` | `none` (closes at once), `confirm` (the app shows its sheet; the CLI needs `--force-confirm`), `locked` (never closed) |
| `totals.chromeSource` | `helper` \| `appleScript` \| `processesOnly` \| `waiting` \| `notRunning` |
| `totals.chromeHelperNote` | Present when the helper cannot see some tabs (incognito without "Allow in Incognito", a profile without the helper). Those tabs are listed with `bytes: null`. |

`list` and `suggest` take no positional arguments: a stray word (a forgotten `--kind` or `--min-mb`) is an error (exit 1).

Reason codes: `busy`, `recentActivity`, `visiblePane`, `notInTmux`, `hasBackground`, `noTranscript`,
`cwdMissing`, `unregistered`, `audible`, `pinned`, `emptiesWindow`, `closesAllWindows`, `leftover`,
`manyItems`, `launcher`, `pidMismatch`, `chromeCore`, `childProcess` (a child or background process of a live session: close the session instead). `close --json` also uses `notFound`.

Two codes also cover Rex, and kept their names when Rex support was added (only their texts changed):
`visiblePane` ("visible or current tmux pane, or visible Rex pane") includes a Rex pane that Headroom cannot place,
and `notInTmux` ("not in tmux or Rex (Undo cannot put it back where it ran)") means the session runs in neither.

## `suggest`

The default mode uses rules only. It is instant, free and local. The tunable numbers are in
`Sources/HeadroomCLI/SuggestRules.swift` (`SuggestTuning`).

| Candidate | Rule | Verdict |
|---|---|---|
| Claude session | Idle more than 2 h, not busy (unknown status counts as busy), not the visible or current tmux pane or a visible Rex pane (a Rex pane Headroom cannot place counts as visible), no background processes | `safe`. If the app would still ask (not in tmux or Rex, no transcript, cwd missing, unregistered), `confirm` with that reason. |
| Leftover | Every leftover | `confirm`. Safe to stop, but it cannot be undone, so it always asks. |
| Chrome tab | Not active, audible, pinned, incognito or already asleep, and either heavy (at least 300 MB) or unused for more than 1 h | `safe` |
| Locked row (launcher, Chrome itself, a process row, a changed pid) | Never suggested | – |

After the rules run, the "safe" set is planned as **one** close with the same Planner as `close`. An item
the plan would ask about (the close empties a window of more than 5 tabs, or every normal window) becomes
`confirm`. At most 15 items stay `safe`, because the Planner asks above 15. The smaller ones become
`confirm` with a note to run a second batch. So **`closeCommand` always runs without `--force-confirm`**.

`--min-mb N` drops candidates smaller than N MB, and tabs whose size is unknown.

The human output groups the items as SAFE / CONFIRM / KEEP, gives one reason line per item and the Planner's
freed estimate (shared renderers counted once), and prints two ready-to-run lines:

```
Close the safe ones:
  headroom close session:41194:1790590080 tab:812:1101014 …
Then, after checking:
  headroom close --force-confirm leftover:7164:1790613600 …
```

### `suggest --json`

```json
{
  "schema": 1,
  "generatedAt": "2026-09-30T17:51:31Z",
  "source": "rules",
  "suggestions": [
    { "id": "session:41194:1790590080", "verdict": "safe", "bytes": 422576128, "title": "map directions",
      "reason": "idle 30h, not busy, not on screen, no background processes; Undo resumes it in tmux" },
    { "id": "leftover:7164:1790613600", "verdict": "confirm", "bytes": 1258291200, "title": "tour landing",
      "reason": "leftover `bun run dev --port 3217` running 2d; its Claude session (pid 21630, “tour landing”) has ended; safe to stop, but it cannot be undone" }
  ],
  "safeBytes": 422576128,
  "closeCommand": "headroom close session:41194:1790590080",
  "confirmCommand": "headroom close --force-confirm leftover:7164:1790613600"
}
```

The suggestions are ordered `safe`, then `confirm`, then `keep`, each by `bytes` descending. `safeBytes` is the sum of the
safe items' `bytes`. It can be a little higher than the real freed amount when tabs share a renderer, and
`close --dry-run --json` gives the exact `plan.estimateBytes`. `closeCommand` is omitted when nothing is safe.
`confirmCommand` (`headroom close --force-confirm <confirm ids…>`) is omitted when nothing is `confirm`.
`notes` holds Claude's prose, and it is present only with `--ask`.
`chromeSource` is the Chrome data source of the snapshot. `skipped: [{kind, reason}]` lists kinds the rules
could not evaluate. Today that is `tab` when the tab list has no per-tab memory and no last-used times: the
AppleScript list (which the CLI always gets while the app is running, because the app holds the helper
connection) or no tab list at all. An empty `suggestions` list then says nothing about tabs.
`confirmCommand` never includes `--include-busy`: a session that became busy after `suggest` ran is refused.
A session's `reason` says `not on screen` when it runs in tmux or Rex, and `not in tmux or Rex` otherwise. A `safe`
session's reason ends with `Undo resumes it in tmux` or, for a session in Rex, `Undo resumes it in Rex`.

### `suggest --ask`

This sends the snapshot (`list --json`) and the rules result (`suggest --json`) to Claude Code in headless
mode, and prints Claude's advice. **It never closes anything.**

- The command is `claude -p --output-format text --tools "" --strict-mcp-config --no-session-persistence [--model M]`.
  The prompt goes in on stdin, and the working directory is a temp dir. Claude gets no tools and no MCP servers, and no session is saved.
- The prompt is fixed (`AskClaude.instructions` in `Ask.swift`). It asks for one fenced JSON block,
  `{"suggestions":[{"id","verdict","reason"}]}`, followed by at most 8 lines of prose.
- Context is sent with the prompt: idle times, bytes, last prompts, background bytes, tab titles and URLs, and for live
  sessions the git state (uncommitted tracked files and commits ahead; read-only, with a 2 s timeout each).
  Incognito tab titles are replaced by `(incognito tab)`, and incognito URLs are never in the snapshot.
- The default timeout is 90 s (`--timeout S`). On a timeout, a non-zero exit or an answer without valid JSON,
  the command exits 1 and prints the reason.

Headroom has the last word. Claude's answer is checked against the snapshot:

| Check | Result |
|---|---|
| The id is not in the snapshot, or is malformed | Dropped |
| The verdict is not `safe` / `confirm` / `keep` (any case) | Dropped |
| An id appears twice | The first entry is kept |
| A `locked` item gets any other verdict | Forced to `keep` |
| `safe` on an item the Planner wants confirmed | Changed to `confirm` |
| The whole `safe` set, planned as one close | The same batch check as the rules (window/all-windows/15-item cap) |
| `bytes` and `title` | Always taken from the snapshot, never from Claude |

Every change is listed under "Headroom checked Claude's answer" in the human output, and as
`[headroom] …` lines at the end of `notes` in `--json`. The output has `source: "claude"`.

## `close`

```
headroom close <ids…> [--dry-run] [--yes] [--force-confirm] [--keep-background] [--json]
```

It goes through the same `ActionExecutor.plan` → `execute` as the app, with every §7.4 safety check: revalidation of the pid and
start time, the signal allowlist, SIGTERM only, and no SIGKILL. The CLI is **all or nothing**:

1. If any id is locked (Chrome itself, a `proc:` row, the launcher, a changed pid) or not found, nothing is
   closed and the exit code is 2. Remove those ids and run the command again.
2. If any item would make the app show its confirm sheet (§7.3: busy, active in the last 10 min, visible
   tmux or Rex pane, not in tmux or Rex, background processes, no transcript, cwd missing, unregistered, audible,
   pinned, emptying a window of more than 5 tabs, closing every window, more than 15 items, any leftover), nothing
   is closed and the exit code is 2. The command prints each reason. `--force-confirm` accepts all of them, like
   the sheet's "Skip Busy", **except busy**: if a session is busy (mid-turn), nothing is closed and the exit code
   is 2, unless you also give `--include-busy` (the sheet's "Close All"). `suggest` never prints `--include-busy`.
3. The command prints the plan, with the same text as the sheet. Then:
   - `--yes`: it closes.
   - Without `--yes`, on a TTY: it asks `[y/N]`. Any answer except `y` or `yes` cancels (exit 2). After a `y`,
     the plan is made again from a fresh snapshot. If an id became locked or gone, or an item gained a confirm
     reason you did not see (for example the session became busy while the prompt waited), nothing is closed (exit 2).
   - Without `--yes` and without a TTY: it prints the plan and exits 2.
   - `--dry-run`: it runs the full pipeline without asking. Nothing is closed or signalled, and the journal logs the entries as `dryRun`.
     `HEADROOM_DRY_RUN=1` does the same, but it keeps the question, so the interaction is the same as a real run.
4. Sessions are closed with SIGTERM, and survivors are reported as "still running" (the app has Force Quit).
   Right before the SIGTERM, each session is checked again: one that became busy, visible or recently active
   since the plan is skipped (`changedSkipped`). A Rex pane that Headroom can no longer place counts as visible.
   The background processes of closed sessions are stopped too, unless you give `--keep-background`. A background
   process that could not be stopped is reported as an extra `results[]` entry (`proc:` id, `failed: …`).

Results go to the shared `actions.jsonl` (`source: "cli"`) and to the Recently Closed store (`closed.jsonl`),
so the app's Undo and ⌘Y see CLI closes. In dry run, Recently Closed is kept in memory only.

### `close --json`

```json
{
  "schema": 1, "command": "close", "status": "closed", "dryRun": true, "mock": true,
  "plan": {
    "items": [{ "id": "tab:812:1101014", "kind": "tab", "title": "Boston to Cambridge – Google Maps",
                "bytes": 404750336, "protection": "none", "reasons": [] }],
    "locked": [],
    "estimateBytes": 404750336, "estimateUnknownTabs": 0, "stopBackground": true, "backgroundCommands": []
  },
  "results": [{ "id": "tab:812:1101014", "outcome": "dryRun" }],
  "needsForce": [],
  "records": []
}
```

| Field | Values |
|---|---|
| `status` | `closed`, `partial` (exit 1), `refused` / `needsConfirmation` / `cancelled` (exit 2; `results` is empty) |
| `plan.locked[]` | `{id, reason: {code, text}, found}`. `found: false` means that the id is not in the current snapshot (`code: notFound`). |
| `plan.estimateUnknownTabs` | Tabs whose memory is unknown (AppleScript list, degraded helper join). `estimateBytes` does not include them, so it is a lower bound when this is > 0. |
| `results[].outcome` | `done`, `alreadyGone`, `changedSkipped` (the tab URL changed), `stayedOpen`, `stillAlive`, `dryRun`, `failed: <why>` |
| `records` | The `ClosedRecord`s written to Recently Closed. Pass `records[].id` to `headroom undo`. It is empty in dry run. |
| `message` | Present when the command did not run (the reason). |

With `--json` the command never prompts. Without `--yes` (or `--dry-run`) it returns `needsConfirmation` with exit 2.

## `undo`

```
headroom undo                 # the newest close batch that has something restorable (same as --last)
headroom undo <id>            # a record id, a unique prefix of at least 6 characters, a batch id,
                              # or an item id such as session:41194:1790590080 (its newest record)
headroom undo --list [--json] # Recently Closed (last 7 days), newest first
```

A tab is reopened with `sessions.restore` (history is kept), or by its URL. A session is resumed with `claude --resume <sid>`
in a new tmux window, or in a new Rex tab if it ran in Rex (an unsent draft is lost). A session that ran in neither
reopens in the tmux session `headroom`, or in the Rex session `headroom` when tmux is not installed and rex is.
Headroom never starts Rex: if Rex is not running, the outcome is
`failed: Rex is not running (open Rex, then Undo again)` and the record stays restorable. Other Rex outcomes:
`failed: rex is not installed (<path>)`, `failed: Rex could not open a tab in “<session>”`,
`failed: Rex could not create session “<session>”` and `failed: Rex opened a tab but could not type the resume command`.
When the Rex session was gone, Undo creates it and asks Rex.app to show it. If Rex.app cannot be asked (Remote
Control off, Rex.app not connected, or only another device's Rex connected), the outcome is still `done`, and
`undo` prints a note after the results: `Resumed in the new Rex session “<label>”; open it in Rex.` followed by the
reason (for example `Turn on Remote Control in Rex so Undo can switch sessions.`).
Leftovers cannot be undone: `undo` of a leftover alone exits 1 and prints the argv to restart it by hand. In a batch
that mixes restorable items and leftovers, the leftovers are reported with outcome `notUndoable` (and their `argv`),
and the status and exit code count only the restorable items.
A record that was already restored (by the app, Recently Closed or an earlier `undo`) is `failed: already restored`.
In dry run, session records still get the real refusals (still running, cwd missing). `undo --json` prints
`{schema, command: "undo", status: "restored"|"partial"|"nothing", dryRun, message?, results: [{recordId, itemId, kind, title, outcome, argv?}], notes?}`.
`notes` (additive, omitted when empty) holds the notes above, one string each.
`undo --list --json` prints `{schema, records: [ClosedRecord]}`. A session record has `tmuxSession` when the session
ran in tmux, or `rexSessionId` (the full Rex session id, `session:<uuid>`) and `rexSessionLabel` when it ran in Rex.
`rexSessionLabel` is omitted when the label was unknown. Records written before Rex support have no Rex keys.
`close --json` `records` have the same keys.

## Recipes for agents

```sh
headroom suggest --json | jq -r .closeCommand            # the safe batch, ready to run
headroom close --json --yes $(headroom suggest --json | jq -r '.suggestions[]|select(.verdict=="safe").id')
headroom close --dry-run --json leftover:7164:1790613600  # exit 2 + reasons: needs --force-confirm
headroom list --json --kind sessions | jq '.items[] | select(.idleSeconds > 7200) | .id'
headroom undo --last --json
```

## `selftest`

`headroom selftest [sys|ownership|claude|chrome]` (no group = all four; the app has the same `Headroom --selftest …`)
runs the read-only checks in `CoreSelfTest`, `ClaudeSelfTest` and `ChromeSelfTest`. The `sys`
group spawns and stops its own short-lived children only. `claude` runs `tmux list-panes` and `list-clients`, and,
when a Rex server runs, the read-only `rex ls`, `session inspect` and `whoami` (it never starts a Rex server). Its
`rex` check prints the server's version, API revision, and whether discovery was reachable and complete. It fails
when a session is in both tmux and Rex, and, when a claude runs in Rex, also when Rex discovery is incomplete or a
claude in Rex cannot be placed in its pane. With no claude in Rex, discovery is printed for information only.
`chrome` binds a scratch socket for its
round trip, reads Chrome with AppleScript only if Automation is already granted, and never prompts. The exit code is
0 when every check passes.
