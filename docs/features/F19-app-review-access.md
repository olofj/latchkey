# F19 — An Apple reviewer can exercise Latchkey

| | |
|---|---|
| **Status** | **options, not decided** (§4). Nothing is built. The reviewer's message is not in hand yet |
| **Requested** | 2026-09-25, by Olof, after Apple rejected Latchkey Remote 0.1 (build 202609250336) for TestFlight beta testing that day: design how an Apple reviewer can exercise the app at all. The reviewer's text is only in App Store Connect and will be pasted later |
| **Revision** | none yet. Options C and B2 below would each need one (they change R15, R3/R41 or the manual-entry gate) |
| **Touches** | depends on the option: none (0, A), App Store Connect and a host outside the owner's tailnet (B), `App/Browser/`, `App/Discovery/`, `App/Workspace/`, `TSNet/TSNetManager.swift` (B2, C) |

## 1. Why

Latchkey opens one thing: the owner's self-hosted KiroCrew dashboard, reached
through its own embedded Tailscale node on the owner's tailnet (PLAN §1.2). A
reviewer has no account on that tailnet and nothing to reach on any other.
Every screen past the first depends on things only the owner has:

1. **A tailnet identity.** Sign-in is Tailscale's browser login. Tailscale
   has no username/password accounts of its own. It signs in through an
   identity provider (Google, Microsoft, GitHub, Apple, a custom OIDC
   provider, or a passkey for invited users). That list is from memory and
   was not re-checked today; §8 Q5 depends on it.
2. **A gateway on that tailnet.** Discovery (R26) considers only `Online`,
   non-expired, non-sharee peers owned by the same user or tagged
   (`GatewayCandidates.exclusion`, `app/App/Discovery/GatewayCandidates.swift:64-70`),
   and accepts one only if `/manifest.json` names "Kiro Crew" and `/api/auth/me`
   answers 403 with `X-Auth-Required`. A typed gateway passes only if the live
   split-tunnel rule set covers it (`manualGateway`, `:188-194`). **Fails
   closed:** an off-tailnet host is refused, because it would load direct and
   become the origin a pasted token is sent to (M5 review).
3. **A dashboard token.** `kirocrew token` or the dashboard's QR code. A link
   is single-use and valid for 300 s (`LINK_WINDOW_SECS`, PLAN §3.3), so it
   cannot be written into review notes. The durable credential is the 30-day
   refresh cookie in the web view's data store. It is excluded from backup
   (R5) and destroyed by sign-out and Reset (R32).

### 1.1 What the reviewer of 0.1 actually saw

The build number is a UTC timestamp (`testflight.sh`). 202609250336 is
2026-09-24 20:36 PDT, one minute after `42af25db4` ("F13: with the keyboard
up…", 20:35:51). **Inferred, not proven:** the archive is gone (`app/build/`
now holds 202609260029). Built from that commit:

- **F11 was not in it.** The introduction landed later, in `5e78558d4`
  (2026-09-25 00:33). The reviewer saw the pre-F11 gate: the brand header,
  "Tailscale Status", a status line and a button labelled `Login`
  (`StatusView.swift:89` at `42af25db4`). No sentence said what the app is
  or that it needs the user's own server.
- **Most likely path:** tap `Login` and sign in with their own Google or Apple
  ID. Tailscale then creates a new, empty tailnet for them. The node joins it.
  Discovery finds no candidates and the picker says "No computer on your
  tailnet could be a gateway…" (`GatewayPickerView.swift:88`). A dead end,
  and to someone who has not read the notes it looks like a broken app. The
  alternative is not signing in at all, which is a dead end one screen
  earlier.
- **No share extension and no App Group.** Both arrived in `098ef5ff3`
  (2026-09-24 23:17). Build 0.1 had no entitlements file at all.

**So whatever the message says, the structural problem is real.** The usual
outcome for an app like this is guideline 2.1 (App Completeness): "we were
unable to review your app… provide a demo account or a fully-featured demo
mode". That is only the most likely message, not the one received. §8 Q2
asks for the real text.

### 1.2 Beta App Review may not be needed at all

