// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Runs the share's page-world scripts (F3 §4.6) under Node against a fake
// fetch, FormData, Blob and atob: shareStageChunk + shareUpload must post ONE
// `file` part holding every staged byte, and shareFetch must return
// {status, body, auth}. Invoked by test-page-scripts.sh, which passes the
// sources as JSON on stdin. What is tested is the exact text the app injects.

'use strict';
const fs = require('fs');

const src = JSON.parse(fs.readFileSync(0, 'utf8'));
let failures = 0;
let checks = 0;
function expect(cond, what, detail) {
  checks++;
  if (!cond) { failures++; console.log(`  FAIL: ${what}${detail ? '\n        ' + detail : ''}`); }
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const globalsNames = ['window', 'fetch', 'FormData', 'Blob', 'atob', 'AbortController', 'setTimeout',
                      'clearTimeout', 'history', 'location', 'dispatchEvent', 'PopStateEvent', 'URLSearchParams'];

class FakeBlob {
  constructor(parts) {
    this.size = 0;
    this.chunks = [];
    for (const p of parts) {
      if (p instanceof FakeBlob) { this.size += p.size; this.chunks.push(...p.chunks); }
      else { this.size += p.length; this.chunks.push(Buffer.from(p)); }
    }
  }
  bytes() { return Buffer.concat(this.chunks); }
}
class FakeFormData {
  constructor() { this.entries = []; }
  append(name, value, filename) { this.entries.push({ name, value, filename }); }
}
class FakeAbortController {
  constructor() { this.signal = { aborted: false, onabort: null }; }
  abort() { this.signal.aborted = true; if (this.signal.onabort) { this.signal.onabort(); } }
}

function env(respond) {
  const window = {};
  const calls = [];
  const fetch = (path, init) => {
    calls.push({ path, init });
    const r = respond(path, init);
    if (r === 'hang') {
      return new Promise((_, reject) => { init.signal.onabort = () => reject(new Error('AbortError')); });
    }
    if (r instanceof Error) { return Promise.reject(r); }
    return Promise.resolve({
      status: r.status, text: () => Promise.resolve(r.body || ''),
      headers: { get: (k) => (r.headers || {})[k] === undefined ? null : r.headers[k] },
    });
  };
  const loc = { search: '', pathname: '/' };
  const history = { pushState: (_s, _t, url) => { const u = new URL(url, 'https://gw.example'); loc.search = u.search; loc.pathname = u.pathname; } };
  const events = [];
  const g = {
    window, fetch, FormData: FakeFormData, Blob: FakeBlob,
    atob: (s) => Buffer.from(s, 'base64').toString('latin1'),
    AbortController: FakeAbortController, setTimeout: global.setTimeout, clearTimeout: global.clearTimeout,
    history, location: loc, dispatchEvent: (e) => events.push(e),
    PopStateEvent: class { constructor(type, init) { this.type = type; this.state = init && init.state; } },
    URLSearchParams,
  };
  return { g, calls, window, events, loc };
}

function run(body, argNames, args, g) {
  const fn = new AsyncFunction(...argNames, ...globalsNames, body);
  return fn(...args, ...globalsNames.map((n) => g[n]));
}

(async () => {
  console.log('\n== share scripts');

  // -- stage + upload: 10 KiB + 10 KiB + 3 bytes, three chunks.
  const data = Buffer.alloc(20483);
  for (let i = 0; i < data.length; i++) { data[i] = (i * 7) & 0xff; }
  const chunks = [data.subarray(0, 10240), data.subarray(10240, 20480), data.subarray(20480)];
  let e = env(() => ({ status: 200, body: '{"paths":["/tmp/up/a.pdf"]}' }));
  for (let i = 0; i < chunks.length; i++) {
    const n = await run(src.stage, ['id', 'index', 'chunk'], ['item1', i, chunks[i].toString('base64')], e.g);
    expect(n === i + 1, `chunk ${i} staged, count ${i + 1}`, String(n));
  }
  let r = await run(src.upload, ['id', 'filename', 'parts', 'timeoutMs'], ['item1', 'report.pdf', 3, 5000], e.g);
  expect(r.status === 200 && r.body.includes('/tmp/up/a.pdf') && r.auth === false,
         'the upload returns {status, body, auth}', JSON.stringify(r));
  expect(e.calls.length === 1, 'exactly one request', String(e.calls.length));
  const c = e.calls[0];
  expect(c.path === '/api/upload/file' && c.init.method === 'POST', 'POST /api/upload/file', JSON.stringify(c.path));
  expect(c.init.credentials === 'same-origin', "the page's cookies go along");
  expect(c.init.headers['X-Latchkey-Share'] === 'item1', 'marked with the item id');
  const form = c.init.body;
  expect(form instanceof FakeFormData && form.entries.length === 1, 'one form part', JSON.stringify(form && form.entries.length));
  const part = form.entries[0];
  expect(part.name === 'file' && part.filename === 'report.pdf', "part name 'file', the filename kept", JSON.stringify([part.name, part.filename]));
  expect(part.value.size === data.length, `the part holds every staged byte (${data.length})`, String(part.value.size));
  expect(Buffer.compare(part.value.bytes(), data) === 0, 'byte for byte');
  expect(e.window.__latchkeyShare.item1 === undefined, 'the staged parts are dropped after the upload');

  // -- a missing chunk is refused before anything is sent.
  e = env(() => ({ status: 200, body: '{}' }));
  await run(src.stage, ['id', 'index', 'chunk'], ['item2', 0, chunks[0].toString('base64')], e.g);
  await run(src.stage, ['id', 'index', 'chunk'], ['item2', 1, chunks[1].toString('base64')], e.g);
  r = await run(src.upload, ['id', 'filename', 'parts', 'timeoutMs'], ['item2', 'x.pdf', 3, 5000], e.g);
  expect(r.status === -1 && e.calls.length === 0, 'fewer parts staged than announced: nothing is posted', JSON.stringify(r));
  // -- out of order: cleared, so a retry cannot append to a half-staged file.
  e = env(() => ({ status: 200, body: '{}' }));
  await run(src.stage, ['id', 'index', 'chunk'], ['item3', 0, 'AAAA'], e.g);
  const bad = await run(src.stage, ['id', 'index', 'chunk'], ['item3', 2, 'AAAA'], e.g);
  expect(bad === -1 && e.window.__latchkeyShare.item3 === undefined, 'a chunk out of order clears the item', String(bad));
  const restart = await run(src.stage, ['id', 'index', 'chunk'], ['item3', 0, 'AAAA'], e.g);
  expect(restart === 1, 'index 0 starts the item over', String(restart));

  // -- shareFetch.
  e = env(() => ({ status: 200, body: '[{"key":"obsidian"}]' }));
  r = await run(src.fetch, ['path', 'method', 'body', 'shareId', 'timeoutMs'], ['/api/chat/slots', 'GET', null, 'i9', 5000], e.g);
  expect(r.status === 200 && r.body === '[{"key":"obsidian"}]' && r.auth === false, 'GET returns {status, body, auth}', JSON.stringify(r));
  expect(e.calls[0].init.credentials === 'same-origin' && e.calls[0].init.headers['X-Latchkey-Share'] === 'i9',
         "as the page, marked with the item");
  expect(e.calls[0].init.body === undefined && !('Content-Type' in e.calls[0].init.headers), 'a GET has no body');
  e = env(() => ({ status: 200, body: '{"ok":true}' }));
  await run(src.fetch, ['path', 'method', 'body', 'shareId', 'timeoutMs'], ['/api/chat?ws=1', 'POST', '{"slot":"a"}', 'i9', 5000], e.g);
  expect(e.calls[0].init.body === '{"slot":"a"}' && e.calls[0].init.headers['Content-Type'] === 'application/json',
         'a POST carries its JSON body');
  e = env(() => ({ status: 403, body: '{"error":"Token required"}', headers: { 'X-Auth-Required': 'true' } }));
  r = await run(src.fetch, ['path', 'method', 'body', 'shareId', 'timeoutMs'], ['/api/chat/slots', 'GET', null, 'i9', 5000], e.g);
  expect(r.status === 403 && r.auth === true, 'X-Auth-Required is reported', JSON.stringify(r));
  e = env(() => new TypeError('Load failed'));
  r = await run(src.fetch, ['path', 'method', 'body', 'shareId', 'timeoutMs'], ['/api/chat/slots', 'GET', null, 'i9', 5000], e.g);
  expect(r.status === 0, 'a network failure is status 0, not a throw', JSON.stringify(r));
  e = env(() => 'hang');
  const t0 = Date.now();
  r = await run(src.fetch, ['path', 'method', 'body', 'shareId', 'timeoutMs'], ['/api/chat/slots', 'GET', null, 'i9', 150], e.g);
  expect(r.status === 0 && Date.now() - t0 < 2000, 'a gateway that never answers is abandoned at the timeout', JSON.stringify(r));


  console.log(failures === 0 ? `share scripts: all ${checks} passed` : `share scripts: ${failures} of ${checks} FAILED`);
  process.exit(failures === 0 ? 0 : 1);
})();
