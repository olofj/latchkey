# F22 — The app bar lists the gateways, with a light for each

| | |
|---|---|
| **Status** | **built** 2026-09-28, overnight; product calls by the building worker, Olof asleep (§8). Issue [#6](https://github.com/olofj/latchkey/issues/6). Owner's device look (§7.5) outstanding |
| **Requested** | 2026-09-27, by Olof: "Idea: in the iOS UI, on the row with the cogwheel, do a row of the different remote dashboards available. Similar UI / look as the list on the dashboards but this is for direct connection instead of via the dashboard. Colored lights to indicate health of connection in the same way. Flesh out and file feature and work on it overnight for me." |
| **Revision** | none: F5 §7's switch path, reached from one more place |
| **Touches** | `App/Browser/AppBar.swift`, `App/Browser/DashboardRootView.swift`, new `App/Browser/GatewayRow.swift` and `App/Discovery/GatewayHealth.swift`, `App/Workspace/Workspace.swift`, `UITests/DiscoveryTests.swift`, a host test |

## 1. Why

Switching gateways today takes Settings → Gateway → a row (F5 §7): four taps
and a sheet, with a light that is only a word ("answering"). The dashboard's
own instance bar does the same job in one tap with a coloured dot, but its
remotes are plain-HTTP frames on the gateway's loopback, which a phone can
never load (F5 §5). So the owner can see his other crews in the page and
cannot reach them from it.

The app already has everything needed to do it directly: the remembered list
(`WorkspaceDefinition.knownGatewayOrigins`, at most 8), the discovery
fingerprint (`/manifest.json`, then `/api/auth/me`), and the switch
(`Workspace.selectGateway`). What is missing is a place to show them that
does not cost the page anything. F15's app bar is that place: it is absent
until summoned, and the cogwheel is already in it.

## 2. What the owner sees

Working:

- He scrolls up a little; the app bar comes in as it does today (F15). Between
  the leading "Dashboard" button (when there is one) and the cogwheel is a row
  of chips, one per gateway he has used, sorted by name and never reordered;
  the one in use is filled solid with the accent, in place (§8 item 6).
- Each chip is a short name (`mac-studio`, or `mac-studio:8443` off 443) and a
  small light, a symbol whose shape as well as colour is the state (✓, …, !,
  –). The lights are KiroCrew's instance-bar colours (`App-*.js`,
  `Y6`/`XEe`: `connected` → `--ok`, `connecting` → `--warn`, `error` →
  `--danger`, anything else → `--muted`), with the same meanings:
  - **green**: answering as a KiroCrew gateway. For the one in use: the page
    loaded.
  - **amber**: being checked (the first check since the bar came in). For the
    one in use: the page is connecting.
  - **red**: did not answer, or answered as something that is not KiroCrew.
    For the one in use: the page failed.
  - **grey**: not checked, or cannot be: the tailnet is not up yet, or the
    host is not on this tailnet. The last one is disabled (it would load
    off the tailnet — F5 §7, the M5 review).
  The state's words (the table in §4) are the chip's accessibility value, not
  drawn: a word after the name resized the chip on every probe and load and
  shifted every chip after it (issue #7). The symbol's shape keeps colour
  from being the only signal.
- One tap on another chip switches to it: the page reopens at that gateway,
  and it becomes the chip in use. No sheet.
- More gateways than fit: the row scrolls sideways; chips keep their width,
  names truncate at 140 pt. Nothing overlaps the cogwheel.
- Scrolling down takes the bar away, row and all. Nothing new is on the page.

Failing:

- A red chip still switches: the light is a forecast from a probe seconds
  ago, not a gate. F4 then shows the real load, with its way to another
  gateway — the same rule as Settings' rows.
- If the tailnet is not up, every other chip is grey, disabled, and says
  "tailnet not connected".
- Only one gateway known: no row. The bar is as it was.

## 3. Non-goals

- **Not the dashboard's instances.** `GET /api/instances` lists SSH-tunnelled
  loopback remotes a phone cannot load, behind a feature that is off by
  default (F5 §5). The row lists what the app itself can open.
- **No discovery sweep from the bar.** Only remembered gateways are probed,
  each directly. Finding new ones stays in Settings and the picker; a 12 s
  sweep of every tailnet peer each time the bar appears would be the wrong
  cost.
- **No change to when the bar shows.** F15's policy is untouched. The row
  neither pins the bar nor adds height to it.
- No per-gateway session state, unread counts or reordering.

## 4. Design

**`GatewayHealth` (`App/Discovery/GatewayHealth.swift`, new).** One per
workspace, beside `discovery` (`Workspace.gatewayHealth`, lazy). It probes a
given list of origins, each with the discovery fingerprint on **its own port
only** (the origin's), through the node's proxy, no cookies, no redirects,
4 s per request: `GatewayDiscovery.probe(_:port:session:)` and
`makeSession(proxy:)`, made internal for this, not copied. It publishes `[origin: Verdict]` where
`Verdict` is `.checking`, `.answering`, `.notGateway`, `.notAnswering`, and
the time of each result.

- `refresh(_ origins:)` probes each origin whose verdict is missing or older
  than `freshFor` (30 s), all at once (at most 7). A verdict being re-checked
  keeps showing until the new one lands: no flicker to amber every 30 s.
- While the row is on screen it calls `refresh` on appear and every 30 s;
  when the row goes, the timer stops and in-flight probes are cancelled. So
  a retracted bar costs nothing. The loop restarts when the node becomes
  ready (a proxy and a rule set): the row is often up before the node is.

**`GatewayChipState` (pure, in `GatewayRow.swift`).** `of(origin:current:
pageState:carried:ready:verdict:)` → a light (`.ok`, `.warn`, `.danger`,
`.muted`), a word, and whether it can be tapped:

| Case | Light | Word | Tappable |
|---|---|---|---|
| in use, page `committed` | ok | "connected" | no (it is in use) |
| in use, `holding`/`connecting` | warn | "connecting" | no |
| in use, `failed` | danger | "failed" | no |
| in use, `idle` | muted | "" | no |
| other, tailnet not ready | muted | "tailnet not connected" | no |
| other, host not carried | muted | "not on this tailnet" | no |
| other, `.answering` | ok | "answering" | yes |
| other, `.checking` or no verdict yet | warn | "checking" | yes |
| other, `.notGateway` | danger | "not KiroCrew" | yes |
| other, `.notAnswering` | danger | "not answering" | yes |

Host-tested by `scripts/test-gateway-row.sh`, every row of the table.

**`GatewayRow` (SwiftUI, same file).** A horizontal `ScrollView`, no
indicators, of `GatewayChip` buttons: 26 pt tall, 6 pt corner radius, 12 pt
text, a 12 pt symbol slot, a hairline border; the one in use filled solid
with the accent under white text and bold, with a 1.5 pt accent border. A
chip's width is its name's alone: the name always reserves its bold width
(a hidden bold copy under it), and the state takes no width. Identifier `gateway-row`;
each chip `gateway-chip-<host[:port]>`, label the full name ("…, in use" for
the current one), value the word. It is shown only when there is at least
one other known gateway.

**`AppBar`.** Takes an optional row view in the middle slot, always starting
at the same leading edge. When signed out, a compact text-only "Sign in"
button (orange outline, fixed 12 pt, label "Signed out — Sign in") sits after
the row, beside the gear; the row scrolls in what is left. Without a row the
F15 capsule is unchanged.

**`DashboardContent`.** Builds the row from `homePage.url`,
`workspace.definition.knownGatewayOrigins`, `tab.viewModel.pageState` and
the proxy policy, and on tap re-checks the rule and calls
`workspace.selectGateway(origin)` — the picker's own apply path. No sheet is
up, so there is nothing to wait out.

**Invariants this must not break** (see `../../app/AGENTS.md`):
- the split tunnel decides what goes through the proxy; only tailnet hosts
  do — a host with no rule is never probed and never selectable;
- `allowFailover` stays false;
- ATS stays on with no exceptions; HTTPS only — origins are `https://` only;
- D1: no app or node logs leave the device;
- a vendored-tree change is its own commit (R16) — none here.

## 5. State and migration

Nothing new is persisted. The row reads F5 §7's remembered list, which
already exists and is written on every switch. Verdicts live in memory only
and start empty on launch.

## 6. End-to-end tests

On the discovery harness (`scripts/test-discovery.sh`): `dash` is a web page
that is not KiroCrew and too short to scroll, so F15 shows the bar from the
start; `gw` is a fake KiroCrew gateway; `plain` has nothing listening.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| `testTheAppBarRowLightsEachGatewayAndSwitchesInOneTap` | Discovery | Home `dash`, known `dash, gw, plain, gateway.example.com`. The row is there with a chip per gateway; `dash` is in use; `gw` turns "answering", `plain` "not answering", `gateway.example.com` "not on this tailnet" and disabled. `gw`'s own log shows the probe (`GET /manifest.json`). One tap on `gw`: `gw`'s log has `GET /`, the sign-in sheet for `gw` comes up, and the row names `gw` as in use | Running it on the tree before the change: no `gateway-row` |
| `testTheAppBarRowIsAbsentWithOneGateway` | Discovery | Home `dash`, known `dash` only: the bar is up (gear hittable) and `gateway-row` does not exist | Showing the row unconditionally |

Host: `scripts/test-gateway-row.sh`, the §4 table, in `make test-policy`.

## 7. Acceptance criteria

1. With two or more remembered gateways, the summoned bar shows one chip per
   gateway, sorted by name — the Discovery test.
2. Each other chip's light matches a probe of that gateway, as the gateway's
   own request log confirms — the Discovery test.
3. One tap switches, proved by the new gateway's log — the Discovery test.
4. The bar's height and its show/hide policy are unchanged: F15's L1 tests
   pass unmodified.
5. Olof confirms on a device that the look reads as the dashboard's chips.

## 8. Open questions and owner actions

Decided overnight, each open to reversal:

1. **Remembered gateways only, not a sweep** (§3). Newly found ones still
   come from Settings or the picker; after one switch they are in the row.
2. **Tapping the chip in use does nothing.** A reload on tap was considered
   and rejected: an accidental reload of a live session is worse than a
   missing shortcut; the error page already has Try again.
3. **Sign-in and the row share the bar.** The first draft hid the row while
   signed out; that removed the way to another gateway exactly when the one
   in use will not let him in. Revised by item 8: the capsule no longer comes
   first.
4. **Red chips still switch** (Settings' rule): the light is a forecast.
5. **Short names**: the first DNS label, plus `:port` off 443. Two gateways
   with the same first label on different tailnets cannot be remembered by
   one workspace, so this does not collide in practice; the accessibility
   label carries the full name.

After Olof's device report (issue #7: chips move, the active one is faint,
an icon pops in on sign-out):

6. **Chips sorted by name, never by recency.** Every switch used to move the
   tapped chip to the front. Alphabetical needs no stored order and holds
   whatever the remembered list does; the chip in use is marked in place.
7. **Fixed chip widths, a solid active chip.** No drawn status word and a
   reserved bold width, so no state, load or switch resizes a chip. The chip
   in use is solid accent with white text and an accent border, where the
   15 % tint over material over the page's colour was hard to see.
8. **Sign-in after the row, beside the gear**, a compact text button with no
   icon. Signing out narrows the row's viewport from the right but moves no
   chip. It still hides while the token sheet is up (F15); that no longer
   shifts anything.

For Olof: whether the row should also offer "Find gateways…" at its end, and
whether the bar should come in by itself when the page in use fails.

## 9. Log

Opened 2026-09-27; filed as issue #6.

### 2026-09-28 — built

Commits: `discovery: let one port of one host be probed on its own` (the
per-port probe and the session made internal, not copied),
`browser: f22, the gateway row's chip states` (pure, host-tested),
`browser: f22, the app bar lists the gateways with a light for each`,
`uitests: f22, …`.

**Found by the first run.** `gw is lit answering: checking` after 15 s, and
gw's log had no probe at all. The row was on screen before the node had a
proxy and a rule set; `refresh` returned early and the loop slept 30 s. The
loop is now keyed on readiness as well as the list (§4).

**Changed from the spec's first draft:** decision 3. Hiding the row behind
the sign-in capsule would have removed the way to another gateway while
signed out of this one; the Discovery test now checks the row beside the
capsule after the switch.

**Shown able to fail** (each built and run on a simpool slot):

| Mutation | Failing assertion, as printed |
|---|---|
| The app code before F22 (tests only) | `the app bar carries the gateway row` |
| `order` keeps a lone gateway | `and has no gateway row` |
| Probing never reaches the node (the readiness bug above) | `gw is lit answering: checking` |

**Tests:** both new Discovery tests pass (11.6 s and 15.9 s); host
`test-gateway-row.sh` 43/43.

**Full tier, on main at `9348733a6` plus these commits:**

- `make test-policy`: green.
- `scripts/test-discovery.sh --build`: 22/22, R26 sweep timing checked,
  373 s. An earlier full run on a busier host failed two picker and
  Settings tests on "not hittable once settled"; each then passed 3 of 3
  with `REPEAT=3`.
- `scripts/test-offline.sh --build` (L1): 45/46 in 357 s. F15's app-bar
  tests pass unmodified (§7.4). The one failure is
  `testTypingInThePageKeepsItOnScreen` on Latchkey Shard 2: no software
  keyboard comes up. F10 recorded the same on the same simulator, and the
  test has no gateway row (one gateway). It also failed once on Shard 3
  before the rebase.

**Not covered end to end:** the colours themselves (XCUITest sees the word,
not the dot), and the 30 s re-probe. Horizontal overflow is SwiftUI's
`ScrollView`; with the cap of 8 it was not driven.

### 2026-09-28 — issue #7: stable, fixed-width chips; sign-in after the row

§8 items 6-8. `testTheAppBarRowLightsEachGatewayAndSwitchesInOneTap` now
checks the chips are by name, and that every chip's frame is unchanged
across the verdicts landing, and across the switch to `gw` with its sign-out
(dash in use and signed in, then gw in use, signed out, sign-in up, dash
red); and that sign-in sits after the row. Run on the old `GatewayRow` and
`AppBar` (new order kept), it fails: `neither the switch nor the sign-out
moved a chip`, every chip 208 pt to the right and dash 71 pt wider. Host
`test-gateway-row.sh` 44/44; Discovery 21/21 (484 s); L1 45/45 (204 s).
