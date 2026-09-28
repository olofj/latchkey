# F21 — A cold launch arrives at the dashboard without flashing through screens

| | |
|---|---|
| **Status** | **built** 2026-09-26, as §4.4, not §4.1–4.3: measurement (§9) put the flash inside the web view, in KiroCrew's shell. The session suite's `CalmLaunchTests` has the test and its control; the before/after curves are in §9. Outstanding: §7.5, the owner's own launch |
| **Requested** | 2026-09-26, by Olof (issue #4): "When the app starts cold there's a lot of flashing on the screen on the way in to the actual default dashboard, likely something like logins and connection screens but they flash fast and I can't tell. It's visually jarring." Then: "Maybe consider a splash screen, worst case?" |
| **Revision** | likely none. Nothing documented promises these screens appear; F4 and F8 promise they appear *when they are true and stay true* |
| **Touches** | as built: `App/Browser/PageScriptSources.swift` (`calmShell`, the reporter), `PageScripts.swift`, `BrowserViewModel.swift` (install, `page-background:` log line, the test instrument), `PageBackgroundInstrument.swift` and `AppBar.swift` (the instrument's element); `UITests/CalmLaunchTests.swift`, in the session suite; `testing/harness/fake_gateway.py` (`/__slow?assets=`); `scripts/measure-launch-flash.sh`. Not, after all, `PageStateView` or `ConnectionGateView` |

## 1. Why

On a healthy cold start the app renders three or four full-screen states in
quick succession, each for a few hundred milliseconds, with hard cuts between
them. Nothing orchestrates that sequence — each screen is an independent view
that happens to be briefly correct:

1. **The gate.** `DashboardRootView.swift:167` shows the dashboard only when
   `hasConnected` is true, and that is set when `statusViewModel.running`
   becomes true (`:186`, `:190`). On a cold start the node is not `Running`
   yet, so `ConnectionGateView` always draws first and is replaced the moment
   the node comes up. No transition, no minimum dwell.
2. **The page states.** `PageState.connecting` renders immediately; only its
   *hint* is delayed, by 8 s (`PageStateView.swift:43`).
3. **The banners.** `gatewayContent` shows `GatewayUnreachableBanner` as soon as
   `homePageAvailability == .unavailable`, which is plausibly true for a few
   hundred milliseconds before the first load succeeds.

**Why this is a real defect and not a cosmetic quibble.** Each of these screens
is a *claim about the system's state* — "you are not connected", "the gateway is
unreachable". Showing them for 200 ms when they are about to be false teaches
the owner to distrust them, which is exactly the opposite of what F4, F8 and
F11 were for. The fast path should look like one transition.

## 2. What the owner sees

A cold launch on a healthy node goes from the system launch screen to the
dashboard, with no intermediate screen appearing and vanishing. When something
really is slow or wrong, the relevant screen appears and **stays**, as it does
today.

Explicitly unchanged: a node that cannot start still shows F8's G7 immediately
once that is known; a gateway that really is unreachable still shows its banner;
the 8 s connecting hint still appears. This feature suppresses *transient*
states, never real ones.

## 3. Non-goals

- **No new artwork, no branded splash animation.** The owner offered a splash
  screen as a worst case, and §4.3 treats it as the fallback it was offered as,
  not the goal.
- **Not slowing the launch.** A grace window must not delay reaching the
  dashboard; it only delays drawing something that is about to be replaced.
- **Not hiding failures.** Any delay measured in hundreds of milliseconds must
  not apply to a state that persists.

## 4. Design

### 4.0 Measure first

Issue #4's count of screens is read from the code. Before choosing, capture the
real sequence with timings on a cold launch:

    xcrun simctl spawn booted log stream --predicate 'subsystem == "net.lixom.latchkey"'

and a slow-motion screen recording on a device. The owner's device timings are
the ones that matter — the node comes up faster on a simulator. Record in §9:
which states appeared, in what order, and for how long each.

That decides whether this is one problem or three, and whether the gate swap
dominates or the banners do.

### 4.1 Preferred: do not draw a state that is about to be replaced

A short grace window before an *intermediate* state is allowed to appear. If
the condition clears within it, that state never draws; if it persists, the
state appears and stays. Applied to the gate swap, `connecting`, and the
availability banners, each with its own window chosen from §4.0's data rather
than a guessed constant.

The subtlety worth stating: this is not a delay on *reaching* the dashboard. It
is a delay on *admitting* an intermediate screen, so the fast path skips them
entirely and the slow path is unchanged.

### 4.2 Then: do not hard-cut between the states that do appear

Where a transition remains visible, it should be a transition rather than a
cut. Cheap, and independent of 4.1.

### 4.3 Fallback: hold the launch surface

`INFOPLIST_KEY_UILaunchScreen_Generation = YES` is already set, so iOS shows a
generated launch screen until the first frame. The fallback is to keep
something with that appearance on screen until the dashboard is ready or a
timeout expires — which is the owner's "splash screen", but framed as *not
tearing the launch screen down prematurely* rather than as adding a new one.

Why it is the fallback and not the first choice: it hides the real state for a
fixed period, so a node that fails in the first 400 ms would be concealed
behind it, and it must be dismantled carefully for the slow paths. It is the
right answer only if §4.1 turns out not to cover the cases §4.0 finds.

**Invariant not to break** (`../../app/AGENTS.md`): whatever replaces the
flashing must not reintroduce a blank or white screen. `RawWebView` sets the
view, scroll and under-page colours (`RawWebView.swift:35-41`) precisely
because `WKWebView` flashes white before its first paint.

### 4.4 Built instead: the shell paints nothing until the page has chosen

§9's measurement moved the problem inside the web view, and §9's reading of
the bundle found the mechanism: the shell is `<html data-theme="dark">`, its
CSS keys everything to that attribute, and the page writes the theme it
chose onto `<html>` (`data-theme` and `data-mode`) only after it has booted.
So the first paint is a *fully styled* dark shell, whatever the phone's
appearance, until the module graph has loaded.

The fix is a `<style>` the app adds at document start
(`PageScriptSources.calmShell`), three declarations that hold while `<html>`
is still the shell's static `data-theme="dark"` and carries no `data-mode`:
the root's `color-scheme` becomes `light dark`, the body's background
transparent, and `#root` invisible. What shows then is the web view's own
backing, which `RawWebView` already keys to the app's appearance — white on
a light phone, black on a dark one — so the pre-boot shell has the colour
of the launch screen instead of the colour of a theme nobody chose. Each
declaration answers a measured frame (§9): WebKit paints a
`color-scheme: dark` document's base canvas black even under a transparent
body, and the app mounts, and paints its toolbar dark, a few frames before
its effect writes the choice. The moment the page writes it the rules stop
matching and the chosen theme paints, as it did before. Nothing is delayed
and nothing is guessed: a stored dark theme on a light phone still arrives
as soon as the page says so.

Why not §9's "hold the web view until it has painted something we would be
happy to show": that needs a definition of "happy" (the page's resolved
colour is unknown until the page resolves it), a timeout for when the
definition is never met, and it costs that timeout for every owner whose
dashboard theme differs from the phone's. Making the unresolved shell paint
nothing needs none of those.

What it rests on, and what happens when it goes: three facts of the 0.7.1
shell — the static `data-theme="dark"`, `data-mode` as the mark of a chosen
theme, and the body taking its background from the theme. A bundle that
changes the first turns the rule into a no-op, which is today's flash and
nothing worse. For the second, the script hands the paint back itself two
seconds after `#root` gained a child (the shell's own "did we boot" test)
with no choice made, so no future bundle is left with a transparent canvas
for good. The durable fix is upstream's (`../upstream/kirocrew-theme-flash.md`).

The instrument, kept in every build: each canvas colour the page reports
(F9's reporter) is logged as `page-background: <colour> after <ms> ms`, so a
device run says what painted first without a recording. Test builds keep
the sequence since the document committed in `page-background-reports`,
shown only under `-UITestReportPageBackgrounds`. While a background
transition is in flight the reporter reports the colour it is heading for
(§9, 2026-09-27).

## 5. State and migration

None. No persisted value changes.

## 6. End-to-end tests

The hard part is that this feature is about what is *not* drawn, and for how
long. The instrument that already exists: L1's fake dashboard can be made to
answer at a chosen speed, and the app's own log records state changes with
timestamps.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| A fast cold launch shows no intermediate state | L1, fast gateway | From launch to page committed, the gate, the connecting state and the availability banner are never reported as having appeared | Removing the grace window: each appears in the log |
| A slow start still shows the connecting state | L1, stalled gateway | The connecting state appears and stays, and the 8 s hint still follows | Applying the grace window to a persisting state: it never appears |
| A node that cannot start still shows G7 immediately | L1, F8's fixture | G7 appears without waiting out any grace window | Delaying failure states: G7 arrives late |

The first is the one worth having beyond this feature: it is the standing test
that the fast path stays quiet as more states are added to this screen.

The three above were written for §1's diagnosis and are superseded with it
(§9): none of those states appears on a cold launch, so a test that they do
not would pass on today's code. The tests built are on the real bundle,
where the flash is:

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| `CalmLaunchTests/testTheRealDashboardNeverPaintsItsDarkShellFirst` | Session suite, real 0.7.1 bundle, signed out | Every opaque canvas colour the page reported since its document committed (`page-background-reports`) is on the side — light or dark — of the one it settled on | `-UITestNoCalmShell`, the next row; and by deleting the `installCalmShell` call (§9) |
| `CalmLaunchTests/testWithoutTheCalmShellTheRealDashboardPaintsDarkFirst` | Session suite, `-UITestNoCalmShell` | The control: the same launch reports the shell's dark default (`rgb(18, 20, 26)`) first and the light theme last, so the instrument sees the flash it is meant to see | Installing the calm shell regardless of the flag |
| `calmShell` under Node | host, `app/scripts/test-calm-shell.js` | The exact injected text adds one `<style>` at document start, removes it when `data-mode` appears or 2 s after the app mounts without it, adds nothing to a document that has already chosen, and never throws into the page | Any of those changing |

## 7. Acceptance criteria

1. §4.0's measurement is recorded in §9, before and after. — Done, §9.
2. On a healthy cold start, no intermediate state is drawn — instrument: test 1.
   — Superseded: none was (§9); the state drawn was the page's own dark
   shell, and `testTheRealDashboardNeverPaintsItsDarkShellFirst` is the
   standing test that it stays undrawn.
3. The slow and failing paths are unchanged in timing — instrument: tests 2 and 3.
   — Nothing of ours changed timing: no grace window was built.
4. No blank or white frame is introduced at any point. — The shell's
   pre-boot frames now have the launch screen's colour (white on a light
   phone) where they had the dark theme's; they were the page's blank
   frames before too, only dark. Nothing the owner can act on is hidden by
   it: the page has nothing to show until it has booted, and the app bar and
   gear stay.
5. Olof installs the build and says the launch no longer flashes. The only
   criterion a test cannot stand in for, since "jarring" is what was reported.
   — Outstanding.

## 8. Open questions and owner actions

- **Owner action, and the first task:** a slow-motion recording of a cold
  launch on your device. The simulator's node comes up faster, so its sequence
  is not yours. — Done (§9), and it is what changed the diagnosis.
- **How long is acceptable to wait before showing a slow-start screen?** —
  Moot: no grace window was built, because none of our screens was flashing.
- **Does the dashboard's own first paint flash?** — Yes, and it was the
  whole of it (§9). Separated: our fix is §4.4, the page's is
  `../upstream/kirocrew-theme-flash.md`.
- **Owner action, after the build:** a cold launch on the phone, in light
  appearance, with the dashboard's theme left at its default; and one with
  the phone in dark appearance, where nothing should have changed. Settings
  → Logs shows `page-background:` lines: the first should be `none`, never
  `rgb(18, 20, 26)`.
- **Should the upstream report be filed?** It is drafted; filing is Olof's
  call, as with the fonts report.

## 9. Log

Opened 2026-09-26 from issue #4. The three-to-four screen count in §1 is
inferred from the code; §4.0's measurement replaces it with observation.

**2026-09-26, measured — and §1 is wrong.** Olof recorded a cold launch on his
phone (8.4 s, 60 fps). Frames and per-frame mean brightness give this sequence:

| Time | On screen |
|---|---|
| → 3.99 s | White page area, the app's own gear already visible |
| **4.003 → ~4.27 s** | **Solid dark, ~250 ms**, gear still visible, faint dark skeleton blocks |
| 4.27 → 4.42 s | Dark toolbar over a lightening background; the theme is switching |
| ~4.44 s | Light empty state: "What can I do for you? / Start a new chat to begin" |
| 4.55 → 5.7 s | Skeleton rows, "Load earlier messages", then content filling in |

About **1.7 s** of churn, whose jarring element is a quarter-second of full
black between two white states on a light-mode phone.

**None of §1's three states appeared.** No gate, no connecting state, no
unreachable banner. The app's gear is visible in every frame, so
`DashboardRootView` was on the dashboard branch throughout. Everything that
flashes happens **inside the web view**: the KiroCrew page paints a dark shell,
then switches to its light theme.

So §4.1's grace window — the preferred fix — would have changed nothing, and
§4.3's held launch surface would only have hidden the first white period, not
the dark flash that follows it. Both are superseded.

**What the fix has to address instead**, in the order the evidence supports:

1. **The ~250 ms dark flash.** The page paints a dark shell before its theme
   resolves. Two candidate causes, and they need distinguishing before
   choosing: the page defaults to dark (`prefers-color-scheme`) before reading
   the owner's stored preference, or it paints an unstyled shell before its CSS
   applies. Either way the *page* is doing it, not us.
2. **Our lever, if we want one:** do not show the web view until it has painted
   something we would be happy to show. The instrument already exists in
   spirit — `eb255cd` added a `rendered` report to the fake dashboard for the
   tap races — but the real bundle gives us no such signal, so this would rest
   on `didFinishNavigation` or a first-paint heuristic plus a timeout. It
   trades a flash for a delay, so it needs a measured threshold, not a guess.
3. **Upstream.** The theme flash is KiroCrew's behaviour and the durable fix
   belongs there. `docs/upstream/` already holds one such report; this is a
   second.

**2026-09-26, reproduced locally — it is the bundle, not the owner's theme.**
Recording the simulator (`xcrun simctl io <udid> recordVideo`) while
`ONLY_TESTS="SessionTests/testTheRealDashboardConnectsToNothingButTheGateway"
scripts/test-session.sh --build` drove the real 0.7.1 bundle through the fake
gateway shows the same sequence: white page area with the app's gear → **solid
black carrying the dashboard's own dark toolbar** → light, with "Signed out —
Sign in". Mean brightness bottoms out at **33.5**, against 22–25 on the owner's
device.

So the dark shell is the pinned bundle's behaviour, reproducible on demand with
no device and no tailnet. That makes this an ordinary fix with a local loop:
measure, change the reveal, measure again. The measurement recipe is the one
above plus per-frame `signalstats` mean brightness, which is what distinguishes
a flash from a redraw without anyone having to watch a video.

Note the reproduction reaches a signed-out dashboard rather than the owner's
signed-in one, and the flash appears in both, so it precedes session state.

**2026-09-26, the cause, read from the pinned bundle.** Neither of the two
candidates above as stated. It is not `prefers-color-scheme` defaulting
before the stored preference: the bundle's CSS has no `prefers-color-scheme`
rule at all. And it is not an unstyled paint: the dark shell is fully
styled, toolbar and all. What the 0.7.1 bundle does:

1. `static/dist/index.html` is `<html lang="en" data-theme="dark">`, with
   `<meta name="theme-color" content="#0d0f12">`. Dark is the static default
   for everyone.
2. `assets/src-*.css` keys every colour to that attribute:
   `[data-theme=dark]{--bg:#12141a;…color-scheme:dark}`,
   `[data-theme=kiro-light]{--bg:#fff;…}` (the default light theme), and
   `body{background:var(--bg);…transition:background-color .25s,color .25s}`.
3. `assets/useTheme-*.js`'s `ThemeProvider` reads
   `localStorage['mc-theme'] || 'system'`, resolves `system` with
   `matchMedia('(prefers-color-scheme: dark)')`, and writes `data-theme`,
   `data-mode` and `data-mode-pref` onto `<html>` from a `useEffect` — a
   passive effect, after the first React commit has painted. The entry module
   is a graph of some seventy `modulepreload` chunks that evaluates only when
   every edge has loaded, so the dark default stays up for the whole module
   load and the first render: the ~250 ms on the phone.
4. The `.25s` transition on `body` is the "lightening background" that
   followed it.

The shell's own inline scripts set `data-ui` and `<html lang>` before
hydration "to prevent flash", and say they mirror "the pattern used by
data-theme bootstrapping" — a pattern that does not ship. That is the
upstream report (`../upstream/kirocrew-theme-flash.md`); the fix on our side
is §4.4.

**2026-09-26, built and measured.** The recipe is now
`scripts/measure-launch-flash.sh`: record the simulator through one session
test, then per-frame `signalstats` mean luma (whole screen, status bar
included; a white page area is ~200–227, the dark shell ~28–35), reporting
every run of frames below 96 after the first bright one.

The bare loopback fixture needed one change first. On it the bundle's
module graph loaded and booted before the shell got a frame on screen, so
the unfixed app recorded **no dark frame at all** (603 frames, darkest 115,
the launch fade) while the phone had shown a quarter-second: the flash is
proportional to the module load, which over a tailnet is not free. The fake
gateway therefore gained `/__slow?assets=S`, and the F21 tests hold every
`/assets/` file 50 ms, which with WebKit's six connections over some
seventy chunks gives the shell a few hundred ms, as the phone did.

| Build | Dark run after the first bright frame | Darkest frame | First `page-background:` reports |
|---|---|---|---|
| Control (`-UITestNoCalmShell`, i.e. before) | **417 ms** (55 → 28.1 → 34.9, then 199) | 28.1 | `rgb(18, 20, 26)` at 2916 ms, `rgb(255, 255, 255)` at 3496 ms |
| Body transparent only (first attempt) | 103 ms (49.4 → 60.4, then 227) | 49.4 | `none` at 2904 ms, white at 3624 ms |
| §4.4 as built (three declarations) | **none** | 115.3 (the launch fade-in) | `none` at 2797 ms, `rgb(255, 255, 255)` at 3530 ms |

The first attempt's residue taught the other two declarations: its frames
were a black page area under the app bar, then the dashboard's toolbar in
dark colours on it. The black was WebKit's base canvas for a
`color-scheme: dark` root, painted whatever the view's colours are; the
toolbar was React mounted under the shell's attributes for ~60 ms before
its effect wrote the choice. `color-scheme: light dark` on the unresolved
root and `visibility: hidden` on `#root` removed both, and the darkest
frame of the fixed launch is the launch screen's own fade.

Time to the dashboard: the light canvas is reported at 3530 ms after the
navigation began against 3496 ms unfixed, the same within run-to-run noise
(the fixture's own commit varies 1008–1095 ms across these runs). Nothing
waits for anything: the page paints its theme the instant it writes it.

Shown to fail: `testTheRealDashboardNeverPaintsItsDarkShellFirst` against a
build with the `installCalmShell` call deleted fails with
`got ["rgb(18, 20, 26)", "rgb(255, 255, 255)"]`; the control test keeps
that failure mode on the record under the flag. Both pass on the fixed
build (16.4 s and 16.6 s). The reporter now also samples every frame for a
document's first three seconds, because the shell's stylesheet arriving and
the theme being chosen after a module load raise no event, and it withholds
a value while the canvas is mid-transition, so the fade never reads as a
colour of its own.

**2026-09-27, finished.** Rebased onto main, reviewed, and three changes
before committing:

1. **The tests moved to their own class.** `SessionTests.swift` and
   `DashboardRootView.swift` belonged to F10's work in flight, so the two
   tests are `CalmLaunchTests` (in `scripts/test-session.sh`'s `CLASSES`
   and the shard plan), and the instrument's element is
   `PageBackgroundInstrument.swift`, attached to `AppBarColumn` in the
   status-bar strip. It is shown only under
   `-UITestReportPageBackgrounds`, so no other suite's screen sweep meets
   a new element.
2. **The reporter was blind to the flash in the control.** Its first run
   in the new class failed: `-UITestNoCalmShell` reported `["", "rgb(255,
   255, 255)"]`, no dark at all, while the log's timings showed the shell
   up for about a second. The shell's stylesheet is queued behind the
   seventy `modulepreload`s, so its dark default arrives late and *fades
   in* over the body's `.25s` transition, and the page's theme turns the
   fade round before it ends. The reporter withheld every value while a
   transition was in flight and so never saw dark; what the owner sees
   meanwhile is the black base canvas of `color-scheme: dark` under that
   fade. It now reports a fade's target (its last keyframe, from
   `getKeyframes()`), withholds only when that is unreadable, and also
   listens for a stylesheet's `load`. The control then reported
   `rgb(18, 20, 26)` at 2780 ms and white at 2895 ms.
3. **The shell's failure panel was checked against the rule.** The
   bundle's own `#boot-failure` panel (shown when a boot-critical chunk
   never arrives) is a sibling of `#root`, not inside it, so hiding
   `#root` never hides it; and a failed boot leaves `#root` empty, so the
   two-second hand-back is not needed for it either.

Measured again (`SIM_NAME="Latchkey Shard 4" LATCHKEY_INSTANCE=4
scripts/measure-launch-flash.sh`, 50 ms per asset):

| Build | Dark run after the first bright frame | Darkest frame |
|---|---|---|
| Control (`CalmLaunchTests/testWithoutTheCalmShell…`, i.e. before) | **225 ms** | 34.3 |
| Built (`CalmLaunchTests/testTheRealDashboardNeverPaints…`) | **none** | 114.2 (the launch fade) |

Shown to fail, each on Shard 4 with the mutation built in and reverted:

- `testTheRealDashboardNeverPaintsItsDarkShellFirst` with the
  `installCalmShell` call commented out: fails, `got ["rgb(18, 20, 26)",
  "rgb(255, 255, 255)"]`.
- `testWithoutTheCalmShellTheRealDashboardPaintsDarkFirst` with the
  calm shell installed regardless of the flag (`if false && …`): fails,
  `got ["", "rgb(255, 255, 255)"]`. The same failure is what the old
  reporter produced unmutated (item 2).
- `calmShell` under Node: unchanged from the entry above, 22/22.

Runs: `ShareTests` and `CalmLaunchTests` serially on Shard 4
(`ONLY_TESTS=<all 17>`), 17/17 in 493 s on the rebased tree; `app/scripts/test-page-scripts.sh`
and `make test-policy` green. A run of `CalmLaunchTests` alone passes its
tests but fails the script's R1 check, which needs a sign-in somewhere in
the run; with `ShareTests` beside it, or in a sharded run, one is there.
