# F20 — Latchkey either supports iPad or stops claiming to

| | |
|---|---|
| **Status** | **exploration; nothing decided.** A first measurement is running — L1 serially on an iPad Pro 11-inch — and its result goes in §9 |
| **Requested** | 2026-09-26, by Olof: "queue a feature for exploring iPad target and needed work. I suspect support for iPhone Duo will be very similar to support for iPad, and I'd love to get that explored too. But let's stick to iPad for now." |
| **Revision** | probably none. If the answer is iPhone-only, that is a build-setting change, not a behaviour change |
| **Touches** | `app/Latchkey.xcodeproj` (`TARGETED_DEVICE_FAMILY`), `App/Browser` layout, the L1/session/discovery suites and their runners |

## 1. Why

**The build already claims iPad and nothing has ever run there.** Measured from
the exported archive on 2026-09-26: `UIDeviceFamily` is `[1, 2]` in *both* the
app and the share extension, the app declares all four iPad orientations and
ships an iPad icon set, and the minimum is iOS 26.0. So the App Store will list
it as iPad-capable and an iPad installs it **natively**, not in iPhone
compatibility mode.

That is a claim with no evidence behind it. It is also a live risk: F19 found
that Apple's reviewer may test on an iPad, and a first submission that looks
broken there earns a rejection for a device the owner may not even care about.

**Why it is probably more than a build setting.** The suites encode iPhone
geometry throughout, and the app's layout decisions were each measured on a
phone:

- F9 removed `.ignoresSafeArea(.container, edges: .top)` because the page was
  drawing under the Dynamic Island. An iPad has no island.
- F13 reclaims bottom space against the home indicator, and F14's note records
  that `geo.safeAreaInsets.bottom` includes the keyboard height.
- F15's app bar retracts on scroll, sized for a phone's width.
- F5's instance chips are asserted to stay in one row, and its §9 records that
  the rule applies in landscape too because since F9 the page is under 767 px
  wide *on a phone*. An iPad is not.

So the interesting question is not "does it launch" but "which of our layout
invariants are phone-specific, and what does the iPad want instead".

**iPhone Duo.** The owner expects it to resemble iPad, and it probably does —
both are the case where the app is no longer one narrow column. This spec stays
on iPad deliberately, but §4 should be written so the answer generalises: if the
work reduces to "stop assuming one phone-width column", Duo inherits it. If it
reduces to "special-case iPad", it will not, and that is worth knowing early.

## 2. What the owner sees

One of two outcomes, and this spec exists to choose between them on evidence:

- **Supported.** Latchkey on an iPad opens the dashboard, with the page using
  the width sensibly, the bar and banners placed for a tablet, and the suites
  running on an iPad as well as a phone so the claim stays true.
- **Not supported.** `TARGETED_DEVICE_FAMILY` becomes `"1"`, the iPad
  orientations and icon go, and the App Store stops offering it for iPad.
  Honest, immediate, and reversible.

## 3. Non-goals

- **No iPad-specific features.** No split view, no multi-column session list,
  no pointer or keyboard shortcuts. The question is whether the existing single
  screen is correct on a larger one.
- **Not iPhone Duo.** Noted in §1, out of scope here.
- **Not a redesign.** If the honest answer is that a tablet wants a different
  layout, that is a separate spec, and this one says so rather than attempting
  it.

## 4. Design

Written after the measurement, not before. What §9's first run reports decides
the shape:

- **If L1 largely passes**, the work is narrow: fix what broke, add an iPad to
  the test rotation, done.
- **If the layout invariants fail**, each one needs a decision — does the
  assertion generalise (measure against the actual safe area and width) or is
  it genuinely phone-only (assert it only on a phone)? Prefer generalising, so
  Duo inherits it.
- **If the page is unusable at iPad width**, that is the real finding, and the
  choice becomes supporting a tablet layout properly or dropping the claim.

**Cost of the test rotation.** The suites now run sharded: L1 42 tests in 184 s
on four simulators, session 39 in 200 s on eight. Running an iPad *as well*
roughly doubles the simulator demand, and F14 §9 measured contention collapsing
past N≈8 on this host. So "run everything on both" is not free — the likely
shape is the full suite on a phone, and a named layout subset on an iPad.

## 5. State and migration

None expected. Dropping `TARGETED_DEVICE_FAMILY` to `"1"` does not affect an
installed app's data; it stops *new* iPad installs. An existing iPad install
(there are none but the owner's own, if any) keeps working.

## 6. End-to-end tests

The instrument already exists and needed no work: `scripts/test-offline.sh`
takes `SIM_NAME`, so

    SIM_NAME="iPad Pro 11-inch (M5)" scripts/test-offline.sh --serial --build

runs L1 on an iPad today. A device family decision should be backed by that run
on at least one iPad, and if iPad is supported, by that run staying green in the
routine tier.

The tests worth naming once the design is known: the page uses the width
without the bar or banners overlapping it, the instance chips behave at iPad
width in both orientations, and the keyboard does not blank the dashboard (the
owner's 2026-09-25 bug) on a tablet keyboard, which is a different size and can
be split or floating.

## 7. Acceptance criteria

1. A named iPad model has run L1, and its result is recorded here.
2. Either the device family is `"1"` with the iPad orientations and icon
   removed, or an iPad is in the test rotation with the layout subset green.
3. Whichever is chosen, `docs/DEVICE-CHECK.md` says what the owner should look
   at on a real device, or states that no iPad is available to check.
4. §1's iPhone Duo question is answered one way or the other: does the work
   generalise, or was it iPad-specific?

## 8. Open questions and owner actions

- **Do you want iPad support at all?** If not, this is a fifteen-minute change
  and the rest of the spec is moot. The current claim is the accident, not the
  decision.
- **Do you own an iPad to check on?** Criterion 3 depends on it. A simulator
  will not show you a real tablet keyboard or a real pointer.
- **Which iPad matters?** The measurement uses an 11-inch Pro. An iPad mini is
  much closer to phone width and would probably pass where a 13-inch fails.

## 9. Log

Opened 2026-09-26, from the owner's question "can't you just run the tests on an
iPad simulator in addition to the iPhone one?" — prompted by F19 §3 finding the
iPad claim unevidenced.

First measurement in flight at the time of writing: L1 serially on an iPad Pro
11-inch (M5), iOS 27. Its pass/fail list is the input to §4 and is recorded here
when it completes.
