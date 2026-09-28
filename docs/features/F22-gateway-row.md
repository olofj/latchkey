# F22 — The app bar lists the gateways, with a light for each

| | |
|---|---|
| **Status** | spec (2026-09-27); decided by the building worker overnight, Olof asleep (§8) |
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
  of chips, one per gateway he has used: the one in use first, filled and bold
  like the dashboard's active chip, then the others, most recent first.
- Each chip is a short name (`mac-studio`, or `mac-studio:8443` off 443) and a
  small dot. The dots are KiroCrew's instance-bar colours (`App-*.js`,
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
  As in the dashboard, a chip that is not green says its state in words after
  the name, in the dot's colour, so colour is never the only signal.
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
4 s per request: the same request shape as `GatewayDiscovery`'s probe, which
it shares rather than copies. It publishes `[origin: Verdict]` where
`Verdict` is `.checking`, `.answering`, `.notGateway`, `.notAnswering`, and
the time of each result.

- `refresh(_ origins:)` probes each origin whose verdict is missing or older
  than `freshFor` (30 s), all at once (at most 7). A verdict being re-checked
  keeps showing until the new one lands: no flicker to amber every 30 s.
- While the row is on screen it calls `refresh` on appear and every 30 s;
  when the row goes, the timer stops and in-flight probes are cancelled. So
  a retracted bar costs nothing.

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
text, a 6 pt dot, a hairline border; the one in use filled with the accent
at low opacity and bold, as `e8`'s active style. Identifier `gateway-row`;
each chip `gateway-chip-<host[:port]>`, label the full name ("…, in use" for
the current one), value the word. It is shown only when there is at least
one other known gateway.

**`AppBar`.** Takes an optional row view in the middle slot. The sign-in
capsule keeps the middle when it shows (it pins the bar and is the only way
in, F15 §9 item 3); the row gives way to it rather than both squeezing.

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
   gateway, in-use first — the Discovery test.
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
3. **The sign-in capsule wins the middle** of the bar when it shows.
4. **Red chips still switch** (Settings' rule): the light is a forecast.
5. **Short names**: the first DNS label, plus `:port` off 443. Two gateways
   with the same first label on different tailnets cannot be remembered by
   one workspace, so this does not collide in practice; the accessibility
   label carries the full name.

For Olof: whether the row should also offer "Find gateways…" at its end, and
whether the bar should come in by itself when the page in use fails.

## 9. Log

Opened 2026-09-27.
