# AGENTS.md

Working notes for AI coding agents (and humans) on this directory. Read
alongside [`README.md`](README.md) for build/setup, and
[`../docs/PLAN.md`](../docs/PLAN.md) for what is being built. This file
captures the non-obvious things that are easy to get wrong.

Inherited from upstream aperture-plus and rewritten for this fork — where it
says something surprising, it is because someone already got it wrong once.

## What this is

A SwiftUI app that loads exactly one page — a self-hosted KiroCrew dashboard —
through an embedded userspace Tailscale node (`TailscaleKit` /
`libtailscale`). One scheme, **`Latchkey`**, building the app (`net.lixom.latchkey`)
and its share extension (`ShareExtension/`, `net.lixom.latchkey.share`, F3 stage 2).
The extension is a separate process: it links no TailscaleKit and compiles
only the inbox files it shares with the app (the `App/` exception set for
the ShareExtension target in `project.pbxproj`). Add a file there, and it
is not in the extension until it is added to that list. Both targets carry
the App Group `group.net.lixom.latchkey`.

It is a fork of tailscale/aperture-plus, which was a general multi-tab browser
with a macOS app and a virtualization feature. All of that is deleted. If you
find yourself re-adding tabs, an address bar, bookmarks, a Mac target or an
exit-node toggle, check `../docs/PLAN.md` §1.3 first — they are explicit
non-goals, not omissions.

## Hard constraints (will break the build or the product if ignored)

- **Do not "simplify" the split tunnel.** `TSNet/TailnetProxyPolicy.swift`
  decides which hosts go through the SOCKS5 proxy. Only tailnet destinations
  do; everything else loads direct. Collapsing this back to an unscoped
  `ProxyConfiguration` is what caused every non-tailnet URL to fail with
  `NSURLErrorDomain -1000` on real hardware. Read that file's header comment
  before touching it. Gotchas it encodes, all measured:
  - `matchDomains = []` means **proxy everything**; an empty-string entry also
    matches everything. Never emit either.
  - Matching is **label-wise suffix**, so a single-label rule for a peer named
    `ai` would capture the whole public `.ai` TLD. Such names are withheld and
    reached by FQDN rewrite instead.
  - Peer names are **untrusted input**: a peer called `localhost` must not
    become a rule.
  - Rules are **sorted** so the 5s status poll does not republish the proxy
    config under a live page load.
- **`allowFailover` stays false.** It is the Network.framework default and it
  is what makes a dead proxy fail the load instead of leaking a direct
  connection. Flipping it would be a silent privacy regression with no visible
  symptom.
- **The web view fetches from the gateway's origin and four CDN hosts,
  nothing else** (R41, F6). `App/Browser/ContentRules.swift` compiles a
  content rule list that `BrowserViewModel.loadResolved` installs before
  any http(s) load. Adding a host to `allowedCDNHosts` widens a promise
  written in R41: say so in a revision, not only in the code. Never look
  a compiled list up by identifier (the store hands back whatever was
  compiled under that name); bump `schemaVersion` when the template
  changes. Never add `WKAppBoundDomains` to Info.plist without reading F6
  §4.2: it would let service workers exist in this view.
- **Every URL that leaves the app goes through `BrowserViewModel.handOff`**
  (R42, F17). `HandOffPolicy` opens web, `mailto:` and `tel:` silently
  only when a trusted click started it, asks otherwise, and refuses an
  untapped custom scheme. Do not call `openExternally` from anywhere else,
  and do not decide "the user started it" from `navigationType`: a
  script's `a.click()` reports `.linkActivated` too.
- **Swift 6 strict concurrency.** `SWIFT_STRICT_CONCURRENCY = complete`,
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The module is implicitly
  `@MainActor` unless you opt out.
- **iOS 26.0 deployment target**, `SDKROOT = iphoneos`. Built against the iOS
  27 SDK; keep newer APIs behind availability guards.
