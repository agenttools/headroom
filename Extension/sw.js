// Headroom helper: MV3 service worker.
// Protocol: docs/protocol.md (wire v1). Design: SPEC §2 (connection modes), §4.2 (messages), §4.3.
//
// Privacy: the manifest has no host permissions and no content scripts. This worker reads tab
// metadata (id, window, title, url, flags) and the process id of each frame. It never reads page
// content, cookies or history, and it never talks to the network. Its only peer is the native host
// "dev.adder.headroom" (headroom-host), which relays to the Headroom app on a local Unix socket.
'use strict';

const HOST = 'dev.adder.headroom';
const WIRE = 1;
const ALARM = 'headroom-connect';
const MODES = ['persistent', 'on-demand'];
const DEFAULT_MODE = 'persistent';
const FAVICON_MAX = 8 * 1024;        // only data: favicons under 8 KB are forwarded
const RECENT_MATCH_MS = 10_000;      // sessions.getRecentlyClosed lastModified tolerance
const DIRTY_DELAY_MS = 300;
const REMOVE_WAIT_MS = 1000;        // longer means a beforeunload dialog is holding the tab
const MAX_BACKOFF_S = 60;
const SW_START = Math.round(performance.timeOrigin);

let port = null;           // the native-messaging port, or null
let backoff = 1;           // seconds until the next reconnect (persistent mode)
let retryTimer = null;
let dirtyTimer = null;
let mode = DEFAULT_MODE;   // cache of storage.local.mode
let ballast = null;        // probe-only memory marker (see probeMark)

// ---------------------------------------------------------------- settings

async function settings() {
  const s = await chrome.storage.local.get(['mode', 'install']);
  const patch = {};
  if (!MODES.includes(s.mode)) { s.mode = DEFAULT_MODE; patch.mode = s.mode; }
  if (typeof s.install !== 'string' || !s.install) { s.install = crypto.randomUUID(); patch.install = s.install; }
  if (Object.keys(patch).length) await chrome.storage.local.set(patch);
  mode = s.mode;
  return s;
}

const ready = settings().catch(() => ({ mode: DEFAULT_MODE, install: 'unknown' }));

// ---------------------------------------------------------------- connection

function connect() {
  if (port) return;
  clearTimeout(retryTimer);
  retryTimer = null;
  let p;
  try {
    p = chrome.runtime.connectNative(HOST);
  } catch (e) {
    scheduleRetry();
    return;
  }
  port = p;
  p.onMessage.addListener(onHostMessage);
  p.onDisconnect.addListener(() => {
    void chrome.runtime.lastError; // read it so Chrome does not log "Unchecked runtime.lastError"
    if (port !== p) return;
    port = null;
    setDirtyListeners(false);
    scheduleRetry();
  });
  setDirtyListeners(true);
  sendHello();
}

async function sendHello() {
  const s = await ready;
  let incognitoAllowed = false;
  try { incognitoAllowed = await chrome.extension.isAllowedIncognitoAccess(); } catch (e) { /* keep false */ }
  post({
    t: 'hello', v: WIRE, ext: chrome.runtime.getManifest().version, install: s.install,
    incognitoAllowed, mode, swStart: SW_START,
  });
}

// Persistent mode: retry with backoff 1, 2, 4 … 60 s. On-demand mode: wait for the next alarm,
// so the worker can go idle while the app is not running.
function scheduleRetry() {
  if (mode !== 'persistent' || retryTimer) return;
  const delay = backoff;
  backoff = Math.min(backoff * 2, MAX_BACKOFF_S);
  retryTimer = setTimeout(() => { retryTimer = null; connect(); }, delay * 1000);
}

function post(msg) {
  if (!port) return;
  try { port.postMessage(msg); } catch (e) { /* port closed underneath us; onDisconnect handles it */ }
}

// ---------------------------------------------------------------- host → extension

async function onHostMessage(m) {
  if (!m || typeof m.t !== 'string') return;
  backoff = 1; // the host is alive and talking
  try {
    switch (m.t) {
      case 'ping': post({ t: 'pong' }); break;
      case 'pong': break;
      case 'snapshot': post(await snapshot(m.req)); break;
      case 'close': post(await closeTabs(m)); break;
      case 'discard': post(await discardTabs(m)); break;
      case 'activate': post(await activateTab(m)); break;
      case 'restore': post(await restoreTabs(m)); break;
      case 'setMode': await setMode(m.mode); break;
      case 'reload': chrome.runtime.reload(); break;
      case 'probeMark': post(probeMark(m)); break;
      default: break; // unknown messages are ignored (docs/protocol.md)
    }
  } catch (e) {
    if (Number.isInteger(m.req)) post({ t: 'result', req: m.req, error: errText(e) });
  }
}

function errText(e) { return String((e && e.message) || e).slice(0, 200); }
function urlOf(tab) { return tab.url || tab.pendingUrl || ''; }
async function getTab(id) { try { return await chrome.tabs.get(id); } catch (e) { return null; } }

// ---------------------------------------------------------------- snapshot

