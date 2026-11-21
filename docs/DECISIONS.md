# Design decisions

These decisions were made on 2026-09-30 (item 6 on 2026-11-19, item 7 on 2026-11-20, items 8 and 9 on 2026-11-21), after [SPEC.md](SPEC.md) was written. Where they differ from SPEC.md, they override it.

1. **Chrome:** helper extension + native-messaging host for per-tab memory, with the JXA/AppleScript fallback (SPEC §4 as written).
2. **Close flow:** undo-first. Close at once and show an Undo toast. Show the confirm sheet only for the risky triggers in SPEC §7.
3. **Lifecycle:** the app quits when its window closes. Resident mode is v1.1 and out of scope.
4. **Signing:** the user runs `scripts/make-signing-cert.sh` once, by hand. `build.sh` signs with "Headroom Local Signing" when it exists, and falls back to ad-hoc with a warning.
5. **CLI is in scope for v1** (moved up from SPEC's v1.1 list). See below.
6. **Rex support** (decided 2026-11-19): sessions that run in Rex get the same depth as sessions in tmux (location, visibility, Peek, Jump, Undo), and tmux behaviour is unchanged. See below and SPEC §5.1.
7. **Docker insight** (decided 2026-11-20): Headroom shows Docker's memory and disk use, read-only. See below and SPEC §5.2.
8. **tmux Jump finds the Ghostty window by tty** (decided 2026-11-21): see below and SPEC §7.6.
9. **Releases** (decided 2026-11-21): a downloadable archive, signed with a Developer ID and notarized. `build.sh --release` adds the hardened runtime, which SPEC §8.2 excludes for local builds. See below.

## tmux Jump: the Ghostty window is found by tty

Jump to a session in tmux switched the tmux client but brought up the wrong Ghostty window. There were three causes, and each has its own fix.

- **The permission was never asked for.** The exact focus ran only when Automation ▸ Ghostty was already granted, and nothing ever asked. Now the app asks at the first Jump that needs it (`GhosttyDesktop(mayAsk: true)`, set only for the app's window). The CLI and the app's one-shot modes never ask.
- **The window was matched by title.** The title is the tmux window name. Two clients on one session share it, and it changes while Claude works, so a title read before the jump is often stale. Now the terminal is matched by the tmux client's tty (`client_tty` equals the `tty` of the Ghostty terminal, Ghostty 1.3 or later), which is exact and unique.
  - Rejected: a temporary unique title (it changes a global tmux option and makes every title flash), Accessibility (SPEC §8.5 says it is never used), and a Shortcuts shortcut built on Ghostty's App Intents (the user would have to install it).
- **Nothing told the user.** Every failure on the tmux path was silent. Now `jumpNote` returns a note for tmux as it does for Rex: the Ghostty window could not be focused (and why), tmux refused, or no client is attached and the attach command was copied.

Two smaller changes:

- The client that is switched is still the one already attached to the session (else the most active one). Without the permission, Headroom does not switch to "the client in the front window" instead: that would move a window away from its session, and the front window cannot be known without the permission.
- When tmux refuses the switch, the attach command is no longer copied (SPEC §7.6 step 5 is for "no client attached" only).

## CLI: `headroom`

A second SwiftPM executable product, `headroom`, built on the same providers (HeadroomCore/Claude/Chrome/Actions) as the app. No duplicated collection logic. It is installed by `install.sh` as a symlink at `~/bin/headroom`, so `~/bin` must be on your `PATH`.

Commands:

- `headroom list [--json] [--kind tabs|sessions|leftovers|all]`
  - Prints a snapshot: system memory (pressure, swap), Chrome tabs, Claude sessions and leftovers.
  - Every item has a stable id string, for example `tab:<browserPid>:<tabId>`, `session:<pid>:<startSec>` or `leftover:<pgid>:<startSec>`.
  - Each item includes: footprint bytes, title, url or cwd, idle or last-activity time, status, and the protection or reasons (§7).
  - Human output is a compact table. `--json` output is stable and documented in `docs/cli.md`, because agents consume it.
- `headroom suggest [--json] [--min-mb N] [--ask]`
  - **Default mode is rules-based, instant and free.** It ranks close candidates, gives each one a plain-English reason, and gives an estimate of bytes freed.
  - Rules (tunable constants in one file):
    - Claude sessions idle for more than 2 h, not busy, not the visible or current pane, and with no background dev servers → "safe";
    - leftovers → "safe, but always confirm";
    - Chrome tabs that are not active, not audible, not pinned, and heavy (at least 300 MB) or unused for more than 1 h;
    - never suggest locked items.
  - Output includes a ready-to-run `headroom close <ids…>` line.
  - `--ask` sends the JSON snapshot plus the rule results to `claude -p` in headless mode, using a fixed prompt. The prompt asks what is safe to close and why, with context such as git dirty state and last prompt. It prints Claude's answer. Claude must answer in JSON with ids, verdicts and reasons, which are validated against the snapshot, followed by prose. Default timeout is 90 s. It never closes anything itself.
- `headroom close <ids…> [--dry-run] [--yes] [--force-confirm]`
  - Uses the same Planner/CloseCoordinator/Signaller as the app, with every safety check.
  - Items that would need the confirm sheet in the app are **refused** unless `--force-confirm` is given. Locked items are always refused.
  - Without `--yes` on a TTY it prints the plan and asks y/N. Without a TTY and without `--yes` it prints the plan and exits with code 2.
  - Results go to the same `actions.jsonl` audit log and Recently Closed store, so the app's Undo and Recently Closed can see CLI closes.
- `headroom undo [--last | <record-id>]`: restores from Recently Closed (reopen tab / `claude --resume`).
- Exit codes: 0 = ok, 1 = error, 2 = needs confirmation or refused.
- `HEADROOM_DRY_RUN=1` is respected as in the app.

## Rex support

Rex is a terminal multiplexer: a session holds windows (tabs), and a window holds blocks (panes). Built against a Rex 0.1.0-preview.20 server, API revision 16. The details are in SPEC §5.1, §7.6 and §7.7.

- **Type shape: Rex sits beside tmux.**
  - `ClaudeSession` gains `rex: RexLoc?` next to `tmux: TmuxLoc?`. At most one of the two is set.
  - A general "location" type was rejected, because it would rename the `tmux` keys in `--dump-json` and `list --json`, which agents read.
  - Call sites use three helpers that treat both alike: `inMultiplexer`, `onScreen` and `placeLabel`.
  - Everything else is additive: `ClosedRecord.rexSessionId` and `rexSessionLabel`, `ListItem.rex`, the filter token `rex:`, the preset `rexSession`, `SysKit.parentPid` and `ActionExecutor.jumpNote` (both with default implementations).
  - The reason codes `visiblePane` and `notInTmux` keep their names and now cover Rex; only their texts changed.
- **Which multiplexer a session runs in: the nearest one, with no rex call.**
  - Headroom walks up the claude's ppid chain. A tmux pane or tmux process met first means tmux; a Rex server met first means Rex. So tmux inside a Rex pane stays tmux, and tmux attribution is unchanged.
  - Rex's root-owned `/usr/bin/login` sits between the server and the pane's shell, and the process scan cannot see it. `SysKit.parentPid` (`PROC_PIDT_SHORTBSDINFO`) reads its parent.
  - The pane comes from the claude's own `REX_BLOCK` and `REX_SESSION`, which the env filter now keeps. They are trusted only when the walk reached a Rex server first.
  - `rex ls` and one `rex session inspect` per session add only the layout and visibility. They run only when a claude is in Rex: at most 8 at a time, the sessions that hold a claude (their `REX_SESSION`) first, then the others, 64 in all, with a 3 s deadline for the whole pass.
- **Visible, and no "current".**
  - A Rex pane is visible when a client that may be showing its session is attached (any client except `cli` and `agent` ones), its tab is the session's active tab, and it is drawn (not minimized, not hidden by a zoomed pane).
  - Rex reports no client activity and no "session the app is showing", so there is no "current". Every drawn pane in the active tab of every attached session counts as visible. This only adds confirmations.
  - Unknown means protected: a claude in Rex whose pane Headroom cannot place (discovery failed or timed out, another Rex server) counts as visible. Closing it asks first, `suggest` skips it, and the check right before SIGTERM treats it the same way. Viewer state Headroom cannot read (an unknown active tab, a client of an unknown kind or without an id) also counts as visible, so a newer Rex that reports these differently fails closed.
- **Jump and Undo.**
  - Jump: `rex focus` on the server, then Rex.app is brought forward with `open -b` (no Automation permission), then `rex do session.select` asks the app to show the session. That last step is a Rex client action and needs Remote Control, which is off by default. It goes to a connected local app client, else to rex's default client, and is skipped when only another device's app is connected (it would switch that device). When it fails, Jump returns a note that the app shows as a toast; the note gives rex's reason (for example, Rex.app not connected yet) and names Remote Control only when rex says nothing more specific.
  - Undo: a new tab in the recorded Rex session (by id, else by label, else a new session) with `--focus=false`, then `send` `claude --resume <sid>` and `send-key enter`. A `window new` or `new` that failed or timed out may still have worked, so Undo compares before and after and adopts the new tab instead of opening a second one. A new session is shown as in Jump; when Rex.app cannot be asked to show it, Undo still reports `done` and its toast (and `headroom undo`) names the new session to open.
  - Headroom never starts a Rex server: every call passes `--autostart=false`. Undo while Rex is down fails with a clear message, and the record stays restorable.
- **What Rex cannot do yet.**
  - No "current" (above).
  - Several Rex.app windows, or a torn-off tab, can show a tab other than the session's active one. Headroom does not detect this, so such a pane can show as not visible. Checking it needs a mutating Rex action; this is a documented gap.
  - Jump into another Rex session needs Remote Control in Rex.
  - No title from Rex pane titles (one call per pane would be needed).
  - Only the user's own Rex server is read. A claude in a pane of another Rex server is unplaced, and therefore protected.
  - Only the read-only Rex calls were run against a real server. The mutating calls (`focus`, `do`, `window new`, `new`, `send`, `send-key`) were tested against a fake `rex` only.
  - No minimum Rex API revision is enforced. Parsing is lenient, and `selftest claude` prints the version and revision.
- **Test isolation: tests never reach the user's Rex server.**
  - Default `swift test` uses `RexStub` (a fake `rex` script that logs its calls), hand-written JSON fixtures and the pure process walk. Claude tests get Rex state from a test seam and set `HEADROOM_REX` to `RexStub` or `/nonexistent/rex`.
  - Every rex call passes `--autostart=false` and an explicit `--timeout`, and removes every `REX_*` variable from the child's environment, because `swift test` itself may run inside a Rex pane. `rex server …` is refused unless `HEADROOM_REX_SERVER` names a private `unix:///` server.
  - The default binary falls back to the CLI in `/Applications` only when `HOME` is the account's real home, so a test with a fake `HOME` finds no binary.
  - The round trip against a real Rex binary is opt-in (`HEADROOM_REX_LIVE_TEST=1`). It starts its own private server and makes no mutating call until `whoami` reports that server's pid.
- **Compatibility.** Records in `closed.jsonl` written before Rex support still decode. An older Headroom ignores the new Rex keys and reopens a Rex session in the tmux session `headroom`; this is accepted. The `ClaudeGrouping` raw values and the "not in either" group id (`tmux:`) are unchanged, so saved list options and expanded rows survive.

## Docker insight

- **Read-only.** Docker rows cannot be selected or closed. Stopping a container frees memory inside the VM, but
  the VM does not always return it to macOS, so "close to free memory" would promise something Headroom cannot
  deliver. The honest number is the VM's footprint on the Mac, and that is what the section shows.
- **The engine's socket, not the `docker` CLI.** An app opened from Finder has no `PATH`, and `docker stats` waits
  a second or more per call. The Engine API over the unix socket (HTTP/1.0, `GET` only) answers in milliseconds:
  one list, one `/info`, and one one-shot stats call per container.
- **Never on the refresh path.** A snapshot uses the last background read. Disk use (`/system/df`) takes tens of
  seconds, so it has its own 15-minute cadence and is saved on disk.
- **The VM is identified, not guessed.** For colima and lima it is the VM process that shares the Lima host
  agent's responsible process (`responsibility_get_pid_responsible_for_pid`, looked up at run time). When that
  fails and more than one VM runs, the VM stays unidentified and the section shows the containers' sum instead.
  The rules for Docker Desktop and OrbStack come from their process names and were not run against those apps.
- **Not done:** stopping or restarting containers, pruning, remote engines (`tcp://`, `ssh://`), and more than one
  engine at a time.

## Releases

- **Two ways to sign.** A local build is unchanged: "Headroom Local Signing" or ad-hoc, no hardened runtime, no
  timestamp (item 4, SPEC §8.2). `build.sh --release` signs with a "Developer ID Application" identity, the
  hardened runtime and a secure timestamp, because Apple's notary service accepts nothing less.
- **One entitlement.** Under the hardened runtime, the app and the CLI get `com.apple.security.automation.apple-events`
  (`scripts/release.entitlements`), so that macOS can ask about Chrome and Ghostty. The host sends no Apple events
  and gets none. There is still no sandbox.
- **A zip with the installer, not a bare app.** Headroom needs more than the bundle: the extension folder, the
  Chrome bridge file and the CLI link. The archive holds `Headroom.app` next to the same `install.sh` and
  `uninstall.sh` as the repository, and `install.sh` finds the app there. One procedure serves both ways to get the app.
  - Rejected: a `.dmg` to drag into `/Applications` (the app repairs the bridge file only when it runs from
    `~/Applications/Headroom.app`, and nothing would link the CLI), and a `.pkg` (it installs as root for all users;
    everything Headroom writes is under `$HOME`).
- **`package.sh` never publishes.** It builds, notarizes, staples, zips and checks the archive. The tag and the
  GitHub release are made by hand, so a release is always a decision.
- **A release and a local build are two apps to macOS.** Their designated requirements differ, so the Automation
  grants do not carry over. All releases share one Developer ID, so grants carry over from release to release.