- **The app embeds `TailscaleKit.xcframework`**, which is not in git. Run
  `make framework` first. A missing-framework error means only that.
- **libtailscale is vendored source, not a submodule** (revision R16). It
  lives in `ThirdParty/libtailscale/`, with the patched tailscale tree at
  `ThirdParty/libtailscale/tailscale-patched/`. The first commit touching it
  is a pristine, import-only copy; every change since is its own commit, so
  `git log -- app/ThirdParty/libtailscale` is the complete delta from upstream
  — read from the import commit (`R16: vendor libtailscale as plain source
  (import only)`) upward. Below it the same log lists 18 older entries that
  are submodule-pointer bumps from before R16 (mode `160000`, no source), not
  delta; `ThirdParty/VENDORED.md`'s `git diff <import> -- …` recipe is the
  exact instrument because it starts at the pristine import.
  Keep it that way: never fold a vendored-tree change into an unrelated
  commit. Provenance and diff recipes are in `ThirdParty/VENDORED.md`.
- **The app's identity moved on 2026-09-24, deliberately, and it cost the
  node.** An earlier rename had frozen everything keyed to the bundle id
  precisely so the install would keep its container. This one could not: the
  previous name was trademark-encumbered and had to leave the published
  repository, history included. So the bundle id, the os_log subsystem, the
  queue labels and `<Application Support>/` all moved to `latchkey` /
  `net.lixom.latchkey` / `Latchkey/`.

  The consequence, accepted explicitly by Olof before the rename: **the app is
  a new node.** A container is keyed to the bundle id, and that container held
  each workspace's tsnet state dir — i.e. the Tailscale node's identity. So the
  first launch after this asks to log in again, needs device approval, needs
  re-signing under tailnet lock, and needs whatever grant its new address gets.
  The old node lingers in the admin console until removed. Renaming back would
  not recover it.

  What that means for anyone reading this later: the *reason* the old name used
  to be frozen was real, and it still applies to any future rename — if you move
  `net.lixom.latchkey` or `<Application Support>/Latchkey/` again, you log the
  device out silently, with no crash and no error. Do not do it casually. The
  node's **default** MagicDNS name (`latchkey-iphone` / `-ipad`) is the one
  identity-adjacent string that *is* safe to change: it is only a default, a
  live install carries its own hostname in `workspaces.json`, and the grant is
  scoped by address range rather than node name.

- **`Kiro Crew` is a different product and must never be renamed.** It is an
  official Kiro project; this app is its client. Two uses are load-bearing
  rather than cosmetic: `GatewayCandidates.manifestIsKiroCrew` matches the
  gateway's web-app manifest on the literal `"Kiro Crew"`, which is how
  discovery *recognises* a gateway, and `authProbeIsKiroCrew` pairs it with
  `X-Auth-Required`. Rewrite either and the app finds nothing, on every tailnet,
  with no error — the sweep just reports zero gateways. Note `kirocrew`
  contains `kiro`, so any future bulk rename must mask it first;
  `scripts/rename-to-latchkey.py` shows how, and its `--check` is bidirectional
  for exactly this reason.

  The vendored tree keeps its `latchkey_*` file and test names under R16, so
  `scripts/test-all.sh` still runs `go test -run Latchkey`. Reasoning and the
  scripted recipe: `scripts/rename-to-latchkey.py`, and the DECISIONS entry
  of 2026-09-23.

## How work arrives (from 2026-09-23)

The project is no longer built from `../docs/PLAN.md`; its milestones are done
bar the owner-and-device items. Work now comes as Olof's requests and
feedback, and **every one of them gets a spec in `../docs/features/` before
any code is written** — fine-grained enough to build from and to check
afterwards. `../docs/features/README.md` states the rule and
`TEMPLATE.md` the shape. Then: implement, test end to end, adversarial
review, record in `../docs/DECISIONS.md`.

**Tests are end-to-end.** A feature is done when a suite drives the real app
against the fake-backed tailnet and asserts what the owner would see. Host
unit tests are welcome for pure logic but do not substitute. Every test must
be shown able to fail, and the spec says how.