async function snapshot(req) {
  const [tabs, wins] = await Promise.all([chrome.tabs.query({}), chrome.windows.getAll()]);
  const real = tabs.filter(t => Number.isInteger(t.id) && t.id >= 0);
  const frames = await Promise.all(real.map(t => t.discarded
    ? Promise.resolve([])
    : chrome.webNavigation.getAllFrames({ tabId: t.id }).then(f => f || [], () => [])));
  return {
    t: 'snapshot', req, at: Date.now(),
    windows: wins.map(w => ({ id: w.id, focused: !!w.focused, incognito: !!w.incognito, type: w.type, state: w.state })),
    tabs: real.map((t, i) => tabJSON(t, frames[i])),
  };
}

function tabJSON(t, frames) {
  const o = {
    id: t.id, windowId: t.windowId, index: t.index, title: t.title || '', url: urlOf(t),
    active: !!t.active, audible: !!t.audible, pinned: !!t.pinned, discarded: !!t.discarded,
    frozen: !!t.frozen, incognito: !!t.incognito,
    frames: frames.map(f => ({
      frameId: f.frameId, parentFrameId: f.parentFrameId, processId: f.processId,
      documentLifecycle: f.documentLifecycle,
    })),
  };
  if (typeof t.lastAccessed === 'number') o.lastAccessed = t.lastAccessed;
  const fav = t.favIconUrl;
  if (typeof fav === 'string' && fav.startsWith('data:') && fav.length < FAVICON_MAX) o.favIconUrl = fav;
  return o;
}

// ---------------------------------------------------------------- close

// Precondition: the tab's current URL must equal the expected URL, else "changedSkipped".
// After removing, match sessions.getRecentlyClosed entries so the app can Undo with history.
//
// tabs.remove does not resolve while the page shows a "Leave site?" (beforeunload) dialog, which Chrome
// shows when the page has had a user gesture (verified in Chrome for Testing 151). So each remove is
// raced against REMOVE_WAIT_MS, all tabs in parallel: if the tab is still there after that, the result
// is "failed:beforeunload" (the app offers Jump; if the user confirms the dialog, the tab closes and a
// `dirty` follows). Without this, one such tab would hold the whole reply past the app's 3 s timeout.
async function closeTabs(m) {
  const results = {};
  const toRemove = [];
  for (const item of m.tabs || []) {
    const id = item.id;
    const tab = await getTab(id);
    if (!tab) { results[id] = 'gone'; continue; }
    const url = urlOf(tab);
    if (url !== item.url) { results[id] = 'changedSkipped'; continue; }
    toRemove.push({ id, url, windowId: tab.windowId });
  }
  const removed = [];
  await Promise.all(toRemove.map(async r => {
    r.at = Date.now();
    const outcome = await Promise.race([
      chrome.tabs.remove(r.id).then(() => 'ok', e => e),
      new Promise(res => setTimeout(() => res('timeout'), REMOVE_WAIT_MS)),
    ]);
    const stillThere = outcome !== 'ok' && !!(await getTab(r.id));
    if (!stillThere) { results[r.id] = 'done'; removed.push(r); }
    else if (outcome === 'timeout') results[r.id] = 'failed:beforeunload';
    else results[r.id] = 'failed:' + errText(outcome);
  }));
  const restore = removed.length ? await matchRecentlyClosed(removed) : {};
  return { t: 'result', req: m.req, results, restore };
}

// Match each removed tab to a recently-closed entry by url and lastModified (±10 s). Chrome reports
// windowId 0 for closed tabs (verified in Chrome for Testing 151), so windowId is compared only when
// it is set. Entries are newest first, and each is used once, so two closed tabs with the same url
// get two different sessionIds. The list can lag tabs.remove by a moment: retry once after 250 ms.
async function matchRecentlyClosed(removed) {
  const out = {};
  const used = new Set();
  for (let attempt = 0; attempt < 2; attempt++) {
    let recent = [];
    try { recent = await chrome.sessions.getRecentlyClosed({ maxResults: 25 }); } catch (e) { return out; }
    for (const r of removed) {
      if (out[r.id]) continue;
      for (const s of recent) {
        const closedMs = (s.lastModified || 0) * 1000; // lastModified is in seconds
        if (Math.abs(closedMs - r.at) > RECENT_MATCH_MS) continue;
        let sid = null;
        if (s.tab && s.tab.url === r.url && (!s.tab.windowId || s.tab.windowId === r.windowId)) sid = s.tab.sessionId;
        // Closing the last tab of a window records the whole window.
        else if (s.window && (s.window.tabs || []).some(t => t.url === r.url)) sid = s.window.sessionId;
        if (sid && !used.has(sid)) { used.add(sid); out[r.id] = sid; break; }
      }
    }
    if (removed.every(r => out[r.id])) break;
    await new Promise(res => setTimeout(res, 250));
  }
  return out;
}

// ---------------------------------------------------------------- discard / activate / restore

