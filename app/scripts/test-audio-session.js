// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Runs PageScriptSources.audioSessionPlayback (issue #10) under Node
// against a fake navigator. Invoked by test-page-scripts.sh, which passes
// the script source as JSON on stdin.

'use strict';
const fs = require('fs');
const vm = require('vm');

const { script } = JSON.parse(fs.readFileSync(0, 'utf8'));
let failures = 0;
let checks = 0;

function expect(cond, what, detail) {
  checks++;
  if (!cond) { failures++; console.log(`  FAIL: ${what}${detail ? '\n        ' + detail : ''}`); }
}

class Track {
  constructor() { this.listeners = []; this.stopped = 0; }
  stop() { this.stopped++; }
  addEventListener(name, f) { if (name === 'ended') this.listeners.push(f); }
  end() { this.listeners.forEach((f) => f()); }
}

// A page with the Audio Session API and getUserMedia. `deny` makes the
// next audio request fail; `typeAtCall` records the type WebKit would see.
function page({ session = true, mediaDevices = true } = {}) {
  const p = { typeAtCall: [], deny: false, calls: [] };
  p.navigator = {};
  if (session) p.navigator.audioSession = { type: 'auto' };
  if (mediaDevices) {
    p.navigator.mediaDevices = {
      getUserMedia(c) {
        p.calls.push({ c, self: this });
        p.typeAtCall.push(p.navigator.audioSession && p.navigator.audioSession.type);
        if (p.deny) return Promise.reject(new Error('NotAllowedError'));
        const tracks = c.audio ? [new Track()] : [];
        return Promise.resolve({ getAudioTracks: () => tracks, tracks });
      },
    };
  }
  vm.runInNewContext(script, { navigator: p.navigator, Set, Promise });
  return p;
}

(async () => {
  console.log('\n== audioSessionPlayback');

  let p = page();
  const s = p.navigator.audioSession;
  expect(s.type === 'playback', 'the page starts in playback', s.type);

  const pending = p.navigator.mediaDevices.getUserMedia({ audio: true });
  expect(s.type === 'auto', 'an audio request hands the type back to WebKit', s.type);
  expect(p.typeAtCall[0] === 'auto', 'WebKit sees auto when capture starts', p.typeAtCall[0]);
  const stream = await pending;
  expect(p.calls[0].self === p.navigator.mediaDevices, 'getUserMedia keeps its receiver');
  expect(s.type === 'auto', 'it stays auto while the mic track is live', s.type);
  stream.tracks[0].stop();
  expect(stream.tracks[0].stopped === 1, 'the real stop() still runs');
  expect(s.type === 'playback', 'playback returns when the track stops', s.type);

  // Two captures overlap: playback only after both end, stop or 'ended'.
  const a = await p.navigator.mediaDevices.getUserMedia({ audio: true });
  const b = await p.navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true } });
  a.tracks[0].end();
  expect(s.type === 'auto', 'one of two tracks ended: still auto', s.type);
  b.tracks[0].stop();
  b.tracks[0].stop();
  expect(s.type === 'playback', 'both done: playback', s.type);

  // Video only: untouched.
  await p.navigator.mediaDevices.getUserMedia({ video: true });
  expect(p.typeAtCall[p.typeAtCall.length - 1] === 'playback', 'a video-only request passes through');
  expect(s.type === 'playback', 'and leaves playback', s.type);

  // A refused request restores playback and rethrows.
  p.deny = true;
  let threw = null;
  try { await p.navigator.mediaDevices.getUserMedia({ audio: true }); } catch (e) { threw = e; }
  expect(threw && threw.message === 'NotAllowedError', 'a refusal reaches the page unchanged', String(threw));
  expect(s.type === 'playback', 'and playback returns', s.type);

  // No Audio Session API: nothing is wrapped.
  p = page({ session: false });
  const before = p.navigator.mediaDevices.getUserMedia;
  expect(!('audioSession' in p.navigator), 'no API: nothing is added');
  expect(p.navigator.mediaDevices.getUserMedia === before, 'no API: getUserMedia is untouched');

  // No mediaDevices (insecure context): still playback, no throw.
  p = page({ mediaDevices: false });
  expect(p.navigator.audioSession.type === 'playback', 'no mediaDevices: playback anyway');

  // A setter that throws never escapes to the page.
  let escaped = false;
  try {
    const nav = {};
    Object.defineProperty(nav, 'audioSession', { get() { throw new Error('boom'); } });
    vm.runInNewContext(script, { navigator: nav, Set, Promise });
  } catch (e) { escaped = true; }
  expect(!escaped, 'an exception inside the script never escapes to the page');

  console.log('');
  if (failures === 0) {
    console.log(`${checks}/${checks} audio session checks passed`);
  } else {
    console.log(`${failures} of ${checks} audio session checks FAILED`);
    process.exit(1);
  }
})();
