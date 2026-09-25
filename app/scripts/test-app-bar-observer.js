// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Runs PageScriptSources.appBarObserver (F15 §4a) under Node against a fake
// window. Invoked by test-page-scripts.sh, which passes {"observer": source}
// on stdin, so what is tested is the exact text the app injects.
//
// The contract that matters most is F15 §4b's last line: the bar observes
// the page's scroll and never takes part in it. So every listener must be
// passive and in the capture phase, and no handler may call preventDefault
// or stopPropagation.

'use strict';
const fs = require('fs');
const vm = require('vm');

const { observer } = JSON.parse(fs.readFileSync(0, 'utf8'));
let failures = 0;
let checks = 0;

function expect(cond, what, detail) {
  checks++;
  if (!cond) { failures++; console.log(`  FAIL: ${what}${detail ? '\n        ' + detail : ''}`); }
}

function setup({ scale = 1, handler = true } = {}) {
  const listeners = {};
  const posts = [];
  const frames = [];
  const document = { scrollingElement: { scrollHeight: 800, clientHeight: 800 } };
  const win = {
    innerWidth: 402, innerHeight: 778,
    visualViewport: { scale },
    webkit: handler ? { messageHandlers: { latchkeyAppBar: { postMessage: (m) => posts.push(m) } } } : undefined,
    addEventListener(type, fn, opts) { (listeners[type] = listeners[type] || []).push({ fn, opts }); },
  };
  const tampered = [];
  function fire(type, props) {
    const ev = Object.assign({
      preventDefault() { tampered.push(`preventDefault on ${type}`); },
      stopPropagation() { tampered.push(`stopPropagation on ${type}`); },
      stopImmediatePropagation() { tampered.push(`stopImmediatePropagation on ${type}`); },
    }, props);
    for (const l of listeners[type] || []) l.fn(ev);
  }
  const touch = (x, y) => ({ touches: [{ clientX: x, clientY: y }] });
  const flush = () => { while (frames.length) frames.shift()(); };
  vm.runInNewContext(observer, { window: win, document, requestAnimationFrame: (f) => frames.push(f) });
  return { listeners, posts, fire, touch, flush, win, document, tampered };
}

console.log('\n== appBarObserver: observes, never takes part');
let s = setup();
const types = Object.keys(s.listeners).sort();
expect(JSON.stringify(types) === JSON.stringify(['scroll', 'touchcancel', 'touchend', 'touchmove', 'touchstart']),
       'listens to touches and scroll, nothing else', JSON.stringify(types));
for (const [type, ls] of Object.entries(s.listeners)) {
  for (const l of ls) {
    expect(l.opts && l.opts.passive === true, `${type}: passive, so it can never cancel a scroll`);
    expect(l.opts && l.opts.capture === true, `${type}: capture phase on window, so it sees every element's scroll`);
  }
}

console.log('\n== a drag up over an inner scroller');
s = setup();
s.fire('touchstart', s.touch(200, 600));
s.fire('touchmove', s.touch(200, 590));
s.fire('touchmove', s.touch(200, 570));
s.fire('scroll', { target: { scrollHeight: 4800, clientHeight: 734 } });
s.flush();
s.fire('touchmove', s.touch(201, 500));
s.fire('touchend', { touches: [] });
s.flush();
expect(s.posts[0] && s.posts[0].p === 's', 'touch-down is posted first', JSON.stringify(s.posts));
const moves = s.posts.filter((m) => m.p === 'm');
const total = moves.reduce((a, m) => a + m.dy, 0);
expect(total === -100, 'the moves add up to the finger\'s travel (-100)', JSON.stringify(s.posts));
expect(moves.length === 2, 'moves are coalesced to one per frame, and the rest flushed on lift', JSON.stringify(moves));
expect(moves[moves.length - 1].r === 4066, 'the inner scroller\'s range is reported', JSON.stringify(moves));
expect(s.posts[s.posts.length - 1].p === 'e', 'the lift is posted last');
expect(s.tampered.length === 0, 'no handler touched the events', s.tampered.join(', '));

console.log('\n== a page too short to scroll reports range 0');
s = setup();
s.fire('touchstart', s.touch(200, 600));
s.fire('touchmove', s.touch(200, 400));
s.fire('scroll', { target: s.document });   // the rubber band at the top: the document "scrolls"
s.fire('touchend', { touches: [] });
expect(s.posts.filter((m) => m.p === 'm').every((m) => m.r === 0),
       'a document with nothing to scroll counts as nothing scrolled', JSON.stringify(s.posts));

console.log('\n== the bar\'s own resize is not travel');
s = setup();
s.fire('touchstart', s.touch(200, 600));
s.fire('touchmove', s.touch(200, 500));
s.flush();
s.win.innerHeight += 44;                  // the bar retracted: same finger, clientY +44
s.fire('touchmove', s.touch(200, 544));
s.fire('touchmove', s.touch(200, 534));
s.fire('touchend', { touches: [] });
const after = s.posts.filter((m) => m.p === 'm').reduce((a, m) => a + m.dy, 0);
expect(after === -110, 'the viewport change re-bases the finger instead of counting +44 of travel', JSON.stringify(s.posts));

console.log('\n== screen points, not CSS pixels');
s = setup({ scale: 2 });
s.fire('touchstart', s.touch(100, 300));
s.fire('touchmove', s.touch(100, 250));
s.fire('touchend', { touches: [] });
expect(s.posts.some((m) => m.p === 'm' && m.dy === -100), 'travel scales with the visual viewport', JSON.stringify(s.posts));

console.log('\n== a second finger ends the drag');
s = setup();
s.fire('touchstart', s.touch(100, 300));
s.fire('touchstart', { touches: [{ clientX: 1, clientY: 1 }, { clientX: 2, clientY: 2 }] });
s.fire('touchmove', { touches: [{ clientX: 1, clientY: 100 }, { clientX: 2, clientY: 200 }] });
expect(s.posts.map((m) => m.p).join('') === 'se', 'touch-down, then lift, and no pinch travel', JSON.stringify(s.posts));

console.log('\n== no handler: the script does nothing');
s = setup({ handler: false });
expect(Object.keys(s.listeners).length === 0, 'no listeners without the app\'s handler');

console.log('');
if (failures === 0) {
  console.log(`${checks}/${checks} app bar observer checks passed`);
} else {
  console.log(`${failures} of ${checks} app bar observer checks FAILED`);
  process.exit(1);
}