`docs/TESTFLIGHT.md` → Testers: **internal testing needs no Beta App Review.**
Internal testers are members of the App Store Connect team, up to 100. Only a
build offered to an *external* group (by email or public link) goes to review.
PLAN §1.3 still lists App Store distribution as a non-goal, and TestFlight
was added "for the owner's own installs". If external testers are not the
goal, the rejection has cost nothing, and option 0 is the whole fix. That is
why §8 Q1 comes first.

## 2. Two checks that are often the real rejection

Both were checked against the project and the latest archive on 2026-09-25.

### 2.1 Export compliance: consistent, not the cause

- `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` is set in all three app
  configurations (Debug, Testing, Release) of the Latchkey target in
  `project.pbxproj`, and was at `42af25db4` too. The latest archive's
  `Info.plist` has `ITSAppUsesNonExemptEncryption = false`. The share
  extension does not carry the key; the app bundle's key is the one App Store
  Connect reads.
- **Is NO right for an app that ships Tailscale?** The key means "no
  encryption, or only encryption exempt from documentation". Latchkey uses
  plenty: WireGuard, Noise and TLS in TailscaleKit, plus system HTTPS. All of
  it is standard, published cryptography in mass-market software. The owner
  answered the App Store Connect questionnaire on 2026-09-24: uses
  encryption, Category 5 Part 2 exemption, no proprietary algorithms, not
  distributed in France. App Store Connect concluded **no documentation is
  required** (`docs/TESTFLIGHT.md` → Export compliance; DECISIONS
  2026-09-24). NO is the value that matches that answer, so the declaration
  and the binary agree.
- **Why it is not the rejection:** a wrong or missing encryption answer shows
  up as a "Missing Compliance" build status that blocks testing. It is not a
  Beta App Review rejection. Revisit the answer only if something
  non-standard or a French release is ever added.

### 2.2 Claimed capabilities: every claim is used, with one gap for the next upload

| Claim | Where | Used by | Verdict |
|---|---|---|---|
| `NSCameraUsageDescription` ("only to scan the sign-in QR code") | build settings, all configs | `App/Session/TokenEntrySheet.swift:169-211`, `AVCaptureSession` QR scanner | used, and the string is accurate |
| `NSLocalNetworkUsageDescription` (direct peer paths) | build settings | tsnet's direct UDP to LAN peers | used. The prompt can appear before the reviewer knows what the app is (a copy question, not a rejection) |
| App Group `group.net.lixom.latchkey` | `Latchkey.entitlements`, `ShareExtension.entitlements`, since `098ef5ff3` | `ShareInboxStore.swift:178`, `ShareCaptureModel.swift:65` | used by both targets. **Not in 0.1**, so it cannot be 0.1's problem |
| URL scheme `latchkey` | `Latchkey/Info.plist`, since F3 | `LatchkeyApp.swift:76` `.onOpenURL`, `App/Share/ShareURL.swift` | used |
| `UIBackgroundModes` | — | — | none claimed, correctly |
| `UIDeviceFamily` 1, 2 (**iPad**) | `TARGETED_DEVICE_FAMILY = "1,2"` | no suite runs on an iPad; L1 uses `iPhone 17`. PLAN calls iPad "secondary" | **claimed, not tested.** Reviewers often run the app on an iPad. It is not a capability, but it is a promise the build makes and nothing checks (§8 Q7) |

**Found, for the next upload, not 0.1:** `ShareExtension.appex` compiles
`App/Share/Inbox/ShareInboxStore.swift` (the ShareExtension exception set in
`project.pbxproj`). That file calls `FileManager.attributesOfItem` for
`.modificationDate` (`:156`), which is a FileTimestamp required-reason API.
The extension has **no `PrivacyInfo.xcprivacy`**. The app's manifest
declares `C617.1`, but its comment lists only `NodeLog.swift`. Whether App
Store Connect wants an extension's own manifest was not verified. The fault
would surface as an ITMS-91053 email after upload, not as a review
rejection. The cheap fix is a manifest in `ShareExtension/` declaring
`C617.1`, checked by `make tf` the way the other two are. Recorded here
because this check found it. It belongs in its own commit.

### 2.3 Other guidelines this app can trip, whatever the fix

These are unverified. They are listed so the reviewer's text can be matched
quickly when it arrives:

- **4.2 Minimum Functionality.** A reviewer who gets through sees a web page
  in a web view. The native half, a private tailnet node with no VPN profile,
  is invisible unless the notes explain it.
