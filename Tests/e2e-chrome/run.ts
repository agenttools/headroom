// End-to-end test of Extension/ + headroom-host in Chrome for Testing. Not a SwiftPM target.
//
//   bun Tests/e2e-chrome/run.ts --host .build/e2e/debug/headroom-host [--dir <scratch>] [--cft <Chrome for Testing binary>]
//                               [--keepalive <sec>] [--skip-ondemand]
//
// This script plays the Headroom app: it is the app.sock server (in <scratch>/support/run, mode 0700)
// and talks wire v1 (docs/protocol.md). It starts its OWN Chrome for Testing, headless, with a scratch
// --user-data-dir under <scratch>, the unpacked Extension/ loaded, and a native-messaging manifest in
// <scratch>/profile/NativeMessagingHosts (Chrome reads <user-data-dir>/NativeMessagingHosts). Chrome
// inherits HEADROOM_SUPPORT_DIR=<scratch>/support, so the host it starts connects to this script.
// It never touches Google Chrome, its profile or its NativeMessagingHosts. At the end it closes only
// the Chrome it started (Browser.close over CDP, then SIGTERM to that one pid if it is still there).
//
// CDP (the browser's --remote-debugging-port) is used only to open test tabs and to read navigation
// history; it never attaches to the extension's service worker, so it does not keep the worker alive.

import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { resolve } from "path";

// ------------------------------------------------------------------ args

const argv = process.argv.slice(2);
const arg = (n: string, d?: string) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const REPO = resolve(import.meta.dir, "../..");
const HOST = resolve(arg("--host", `${REPO}/.build/e2e/debug/headroom-host`)!);
const DIR = resolve(arg("--dir", `${process.env.TMPDIR ?? "/tmp"}/headroom-e2e-${Date.now()}`)!);
const CFT = arg("--cft", `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`)!;
const KEEPALIVE = Number(arg("--keepalive", "0"));
const SKIP_ONDEMAND = argv.includes("--skip-ondemand");
const ONDEMAND_IDLE = Number(arg("--ondemand-idle", "40")); // seconds with no app in on-demand mode
const EXT = `${REPO}/Extension`;
const HOST_NAME = "dev.adder.headroom";

const results: { name: string; ok: boolean; detail: any }[] = [];
function check(name: string, ok: boolean, detail: any = "") {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail !== "" ? "  " + (typeof detail === "string" ? detail : JSON.stringify(detail)) : ""}`);
}
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
async function until<T>(f: () => T | undefined | Promise<T | undefined>, ms: number, step = 100): Promise<T | undefined> {
  const end = Date.now() + ms;
  while (Date.now() < end) { const v = await f(); if (v) return v; await sleep(step); }
  return undefined;
}

// ------------------------------------------------------------------ scratch world

if (!existsSync(HOST)) { console.error(`no host binary at ${HOST}; build it first`); process.exit(1); }
if (!existsSync(CFT)) { console.error(`no Chrome for Testing at ${CFT}`); process.exit(1); }
if (!DIR.includes("headroom")) { console.error("--dir must be a scratch directory"); process.exit(1); }
const PROFILE = `${DIR}/profile`, SUPPORT = `${DIR}/support`, RUN = `${SUPPORT}/run`;
rmSync(PROFILE, { recursive: true, force: true });
mkdirSync(`${PROFILE}/NativeMessagingHosts`, { recursive: true });
mkdirSync(RUN, { recursive: true });
chmodSync(RUN, 0o700);
const keyB64 = JSON.parse(readFileSync(`${EXT}/manifest.json`, "utf8")).key as string;
const extId = await (async () => {
  const der = Buffer.from(keyB64, "base64");
  const h = new Bun.CryptoHasher("sha256").update(der).digest("hex").slice(0, 32);
  return [...h].map(c => String.fromCharCode("a".charCodeAt(0) + parseInt(c, 16))).join("");
})();
writeFileSync(`${PROFILE}/NativeMessagingHosts/${HOST_NAME}.json`, JSON.stringify({
  name: HOST_NAME, description: "Headroom helper (e2e test)", path: HOST, type: "stdio",
  allowed_origins: [`chrome-extension://${extId}/`],
}, null, 2));

// ------------------------------------------------------------------ test pages

