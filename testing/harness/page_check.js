#!/usr/bin/env node
// Self-test of the fake dashboard page's reconnect (PLAN M6.4): the script
// inside dashboard.py's PAGE runs here under fake timers, a fake DOM and a
// fake WebSocket, and must reconnect the way KiroCrew's page does --
// 1 s after a close, doubling, capped at 10 s, reset to 1 s once a socket
// opens -- refetch over HTTP on every reconnect, and refetch when the page
// becomes visible again. Run by `make check` in this directory.
'use strict';
const { execFileSync } = require('child_process');
const assert = require('assert');
const vm = require('vm');

const src = execFileSync('python3', ['-c',
    'import re; from dashboard import PAGE; print(re.search(r"<script>(.*)</script>", PAGE, re.S).group(1))'],
    { cwd: __dirname, encoding: 'utf8' });

// Fake timers, advanced by hand.
let now = 0;
let timers = [];
function setTimeout(fn, ms) { timers.push({ at: now + ms, fn, every: 0 }); }
function setInterval(fn, ms) { timers.push({ at: now + ms, fn, every: ms }); }
function advance(ms) {
    const end = now + ms;
    for (;;) {
        timers.sort((a, b) => a.at - b.at);
        const t = timers[0];
        if (!t || t.at > end) break;
        now = t.at;
        timers.shift();
        t.fn();
        if (t.every) timers.push({ at: now + t.every, fn: t.fn, every: t.every });
    }
    now = end;
}
const flush = () => new Promise((r) => setImmediate(r));   // let promise chains settle

// Fake DOM and network.
const texts = {};
const listeners = {};
const document = {
    getElementById: (id) => ({
        get textContent() { return texts[id] || ''; },
        set textContent(v) { texts[id] = v; },
    }),
    addEventListener: (ev, fn) => { listeners[ev] = fn; },
    visibilityState: 'visible',
};
const fetches = [];
function fetch(url, opts) { fetches.push({ url, opts, body: opts && opts.body }); return Promise.resolve({ ok: true }); }
const sockets = [];
class WebSocket { constructor(url) { this.url = url; this.sent = []; sockets.push(this); } send(d) { this.sent.push(d); } }
class EventSource { constructor(url) { this.url = url; } }
const location = { host: 'dash.test', search: '', pathname: '/' };

vm.runInContext(src, vm.createContext({
    document, location, fetch, WebSocket, EventSource, setTimeout, setInterval, JSON, Math, Date,
}));

const lastReport = () => JSON.parse(fetches.filter((f) => f.url === '/__report').slice(-1)[0].body);
const healthz = () => fetches.filter((f) => f.url === '/healthz').length;

(async () => {
    assert.strictEqual(sockets.length, 1, 'one socket on load');
    sockets[0].onopen();
    await flush();
    assert.strictEqual(texts.wsstate, 'ws:open');
    assert.deepStrictEqual(sockets[0].sent, ['ping']);
    assert.strictEqual(healthz(), 0, 'the first open is not a reconnect: no refetch');
    assert.strictEqual(lastReport().next_delay_ms, 1000);

    // The schedule after repeated closes: 1, 2, 4, 8, 10, 10 s -- and never
    // a reconnect a millisecond early.
    const schedule = [1000, 2000, 4000, 8000, 10000, 10000];
    for (const delay of schedule) {
        const n = sockets.length;
        sockets[n - 1].onclose();
        assert.strictEqual(texts.wsstate, 'ws:closed');
        advance(delay - 1);
        assert.strictEqual(sockets.length, n, `no reconnect before ${delay} ms`);
        advance(1);
        assert.strictEqual(sockets.length, n + 1, `a reconnect at ${delay} ms`);
    }
    assert.strictEqual(lastReport().reconnects, schedule.length);
    assert.strictEqual(lastReport().next_delay_ms, 10000, 'capped at 10 s');

    // An open resets the backoff and refetches (no replay cursor).
    sockets[sockets.length - 1].onopen();
    await flush();
    assert.strictEqual(healthz(), 1, 'a reconnect refetches once');
    assert.strictEqual(lastReport().refetches, 1);
    assert.strictEqual(lastReport().next_delay_ms, 1000, 'reset to 1 s on open');
    assert.strictEqual(lastReport().ws_opens, 2);
    const n = sockets.length;
    sockets[n - 1].onclose();
    advance(1000);
    assert.strictEqual(sockets.length, n + 1, 'after a reset, the next reconnect is 1 s again');

    // Visible again: a fresh request, no reconnect.
    listeners.visibilitychange();
    await flush();
    assert.strictEqual(healthz(), 2, 'a visibilitychange refetches');
    assert.strictEqual(lastReport().visible_fetches, 1);
    assert.strictEqual(fetches.filter((f) => f.url === '/healthz').every((f) => f.opts.cache === 'no-store'), true,
        'refetches bypass the cache');
    document.visibilityState = 'hidden';
    listeners.visibilitychange();
    await flush();
    assert.strictEqual(healthz(), 2, 'going hidden fetches nothing');

    // The 1-s report interval keeps running throughout.
    const before = fetches.filter((f) => f.url === '/__report').length;
    advance(3000);
    assert.strictEqual(fetches.filter((f) => f.url === '/__report').length, before + 3);
    console.log('    ok (schedule 1,2,4,8,10,10 s; reset on open; refetch on reconnect and on visible)');
})().catch((e) => { console.error('page_check: ' + e.message); process.exit(1); });
