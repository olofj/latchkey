// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Runs PageScriptSources.blockedMarker (F6 §4a) under Node against a fake
// document, location and window.webkit. Invoked by test-page-scripts.sh,
// which passes {marker, handler, styleID, label} on stdin, so what is tested
// is the exact text the app injects, checked against the names native uses.
//
// What matters most: only a trusted click can post `open` (the page's own
// el.click() must send nothing to Safari), only an off-origin image is
// marked, and counts and hosts are numbers and origins, never URLs.
// Timers are faked, so the debounces are deterministic.

'use strict';
const fs = require('fs');
const vm = require('vm');

const { marker, handler, styleID, label } = JSON.parse(fs.readFileSync(0, 'utf8'));
let failures = 0;
let checks = 0;
function expect(cond, what, detail) {
  checks++;
  if (cond) { console.log(`  ok   ${what}`); return; }
  failures++;
  console.log(`  FAIL ${what}${detail ? '\n       ' + detail : ''}`);
}
const j = (x) => JSON.stringify(x);

const ORIGIN = 'https://gw.example.ts.net:8443';
const ATTR = 'data-latchkey-blocked';

function el(tagName, props = {}, parent = null) {
  const attrs = {};
  return Object.assign({
    tagName, parent, attrs,
    setAttribute(k, v) { attrs[k] = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(attrs, k) ? attrs[k] : null; },
    closest(sel) {
      const [, tag, name] = /^([a-z]*)\[([^\]]+)\]$/.exec(sel);
      for (let n = this; n; n = n.parent) {
        if (n.getAttribute(name) !== null && (!tag || n.tagName.toLowerCase() === tag)) { return n; }
      }
      return null;
    },
  }, props);
}

function page({ withHandler = true, baseURI = ORIGIN + '/chat/abc' } = {}) {
  const posts = [];
  const docListeners = {};
  const winListeners = {};
  const appended = [];
  let now = 0, nextId = 1;
  const timers = new Map();
  const observers = [];
  const document = {
    baseURI,
    documentElement: { appendChild(n) { appended.push(n); } },
    createElement(tag) { return { tagName: tag.toUpperCase(), id: '', textContent: '' }; },
    addEventListener(type, fn, capture) { (docListeners[type] = docListeners[type] || []).push({ fn, capture }); },
  };
  const window = { addEventListener(type, fn) { (winListeners[type] = winListeners[type] || []).push(fn); } };
  if (withHandler) {
    window.webkit = { messageHandlers: { [handler]: { postMessage(m) { posts.push(JSON.parse(JSON.stringify(m))); } } } };
  }
  const ctx = {
    window, document, URL,
    location: { origin: ORIGIN, href: ORIGIN + '/chat/abc' },
    setTimeout(fn, ms) { const id = nextId++; timers.set(id, { fn, at: now + ms }); return id; },
    clearTimeout(id) { timers.delete(id); },
    PerformanceObserver: function (cb) {
      this.observe = (opts) => observers.push({ cb, opts });
    },
  };
  vm.runInNewContext(marker, ctx);
  function advance(ms) {
    const until = now + ms;
    for (;;) {
      const due = [...timers.entries()].filter(([, t]) => t.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) { break; }
      timers.delete(due[0]); now = due[1].at; due[1].fn();
    }
    now = until;
  }
  function fire(type, target, props = {}) {
    const calls = [];
    const ev = Object.assign({
      type, target,
      preventDefault() { calls.push('preventDefault'); },
      stopPropagation() { calls.push('stopPropagation'); },
    }, props);
    for (const l of docListeners[type] || []) { l.fn(ev); }
    return calls;
  }
  function entries(names) {
    for (const o of observers) { o.cb({ getEntries: () => names.map((name) => ({ name })) }); }
  }
  return { posts, docListeners, winListeners, appended, observers, advance, fire, entries, timers };
}

console.log('\n== at document start');
let p = page();
const style = p.appended.find((n) => n.id === styleID);
expect(!!style && style.tagName === 'STYLE', `a <style id="${styleID}"> on documentElement`, j(p.appended));
expect(style && /min-width:\s*44px/.test(style.textContent) && /min-height:\s*44px/.test(style.textContent),
       'the marker is at least 44 by 44', style && style.textContent);
expect(style && style.textContent.includes(`img[${ATTR}]`), 'it styles only marked images');
expect(style && !style.textContent.includes('url('), 'no url( in the CSS: it loads nothing');
expect((p.docListeners.error || []).length === 1 && p.docListeners.error[0].capture === true,
       'error is heard in the capture phase (it does not bubble)');
expect((p.docListeners.click || []).length === 1 && p.docListeners.click[0].capture === true,
       'click is heard in the capture phase, before the page\'s own handler');