- **5.2.2 Third-party services.** The app displays content from KiroCrew (an
  official Kiro project) and signs in through Tailscale. Apple can ask for
  authorisation to access a third-party service. KiroCrew is self-hosted by
  the user, which is the answer, but it has to be said.
- **2.3.1 Hidden features.** This is a constraint on option C, not a current
  fault. A demo path must not be hidden or dormant.

## 3. Non-goals

- **Not deciding.** §4 costs the routes. Olof picks.
- **Not writing the reply to Apple.** Its wording depends on the message.
- **Not App Store distribution.** PLAN §1.3 stands unless §8 Q3 changes it.
  App Store review is stricter than Beta App Review, and a route that passes
  one may not pass the other. §4 says where that matters.
- **Not weakening any invariant as a side effect.** The split tunnel,
  `allowFailover = false`, ATS without exceptions, D1, R3/R41's single
  destination, R15's test-hooks-only-in-Testing rule, and R32's sign-out and
  Reset semantics are listed per option below. An option that would change
  one says so and needs a revision in `../PLAN-REVISIONS.md`. It never
  changes one quietly.

## 4. Options

Summary first, detail after. "Reviewer sees" means what they can reach in the
app, not what the notes say.

| | Reviewer sees | Build cost | Upkeep | Ships in the product | Invariant conflict |
|---|---|---|---|---|---|
| **0. Internal testers only** | nothing; no review | none | none | nothing | none |
| **A. Notes only** (+ video) | the gate and F11's intro; a dead end after sign-in | an hour of writing | re-check per submission | nothing | none |
| **B1. Review tailnet, reviewer signs in with a given SSO identity** | the whole real app against a demo gateway | 1–2 days | a host that stays up; the SSO login is the fragile part | nothing | none |
| **B2. Review tailnet, reviewer pastes an auth key** | the whole real app | B1 plus a new login path | rotate the key ≤ 90 days | an auth-key login in Release | **R15** (promotes a test hook) |
| **C1. In-app demo, no network** | the chrome (gate, picker, app bar, Settings) around a canned page | 2–4 days | follows every UI change | a permanent, visible demo entry | R15 in spirit; KiroCrew bundle licence if the real frontend ships |
| **C2. In-app demo against a public demo gateway** | the real frontend over the internet, not the tailnet | C1 plus a public host | a public service to run | a path that loads an off-tailnet origin | **R3/R41, the manual-entry gate**; split tunnel in spirit |

### 4.0 Option 0 — Do not submit for Beta App Review

Use internal testing only. Anyone who should install the app is added as an
App Store Connect user with a role, and then as an internal tester.

- **Reviewer sees:** nothing; there is no review.
- **Cost:** none to build. Each tester needs an App Store Connect login and
  can see the team's App Store Connect (with a limited role). Up to 100 people.
- **Product risk:** none.
- **Conflicts:** none. It is the reading of PLAN §1.3 as written.
- **Unknown:** whether a build rejected for external testing can still go to
  internal testers. Believed yes (internal groups never needed the review);
  check the build's page in App Store Connect before relying on it.
- **Stops working if:** Olof wants a public link, testers outside his App
  Store Connect team, or the App Store.

### 4.1 Option A — Reviewer notes alone

Fill in App Review Information (Beta App Review Information → Review Notes).
Say that Latchkey is a client for a server the user runs themselves, that it
cannot reach anything without that server, what the app does once connected,
and why no demo account can exist: the dashboard's links are single-use and
last five minutes, and the tailnet is private. Optionally attach or link a
screen recording of the full flow on the owner's phone. Whether Beta App
Review takes attachments, as App Store review does, was not verified.

- **Reviewer sees:** from the next build, F11's introduction, which now says
  what the app is and what it needs (0.1 lacked even that, §1.1). After
  sign-in, the same dead end.
- **Build cost:** writing the notes and recording a video. The recording must
  not show the owner's real tailnet names, node names or sessions (D5's
  policy names, gateway hosts). Use a demo tailnet, or blur it.
- **Upkeep:** keep the notes true as the app changes, and re-record when the
  UI changes enough to mislead.
- **Product risk:** none. Nothing ships.
- **Conflicts:** none.
- **Honest odds:** the lowest of the non-zero options. 2.1 asks for "a demo
  account or a fully-featured demo mode", and reviewers routinely reject
  client apps for self-hosted servers until they get one. It is cheap enough
  to try first, but plan for a second rejection. Worse for App Store review
  than for beta review.

