# Headroom helper extension

An MV3 extension that tells Headroom which tab uses which Chrome process, so the app can show memory per tab.
It also closes, discards, activates and restores tabs for the app. Protocol: `docs/protocol.md`. Design:
`docs/SPEC.md` §2 and §4.2–4.3. Tests: `Tests/e2e-chrome/`.

| File | What |
|---|---|
| `manifest.json` | fixed `key`, so the id is always **`iocalbnflgmfkcdpjeobogdpgjdfkokp`** (`scripts/extension-id.sh`) |
| `sw.js` | the service worker (all of the logic) |

`scripts/build.sh` copies this folder (without `*.md`) into `Headroom.app/Contents/Resources/ChromeExtension/`.
The manifest declares no icon, so Chrome shows a letter tile.

## Permissions

`tabs`, `webNavigation` (frame → `processId`), `sessions` (Undo with history), `nativeMessaging`, `alarms`,
`storage`. There are **no host permissions and no content scripts**, so it cannot read page content, cookies
or history. It never uses the network. Its only peer is the native host `dev.adder.headroom` (`headroom-host`).

## Connection modes (`chrome.storage.local.mode`; the app changes it with `setMode`)

- **persistent** (default): `connectNative` at start-up, on `onStartup` and `onInstalled`. On disconnect it
  retries after 1, 2, 4 … 60 s. The host's 20 s ping keeps the worker alive. The 30 s alarm is a backstop.
- **on-demand**: only the 30 s alarm connects. The host exits at once when the app is not running, so the
  worker can go idle. Dirty-event listeners are added only while a port is open, so tab activity does not
  wake an idle worker.

## Behaviour worth knowing (verified in Chrome for Testing 151)

- `close`: the tab's current URL must equal the expected URL, else `changedSkipped`. Removes run in parallel,
  and each waits at most 1 s. A page that has had a user gesture and has a `beforeunload` handler shows
  "Leave site?", and `tabs.remove` does not resolve until the dialog is answered. That tab gets
  `failed:beforeunload`.
- `restore` ids come from `sessions.getRecentlyClosed`. Chrome reports `windowId: 0` there, and returns at most
  25 entries, so only the last 25 tabs of a large close can be restored with history.
- `sessions.restore` brings the tab back with its back/forward history. Without a sessionId, the tab is
  reopened with `tabs.create` (`via:"create"`, without history).
- `probeMark` is used only by `headroom-host --probe` (Spike S). The worker holds N MiB for a moment and then
  frees it at once with `ArrayBuffer.prototype.transfer(0)`.

## Loading it

- Real Chrome: `scripts/install.sh` copies it to `~/Library/Application Support/Headroom/ChromeExtension`. Load
  that folder at `chrome://extensions` → Developer mode → Load unpacked (see "First run" in the README).
  `docs/spike-s.md` describes the one-time probe run.
- Tests: `Tests/e2e-chrome/` runs it in Chrome for Testing with a scratch profile.
