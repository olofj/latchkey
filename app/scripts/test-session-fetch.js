// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Runs PageScriptSources.sessionFetch -- the body the app hands to
// callAsyncJavaScript for its own /api/auth/me check (M4) and for sign-out's
// POST /api/auth/logout (R32) -- under Node against a fake fetch. Invoked by
// test-page-scripts.sh, which passes the source as JSON on stdin.
//
// What matters is the contract with the gateway: the page's cookies go along
// (credentials: same-origin; `omit` would make the logout a 200 that revokes
// nothing), the method is the caller's, and a gateway that never answers is
// abandoned after the timeout rather than hanging the sign-out.

'use strict';
const fs = require('fs');

const { fetchBody } = JSON.parse(fs.readFileSync(0, 'utf8'));
let failures = 0;
let checks = 0;
function expect(cond, what, detail) {
  checks++;
  if (!cond) { failures++; console.log(`  FAIL: ${what}${detail ? '\n        ' + detail : ''}`); }
}

// The same free names WebKit's page world provides; `fetch` is the fake.
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const fn = new AsyncFunction('path', 'method', 'timeoutMs',
                             'fetch', 'AbortController', 'setTimeout', 'clearTimeout', fetchBody);

class FakeAbortController {
  constructor() { this.signal = { aborted: false, onabort: null }; }
  abort() { this.signal.aborted = true; if (this.signal.onabort) { this.signal.onabort(); } }
}

function call(path, method, timeoutMs, behaviour) {
  const calls = [];
  const timers = { set: 0, cleared: 0 };
  const fetch = (p, init) => {
    calls.push({ path: p, init });
    if (behaviour === 'hang') {
      return new Promise((_, reject) => { init.signal.onabort = () => reject(new Error('AbortError')); });
    }
    return Promise.resolve({ status: behaviour });
  };
  const setTimeout = (f, ms) => { timers.set++; timers.ms = ms; return global.setTimeout(f, ms); };
  const clearTimeout = (t) => { timers.cleared++; global.clearTimeout(t); };
  return fn(path, method, timeoutMs, fetch, FakeAbortController, setTimeout, clearTimeout)
    .then((status) => ({ status, calls, timers }), (error) => ({ error, calls, timers }));
}

(async () => {
  console.log('\n== sessionFetch');

  let r = await call('/api/auth/me', 'GET', 0, 200);
  expect(r.status === 200 && r.calls.length === 1, 'returns the status of one fetch', JSON.stringify(r));
  let init = r.calls[0].init;
  expect(r.calls[0].path === '/api/auth/me' && init.method === 'GET', 'the path and method are the caller\'s');
  expect(init.credentials === 'same-origin', "the page's cookies go along (credentials: same-origin)", JSON.stringify(init));
  expect(init.cache === 'no-store', 'never answered from a cache');
  expect(init.headers && init.headers['X-Latchkey-Check'] === '1', "marked as the app's own request");
  expect(r.timers.set === 0, 'timeoutMs 0: no timer (the contract; no caller in the app sends 0 any more -- test-session-manager.sh pins that)');

  r = await call('/api/auth/logout', 'POST', 10000, 200);
  init = r.calls[0].init;
  expect(r.status === 200 && init.method === 'POST' && init.credentials === 'same-origin',
         'sign-out: a POST with the cookies', JSON.stringify(init));
  expect(r.timers.set === 1 && r.timers.ms === 10000 && r.timers.cleared === 1,
         'a timer for the timeout, cleared once the gateway answered', JSON.stringify(r.timers));
  expect(init.signal && init.signal.aborted === false, 'not aborted when the answer came in time');

  r = await call('/api/auth/logout', 'POST', 403, 403);
  expect(r.status === 403, 'a refusal is returned, not thrown (the caller decides)', JSON.stringify(r));

  r = await call('/api/auth/logout', 'POST', 30, 'hang');
  expect(r.error && r.calls[0].init.signal.aborted, 'a gateway that never answers: aborted after timeoutMs', String(r.error));
  expect(r.timers.cleared === 1, 'the timer is cleared on the way out too');

  console.log('');
  if (failures === 0) {
    console.log(`${checks}/${checks} session fetch checks passed`);
  } else {
    console.log(`${failures} of ${checks} session fetch checks FAILED`);
    process.exit(1);
  }
})();