const big = `<script>window.x=[];for(let i=0;i<40;i++){const a=new Float64Array(1e6);a.fill(i);x.push(a)}</script>`;
const http = Bun.serve({
  port: 0, hostname: "127.0.0.1",
  fetch(req) {
    const u = new URL(req.url);
    const html = (b: string) => new Response(`<!doctype html>${b}`, { headers: { "content-type": "text/html" } });
    switch (u.pathname) {
      case "/big": return html(`<title>big</title>320 MB ${big}`);
      case "/iframe": return html(`<title>iframe host</title><iframe src="http://localhost:${http.port}/frame"></iframe>`);
      case "/frame": return html(`<title>frame</title>cross-site frame`);
      case "/h1": return html(`<title>h1</title>history 1`);
      case "/h2": return html(`<title>h2</title>history 2`);
      case "/unload": return html(`<title>unload</title><script>addEventListener('beforeunload',e=>{e.preventDefault();e.returnValue='x'})</script>`);
      default: return html(`<title>${u.pathname}</title>${u.pathname}`);
    }
  },
});
const ORIGIN = `http://127.0.0.1:${http.port}`;

// ------------------------------------------------------------------ app.sock server (the fake app)

type Conn = { sock: any; buf: string; lines: any[]; closed: boolean; id: number; out: Buffer[] };
const conns: Conn[] = [];
let connSeq = 0;
function startListener() {
  process.chdir(RUN); // listen relative to RUN: the absolute path is longer than sun_path allows
  try { rmSync("app.sock", { force: true }); } catch {}
  const l = Bun.listen<{ c: Conn }>({
    unix: "app.sock",
    socket: {
      open(s) { const c = { sock: s, buf: "", lines: [], closed: false, id: ++connSeq, out: [] }; s.data = { c }; conns.push(c); },
      drain(s) { flush(s.data.c); },
      data(s, d) {
        const c = s.data.c;
        c.buf += d.toString();
        let i;
        while ((i = c.buf.indexOf("\n")) >= 0) {
          const line = c.buf.slice(0, i); c.buf = c.buf.slice(i + 1);
          if (!line.trim()) continue;
          try { c.lines.push(JSON.parse(line)); } catch { c.lines.push({ t: "__unparseable", line }); }
        }
      },
      close(s) { s.data.c.closed = true; },
      error(s) { s.data.c.closed = true; },
    },
  });
  process.chdir(REPO);
  return l;
}
let listener = startListener();
const live = () => conns.filter(c => !c.closed);
let reqSeq = 100;
// Bun's socket.write may write only part of a large buffer; keep the rest and finish on drain.
function flush(c: Conn) {
  while (c.out.length && !c.closed) {
    const b = c.out[0];
    const n = c.sock.write(b);
    if (n < 0) return;
    if (n < b.length) { c.out[0] = b.subarray(n); return; }
    c.out.shift();
  }
}
function send(c: Conn, o: any) { c.out.push(Buffer.from(JSON.stringify(o) + "\n")); if (c.out.length === 1) flush(c); }
async function request(c: Conn, o: any, ms = 5000): Promise<any> {
  const req = ++reqSeq;
  const from = c.lines.length;
  send(c, { ...o, req });
  return until(() => c.lines.slice(from).find(l => l.req === req), ms, 20);
}
async function nextConn(after: number, ms: number) { return until(() => conns.find(c => c.id > after && c.lines.length >= 2), ms); }

// ------------------------------------------------------------------ Chrome for Testing

function psTable() {
  const out = Bun.spawnSync(["ps", "-axo", "pid=,ppid=,args="]).stdout.toString();
  return out.split("\n").filter(Boolean).map(l => {
    const m = l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)!;
    return { pid: +m[1], ppid: +m[2], args: m[3] };
  });
}
function descendants(root: number) {
  const t = psTable(), out: typeof t = [];
  let frontier = [root];
  while (frontier.length) {
    const next = t.filter(p => frontier.includes(p.ppid));
    out.push(...next); frontier = next.map(p => p.pid);
  }
  return out;
}
function footprintMB(pid: number): number | null {
  const o = Bun.spawnSync(["footprint", "-f", "bytes", "--noCategories", "-p", String(pid)]).stdout.toString();
  const m = o.match(/Footprint:\s+(\d+)\s*B/);
  return m ? +m[1] / 1048576 : null;
}
const alive = (pid: number) => psTable().some(p => p.pid === pid);