async function discardTabs(m) {
  const results = {};
  const replaced = {};
  for (const id of m.tabIds || []) {
    const tab = await getTab(id);
    if (!tab) { results[id] = 'gone'; continue; }
    if (tab.discarded) { results[id] = 'done'; continue; }
    try {
      const d = await chrome.tabs.discard(id);
      if (d && d.discarded) {
        results[id] = 'done';
        if (d.id !== id) replaced[id] = d.id; // older Chrome gave discarded tabs a new id
      } else {
        results[id] = 'failed:not discarded';
      }
    } catch (e) {
      results[id] = 'failed:' + errText(e);
    }
  }
  const reply = { t: 'result', req: m.req, results };
  if (Object.keys(replaced).length) reply.replaced = replaced;
  return reply;
}

async function activateTab(m) {
  const results = {};
  const tab = await getTab(m.tabId);
  if (!tab) {
    results[m.tabId] = 'gone';
  } else {
    try {
      await chrome.tabs.update(tab.id, { active: true });
      await chrome.windows.update(tab.windowId, { focused: true });
      results[m.tabId] = 'done';
    } catch (e) {
      results[m.tabId] = 'failed:' + errText(e);
    }
  }
  return { t: 'result', req: m.req, results };
}

async function windowExists(id) {
  try { await chrome.windows.get(id); return true; } catch (e) { return false; }
}

// sessions.restore keeps the tab's history. If it fails, or there is no sessionId, reopen the URL
// with tabs.create ("reopened without history"), in the original window when it still exists.
async function restoreTabs(m) {
  const restored = [];
  for (const it of m.items || []) {
    let done = null;
    if (it.sessionId) {
      try {
        const s = await chrome.sessions.restore(it.sessionId);
        const tab = (s && s.tab) || (s && s.window && ((s.window.tabs || []).find(t => t.url === it.url) || (s.window.tabs || [])[0]));
        done = { url: it.url, newTabId: tab && Number.isInteger(tab.id) ? tab.id : null, via: 'sessions' };
      } catch (e) { /* fall back to tabs.create */ }
    }
    if (!done) {
      try {
        const opts = { url: it.url, active: false };
        if (Number.isInteger(it.windowId) && await windowExists(it.windowId)) {
          opts.windowId = it.windowId;
          if (Number.isInteger(it.index)) opts.index = it.index;
        }
        const t = await chrome.tabs.create(opts);
        done = { url: it.url, newTabId: t.id, via: 'create' };
      } catch (e) {
        done = { url: it.url, newTabId: null, via: 'failed', error: errText(e) };
      }
    }
    restored.push(done);
  }
  return { t: 'result', req: m.req, restored };
}

async function setMode(next) {
  if (!MODES.includes(next)) return;
  mode = next;
  await chrome.storage.local.set({ mode: next });
  if (next === 'persistent') { backoff = 1; connect(); }
}

// Probe-only (Spike S): hold `mb` MiB so headroom-host --probe can tell which extension renderer
// is this worker's, by its footprint jump. mb = 0 releases it. Capped at 256.
// The memory is freed at once by detaching the buffer (ArrayBuffer.prototype.transfer), not left to GC.
function probeMark(m) {
  const mb = Math.max(0, Math.min(256, m.mb | 0));
  if (ballast) { try { ballast.buffer.transfer(0); } catch (e) { /* older V8: left to GC */ } ballast = null; }
  if (mb > 0) { ballast = new Float64Array(mb * 131072); ballast.fill(1.5); }
  return { t: 'result', req: m.req, results: { mark: 'done' }, mb };
}

// ---------------------------------------------------------------- dirty events

// Sent at most once per 300 ms while connected. The listeners are added only while a port is open,
// so tab activity does not wake an idle worker in on-demand mode.
function markDirty() {
  if (!port || dirtyTimer) return;
  dirtyTimer = setTimeout(() => { dirtyTimer = null; post({ t: 'dirty' }); }, DIRTY_DELAY_MS);
}
function onTabUpdated(_id, info) {
  if ('status' in info || 'title' in info || 'url' in info || 'discarded' in info ||
      'audible' in info || 'pinned' in info) markDirty();
}
const dirtyEvents = [
  [chrome.tabs.onCreated, markDirty],
  [chrome.tabs.onRemoved, markDirty],
  [chrome.tabs.onUpdated, onTabUpdated],
  [chrome.tabs.onActivated, markDirty],
  [chrome.tabs.onReplaced, markDirty],
  [chrome.webNavigation.onCommitted, markDirty],
];
let listening = false;
function setDirtyListeners(on) {
  if (on === listening) return;
  listening = on;
  for (const [ev, fn] of dirtyEvents) on ? ev.addListener(fn) : ev.removeListener(fn);
}

// ---------------------------------------------------------------- start-up

// chrome.alarms fires every 30 s (the minimum on Chrome 120+). Persistent mode: a backstop.
// On-demand mode: it drives the connection.
chrome.alarms.get(ALARM).then(a => { if (!a) chrome.alarms.create(ALARM, { periodInMinutes: 0.5 }); });
chrome.alarms.onAlarm.addListener(a => { if (a.name === ALARM) ready.then(connect); });
chrome.runtime.onStartup.addListener(() => ready.then(connect));
chrome.runtime.onInstalled.addListener(() => ready.then(connect));
ready.then(connect);
