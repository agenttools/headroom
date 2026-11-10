// End-to-end run of `headroom-host --probe` (Spike S) in Chrome for Testing. Not a SwiftPM target.
//
//   bun Tests/e2e-chrome/probe.ts --host .build/e2e/debug/headroom-host [--dir <scratch>] [--cft <binary>]
//                                 [--snapshots N] [--interval SEC] [--duration SEC]
//
// Starts its own headless Chrome for Testing with a scratch profile, the unpacked Extension/ and a
// native-messaging manifest (in <scratch>/profile/NativeMessagingHosts) that points at a wrapper script,
// exactly like docs/spike-s.md does for Google Chrome, except that here everything is scratch. A few test
// tabs are opened from the command line; there is no CDP connection at all, so nothing but the host's
// own pings keeps the extension's service worker alive. Waits for <scratch>/probe.log.summary.json,
// checks it, then stops the Chrome it started (SIGTERM to that pid, after checking its argv names the
// scratch profile) and checks that the probe host exits.

import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { resolve } from "path";

const argv = process.argv.slice(2);
const arg = (n: string, d?: string) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const REPO = resolve(import.meta.dir, "../..");
const HOST = resolve(arg("--host", `${REPO}/.build/e2e/debug/headroom-host`)!);
const DIR = resolve(arg("--dir", `${process.env.TMPDIR ?? "/tmp"}/headroom-probe-e2e-${Date.now()}`)!);
const CFT = arg("--cft", `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`)!;
const SNAPS = arg("--snapshots", "5")!, INTERVAL = arg("--interval", "3")!, DURATION = arg("--duration", "30")!;
const EXT = `${REPO}/Extension`, HOST_NAME = "dev.adder.headroom";
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
const ps = () => Bun.spawnSync(["ps", "-axo", "pid=,ppid=,args="]).stdout.toString().split("\n").filter(Boolean)
  .map(l => { const m = l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)!; return { pid: +m[1], ppid: +m[2], args: m[3] }; });

if (!DIR.includes("headroom")) { console.error("--dir must be a scratch directory"); process.exit(1); }
const PROFILE = `${DIR}/profile`, LOG = `${DIR}/probe.log`, WRAP = `${DIR}/headroom-host-probe.sh`;
rmSync(PROFILE, { recursive: true, force: true });
rmSync(LOG, { force: true }); rmSync(LOG + ".summary.json", { force: true });
mkdirSync(`${PROFILE}/NativeMessagingHosts`, { recursive: true });
writeFileSync(WRAP, `#!/bin/sh\nexec "${HOST}" --probe --log "${LOG}" --snapshots ${SNAPS} --interval ${INTERVAL} --duration ${DURATION} "$@"\n`);
chmodSync(WRAP, 0o755);
const key = JSON.parse(readFileSync(`${EXT}/manifest.json`, "utf8")).key as string;
const hex = new Bun.CryptoHasher("sha256").update(Buffer.from(key, "base64")).digest("hex").slice(0, 32);
const extId = [...hex].map(c => String.fromCharCode(97 + parseInt(c, 16))).join("");
writeFileSync(`${PROFILE}/NativeMessagingHosts/${HOST_NAME}.json`, JSON.stringify({
  name: HOST_NAME, description: "Headroom probe (e2e test)", path: WRAP, type: "stdio", allowed_origins: [`chrome-extension://${extId}/`] }, null, 2));

const big = `<script>window.x=[];for(let i=0;i<10;i++){const a=new Float64Array(1e6);a.fill(i);x.push(a)}</script>`;
const http = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch(req) {
  const u = new URL(req.url);
  const body = u.pathname === "/iframe" ? `<iframe src="http://localhost:${http.port}/frame"></iframe>` : u.pathname === "/big" ? big : u.pathname;
  return new Response(`<!doctype html><title>${u.pathname}</title>${body}`, { headers: { "content-type": "text/html" } });
} });
const O = `http://127.0.0.1:${http.port}`;
const chrome = Bun.spawn([CFT, `--user-data-dir=${PROFILE}`, `--load-extension=${EXT}`, `--disable-extensions-except=${EXT}`,
  "--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-sync", "--use-mock-keychain",
  "--remote-debugging-port=0", `${O}/big`], { stdout: "ignore", stderr: Bun.file(`${DIR}/chrome.log`) });
