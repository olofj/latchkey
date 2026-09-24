# F11 — The first screen says what this is and what is about to be asked of you

| | |
|---|---|
| **Status** | spec |
| **Requested** | 2026-09-24, by Olof, from the first TestFlight install: "When first bringing up the app without being signed into tailscale, it's just a big 'sign into tailscale' button. Should have an introduction about what the app does and why you need to sign in." |
| **Revision** | none |
| **Touches** | `app/App/Browser/ConnectionGateView.swift`, `app/App/Tailnet Status/StatusView.swift`, `app/UITests/`, `scripts/test-offline.sh` |

## 1. Why

The first screen is a brand header, the words "Tailscale Status", a status line,
and a button labelled `Login` (`StatusView.swift:93`). Nothing says what Latchkey
is, why a Tailscale account is involved, or what happens after the button.

The asymmetry is the tell. Every *later* state on this screen has careful copy:

- waiting for approval — "This device is logged in but waiting for a tailnet
  admin to approve it…" (`:75`);
- stopped — "Latchkey starts the node again when it returns to the foreground…";
- slow to start — a 15 s hint pointing at Settings → Node log (F4 §3.6, G2/G6).

F4 hardened the *failure* states of this screen. The **initial** state was never
treated as a state that needs words, so the one screen every new user is
guaranteed to see is the only one that explains nothing.

And this is not cosmetic. On 2026-09-24 the owner signed in successfully and then
reported "scan didn't work, nothing found". A fresh install is a **new node** on
the tailnet: it may need approval, it may need signing under tailnet lock, and it
needs a grant that reaches the dashboard's machine. The app explains approval
*once you are past login* — but by then the user has already formed the
expectation that signing in is the whole story. Told up front, that outcome is a
step in a list instead of a bug report.

## 2. What the owner sees

On first launch, before signing in, in this order:

1. **What this is.** One sentence: Latchkey opens one thing — a KiroCrew
   dashboard running on a machine you own — and it is not a general browser.
2. **Why Tailscale.** One sentence: that machine is not on the public internet;
   Latchkey carries its own Tailscale node so it can reach it directly. Worth
   saying plainly that **no VPN profile is installed** and the rest of the
   phone's traffic is untouched — iOS users reasonably expect a VPN prompt, and
   its absence is otherwise unexplained.
3. **What happens next**, as a short numbered list, because this is the part that
   turns a confusing dead end into a known step:
   - sign in to your tailnet in a browser sheet;
   - this install is a new device, so your tailnet may need to approve it (and
     sign it, if you use tailnet lock);
   - it needs access to the machine running the dashboard;
   - then Latchkey finds the dashboard and opens it.
4. **The button**, relabelled from `Login` to **Sign in to Tailscale** — a verb
   with an object, and the same words the screen has just used.

Not shown: any of this once the node has ever been logged in. A user reconnecting
after key expiry gets today's terse screen; they already know what the app is.

Failing: the screen must still work when the text cannot fit — see §4.3. The
button is never pushed off-screen by its own explanation.

## 3. Non-goals

- **No multi-page onboarding carousel, no "Get started" flow.** One screen, read
  in a few seconds, with the button on it. The value is in what is said, not in
  ceremony.
- **Not a Tailscale tutorial.** It does not explain what a tailnet is, how to
  create one, or what an ACL is. It says what *this app* needs and where that
  happens.
- **Not a privacy policy.** One clause about logs staying on the device (D1),
  because it is true and load-bearing, not a section.

## 4. Design

### 4.1 Where it goes

`ConnectionGateView` already calls itself "the pre-connection onboarding screen"
in its own header comment; it is currently a header, `StatusView`, and a
`Spacer`. The introduction becomes a sibling view above `StatusView`, shown only
when the node has **never** been logged in.

New `GateIntroduction` view in `ConnectionGateView.swift`; `StatusView` keeps its
current job of reporting node state. Splitting them this way keeps the status
section — which the connection-independent UI tests anchor on — untouched.

### 4.2 When it shows

