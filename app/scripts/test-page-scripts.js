// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Runs App/Browser/PageScriptSources.swift's scripts under Node against a
// fake window.location / window.history. Invoked by test-page-scripts.sh,
// which passes the script source on stdin.

'use strict';
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(0, 'utf8');
let failures = 0;
let checks = 0;

function run(href, state) {
  const url = new URL(href);
  const calls = [];
  const win = {
    location: { search: url.search, pathname: url.pathname, hash: url.hash },
    history: {
      state: state,
      replaceState(s, title, u) { calls.push({ state: s, url: u }); },
    },
  };
  vm.runInNewContext(source, { window: win, URLSearchParams });
  return calls;
}

function expect(cond, what, detail) {
  checks++;
  if (!cond) { failures++; console.log(`  FAIL: ${what}${detail ? '\n        ' + detail : ''}`); }
}

console.log('\n== stripSignInToken');

let c = run('https://gateway.example.ts.net/?token=SECRET');
expect(c.length === 1 && c[0].url === '/', 'bare sign-in URL becomes /', JSON.stringify(c));

c = run('https://g.example/chat?sid=abc&token=SECRET&x=1#frag');
expect(c.length === 1 && c[0].url === '/chat?sid=abc&x=1#frag',
       'other parameters and the fragment survive', JSON.stringify(c));
expect(c.length === 1 && !c[0].url.includes('SECRET'), 'the token value is gone');

c = run('https://g.example/?sid=abc');
expect(c.length === 0, 'no token: history is not touched', JSON.stringify(c));

c = run('https://g.example/');
expect(c.length === 0, 'no query at all: history is not touched');

const routerState = { usr: null, key: 'k1', idx: 0 };
c = run('https://g.example/?token=SECRET', routerState);
expect(c.length === 1 && c[0].state === routerState,
       "history.state is passed through (React Router's own state survives)");

c = run('https://g.example/?token=');
expect(c.length === 1 && c[0].url === '/', 'an empty token parameter is removed too');

c = run('https://g.example/?Token=SECRET');
expect(c.length === 0, "parameter names are case-sensitive, matching the server's own lookup");

// A throwing history must never break the page.
{
  let threw = false;
  try {
    vm.runInNewContext(source, {
      window: {
        location: { search: '?token=x', pathname: '/', hash: '' },
        history: { state: null, replaceState() { throw new Error('SecurityError'); } },
      },
      URLSearchParams,
    });
  } catch (e) { threw = true; }
  expect(!threw, 'an exception inside the script never escapes to the page');
}

console.log('');
if (failures === 0) {
  console.log(`${checks}/${checks} page script checks passed`);
} else {
  console.log(`${failures} of ${checks} page script checks FAILED`);
  process.exit(1);
}