console.log(`Chrome for Testing pid ${chrome.pid}; probe log ${LOG}`);

// Headless takes one URL on the command line; open the other tabs over CDP, then disconnect.
// (CDP never attaches to the service worker, so it does not keep the worker alive.)
let pf: string | undefined;
for (let i = 0; i < 150 && !pf; i++) { await sleep(100); if (existsSync(`${PROFILE}/DevToolsActivePort`)) pf = readFileSync(`${PROFILE}/DevToolsActivePort`, "utf8"); }
if (pf) {
  const [port, path] = pf.trim().split("\n");
  const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`);
  await new Promise(r => ws.addEventListener("open", r, { once: true }));
  let id = 0;
  for (const url of [`${O}/iframe`, `${O}/a`, `${O}/b`, `http://localhost:${http.port}/c`]) ws.send(JSON.stringify({ id: ++id, method: "Target.createTarget", params: { url, background: true } }));
  await sleep(1000);
  ws.close();
}

const deadline = Date.now() + (Number(DURATION) + Number(SNAPS) * Number(INTERVAL) + 60) * 1000;
let summary: any = null;
while (Date.now() < deadline && !summary) {
  await sleep(1000);
  if (existsSync(LOG + ".summary.json")) summary = JSON.parse(readFileSync(LOG + ".summary.json", "utf8"));
}
const probeHost = ps().find(p => p.ppid === chrome.pid && p.args.includes("--probe"));
const me = ps().find(p => p.pid === chrome.pid);
if (me && me.args.includes(PROFILE)) chrome.kill("SIGTERM");
await sleep(3000);
const hostExited = !probeHost || !ps().some(p => p.pid === probeHost.pid);
http.stop(true);

const checks: [string, boolean, any][] = [
  ["summary written", !!summary, summary ? "" : "no summary before the deadline"],
  ["summary is complete", summary?.complete === true, summary?.elapsedSec],
  ["browserPid is the Chrome for Testing pid", summary?.browserPid === chrome.pid, { got: summary?.browserPid, spawned: chrome.pid }],
  [`${SNAPS} snapshots`, summary?.snapshots === Number(SNAPS), summary?.snapshots],
  ["tab join rate 100% in every snapshot", summary?.minTabJoinRate === 1, summary?.minTabJoinRate],
  ["helper extension process identified by the probeMark", Number.isInteger(summary?.helperPid), { helperPid: summary?.helperPid, helperMB: summary?.helperMB, baseline: summary?.helperBaselineMB }],
  ["every ping answered", summary && summary.pongs >= summary.pingsSent - 1, { pings: summary?.pingsSent, pongs: summary?.pongs, maxGap: summary?.maxPongGapSec }],
  ["verdict: per-tab memory GO", summary?.verdict?.perTabMemory === "go", summary?.verdict],
  ["verdict: worker stayed alive", summary?.verdict?.workerStayedAlive === true, ""],
  ["probe host exited after Chrome quit", hostExited, probeHost?.pid],
  ["log has no URLs", existsSync(LOG) && !readFileSync(LOG, "utf8").includes("http://"), ""],
];
let failed = 0;
for (const [n, ok, d] of checks) { if (!ok) failed++; console.log(`${ok ? "PASS" : "FAIL"}  ${n}  ${d === "" ? "" : JSON.stringify(d)}`); }
console.log(`\n${checks.length - failed}/${checks.length} passed; log ${LOG}`);
process.exit(failed ? 1 : 0);