const chrome = Bun.spawn([CFT,
  `--user-data-dir=${PROFILE}`, `--load-extension=${EXT}`, `--disable-extensions-except=${EXT}`,
  "--headless=new", "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check",
  "--disable-sync", "--disable-background-networking", "--use-mock-keychain", "about:blank",
], { env: { ...process.env, HEADROOM_SUPPORT_DIR: SUPPORT }, stdout: "ignore", stderr: Bun.file(`${DIR}/chrome.log`) });
const BROWSER = chrome.pid;
console.log(`Chrome for Testing pid ${BROWSER}, profile ${PROFILE}, extension id ${extId}`);

let cleaned = false;
async function cleanup() {
  if (cleaned) return; cleaned = true;
  try { await cdp("Browser.close"); } catch {}
  await until(() => !alive(BROWSER) || undefined, 5000);
  if (alive(BROWSER)) {
    // Only the Chrome this script started: same pid, and its argv names our scratch profile.
    const p = psTable().find(p => p.pid === BROWSER);
    if (p && p.args.includes(PROFILE)) chrome.kill("SIGTERM");
  }
  http.stop(true);
  listener.stop(true);
}

// ------------------------------------------------------------------ CDP (browser endpoint only)

const portFile = await until(() => existsSync(`${PROFILE}/DevToolsActivePort`) ? readFileSync(`${PROFILE}/DevToolsActivePort`, "utf8") : undefined, 15000);
if (!portFile) { console.error("Chrome did not start"); await cleanup(); process.exit(1); }
const [cdpPort, cdpPath] = portFile.trim().split("\n");
const ws = new WebSocket(`ws://127.0.0.1:${cdpPort}${cdpPath}`);
await new Promise(r => ws.addEventListener("open", r, { once: true }));
let cdpSeq = 0;
const cdpWait = new Map<number, (v: any) => void>();
ws.addEventListener("message", e => { const m = JSON.parse(String(e.data)); if (m.id && cdpWait.has(m.id)) { cdpWait.get(m.id)!(m); cdpWait.delete(m.id); } });
function cdp(method: string, params: any = {}, sessionId?: string): Promise<any> {
  const id = ++cdpSeq;
  ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  return new Promise((res, rej) => { cdpWait.set(id, m => m.error ? rej(new Error(m.error.message)) : res(m.result)); setTimeout(() => rej(new Error(`cdp timeout ${method}`)), 10000); });
}
async function openTab(url: string) { return (await cdp("Target.createTarget", { url, background: true })).targetId as string; }
async function pageTargets() { return (await cdp("Target.getTargets")).targetInfos.filter((t: any) => t.type === "page"); }
async function swTargets() { return (await cdp("Target.getTargets")).targetInfos.filter((t: any) => t.type === "service_worker" && t.url.includes(extId)); }

// ------------------------------------------------------------------ the tests