expect(p.observers.length === 1 && p.observers[0].opts.type === 'resource' && p.observers[0].opts.buffered === true,
       'observes resource entries, buffered', j(p.observers.map((o) => o.opts)));
expect(p.posts.length === 0, 'posts nothing yet');

console.log('\n== error events');
p = page();
let same = el('IMG', { src: ORIGIN + '/assets/logo.png', currentSrc: '' });
p.fire('error', same);
expect(same.getAttribute(ATTR) === null && same.getAttribute('aria-label') === null,
       'a same-origin image is not marked');
let off = el('IMG', { src: 'https://dash.localtest.me:8443/f6/img.png?x=1', currentSrc: '' });
p.fire('error', off);
expect(off.getAttribute(ATTR) === 'https://dash.localtest.me:8443/f6/img.png?x=1',
       'an off-origin image is marked with its absolute URL', off.getAttribute(ATTR));
expect(off.getAttribute('aria-label') === label, 'and labelled for VoiceOver and the L1 test', off.getAttribute('aria-label'));
let srcset = el('IMG', { src: 'https://a.example/small.png', currentSrc: 'https://b.example/big.png' });
p.fire('error', srcset);
expect(srcset.getAttribute(ATTR) === 'https://b.example/big.png', 'currentSrc wins (srcset)', srcset.getAttribute(ATTR));
let port = el('IMG', { src: 'https://gw.example.ts.net:8444/f6/port-probe' });
p.fire('error', port);
expect(port.getAttribute(ATTR) !== null, 'another port on the same host is off-origin');
for (const src of ['javascript:alert(1)', 'data:image/png;base64,AAAA', 'blob:' + ORIGIN + '/x', 'about:blank', '']) {
  const e = el('IMG', { src });
  p.fire('error', e);
  expect(e.getAttribute(ATTR) === null && e.getAttribute('aria-label') === null, `src "${src}": nothing`);
}
const script = el('SCRIPT', { src: 'https://esm.sh.away.example/f6/pwn.js' });
p.fire('error', script);
expect(script.getAttribute(ATTR) === null, 'an off-origin script is not marked');
p.fire('error', el('LINK', { href: 'https://fonts.googleapis.com/css2?family=X' }));
p.fire('error', el('SCRIPT', { src: ORIGIN + '/assets/index.js' }));
p.fire('error', el('LINK', { href: ORIGIN + '/assets/index.css' }));
p.fire('error', el('VIDEO', { src: 'https://dash.localtest.me/v.mp4' }));
p.fire('error', null);
p.fire('error', {});
expect(p.posts.length === 0, 'nothing posted before the debounce', j(p.posts));
p.advance(999);
expect(p.posts.length === 0, 'still nothing at 999 ms');
p.advance(1);
// blocked: off, srcset, port, script, link = 5; gatewayFailed: same, script, link = 3
expect(j(p.posts) === j([{ event: 'counts', blocked: 5, gatewayFailed: 3 }]),
       'one counts post, 1 s after the last error: 5 blocked, 3 gateway failures', j(p.posts));
expect(!j(p.posts).includes('http'), 'counts carry no URL');
p.advance(10000);
expect(p.posts.length === 1, 'and not again without new errors');
p.fire('error', el('IMG', { src: 'https://dash.localtest.me/2.png' }));
p.advance(500);
p.fire('error', el('SCRIPT', { src: ORIGIN + '/x.js' }));
p.advance(999);
expect(p.posts.length === 1, 'a new error restarts the debounce');
p.advance(1);
expect(j(p.posts[1]) === j({ event: 'counts', blocked: 1, gatewayFailed: 1 }),
       'a second burst posts only the new ones', j(p.posts));

p = page({ baseURI: 'https://other.example/base/' });
const rel = el('IMG', { src: 'img/a.png' });
p.fire('error', rel);
expect(rel.getAttribute(ATTR) === 'https://other.example/base/img/a.png',
       'a relative src resolves against baseURI', rel.getAttribute(ATTR));
p = page({ baseURI: ORIGIN + '/chat/' });
const relSame = el('IMG', { src: '../img/a.png' });
p.fire('error', relSame);
p.advance(1000);
expect(relSame.getAttribute(ATTR) === null && j(p.posts) === j([{ event: 'counts', blocked: 0, gatewayFailed: 1 }]),
       'a relative src on the gateway is the gateway\'s own failure', j(p.posts));

console.log('\n== clicks');
p = page();
const marked = el('IMG', { src: 'https://dash.localtest.me/f6/img.png' });
p.fire('error', marked);
p.advance(1000);
p.posts.length = 0;
let calls = p.fire('click', marked, { isTrusted: false });
expect(p.posts.length === 0 && calls.length === 0, 'an untrusted click (the page\'s el.click()) posts nothing',
       j({ posts: p.posts, calls }));
