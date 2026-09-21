// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Runs PageScriptSources.sessionBridge and .revealSessionBanner under Node
// against a fake window/document (M4.2, R21, R22). Invoked by
// test-page-scripts.sh, which passes both sources as JSON on stdin.

'use strict';
const fs = require('fs');
const vm = require('vm');

const { bridge, reveal, styleID } = JSON.parse(fs.readFileSync(0, 'utf8'));
let failures = 0;
let checks = 0;
function expect(cond, what, detail) {
  checks++;
  if (!cond) { failures++; console.log(`  FAIL: ${what}${detail ? '\n        ' + detail : ''}`); }
}

function page({ withHandler = true, withHead = true } = {}) {
  const posted = [];
  const listeners = {};
  const nodes = [];
  const byId = {};
  const container = {
    appendChild(n) { nodes.push(n); if (n.id) { byId[n.id] = n; } n.remove = () => { delete byId[n.id]; n.removed = true; }; },
  };
  const document = {
    head: withHead ? container : null,
    documentElement: container,
    createElement(tag) { return { tag, id: '', textContent: '' }; },
    getElementById(id) { return byId[id] || null; },
  };
  const window = {
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn); },
    dispatch(name) { (listeners[name] || []).forEach((fn) => fn({ type: name })); },
  };
  if (withHandler) {
    window.webkit = { messageHandlers: { kiroSession: { postMessage(m) { posted.push(m); } } } };
  }
  const ctx = { window, document };
  return { ctx, posted, listeners, nodes, byId, run: (src) => vm.runInNewContext(src, ctx) };
}

console.log('\n== sessionBridge');
let p = page();
p.run(bridge);
expect(p.posted.length === 1 && p.posted[0].event === 'ready', 'says ready at document start', JSON.stringify(p.posted));
const style = p.byId[styleID];
expect(!!style && style.tag === 'style', 'adds the banner-hiding style element');
expect(style && /#mc-session-expired\s*\{\s*display\s*:\s*none\s*!important\s*\}/.test(style.textContent),
       'hides #mc-session-expired with display:none!important (CSS only)', style && style.textContent);
p.ctx.window.dispatch('mc-auth-required');
expect(p.posted.some((m) => m.event === 'auth-required'), 'forwards mc-auth-required');
p.ctx.window.dispatch('mc-auth-cleared');
expect(p.posted.some((m) => m.event === 'auth-cleared'), 'forwards mc-auth-cleared');
p.ctx.window.dispatch('mc-something-else');
expect(p.posted.length === 3, 'forwards nothing else', JSON.stringify(p.posted));

p = page({ withHead: false });
p.run(bridge);
expect(!!p.byId[styleID], 'with no <head> yet (document start), the style goes on <html>');

p = page({ withHandler: false });
p.run(bridge);
expect(p.posted.length === 0 && !p.byId[styleID] && Object.keys(p.listeners).length === 0,
       'no message handler (the page world, or a broken bridge): the banner is left visible');

console.log('\n== revealSessionBanner');
p = page();
p.run(bridge);
p.run(reveal);
expect(!p.byId[styleID], 'removes the style again (the R22 fallback)');
p.run(reveal);
expect(true, 'is harmless when the style is already gone');

console.log(failures === 0 ? `\n${checks}/${checks} session bridge checks passed` : `\n${failures} of ${checks} session bridge checks FAILED`);
process.exit(failures === 0 ? 0 : 1);