Shown when `viewModel.needsAuth` **and** no workspace has ever recorded a
successful login. The second half needs a stored flag: `hasEverConnected` in the
workspace record, set the first time the node reaches `Running`. Without it, a
user whose key expired would be re-introduced to an app they have been using for
months.

### 4.3 It must not push the button off the screen

This is the real risk the change introduces, and the reason it is a spec rather
than a copy tweak. At the largest accessibility text sizes, four paragraphs and a
list will not fit on a phone. So:

- the gate's content is wrapped in a `ScrollView`;
- the sign-in button stays reachable at every Dynamic Type size, pinned below the
  scrolling content rather than inside it.

The failure this prevents — adding helpful words until the only control is
unreachable — is worse than the problem being fixed.

### 4.4 Copy

Written into the view, not a strings file: the app is not localised, and a
strings file would imply otherwise.

**Invariants this must not break** (see `../../app/AGENTS.md`): no change to the
split tunnel, `allowFailover`, ATS or D1; no vendored-tree change. The
connection-independent UI tests (`testAppLaunchesAndShowsStatus`,
`testOpenAndCloseSettings`) anchor on this screen and must keep passing
unmodified — if they need changing, the split in §4.1 was done wrong.

## 5. State and migration

One new persisted value: `hasEverConnected: Bool` in the workspace record,
default **false**. An existing install written by a previous version has no such
key; decoding it as `false` would re-introduce the app to an existing user on
their next expiry. So the decoder treats a missing key as **true** when the
workspace already has a node state directory on disk, and false otherwise — the
node directory is the evidence that this install has run before.

## 6. End-to-end tests

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| A first launch explains itself | L1, fresh container | Before any sign-in, the gate shows the intro (`gate-intro`), the what-happens-next list (`gate-intro-steps`), and a button labelled "Sign in to Tailscale" | Reverting `ConnectionGateView` to today's: only the status section and a `Login` button are present |
| The explanation names the post-login steps | L1 | The steps element's text mentions device approval **and** access to the dashboard's machine — the two things that stranded the owner on 2026-09-24 | Editing the copy to drop either: the assertion names which one went missing |
| The button survives its own copy | L1, largest accessibility text size | With `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`, the sign-in button exists, is hittable, and its frame is inside the window's safe area | Removing the `ScrollView` from §4.3: at XXXL the button is pushed off-screen and is not hittable |
| A returning user is not re-introduced | L1 | With `hasEverConnected` true and the node logged out, the gate shows the status section and button but **no** intro | Forcing the flag false: the intro appears for a user who has connected before |

The third is the one worth having beyond this feature: it is the standing test
that copy changes on this screen cannot cost the user the only control on it. It
belongs to the same family as F10 §4.4 and should use that helper once it exists.

## 7. Acceptance criteria

1. On a fresh install, the first screen names what the app does, why Tailscale is
   involved, and the steps after sign-in — instrument: test 1 and 2.
2. At `AccessibilityXXXL` the sign-in button is hittable and within the safe area
   — instrument: test 3.
3. An install that has connected before shows no introduction — instrument:
   test 4.
4. `testAppLaunchesAndShowsStatus` and `testOpenAndCloseSettings` pass unchanged.
5. Olof installs the next TestFlight build on a phone that has never run Latchkey
   and can say what the app is and what it will ask of him before tapping
   anything — the only criterion a test cannot stand in for.

## 8. Open questions and owner actions

- ~~Does the grant step belong in the list?~~ **Settled 2026-09-24**: Olof
  administers his own tailnet, so the step reads "it needs access to the machine
  running the dashboard" — direct, in the second person, no conditional. The
  "if the tailnet is not yours, an admin grants it" variant was considered and
  dropped: it hedges the one sentence that has to be actionable, for a reader
  this app does not yet have. Revisit if Latchkey is ever used on a tailnet the
  user does not administer.
- **Owner action:** criterion 5, on a device with no prior install. A reinstall
  over an existing container is not the same test.

## 9. Log

Opened 2026-09-24, from the first TestFlight install.