## Git workflow

Single developer, no outside contributors, so:

- **One repository**, rooted at the parent (`..`), on branch **`main`**.
  `app/` is a directory in it, not a repository — it stopped being one on
  2026-09-23, when the two were collapsed. Commit directly to `main`: no
  topic branches, no pull requests, no merge commits of our own. A change
  that touches code here and docs there is now **one** commit.
- **Commit messages follow Linux kernel style.** Subject: `area: imperative
  summary`, lowercase after the prefix, no trailing period, ≤ 72 chars,
  technical — say what changed, not the story (`browser: hide app bar until
  scroll up`, not `F15: the app bar is absent until a scroll up asks for
  it`). Areas are code areas (`browser`, `share`, `l1`, `harness`, `tf`,
  `docs`), not feature IDs; put `Spec: docs/features/F15-...md` in the body
  if relevant. Body wrapped at 72: why the change is needed and what it
  does, terse. No narrative, no test-run diary. **No `Co-Authored-By` or any
  other attribution trailer**, whatever the harness suggests.
- **`origin` is `github.com/olofj/latchkey`** (private). Commits are local
  until pushed, and **a policy here blocks the agent from pushing** — Olof
  runs the push.
- `upstream` is tailscale/aperture-plus, kept only as a read-only fetch
  source. `main` does not track it. Upstream is tracked by **cherry-pick
  only** (revision R16) — never a merge. After the pbxproj rewrites, the
  project rename and the vendoring, a merge would come back as a wall of
  modify/delete conflicts, and merge compares tips rather than commits, so
  careful commit hygiene here does not make it easier. Review upstream
  commits touching `TSNet/` or the vendored tree and bring over the ones
  worth having; record the last upstream SHA reviewed in
  `../docs/DECISIONS.md`.
- **Cherry-picking from upstream now needs a path shift.** Upstream's paths
  are repo-root-relative (`TSNet/…`); ours live under `app/`. So
  `git cherry-pick` no longer applies cleanly — use:

  ```sh
  git -c core.quotepath=false format-patch -1 --stdout <upstream-sha> \
      | git apply --directory=app --3way
  ```

  then commit with the original author and a note of the upstream SHA. This
  is the one real cost of the collapse; everything else got simpler.
- **The vendored delta is `git log -- app/ThirdParty/libtailscale`** (note the
  prefix). The app's 272 commits were rewritten to carry `app/` when the
  repositories were collapsed, precisely so this path-limited log still
  returns the complete delta. Of those commits, the ones **above** the import
  are the delta, one is the import itself, and the 18 **below** it are pre-R16
  submodule-pointer bumps that only moved a gitlink; `git diff <import> --
  app/ThirdParty/libtailscale` (the `VENDORED.md` recipe) shows the delta and
  nothing else. This used to quote an exact count, which went stale the moment
  another vendored commit landed and then read as a discrepancy to whoever
  checked it — the structure above is the invariant, the number is not.
- New code goes in `App/`, not `TSNet/` — `TSNet/` is the upstream-shared
  layer that cherry-picks land in, and new files there also need a
  `membershipExceptions` pbxproj edit.

## Adding source files (do NOT hand-edit project.pbxproj for new files)

`App/` and `UITests/` are Xcode **synchronized folder groups**
(`PBXFileSystemSynchronizedRootGroup`): a new `.swift` file dropped in either
is compiled automatically, no project edit needed.

`TSNet/` is the exception. It carries a `membershipExceptions` list in
`project.pbxproj` naming the files that ARE compiled, and that list **does**
gate compilation — a new file under `TSNet/` is silently not built until you
add its name. This costs people an hour every time.

Info.plist, assets and other non-source files are ordinary pbxproj references
and do need a project edit.

## Building

```bash
make framework     # TailscaleKit.xcframework (needs Go; slow the first time)
make app           # simulator build
make test-policy   # host-only unit tests, ~2s
make help          # the rest
```