calls = p.fire('click', marked, { isTrusted: true });
expect(j(p.posts) === j([{ event: 'open', url: 'https://dash.localtest.me/f6/img.png' }]),
       'a trusted click on a marked image posts open with its URL', j(p.posts));
expect(calls.includes('stopPropagation') && calls.includes('preventDefault'),
       'and the page\'s own handler (a lightbox) does not also run', j(calls));
p.posts.length = 0;
// Review, 2026-09-25: the page (or sanitized agent HTML, which keeps data-*)
// can set the attribute itself. Only an image this script marked counts.
const wrapper = el('DIV');
wrapper.setAttribute(ATTR, 'https://phish.example/');
const child = el('SPAN', {}, wrapper);
const forgedImg = el('IMG', { src: 'https://phish.example/x.png' });
forgedImg.setAttribute(ATTR, 'https://phish.example/');
calls = p.fire('click', child, { isTrusted: true }).concat(p.fire('click', forgedImg, { isTrusted: true }));
expect(p.posts.length === 0 && calls.length === 0,
       'a forged attribute, on a wrapper or on an image never blocked, posts nothing', j({ posts: p.posts, calls }));
marked.setAttribute(ATTR, 'https://phish.example/');
calls = p.fire('click', marked, { isTrusted: true });
expect(j(p.posts) === j([{ event: 'open', url: 'https://dash.localtest.me/f6/img.png' }]),
       'and rewriting a marked image\'s attribute does not change where a tap goes', j(p.posts));
p.posts.length = 0;
const plainImg = el('IMG', { src: ORIGIN + '/ok.png' }, el('DIV'));
calls = p.fire('click', plainImg, { isTrusted: true });
calls = calls.concat(p.fire('click', null, { isTrusted: true }), p.fire('click', {}, { isTrusted: true }));
expect(p.posts.length === 0 && calls.length === 0, 'a trusted click elsewhere does nothing', j({ posts: p.posts, calls }));

console.log('\n== off-origin hosts');
p = page();
p.entries([ORIGIN + '/assets/index.js', 'https://esm.sh/react@19', 'https://esm.sh/@excalidraw/x',
           'https://cdn.jsdelivr.net/npm/a?b=1', 'data:image/png;base64,AA', 'blob:' + ORIGIN + '/1']);
p.advance(1999);
expect(p.posts.length === 0, 'nothing before 2 s');
p.advance(1);
expect(j(p.posts) === j([{ event: 'hosts', hosts: { 'https://esm.sh': 2, 'https://cdn.jsdelivr.net': 1 } }]),
       'origins of other origins, counted; the gateway, data: and blob: ignored; no paths', j(p.posts));
p.entries([ORIGIN + '/api/x']);
p.advance(5000);
expect(p.posts.length === 1, 'only gateway entries: nothing posted');
p.entries(['https://esm.sh/again']);
p.advance(1000);
p.entries(['https://cdnjs.cloudflare.com/x']);
p.advance(1999);
expect(p.posts.length === 1, 'a new entry restarts the 2 s debounce');
p.advance(1);
expect(j(p.posts[1]) === j({ event: 'hosts', hosts: { 'https://esm.sh': 1, 'https://cdnjs.cloudflare.com': 1 } }),
       'the next post carries only the new ones', j(p.posts));
p.entries(['https://cdn.tailwindcss.com/x']);
for (const fn of p.winListeners.load || []) { fn({ type: 'load' }); }
expect(j(p.posts[2]) === j({ event: 'hosts', hosts: { 'https://cdn.tailwindcss.com': 1 } }),
       'load flushes what is pending without waiting', j(p.posts));
p.advance(5000);
expect(p.posts.length === 3, 'and it is not posted twice', j(p.posts));

console.log('\n== no handler (the page world, or no bridge)');
let threw = null;
try {
  p = page({ withHandler: false });
  const img = el('IMG', { src: 'https://dash.localtest.me/x.png' });
  p.fire('error', img);
  p.advance(1000);
  p.fire('click', img, { isTrusted: true });
  p.entries(['https://esm.sh/x']);
  p.advance(2000);
  for (const fn of p.winListeners.load || []) { fn({ type: 'load' }); }
} catch (e) { threw = e; }
expect(threw === null, 'nothing throws', threw && threw.stack);

console.log('');
if (failures === 0) {
  console.log(`${checks}/${checks} blocked marker checks passed`);
} else {
  console.log(`${failures} of ${checks} blocked marker checks FAILED`);
  process.exit(1);
}
