// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Runs PageScriptSources.calmShell under Node against a fake document (F21
// §4.4). Invoked by test-page-scripts.sh, which passes the script, the style
// id and the rule as JSON on stdin.
//
// What is checked is the exact text the app injects: one <style> whose rule
// reaches only the bundle's unresolved shell, added at document start,
// removed once the page has chosen its theme (`data-mode` on <html>), or two
// seconds after the app mounted without choosing -- and nothing at all when
// the theme is already chosen, or when the DOM refuses the element.

'use strict';
const fs = require('fs');
const vm = require('vm');

const { script, styleID, css } = JSON.parse(fs.readFileSync(0, 'utf8'));
let failures = 0;
let checks = 0;
function expect(cond, what, detail) {
  checks++;
  if (!cond) { failures++; console.log(`  FAIL: ${what}${detail ? '\n        ' + detail : ''}`); }
}

function page({ withHead = true, throwing = false, resolved = false, mounted = false } = {}) {
  const byId = {};
  const attrs = resolved ? { 'data-theme': 'kiro-light', 'data-mode': 'light' } : { 'data-theme': 'dark' };
  function node(id) {
    const n = {
      id, children: [], parentNode: null,
      get firstChild() { return this.children[0] || null; },
      appendChild(c) {
        if (throwing) { throw new Error('appendChild refused'); }
        c.parentNode = this; this.children.push(c); if (c.id) { byId[c.id] = c; }
        return c;
      },
      removeChild(c) {
        const i = this.children.indexOf(c);
        if (i >= 0) { this.children.splice(i, 1); c.parentNode = null; delete byId[c.id]; }
        return c;
      },
    };
    if (id) { byId[id] = n; }
    return n;
  }
  const root = node('');
  root.hasAttribute = (name) => Object.prototype.hasOwnProperty.call(attrs, name);
  root.getAttribute = (name) => attrs[name] ?? null;
  root.setAttribute = (name, value) => { attrs[name] = value; };
  const head = withHead ? node('') : null;
  const app = node('root');
  if (mounted) { app.appendChild(node('')); }
  const observers = [];
  const timers = [];
  class MutationObserver {
    constructor(cb) { this.cb = cb; this.disconnected = false; observers.push(this); }
    observe(target, options) { this.target = target; this.options = options; }
    disconnect() { this.disconnected = true; }
  }
  const document = {
    head, documentElement: root,
    createElement(tag) { return Object.assign(node(''), { tag, textContent: '' }); },
    getElementById(id) { return byId[id] || null; },
  };
  const ctx = {
    document, MutationObserver,
    setTimeout(fn, ms) { timers.push({ fn, ms, cleared: false }); return timers.length; },
    clearTimeout(handle) { if (timers[handle - 1]) { timers[handle - 1].cleared = true; } },
  };
  const live = () => observers.filter((o) => !o.disconnected);
  // What the page does: the bundle's ThemeProvider writes both attributes.
  const choose = () => { attrs['data-theme'] = 'kiro-light'; attrs['data-mode'] = 'light'; live().forEach((o) => o.cb([])); };
  const mount = () => { app.appendChild(node('')); live().forEach((o) => o.cb([])); };
  const style = () => byId[styleID] || null;
  return { root, head, app, observers, timers, live, choose, mount, style,
           run: () => vm.runInNewContext(script, ctx) };
}

console.log('\n== calmShell');
expect(typeof script === 'string' && script.length > 0, 'Swift built the script');
const rules = css.split('}').map((r) => r.trim()).filter(Boolean);
expect(rules.length === 3 && rules.every((r) => r.startsWith('html[data-theme="dark"]:not([data-mode])')),
       "three rules, each reaching only the shell's unresolved dark default", css);
expect(css.includes('html[data-theme="dark"]:not([data-mode]) { color-scheme: light dark !important; }'),
       "the root's base canvas follows the phone, not the shell's dark scheme", css);
expect(css.includes('html[data-theme="dark"]:not([data-mode]) body { background-color: transparent !important; }'),
       'the body paints nothing over it', css);
expect(css.includes('html[data-theme="dark"]:not([data-mode]) #root { visibility: hidden !important; }'),
       'and the app, mounted before it has chosen, is invisible rather than dark', css);
expect(!/display\s*:|position\s*:|(?<![\w-])color\s*:|width\s*:|height\s*:/.test(css),
       'no display, position, size or text colour: the mildest declarations', css);

let p = page();
p.run();
expect(!!p.style() && p.style().tag === 'style' && p.style().parentNode === p.head,
       `one <style id="${styleID}"> is added to <head>`, JSON.stringify(p.head.children.map((c) => c.id)));
expect(p.style() && p.style().textContent === css, 'carrying the rule', p.style() && p.style().textContent);
expect(p.live().length === 1 && p.live()[0].target === p.root
       && p.live()[0].options.attributeFilter.includes('data-mode') && p.live()[0].options.childList === true,
       "it watches <html> for the page's choice and the app's mount");
p.run();
expect(p.head.children.length === 1, 'run again on the same document: still one element');

p.choose();
expect(p.style() === null, 'once <html> carries data-mode, the style is gone');
expect(p.live().length === 0, 'and the observer is disconnected');
expect(p.timers.every((t) => t.cleared), 'with no timer left running');

p = page({ withHead: false });
p.run();
expect(!!p.style() && p.style().parentNode === p.root, 'with no <head> yet (document start), it goes on <html>');

p = page({ resolved: true });
p.run();
expect(p.style() === null && p.observers.length === 0,
       'a document whose theme is already chosen gets nothing: no style, no observer');

p = page();
p.run();
p.mount();
expect(!!p.style(), 'the app mounting without choosing does not remove the style at once');
expect(p.timers.length === 1 && p.timers[0].ms === 2000 && !p.timers[0].cleared,
       'it starts one 2 s timer', JSON.stringify(p.timers.map((t) => t.ms)));
p.mount();
expect(p.timers.length === 1, 'further mutations start no second timer');
p.timers[0].fn();
expect(p.style() === null && p.live().length === 0,
       'when it fires, the paint is handed back to the page and the observer is disconnected');

p = page();
p.run();
p.mount();
p.choose();
expect(p.style() === null && p.timers[0].cleared, 'a choice made before the timer fires cancels it');

p = page({ throwing: true });
let threw = false;
try { p.run(); } catch (e) { threw = true; }
expect(!threw, 'a DOM that refuses the element does not throw into the page');
expect(p.observers.length === 0, 'and nothing is left watching');

console.log(failures === 0 ? `\n${checks}/${checks} calm-shell checks passed` : `\n${failures} of ${checks} calm-shell checks FAILED`);
process.exit(failures === 0 ? 0 : 1);
