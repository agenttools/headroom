# Spike S: check the helper in your real Chrome

**Who does this:** you, by hand. It is optional. No script or agent should do these steps for you: they touch your Chrome, its settings and its `NativeMessagingHosts` folder.
**Time:** about 15 minutes, of which 10 are waiting while you use Chrome as usual.
**Result:** confirms that per-tab memory works in your Chrome, and whether the helper's extension process stays under 40 MB (if not, on-demand mode suits you better). SPEC §2 and §10 give the reasons.

## What the probe does, and what it does not do

`headroom-host --probe` is the real native host in a read-only mode. Chrome starts it when the helper extension connects. For about 10 minutes it:

- logs the Chrome browser pid (`getppid()`), its version and that it is the main browser process;
- asks the extension for 20 tab snapshots, one every 30 s. It joins each frame's `processId` to the renderers' `--renderer-client-id`. This is how per-tab memory works;
- pings the extension every 20 s, to check that the MV3 service worker stays alive for 10 minutes;
- finds the helper's own extension process and measures its memory. To do this it asks the worker to hold 64 MiB for about 1.5 s, looks for the extension process that grew, and then frees the 64 MiB at once;
- writes a summary with the go/no-go decision.

It **never** closes, discards, reloads or activates a tab. It never connects to the Headroom app and never uses the network. It writes only two files: `probe.log` and `probe.log.summary.json`. The log contains counts and process ids only, never URLs or titles.

The extension has no host permissions and no content scripts, so it cannot read page content (see `Extension/manifest.json`).

## Steps

Run the commands in a terminal. The folder `/tmp/headroom-spike` is scratch; nothing else is written.

### 1. Build the host (about 1 minute)

```sh
cd path/to/headroom      # your clone of this repository
REPO="$PWD"              # step 2 uses it; run the steps in the same terminal
swift build -c release --product headroom-host --scratch-path .build/spike
.build/spike/release/headroom-host --version      # prints: headroom-host 0.1.0 (wire v1)
```

### 2. Make the wrapper script

Chrome starts a native host without arguments, so a two-line script adds `--probe` and the log path:

```sh
mkdir -p /tmp/headroom-spike
cat > /tmp/headroom-spike/headroom-host-probe.sh <<EOF
#!/bin/sh
exec "$REPO/.build/spike/release/headroom-host" --probe --log /tmp/headroom-spike/probe.log "\$@"
EOF
chmod 755 /tmp/headroom-spike/headroom-host-probe.sh
cat /tmp/headroom-spike/headroom-host-probe.sh     # check that the path in it is correct
```

### 3. Register the native host with Chrome (your step)

This writes one file into your Chrome's `NativeMessagingHosts` folder. Step 7 removes it or puts your own copy back.

**If you already ran `scripts/install.sh`:** this step overwrites the bridge file that points Chrome at the installed Headroom. Quit Headroom first, copy the existing file aside, and do not open Headroom again until step 7. At launch Headroom repairs a bridge file whose path is wrong, which points it back at the real host and stops the probe.

```sh
cp "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/dev.adder.headroom.json" /tmp/headroom-bridge-backup.json   # only if Headroom is installed
```

```sh
mkdir -p "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
cat > "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/dev.adder.headroom.json" <<'EOF'
{
  "name": "dev.adder.headroom",
  "description": "Headroom helper (Spike S probe)",
  "path": "/tmp/headroom-spike/headroom-host-probe.sh",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://iocalbnflgmfkcdpjeobogdpgjdfkokp/"]
}
EOF
```

The extension id `iocalbnflgmfkcdpjeobogdpgjdfkokp` comes from the fixed `key` in `Extension/manifest.json`. To check it, run `scripts/extension-id.sh`.

### 4. Load the extension (your step)

1. In Chrome, open `chrome://extensions`.
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and select the `Extension` folder in your clone of this repository.
4. Make sure that the card "Headroom helper 1.0.0" shows **ID: iocalbnflgmfkcdpjeobogdpgjdfkokp**. If the ID is different, stop: the `key` in `Extension/manifest.json` has changed, and the host registration from step 3 does not match.

The extension connects at once, and Chrome starts the probe.

If the Headroom helper is already loaded from your install, it has the same id: do not load a second copy. Click ↻ (reload) on its card instead, so it reconnects to the probe.

### 5. Watch and wait for 10 minutes

```sh
tail -f /tmp/headroom-spike/probe.log
```

