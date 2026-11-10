# Chrome for Testing end-to-end tests

These are not SwiftPM targets. They run the real `Extension/` and the real `headroom-host` in **Chrome for
Testing**, headless, with a scratch `--user-data-dir`. They never touch Google Chrome, its profile or its
`NativeMessagingHosts` folder. Chrome for Testing reads the host manifest from
`<user-data-dir>/NativeMessagingHosts/`, and the scripts write it there. They stop only the Chrome they
started: they check its pid and that its argv names the scratch profile.

```sh
swift build --scratch-path .build/e2e --product headroom-host

# Relay mode. The script is the app.sock server (the fake app), in <dir>/support/run.
bun Tests/e2e-chrome/run.ts   --host .build/e2e/debug/headroom-host --dir "$TMPDIR/headroom-e2e"
#   --skip-ondemand   skip the on-demand checks (they wait for the 30 s alarm, about 2 minutes)
#   --keepalive 600   also idle 600 s with no app traffic, then check that the same worker answers

# Probe mode (Spike S), without the app, like docs/spike-s.md.
bun Tests/e2e-chrome/probe.ts --host .build/e2e/debug/headroom-host --dir "$TMPDIR/headroom-probe" \
    [--snapshots 20 --interval 30 --duration 600]
```

The default Chrome for Testing is Playwright's
(`~/Library/Caches/ms-playwright/chromium-1234/…/Google Chrome for Testing`). Use `--cft <binary>` to choose
another. Each script prints PASS or FAIL for each check. It also writes `results.json` (run.ts) or `probe.log`
and `probe.log.summary.json` (probe.ts) in `--dir`, and exits with 1 when any check fails.

CDP (the `--remote-debugging-port` of this Chrome only) is used to open test tabs, click a page, and read
navigation history. It never attaches to the extension's service worker, because that would keep the
worker alive and make the keepalive test meaningless.