try {
  // 1. Chrome starts the host, the host connects, host line first, then the cached hello.
  const c1 = await until(() => conns.find(c => c.lines.length >= 2), 20000);
  check("host connected to app.sock (relative path, 0700 run dir)", !!c1, c1 ? `connection ${c1.id}` : "no connection in 20 s");
  if (!c1) throw new Error("no host");
  const hostLine = c1.lines[0], hello = c1.lines[1];
  check("first line is the host line", hostLine.t === "host" && hostLine.v === 1, hostLine);
  check("host line browserPid == the Chrome for Testing browser pid", hostLine.browserPid === BROWSER, { browserPid: hostLine.browserPid, spawned: BROWSER });
  const hostPid = hostLine.hostPid;
  const hostProc = psTable().find(p => p.pid === hostPid);
  check("host process is a child of the browser and got the origin argument",
    !!hostProc && hostProc.ppid === BROWSER && hostProc.args.includes(`chrome-extension://${extId}/`), hostProc?.args);
  check("second line is the extension hello (persistent)", hello.t === "hello" && hello.v === 1 && hello.mode === "persistent" && typeof hello.install === "string", hello);
  const swStart = hello.swStart;
  check("extension loaded with the fixed id from the manifest key", (await swTargets()).length === 1, extId);

  // 2. Test tabs.
  const bigT = await openTab(`${ORIGIN}/big`);
  await openTab(`${ORIGIN}/iframe`);
  await openTab(`${ORIGIN}/b`);
  await openTab(`${ORIGIN}/b?same-site-2`);
  const hT = await openTab(`${ORIGIN}/h1`);
  await openTab(`${ORIGIN}/unload`);
  await openTab(`${ORIGIN}/victim`);
  await openTab(`${ORIGIN}/discard-me`);
  await sleep(2500);
  const hs = (await cdp("Target.attachToTarget", { targetId: hT, flatten: true })).sessionId;
  await cdp("Page.enable", {}, hs);
  await cdp("Page.navigate", { url: `${ORIGIN}/h2` }, hs);
  await sleep(1500);
  await cdp("Target.detachFromTarget", { sessionId: hs });
  const dirty = c1.lines.filter(l => l.t === "dirty").length;
  check("dirty messages arrive (debounced) while tabs open and navigate", dirty >= 1, `${dirty} dirty lines`);

  // 3. Snapshot and the processId ↔ --renderer-client-id join.
  const snap = await request(c1, { t: "snapshot" });
  check("snapshot reply", !!snap && Array.isArray(snap.tabs) && Array.isArray(snap.windows), snap ? `${snap.tabs.length} tabs, ${snap.windows.length} windows` : "timeout");
  const kids = descendants(BROWSER);
  const clientMap = new Map<number, { pid: number; args: string }>();
  for (const k of kids) {
    const m = k.args.match(/--renderer-client-id=(\d+)/);
    if (k.args.includes("--type=renderer") && m && !k.args.includes("--extension-process")) clientMap.set(+m[1], k);
  }
  const frames = snap.tabs.flatMap((t: any) => t.frames.map((f: any) => ({ tab: t, f }))).filter((x: any) => x.f.processId > 0);
  const joined = frames.filter((x: any) => clientMap.has(x.f.processId));
  check("every frame processId joins a --renderer-client-id renderer of this browser", frames.length > 0 && joined.length === frames.length,
    `${joined.length}/${frames.length} frames; client ids ${[...clientMap.keys()].sort((a, b) => a - b).join(",")}`);
  const ifr = snap.tabs.find((t: any) => t.url.endsWith("/iframe"));
  const ifrProcs = new Set(ifr?.frames.map((f: any) => f.processId));
  check("cross-site iframe reported as a second frame in another process", !!ifr && ifr.frames.length === 2 && ifrProcs.size === 2, ifr?.frames);
  const bigTab = snap.tabs.find((t: any) => t.url.endsWith("/big"));
  const bigProc = bigTab && clientMap.get(bigTab.frames[0].processId);
  const bigMB = bigProc ? footprintMB(bigProc.pid) : null;
  check("320 MB page: its joined renderer's footprint is about 330–350 MB", !!bigMB && bigMB > 320 && bigMB < 380, bigMB ? `${bigMB.toFixed(1)} MB (pid ${bigProc!.pid}, client id ${bigTab.frames[0].processId})` : "no renderer");
  const extRenderers = kids.filter(k => k.args.includes("--extension-process"));
  const extMB = extRenderers.map(k => ({ pid: k.pid, mb: footprintMB(k.pid) }));
  check("helper extension process footprint recorded", extRenderers.length >= 1, extMB);

  // 4. Framing round trip with messages larger than one pipe buffer, both directions.
  for (let i = 0; i < 40; i++) await openTab(`${ORIGIN}/long?${"p".repeat(4000)}${i}`);
  await sleep(2500);
  const bigSnap = await request(c1, { t: "snapshot" }, 10000);
  const bigBytes = bigSnap ? JSON.stringify(bigSnap).length : 0;
  check("extension→host→app: a >150 KB snapshot arrives whole", bigBytes > 150_000 && bigSnap.tabs.length >= 48, `${bigBytes} bytes, ${bigSnap?.tabs.length} tabs`);
  const padReply = await request(c1, { t: "activate", tabId: bigTab.id, windowId: bigTab.windowId, pad: "z".repeat(600_000) });
  check("app→host→extension: a 600 KB request is framed and answered", padReply?.results?.[bigTab.id] === "done", padReply);
  const tooBig = await request(c1, { t: "activate", tabId: bigTab.id, windowId: bigTab.windowId, pad: "z".repeat(1_100_000) }, 3000);
  check("a request over Chrome's 1 MB limit is dropped by the host, not sent (no reply, host alive)", !tooBig && alive(hostPid) && !c1.closed);
  const longs = bigSnap.tabs.filter((t: any) => t.url.includes("/long?"));
  const closeLongs = await request(c1, { t: "close", tabs: longs.map((t: any) => ({ id: t.id, url: t.url })) }, 15000);
  check("close 40 tabs in one request", !!closeLongs && longs.every((t: any) => closeLongs.results[t.id] === "done"), closeLongs ? `${Object.values(closeLongs.results).filter(v => v === "done").length} done, ${Object.keys(closeLongs.restore ?? {}).length} with a sessionId (getRecentlyClosed returns at most 25)` : "timeout");

  // 5. Close with a changed URL → changedSkipped; with the right URL → done + restore sessionId.
  const victim = snap.tabs.find((t: any) => t.url.endsWith("/victim"));
  const skipped = await request(c1, { t: "close", tabs: [{ id: victim.id, url: victim.url + "#changed" }] });
  check("close with a changed URL returns changedSkipped (tab stays open)", skipped?.results?.[victim.id] === "changedSkipped" && (await pageTargets()).some((t: any) => t.url.endsWith("/victim")), skipped);
  const gone = await request(c1, { t: "close", tabs: [{ id: 987654, url: "x" }] });
  check("close of an unknown tab returns gone", gone?.results?.["987654"] === "gone", gone);

  const snap2 = await request(c1, { t: "snapshot" });
  const h2 = snap2.tabs.find((t: any) => t.url.endsWith("/h2"));
  const closed = await request(c1, { t: "close", tabs: [{ id: h2.id, url: h2.url }] });
  const sid = closed?.restore?.[h2.id];
  check("close with the right URL returns done and a sessions sessionId", closed?.results?.[h2.id] === "done" && typeof sid === "string", closed);

  // 6. Restore keeps history (sessions.restore), and falls back to tabs.create.
  const restored = await request(c1, { t: "restore", items: [{ sessionId: sid, url: h2.url, windowId: h2.windowId, index: h2.index }] });
  const r0 = restored?.restored?.[0];
  check("restore via sessions.restore", r0?.via === "sessions" && Number.isInteger(r0.newTabId), restored);
  await sleep(1000);
  const rt = (await pageTargets()).find((t: any) => t.url.endsWith("/h2"));
  let hist: any = null;
  if (rt) {
    const s = (await cdp("Target.attachToTarget", { targetId: rt.targetId, flatten: true })).sessionId;
    hist = await cdp("Page.getNavigationHistory", {}, s);
    await cdp("Target.detachFromTarget", { sessionId: s });
  }
  const urls = hist?.entries?.map((e: any) => new URL(e.url).pathname) ?? [];
  check("restored tab keeps its back history (h1 → h2)", urls.join(",") === "/h1,/h2" && hist.currentIndex === 1, { entries: urls, currentIndex: hist?.currentIndex });
  const fb = await request(c1, { t: "restore", items: [{ sessionId: "no-such-session", url: `${ORIGIN}/fallback`, windowId: h2.windowId, index: 0 }] });
  check("restore with a bad sessionId falls back to tabs.create", fb?.restored?.[0]?.via === "create" && Number.isInteger(fb.restored[0].newTabId), fb);
  const fb2 = await request(c1, { t: "restore", items: [{ url: `${ORIGIN}/fallback2`, windowId: 999999 }] });
  check("restore into a window that is gone opens in the current window", fb2?.restored?.[0]?.via === "create", fb2);

  // 7. Discard: a background tab, then the active tab.
  const dt = snap.tabs.find((t: any) => t.url.endsWith("/discard-me"));
  const disc = await request(c1, { t: "discard", tabIds: [dt.id] });
  const snap3 = await request(c1, { t: "snapshot" });
  const dt3 = snap3.tabs.find((t: any) => t.id === dt.id || (disc?.replaced && t.id === disc.replaced[dt.id]));
  check("discard of a background tab works (discarded, frames [])", disc?.results?.[dt.id] === "done" && dt3?.discarded === true && dt3.frames.length === 0, { disc, after: dt3 && { discarded: dt3.discarded, frames: dt3.frames } });
  const active = snap3.tabs.find((t: any) => t.active && !t.discarded);
  const discA = await request(c1, { t: "discard", tabIds: [active.id] });
  check("discard of the active tab: result recorded", !!discA, discA?.results);

  // 8. beforeunload: tabs.remove on a page with a beforeunload handler (no user gesture).
  const ut = snap3.tabs.find((t: any) => t.url.endsWith("/unload"));
  const uc = await request(c1, { t: "close", tabs: [{ id: ut.id, url: ut.url }] });
  await sleep(1000);
  const stillThere = (await pageTargets()).some((t: any) => t.url.endsWith("/unload"));
  check("beforeunload page, no user gesture: tabs.remove closes it", uc?.results?.[ut.id] === "done" && !stillThere, { result: uc?.results?.[ut.id], stillOpenAfter1s: stillThere });
  // Same page after a click (sticky user activation), which is when Chrome shows the "Leave site?" dialog.
  const u2 = await openTab(`${ORIGIN}/unload?gesture`);
  await sleep(1500);
  const us = (await cdp("Target.attachToTarget", { targetId: u2, flatten: true })).sessionId;
  await cdp("Page.enable", {}, us);
  let dialog: any = null;
  const onDialog = (e: MessageEvent) => { const m = JSON.parse(String(e.data)); if (m.method === "Page.javascriptDialogOpening" && m.sessionId === us) dialog = m.params; };
  ws.addEventListener("message", onDialog);
  for (const type of ["mousePressed", "mouseReleased"]) await cdp("Input.dispatchMouseEvent", { type, x: 20, y: 20, button: "left", clickCount: 1 }, us);
  await sleep(300);
  const snapU = await request(c1, { t: "snapshot" });
  const ug = snapU.tabs.find((t: any) => t.url.endsWith("/unload?gesture"));
  const ugc = await request(c1, { t: "close", tabs: [{ id: ug.id, url: ug.url }] });
  await sleep(1500);
  const ugOpen = (await pageTargets()).some((t: any) => t.url.endsWith("/unload?gesture"));
  if (dialog) await cdp("Page.handleJavaScriptDialog", { accept: true }, us).catch(() => {});
  ws.removeEventListener("message", onDialog);
  await sleep(500);
  const ugOpenAfter = (await pageTargets()).some((t: any) => t.url.endsWith("/unload?gesture"));
  check("beforeunload page after a click: dialog shown, reply in time with failed:beforeunload", ugc?.results?.[ug.id] === "failed:beforeunload" && !!dialog && ugOpen && !ugOpenAfter,
    { result: ugc?.results?.[ug.id], dialogShown: !!dialog, dialogType: dialog?.type, stillOpenAfter1_5s: ugOpen, openAfterAcceptingDialog: ugOpenAfter });

  // 9. Unknown message types are ignored; the ping is not forwarded to the app.
  send(c1, { t: "noSuchThing", req: 5 });
  await sleep(300);
  check("host never forwards ping/pong to the app", !c1.lines.some(l => l.t === "ping" || l.t === "pong"));

  // 10. Persistent mode: app drops the connection → host stays and reconnects within ~2 s.
  const before = connSeq;
  c1.sock.end();
  const c2 = await nextConn(before, 6000);
  check("persistent: host stays alive and reconnects after the app disconnects", !!c2 && c2.lines[0].hostPid === hostPid && alive(hostPid),
    c2 ? { hostPid: c2.lines[0].hostPid, replayedHello: c2.lines[1]?.t } : "no reconnect");
  let cur = c2!;

  // 11. On-demand mode.
  if (!SKIP_ONDEMAND) {
    send(cur, { t: "setMode", mode: "on-demand" });
    await sleep(500);
    const b2 = connSeq;
    cur.sock.end();
    const exited = await until(() => !alive(hostPid) || undefined, 4000);
    check("on-demand: host exits when the app disconnects", !!exited);
    const t0 = Date.now();
    const c3 = await nextConn(b2, 45000);
    check("on-demand: the 30 s alarm reconnects (new host, hello mode on-demand)", !!c3 && c3.lines[0].hostPid !== hostPid && c3.lines[1]?.mode === "on-demand",
      c3 ? { after: `${((Date.now() - t0) / 1000).toFixed(1)} s`, hostPid: c3.lines[0].hostPid, hello: c3.lines[1] } : "no reconnect in 45 s");
    // App absent: every alarm-started host must exit at once.
    listener.stop(true);
    rmSync(`${RUN}/app.sock`, { force: true });
    c3?.sock.end();
    const seen = new Set<number>(), lingering = new Set<number>();
    const tStart = Date.now(), tEnd = tStart + Math.max(40, ONDEMAND_IDLE) * 1000;
    const idleSamples: { t: number; sw: number; extProcs: number; extMB: number }[] = [];
    let lastSample = 0;
    while (Date.now() < tEnd) {
      for (const k of descendants(BROWSER).filter(k => k.args.startsWith(HOST))) {
        if (seen.has(k.pid)) lingering.add(k.pid); else seen.add(k.pid);
      }
      if (Date.now() - lastSample > 10000) {
        lastSample = Date.now();
        const ext = descendants(BROWSER).filter(k => k.args.includes("--extension-process"));
        idleSamples.push({ t: Math.round((Date.now() - tStart) / 1000), sw: (await swTargets()).length, extProcs: ext.length,
          extMB: Math.round(ext.reduce((n, k) => n + (footprintMB(k.pid) ?? 0), 0)) });
      }
      await sleep(1500);
    }
    // A host seen twice 1.5 s apart is still alive (should not happen with no app.sock). The hosts' own
    // stderr (Chrome passes it through to chrome.log) says why each one exited.
    const absentExits = (readFileSync(`${DIR}/chrome.log`, "utf8").match(/exiting: app\.sock is absent \(on-demand mode\)/g) ?? []).length;
    check("on-demand with no app: alarm-started hosts exit at once (no lingering host)", lingering.size === 0 && absentExits >= 1,
      { hostsSeenByPs: seen.size, lingering: [...lingering], hostsThatLoggedAppSockAbsentExit: absentExits });
    listener = startListener();
    cur = (await nextConn(connSeq, 45000))!;
    const idleHello = cur?.lines[1];
    check("on-demand idle: worker and extension-process samples recorded (informational)", true,
      { idleSec: Math.max(40, ONDEMAND_IDLE), samples: idleSamples, swStartBefore: swStart, swStartAfter: idleHello?.swStart,
        workerRestarted: idleHello?.swStart !== undefined && idleHello.swStart !== swStart });
    check("on-demand: reconnects once the app listens again", !!cur && !cur.closed, cur ? cur.lines.slice(0, 2) : "none");
    send(cur, { t: "setMode", mode: "persistent" });
    await sleep(500);
    // The host now also runs in persistent mode: a disconnect must not make it exit.
    const hp = cur.lines[0].hostPid, b3 = connSeq;
    cur.sock.end();
    const c5 = await nextConn(b3, 6000);
    check("setMode persistent from the app switches the host back (it reconnects)", !!c5 && c5.lines[0].hostPid === hp, c5?.lines[0]);
    cur = c5!;
  }

  // 12. Keepalive: no app traffic for KEEPALIVE seconds, then a snapshot on the same connection.
  if (KEEPALIVE > 0) {
    const sw0 = await swTargets();
    const conn0 = connSeq, hp = cur.lines[0].hostPid;
    const helloCount = () => conns.reduce((n, c) => n + c.lines.filter(l => l.t === "hello").length, 0);
    const h0 = helloCount();
    console.log(`keepalive: idle for ${KEEPALIVE} s…`);
    let swGaps = 0;
    for (let t = 0; t < KEEPALIVE; t += 15) { await sleep(15000); if ((await swTargets()).length === 0) swGaps++; }
    const s = await request(cur, { t: "snapshot" });
    check(`worker keepalive: ${KEEPALIVE} s idle, same connection and host, snapshot answered`,
      !!s && connSeq === conn0 && !cur.closed && alive(hp) && helloCount() === h0 && swGaps === 0,
      { answered: !!s, newConnections: connSeq - conn0, newHellos: helloCount() - h0, swTargetMissingSamples: swGaps, swBefore: sw0.length });
  }

  // 13. The host exits when Chrome quits.
  const lastHost = cur.lines[0].hostPid;
  await cdp("Browser.close").catch(() => {});
  const chromeGone = await until(() => !alive(BROWSER) || undefined, 8000);
  const hostGone = await until(() => !alive(lastHost) || undefined, 5000);
  check("the host exits when that Chrome quits", !!chromeGone && !!hostGone, { chromeGone: !!chromeGone, hostGone: !!hostGone });
} catch (e) {
  check("harness", false, String(e));
} finally {
  await cleanup();
  const failed = results.filter(r => !r.ok);
  writeFileSync(`${DIR}/results.json`, JSON.stringify({ at: new Date().toISOString(), extId, browser: CFT, results }, null, 2));
  console.log(`\n${results.length - failed.length}/${results.length} passed; details in ${DIR}/results.json`);
  process.exit(failed.length ? 1 : 0);
}
