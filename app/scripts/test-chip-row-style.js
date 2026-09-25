// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Runs PageScriptSources.chipRowStyle(origin:) under Node against a fake
// window/document (F5 §6, §9). Invoked by test-page-scripts.sh, which passes
// the script built for ORIGIN, the style id and what Swift returned for a
// refused origin, as JSON on stdin.

'use strict';
const fs = require('fs');
const vm = require('vm');

const { script, origin, styleID, refused } = JSON.parse(fs.readFileSync(0, 'utf8'));
let failures = 0;
let checks = 0;
function expect(cond, what, detail) {
  checks++;
  if (!cond) { failures++; console.log(`  FAIL: ${what}${detail ? '\n        ' + detail : ''}`); }
}

function page(at, { withHead = true, throwing = false } = {}) {
  const appended = [];
  const byId = {};
  const container = {
    appendChild(n) {
      if (throwing) { throw new Error('appendChild refused'); }
      appended.push(n); if (n.id) { byId[n.id] = n; }
    },
  };
  const document = {
    head: withHead ? container : null,
    documentElement: container,
    createElement(tag) { return { tag, id: '', textContent: '' }; },
    getElementById(id) { return byId[id] || null; },
  };
  const ctx = { window: { location: { origin: at } }, document };
  return { appended, byId, run: () => vm.runInNewContext(script, ctx) };
}

console.log('\n== chipRowStyle');
expect(typeof script === 'string' && script.length > 0, 'Swift built a script for the gateway origin');

let p = page(origin);
p.run();
const style = p.byId[styleID];
expect(p.appended.length === 1 && !!style && style.tag === 'style',
       `on ${origin}: one <style id="${styleID}"> is appended`, JSON.stringify(p.appended));
const css = style ? style.textContent : '';
expect(css.includes('(width <= 767px)'), "gated by the bundle's own phone breakpoint", css);
expect(css.includes('.tb-left > .instance-tab-bar-inline[role="group"]'), 'the full three-part selector', css);
expect(css.includes('overflow-x: auto'), 'the bar scrolls', css);
expect(css.includes('flex-shrink: 0'), 'its wrapper keeps its content width', css);
expect(!/display\s*:|position\s*:|width\s*:\s*\d/.test(css.replace('(width <= 767px)', '')),
       'no display, position or size: the mildest declarations', css);

p.run();
expect(p.appended.length === 1, 'run again on the same document: still one element', JSON.stringify(p.appended));

p = page(origin, { withHead: false });
p.run();
expect(p.appended.length === 1, 'with no <head> yet (document start), it goes on <html>');

for (const other of ['https://evil.example', origin + ':8443', origin.replace('https:', 'http:'), 'null']) {
  p = page(other);
  p.run();
  expect(p.appended.length === 0, `on another origin (${other}): nothing is appended`, JSON.stringify(p.appended));
}

p = page(origin, { throwing: true });
let threw = false;
try { p.run(); } catch (e) { threw = true; }
expect(!threw, 'a DOM that refuses the element does not throw into the page');

expect(refused === null, 'an origin with a quote in it is refused by Swift before substitution', String(refused));

console.log(failures === 0 ? `\n${checks}/${checks} chip-row style checks passed` : `\n${failures} of ${checks} chip-row style checks FAILED`);
process.exit(failures === 0 ? 0 : 1);