In the first seconds you should see `hello`, `pong 1`, `snapshot 1/20` and `helper extension process is pid …`. After this, use Chrome as usual: open and close tabs, and leave some tabs in the background. **Do not quit Chrome, and do not reload or remove the extension for 10 minutes.** Quitting Chrome stops the probe, which then writes an INCOMPLETE summary.

After about 10 minutes the log shows a block like this:

```
==== SUMMARY (complete)
per-tab memory in v1: GO
default helper mode: persistent
worker stayed alive: yes
  - tab join rate: mean 100.0%, min 100.0% over 20 snapshots
  - worker: 600 s connected, 31/31 pongs, longest gap 20 s
  - helper extension process: 29.0 MB (limit 40 MB)
```

### 6. Collect the result

This command prints the summary file and the important log lines. Keep the output; attach it to a bug report if a check failed. It contains no URLs or titles:

```sh
cat /tmp/headroom-spike/probe.log.summary.json; grep -E "snapshot|helper|SUMMARY|unanswered|exiting" /tmp/headroom-spike/probe.log | tail -40
```

### 7. Clean up

The probe keeps running (and does nothing) until the extension or Chrome stops. To remove everything:

1. If you loaded the extension only for this check, click **Remove** on "Headroom helper" in `chrome://extensions`. If Headroom is installed, keep it loaded. You can also leave it loaded anyway: once the bridge file points at the real host (the next item, or `scripts/install.sh` later), the same extension id talks to Headroom. If you leave it loaded without a host, it retries the connection every 60 s and shows "Specified native messaging host not found" under **Errors**. This is harmless.
2. Undo the spike's host registration, then remove the scratch folder:
   - **If Headroom is installed:** put your backup from step 3 back. Without a backup, run `scripts/install.sh` again and answer yes only to step 3 (the bridge file).
     ```sh
     mv /tmp/headroom-bridge-backup.json "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/dev.adder.headroom.json"
     ```
   - **If Headroom is not installed:** remove the file. `scripts/install.sh` writes the real one later.
     ```sh
     rm "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/dev.adder.headroom.json"
     ```
   ```sh
   rm -r /tmp/headroom-spike
   ```

## How the result is decided

| Check | Pass rule | If it fails |
|---|---|---|
| Per-tab memory | Chrome shows at least one renderer with `--renderer-client-id`, **and** in every snapshot at least 80% of the tabs (not counting discarded ones) have their main frame's `processId` matched to a renderer (SPEC §4.4 degraded-mode rule) | Per-tab memory will be unreliable in your Chrome; use the AppleScript tab list instead (Automation ▸ Google Chrome) |
| Worker stays alive | The probe stays connected for 600 s, misses at most one pong, and no gap between pongs is more than 45 s | The 20 s ping does not keep the worker alive in your Chrome. Include the summary in a bug report |
| Default mode | The helper's extension process is 40 MB or less (median of the samples after the mark) | Above 40 MB: **on-demand** mode suits you better. The app has no switch for it yet; include the summary in a bug report |

## If something goes wrong

| What you see | Cause and fix |
|---|---|
| No `probe.log` after step 4 | Open `chrome://extensions` → Headroom helper → **Errors**. If it says "Specified native messaging host not found", the file from step 3 is missing or has bad JSON: check it with `plutil -lint <file>`. If it says "Access to the specified native messaging host is forbidden", the extension id is not `iocalbnflgmfkcdpjeobogdpgjdfkokp`. |
| "Native host has exited" under Errors, and the log stops at the header | The path in the wrapper script is wrong, or the binary is not built. Run the wrapper by hand: `/tmp/headroom-spike/headroom-host-probe.sh </dev/null`. It must write a header to the log and exit with "stdin closed". |
| `could not identify the helper's extension process` | Another extension process grew at the same moment. The summary then says "mode stays persistent until measured". Reload the extension once (`chrome://extensions` → ↻) to run the probe again; the log appends a new session. |
| `ping unanswered` lines | The worker was stopped. Note the time, and what you were doing in Chrome at that moment. |

## Measured in Chrome for Testing (for comparison)

The same probe with the same extension, run by `Tests/e2e-chrome/probe.ts` against Chrome for Testing 151 (headless, scratch profile, 5 test tabs, one with a cross-site iframe): join 100% in every snapshot, the helper's extension process was about 29 MB, and every ping was answered. To repeat the 10-minute keepalive check in Chrome for Testing, run `Tests/e2e-chrome/run.ts` with `--keepalive 600` (see `Tests/e2e-chrome/README.md`).
