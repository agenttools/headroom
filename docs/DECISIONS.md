# Design decisions

These decisions were made on 2026-09-30, after [SPEC.md](SPEC.md) was written. Where they differ from SPEC.md, they override it.

1. **Chrome:** helper extension + native-messaging host for per-tab memory, with the JXA/AppleScript fallback (SPEC §4 as written).
2. **Close flow:** undo-first. Close at once and show an Undo toast. Show the confirm sheet only for the risky triggers in SPEC §7.
3. **Lifecycle:** the app quits when its window closes. Resident mode is v1.1 and out of scope.
4. **Signing:** the user runs `scripts/make-signing-cert.sh` once, by hand. `build.sh` signs with "Headroom Local Signing" when it exists, and falls back to ad-hoc with a warning.
5. **CLI is in scope for v1** (moved up from SPEC's v1.1 list). See below.

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