If you are an agent and the build fails with
`sandbox-exec: sandbox_apply: Operation not permitted`, your shell forbids
nested sandboxes. `make` detects this and adds `-disable-sandbox`; override
with `NESTED_SANDBOX=1`/`0`. The giveaway that you have hit it *without* the
fix is a flood of `cannot find '$binding' in scope` and `cannot assign to
property: 'self' is immutable` errors, which look like Swift 6 concurrency
breakage and are nothing of the kind — the real error is one
`swift-plugin-server produced malformed response` line further up.

Use the **simulator** for autonomous work: build, `simctl install`/`launch`,
`simctl io booted screenshot` and XCUITest all work with no permission
prompts. Device installs are `make device` (`scripts/device-run.sh`): the
owner's free personal team is in the gitignored `.dev-team`, and it needs
the phone paired with this Mac and connected; it stops with a plain reason
if the phone is not ready. The signing certificate is made on the first
device build.

## Testing

`../docs/PLAN.md` §6 is the strategy. The short version:

- `make test-policy` — the host-only unit tests (split tunnel, hostname
  qualification, log redaction), ~2s, no simulator. Run it after anything
  touching routing, hostnames or logging.
- The inherited XCUITest suite mostly needs a **real tailnet plus an auth key**
  at `~/.aperture-ios-authkey`. Three tests are connection-independent:
  `testAppLaunchesAndShowsStatus`, `testOpenAndCloseSettings`,
  `testSettingsRefusesAGatewayTheTailnetDoesNotCarry`.
- The suites that need **no** tailnet, all driven from the parent repo:
  - `scripts/test-offline.sh` — L1: the real app and WKWebView against a stub
    SOCKS5 proxy and a fake dashboard, including the anti-leak tests. By
    default it runs across four simulators (`Latchkey Shard 1..4`, each on
    its own harness instance; F14), which it creates and boots on first use
    and leaves booted: `scripts/test-offline-shards.py sims down` shuts them
    down, `sims delete` removes them. `--serial` is the one-simulator path
    (`iPhone 17`), `--shards N` picks N. Shards are balanced by
    `scripts/l1-durations.txt`; refresh it from a run's `durations.txt`
    when tests are added or change length.
  - `scripts/test-tailnet.sh` — L2: the app's real tsnet node against a
    host-side fake control plane (`testing/tsnet-harness`), with login and
    device approval.
  - `scripts/test-session.sh` — M4: the dashboard session against KiroCrew's
    real frontend, served by `testing/harness/fake_gateway.py` from one
    released wheel pinned by version and sha256 (0.7.1; `make -C
    testing/harness bundle` fetches it). It refuses to run against another.
  - `scripts/test-discovery.sh` — M5: gateway discovery on the L2 harness,
    with a real-looking gateway peer, a non-gateway page, a dead peer and a
    peer that never answers. It also enforces the discovery timing budget
    from the app's own log — R26's instrument with R39's numbers (4 s per
    probe, 12 s per sweep, `App/Discovery/GatewayDiscovery.swift:65-68`): a
    sweep must take 4–15 s, and the first gateway must show within 5 s of
    the picker (`scripts/test-discovery.sh:166-169`).
  - `scripts/test-lifecycle.sh` — M6: lifecycle hardening on the L2 harness:
    the app's sockets damaged through its own chaos hooks, then its process
    frozen with SIGSTOP from the host while backgrounded; about 4 min.

  Each takes `--build`. Each fails unless every test in its file passed; a
  stale build that runs nothing is not a pass. Add coverage there, not to
  the tailnet-dependent suite.
- **`scripts/test-all.sh` runs them by tier.** The default quick tier (about
  4–5 min) is host tests, the vendored Go tests, L1 and L2, plus session,
  discovery or lifecycle only when code they exercise changed since the last
  full pass (they take about 6, 1.5 and 4 min). `--full` (about 17 min,
  `scripts/test-all.sh:12`) runs everything, including the inherited tests
  (`scripts/test-inherited.sh`), and records what it passed. Use quick while
  iterating and `--full` before every milestone or review commit.