### 4.2 Option B — A dedicated review tailnet with a demo gateway

A separate tailnet that belongs to a throwaway identity and holds nothing of
the owner's. It has one always-on node serving a demo dashboard over HTTPS
with a valid certificate. The reviewer's Latchkey joins it, discovers the
gateway, and opens it. **The shipped app is unchanged in B1.** That is this
route's defining property.

**The demo gateway.** A real KiroCrew instance is the wrong thing to hand a
stranger: it runs Claude sessions on a machine, spends tokens and executes
tools. The better candidate is `testing/harness/fake_gateway.py`. It already
serves KiroCrew's real 0.7.1 frontend byte for byte and emulates the whole
auth contract (D10, R19). It would need:

- a **long-lived demo token**, redeemable more than once, or re-minted
  per visit (the fake invents its own credentials, so this is its own
  rule, not KiroCrew's);
- **canned content** worth looking at. The fake is built to exercise auth,
  not to look lived-in, so this is real work;
- **HTTPS with a publicly trusted certificate** (ATS, R28). The easiest is
  `tailscale serve` on a small host on the review tailnet (MagicDNS and HTTPS
  enabled there). It could instead be a tsnet listener with `ListenTLS`. The
  owner's machines are on his tailnet, so the host is a separate VM or
  container, or a tsnet process on chonk that joins the second tailnet;
- node key expiry **disabled** on that host, so it does not lapse between
  submissions (D8 applies to the phone, not to this).

Discovery's same-user rule passes if the gateway is tagged or owned by the
same user the reviewer signs in as (`GatewayCandidates.swift:70`). The review
tailnet needs no device approval and no tailnet lock, so the reviewer's node
works on first sign-in. That is the opposite of D5's purgatory, and correct
only because this tailnet holds nothing.

**B1: the reviewer signs in with an identity given in App Review Information.**
This is the fragile part. Tailscale sign-in goes through an identity
provider, and the big ones challenge a login from a new device in a new
place: Google and Microsoft with verification prompts, GitHub with an
emailed device code, Apple ID with mandatory two-factor. A reviewer in
Cupertino cannot answer a code sent to Olof's phone. Ways around it, each
with its own cost:

- a Google or GitHub account made for this, with the challenge contact
  pointed at a mailbox Olof watches, and being on hand during the review
  window. Brittle, and a known cause of repeat rejections;
- a **custom OIDC provider** for the review tailnet (username and password,
  no 2FA). It needs a domain Olof controls, WebFinger, and an IdP to run.
  The most robust login, and the most to maintain.

Both give Apple a credential. It must reach nothing but the review tailnet.
Make the reviewer's identity a **member**, not the tailnet's admin, so the
credential does not open the admin console.

**B2: the reviewer pastes a tailnet auth key.** This skips the identity
provider entirely. A reusable, pre-approved auth key goes in the notes, and
the app joins with it. The app can already log in with an auth key
(`TSNetManager.launchAuthKey`, `TSNet/TSNetManager.swift:273`), but only under
`LATCHKEY_TEST_HOOKS` (R15). B2 means a **user-visible "join with an auth
key" path in Release**: new UI, a new login route to test, and an R15
revision. Auth keys last at most 90 days, so each submission needs a fresh
one. The attack surface is modest but real. A user can be talked into
joining someone else's tailnet, whose "gateway" then receives the dashboard
token they paste. The manual-entry gate does not help, because the attacker's
host *is* on the tailnet the app just joined.

- **Reviewer sees:** everything. Gate, sign-in, discovery finding a gateway,
  the token sheet (a demo token in the notes), the real frontend, the app bar,
  Settings, sign-out and Reset.
- **Build cost:** B1 is 1–2 days (host, tailnet, fake-gateway changes,
  canned content, notes), plus the OIDC provider if chosen. B2 is B1 plus
  about a day of app work, with tests.
- **Upkeep:** the host must be up whenever a build is in review. Rejections
  often come from "server unreachable". Each review sign-in leaves a node on
  the review tailnet; Reset logs it out (R32), but expired nodes pile up
  until they are removed. The fake gateway's pinned bundle (0.7.1) ages;
  that is fine for review, since it is what is shown, not what is tested.
- **Product risk:** B1 ships nothing. B2 ships the auth-key path.
- **Conflicts:** B1 none. D1 is untouched (the reviewer's logs stay on the
  reviewer's device). R32 works as designed and even gets exercised. B2
  conflicts with R15.
- **Open:** redistribution. The demo gateway serves KiroCrew's frontend to
  Apple. The harness downloads it for local tests, and serving it to a third
  party is a different act. Check the KiroCrew wheel's licence (§8 Q6).

### 4.3 Option C — A demo mode inside the app

A visible entry on the gate ("Look around without a server", or similar)
that runs the real UI against something that is not the owner's tailnet.
Guideline 2.3.1 rules out a hidden or reviewer-only switch, so **every owner
sees this entry, on the one screen F11 just made careful**, and keeps seeing
it. The learned rule about permanent UI costs applies: weigh what it costs
the screen when it is always there.

**C1: no network.** The demo loads a canned page from inside the app, through
a `WKURLSchemeHandler` or a bundled file. That keeps the tailnet node,
discovery and the network out of it entirely.

- Reviewer sees: the gate, a faked picker, the app bar, Settings and a page.
  The page is either Latchkey's own mock-up (honest, but it shows a
  dashboard that is not KiroCrew's) or **KiroCrew's real bundle shipped
  inside the app**. The second is a licence question (§8 Q6), goes stale with
  every KiroCrew release, and feeds 4.2 ("a bundled web page").
- Cost: 2–4 days, plus a lasting tax. Every change to the gate, picker, app
  bar or Settings has to keep the demo working, with its own L1 tests.
- **Attack surface:** a code path in Release where the app shows a gateway
  UI without a gateway. It must be impossible to reach from outside. The
  `latchkey://` scheme exists (`LatchkeyApp.swift:76`), so no URL may enter
  demo mode. The demo's web view gets a **separate, non-persistent**
  `WKWebsiteDataStore`, so it can never read or write a workspace's
  cookies. That keeps R32's "sign-out and Reset destroy the session" true,
  and R5's backup exclusion irrelevant. It is effectively R11's status
  fixture promoted to Release, which R15 exists to prevent. That needs a
  revision, or a demo built separately from the fixture so the fixture
  stays test-only.

**C2: against a public demo gateway.** The demo loads a real (fake-backed)
dashboard hosted on the public internet.

- Reviewer sees: the real frontend, live, without any tailnet.
- **Conflicts, the most of any option.** The app would load an off-tailnet
  origin, the exact thing `manualGateway` fails closed on, because an
  off-tailnet origin is where a pasted token would be sent. It crosses R3's
  main-frame lock and R41's single destination, which are now scoped to one
  hard-coded extra origin. The split tunnel is untouched in mechanism (the
  host just loads direct), but "only tailnet gateways" stops being true of
  the product. If anything ever lets the demo origin be configured, or lets
  the token sheet appear against it, it becomes a phishing primitive.
- Cost: C1's app work, plus a public host that must stay up and be hardened.
  It is internet-facing, unlike B's.

### 4.4 Combinations

Listed without a pick:

- **0 now, and A or B only if external testers are wanted.** Zero cost until
  the question is real.
- **A with the F11 build, then B1 if it is rejected again.** Try the cheap
  route first, and keep B's cost for when the message proves it is needed.
  The downside is a second review cycle, about a day each.
- **B1 + A.** The notes explain what the app is (for 4.2 and 5.2.2), and B1
  gives the reviewer something to reach. This is the combination most likely
  to pass both beta and App Store review without shipping anything.
- **C1 + A.** Self-contained. There is no host to keep up, but it ships a
  permanent demo entry and carries C1's attack-surface and R15 costs.
- Whatever is chosen, **the next submission should be a build with F11 in
  it.** 0.1's gate did not say what the app is, and that alone invites 2.1.

## 5. State and migration

- **0, A:** nothing.
- **B1:** nothing in the app. State lives outside it: the review tailnet, its
  identity or OIDC provider, the host and the demo token. These need a
  runbook entry in `docs/TESTFLIGHT.md` (what to check is up before
  submitting).
- **B2:** an auth-key login writes the same node state as an interactive
  login. There is no new persisted value, but the entry UI must not persist
  the key (the same rule as R2 for sign-in URLs).
- **C:** the demo must persist nothing. It gets its own non-persistent data
  store, no workspace record and no `hasEverConnected` write (F11 §5). If a
  demo flag were ever persisted, a later real sign-in must not inherit it.

## 6. End-to-end tests

Per option. Each must be shown able to fail, per the README.

| Option | Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|---|
| B1/B2 | review gateway check | owner-run, on the lines of `testing/harness/gateway_check.py`, from a node on the review tailnet | the demo host answers the R26 recognition pair (manifest "Kiro Crew" + 403/`X-Auth-Required`) over HTTPS with a publicly trusted certificate, and the demo token redeems | stopping the host; a self-signed certificate |
| B2 | auth-key join | L2 | a pasted key joins the fake control plane; the key reaches no log and no file in the container (the existing login-link check extended) | writing the key to the node log |
| C | demo is sealed | L1 | the demo creates no workspace, no node state dir, no cookie in the default data store; `latchkey://` URLs cannot enter it | using the default data store for the demo |
| C2 | demo origin only | L1 | the demo web view reaches the demo origin and nothing else, and the token sheet cannot appear against it | allowing the token sheet in demo mode |
| all | submission check | App Store Connect | the build's Beta App Review status is Approved | — (Apple's verdict is the instrument) |

## 7. Acceptance criteria

1. The chosen route's build is approved for external TestFlight testing.
   Instrument: the build's status in App Store Connect. For option 0,
   internal testers install it with no review.
2. Nothing in the Release binary loads an off-tailnet origin, or holds a login
   path outside Testing, unless a revision in `../PLAN-REVISIONS.md` says it
   may. Instrument: the §6 tests of the chosen option, and
   `strings`/`nm` on the Release binary for the demo or auth-key symbols
   where they must be absent.
3. For B: the review host passes the §6 check within an hour before each
   submission.

## 8. Open questions and owner actions

Most design-changing first.

1. **Do you want external testers at all, and who?** If everyone who should
   install it can be an internal tester (an App Store Connect user), there
   is no Beta App Review and option 0 is the whole answer. This one answer
   removes or keeps everything else in this spec.
2. **The reviewer's message, verbatim.** The guideline number decides the
   route: 2.1 (cannot review) points to A/B/C; 4.2 or 5.2.2 point to notes
   and framing; a crash or iPad layout issue points to a bug fix and none of
   §4.
3. **Is the App Store itself on the horizon, or only TestFlight?** PLAN §1.3
   says not. If it is, B1 (or C) becomes close to mandatory, and a demo route
   is worth building once and properly.
4. **Will you ship any demo or login path in the Release binary?** A "no"
   rules out B2 and C and leaves 0, A and B1.
5. **For B1: which identity can you hand Apple?** A dedicated Google or GitHub
   account (you on hand for its challenges during review), or a custom OIDC
   provider on a domain you control (robust, more to run). Check Tailscale's
   current sign-in options first; §1 lists them from memory.
6. **May KiroCrew's frontend be served to a third party (B), or shipped inside
   the app (C1)?** It needs the wheel's licence and, being an official Kiro
   project, perhaps an ask. If not, the demo page is Latchkey's own mock-up.
7. **iPad: keep claiming it?** `TARGETED_DEVICE_FAMILY = "1,2"`, and no suite
   runs on an iPad. Reviewers use iPads. Either test on one, or ship
   iPhone-only until someone does.
8. **Where would a review host live**, and are you willing to keep it up for
   every review window (B), or public (C2)?

**Owner actions:**

- Paste the rejection text from App Store Connect (Q2).
- Check in App Store Connect whether 202609250336 is still installable by
  internal testers (§4.0).
- Separately from this spec: the share extension's missing privacy manifest
  (§2.2) before the next `make tf` upload.

## 9. Log

2026-09-25, opened after the 0.1 rejection. Findings while writing, before
any decision:

- 0.1 predates F11 (`5e78558d4`) and the share extension (`098ef5ff3`),
  inferred from the build timestamp. §1.1.
- The encryption declaration is consistent with the owner's answer and with
  the binary. §2.1.
- Every claimed capability is used. iPad is claimed and untested. The share
  extension compiles a FileTimestamp API with no privacy manifest of its
  own. §2.2.