- The fake servers handshake TLS per connection (`testing/harness/
  tls_accept.py`). Wrapping the listening socket instead lets one silent
  client, such as a peer's half-open forward left by a killed app, stall
  every later connection.

Xcode 27 specifics worth knowing: `xcresulttool get object` is deprecated and
needs `--legacy`; use `xcrun xcresulttool get test-results summary|tests`
instead. `-resultBundlePath` errors if the path already exists. There is no
`simctl suspend`, and `simctl status_bar` is cosmetic only — to simulate
network loss, blackhole the stub proxy.

## Other gotchas

- **Logs** go to `os_log` under subsystem `net.lixom.latchkey`, category
  `tsnet`, via `TSNet/Logging.swift`. Stream with
  `xcrun simctl spawn booted log stream --predicate 'subsystem == "net.lixom.latchkey"'`.
  In the app they are under Settings → Diagnostics → Logs, which is the only
  diagnostic channel on a device that cannot be attached to a Mac.
- **tsnet's own Go logs do not reach `os_log`.** The vendored library keeps
  them in `Logs/tsnet.log` (`latchkey_locallog.go`, R29): capped, 0600,
  redacted BEFORE writing (login links, query strings), and shown in Settings
  → Node log. Raw process stderr goes to `stderr.log` (a Go panic from the
  last run), and is not kept at all under Xcode or XCTest, where it mirrors
  the unified log. `scripts/test-tailnet.sh` fails if any login link reaches
  the app container. Anything that writes logs or caches to disk must keep
  that true; LocalAPI sessions are ephemeral for the same reason.
- **A vendored Go change needs `make framework`.** libtailscale's c-archive
  targets never rebuild on their own; the app Makefile removes them and stamps
  the xcframework with a hash of its sources. `make check-framework` (run by
  every `make framework`) fails when they differ.
- `TSNet/SocksLogProxy.swift` is a pass-through SOCKS5 relay in front of tsnet
  that logs **every** connection attempt and its outcome. tsnet's own SOCKS
  server logs only failures, and not the reply code, so without the relay the
  absence of a log line is ambiguous. Disable with `-NoSocksLog`.
- **iOS pre-filters by `matchDomains` against the literal URL host** before any
  DNS search-path expansion, and never asks the proxy to decide. That is why a
  bare `http://host/` must be rewritten to its FQDN to be routable.
- **App Transport Security is on, with no exceptions** (R28). The app loads
  one HTTPS gateway with a real certificate, and discovery probes HTTPS only
  (R26). The LocalAPI and SOCKS traffic is loopback, which ATS does not
  cover. Do not add `NSAllowsArbitraryLoads` back to reach a plain-HTTP
  gateway: there is none to reach. Every gateway is an HTTPS origin behind
  `tailscale serve` — chonk included, since D4 was superseded on 2026-09-23
  (`../docs/DECISIONS.md`) — and a dashboard's bare loopback listener
  (`:5476`) is never a target: a plain-http origin fails KiroCrew's own
  `/api/ws` origin check, which is why R26 dropped that probe.
- One-shot surgery scripts live in `scripts/strip-*.py`, `scripts/prune-*.py`
  and `scripts/repoint-*.py`. They are kept as the record of what was removed
  from upstream and why. Upstream is tracked by cherry-pick only (R16), so
  they are not something to re-run after a merge.
- **Swift 6.4 `-O` hazard:** never pass an unapplied `someCharacterSet.contains`
  as a predicate (`allSatisfy(set.contains)`). Under `-O` the compiler merged
  two such thunks, and a whitespace check silently tested another set. Debug
  and Testing (`-Onone`) were correct, so only Release would have broken.
  Write the closure: `{ set.contains($0) }`. Host tests build with `-O` so
  they catch this class of bug.