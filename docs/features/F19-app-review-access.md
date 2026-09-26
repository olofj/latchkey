# F19 — An Apple reviewer can exercise Latchkey

| | |
|---|---|
| **Status** | **options, not decided** (§5). Option B's own side is built: the demo token, canned content, the service and the check (`../REVIEW-GATEWAY.md`). The review tailnet, the VM and the invites are the owner's. Paste-ready texts per option in §6 |
| **Requested** | 2026-09-25, by Olof, after Beta App Review stopped Latchkey Remote 0.1 (build 202609250336) that day: design how an Apple reviewer can exercise the app at all. Revised the same evening once the reviewer's message arrived (§1) |
| **Revision** | none yet. Options B-key and C would each need one (R15; R3/R41 and the manual-entry gate) |
| **Touches** | depends on the option: none (0, A), App Store Connect plus a host and a tailnet outside the owner's (B), `testing/harness/fake_gateway.py` (B, a demo-token rule), `TSNet/TSNetManager.swift` and a new login UI (B-key), `App/Browser/`, `App/Discovery/`, `App/Workspace/` (C) |

## 1. What Apple said

> Guideline 2.1 - Information Needed. We have started your beta app's review,
> but we couldn't access all or part of the app because we need a demo QR
> code or AR marker. Next Steps: Please provide the code/markers in the Beta
> App Review Information section for the app in App Store Connect or reply to
> this message with the requested demo information. Make sure that the
> information includes any data necessary to use the app's features and
> functionality.

**This asks for information, not a code change.** Apple wants demo data. The
camera string and the scanner are fine (`INFOPLIST_KEY_NSCameraUsageDescription`
in all three configurations; `app/App/Session/TokenEntrySheet.swift`). The
reviewer saw the QR scanner, or the camera string that describes it, and asked
for a code to point it at.

**A QR image is not needed.** The same sheet accepts a pasted sign-in URL or a
bare token (`docs/DEVICE-CHECK.md:123`; `TokenInput.parse`,
`app/App/Session/TokenInput.swift:55`). So the demo data can be text.

**But a QR code or token is the *last* thing the reviewer needs, and the easy
one.** It only works against a dashboard the reviewer can reach, and reaching
one needs a tailnet identity and a gateway on that tailnet first. The last
sentence of Apple's message, "any data necessary to use the app's features",
is the real requirement. §2 walks the chain.

### 1.1 Which build the reviewer has

- **202609250336 (the one reviewed).** Built one minute after `42af25db4`
  (2026-09-24 20:35 PDT; inferred from the UTC build number, the archive is
  gone). It is **before F11** (`5e78558d4`), so its first screen says only
  "Tailscale Status" and `Login`, not what the app is. It is also before the
  share extension (`098ef5ff3`).
- **202609251549 (newer, already available to test).** 08:49 PDT, just after
  `009dbbbdd`. It has F11's introduction (`GateIntroduction` present at that
  commit) and the share extension.

**Replying to the message resumes review of 202609250336**, the build without
F11. Filling in Beta App Review Information and submitting 202609251549
instead puts the introduction in front of the reviewer, at the cost of
starting a new review. That is a choice for Olof (§8 Q2).

## 2. From a fresh install to a working dashboard: what each step needs

In the order the app goes through it. "Owner" is what Olof has; "Reviewer"
is what must be supplied for someone with no account on his tailnet.

| # | Step | Code | Owner has | Reviewer needs | Hard? |
|---|---|---|---|---|---|
| 1 | **Tailscale sign-in.** `Sign in to Tailscale` opens Tailscale's login in an `ASWebAuthenticationSession` sheet (`StatusView.swift:116`, `StatusViewModel` / `TSNetModel.browseToURL`) | node at `NeedsLogin` | his identity provider account on his tailnet | **an identity on a tailnet that holds a gateway.** Tailscale has no passwords of its own: sign-in goes through Google, Microsoft, GitHub, Apple, OIDC or a passkey (from memory, not re-checked today). The only non-interactive route, an auth key (`TSNetManager.launchAuthKey`, `:273`), exists only in Testing builds (R15) | **hard** |
| 2 | **Node approval.** A new node may sit at `NeedsMachineAuth`; the app shows the waiting screen and cannot do anything about it (`DashboardRootView.swift:388`, `:554`) | — | D5's purgatory: an admin approves and moves the address | a tailnet with device approval **off** and no tailnet lock | easy on a tailnet built for this; impossible on Olof's |
| 3 | **Access to the gateway.** The node needs a grant that reaches the gateway's HTTPS port | — | `kiro-clients` → gateway:443 | a policy that allows it (a fresh tailnet's default allow-all does) | easy on a tailnet built for this |
| 4 | **Gateway discovery.** Peers filtered to online, not expired, not a sharee, OS linux/macOS/windows, same owner **or tagged** (`GatewayCandidates.exclusion`, `app/App/Discovery/GatewayCandidates.swift:64-72`). Each is probed over HTTPS through the node: `/manifest.json` named "Kiro Crew" **and** `/api/auth/me` answering 403 with `X-Auth-Required` (R26). Fallback: *Enter manually*, which accepts a name only if the live split-tunnel rules carry it, i.e. a peer on this tailnet (`manualGateway`, `:188-194`) | picker | byskebox / chonk / box behind `tailscale serve` | **a running dashboard, reachable on that tailnet, HTTPS with a publicly trusted certificate** (ATS, R28), owned by the reviewer's user or tagged. If it is off when the reviewer looks, the picker says so and nothing else works | **hard: it is a server that must stay up** |
| 5 | **Dashboard token.** The token sheet opens by itself when the page reports no session. Paste a link or bare token, or scan a QR. A pasted link's host must be the selected gateway (`SessionManager.swift:402`). A bare token avoids that check. The app loads `<gateway>/?token=<token>` (`TokenInput.signInURL`) | sheet | `kirocrew token` (5-minute link) | **a token that is still redeemable whenever the reviewer gets there**, which may be days after submission | **hard with a real KiroCrew; easy with a harness change** (below) |
| 6 | **Session.** The page keeps itself signed in (R20). Sign-out and Reset destroy it (R32) | page | cookies | nothing more | — |

**Step 5 in detail, because it is the one Apple named.** Real KiroCrew caps a
sign-in link at five minutes with a constant, `LINK_WINDOW_SECS = 300`
(`kiro_crew/dashboard/token_auth.py:704` in the pinned 0.7.1 wheel), and
consumes it on redemption. A real dashboard therefore cannot give Apple a
token that works tomorrow, and no QR code can be printed for it. The fake
gateway that the suites use (`testing/harness/fake_gateway.py`, the real
0.7.1 frontend byte for byte, D10/R19) caps links at the same 300 s
(`LINK_WINDOW`, `:204`) but does not consume them. A **demo-token rule** there,
one fixed link redeemable for weeks, is a small harness change. It ships
nothing in the app. Any fake token (`fk1.` + 32 characters) passes
`TokenInput`'s 16-character minimum as a bare token.

**So the hard parts are steps 1 and 4**, a tailnet identity for a stranger
and a dashboard that stays reachable. Step 5 is hard only as long as the
dashboard is a real KiroCrew. Steps 2 and 3 are free on a tailnet made for
review.

## 3. Checks that are often the real rejection

### 3.1 Export compliance: correct, not the cause

- `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` is set in all three app
  configurations at `42af25db4` (the reviewed build) and at `009dbbbdd`
  (202609251549). The latest local archive's `Info.plist` has it as `false`.
  The share extension does not carry the key; the app bundle's key is the one
  that counts.
- **Right for an app that ships Tailscale?** Yes. The app uses WireGuard,
  Noise and TLS (TailscaleKit) and system HTTPS, all standard, published
  cryptography in mass-market software. The owner's 2026-09-24 questionnaire
  answers were: uses encryption, Category 5 Part 2 exemption, no proprietary
  algorithms, not distributed in France. App Store Connect concluded no
  documentation is required (`docs/TESTFLIGHT.md` → Export compliance). `NO`
  ("none, or only exempt") matches that answer.
- The rejection is 2.1 Information Needed. An encryption problem shows up as a
  "Missing Compliance" build status, which this was not.

### 3.2 Claimed capabilities: all used, with one gap for the next upload

| Claim | Used by | Verdict |
|---|---|---|
| Camera usage string | `TokenEntrySheet.swift` QR scanner | used, and the string is accurate. It is what prompted Apple's question |
| Local network usage string | tsnet's direct peer paths | used |
| App Group `group.net.lixom.latchkey` (202609251549 on; not in the reviewed build) | `ShareInboxStore.swift:178`, `ShareCaptureModel.swift:65` | used by both targets |
| URL scheme `latchkey` | `LatchkeyApp.swift:76` | used |
| Background modes | — | none claimed |
| iPad (`TARGETED_DEVICE_FAMILY = "1,2"`) | no suite runs on an iPad | **claimed, untested.** Reviewers often test on iPads (§8 Q6) |

**Gap:** the share extension compiles `ShareInboxStore.swift`, whose
`attributesOfItem(...)[.modificationDate]` (`:156`) is a FileTimestamp
required-reason API. The extension has no `PrivacyInfo.xcprivacy` of its own.
Whether one is required was not verified. If it is, the result is an
ITMS-91053 email at upload, not a review rejection. The fix is its own commit.

## 4. Non-goals

- **Not picking an option.** §5 costs them, and Olof picks.
- **Not App Store distribution** (PLAN §1.3), unless §8 Q4 says otherwise.
- **No invariant weakened quietly.** The split tunnel, `allowFailover`, ATS,
  D1, R3/R41, R15 and R32 are named per option. Changing any of them needs a
  revision in `../PLAN-REVISIONS.md`.

## 5. Options

| | Reviewer reaches | Must be stood up | Ships in the app | Conflicts | Actionable tonight? |
|---|---|---|---|---|---|
| **0. Internal testers only** | nothing; no review | nothing | nothing | none | **yes** |
| **A. Explain, no demo** | the gate; a dead end after sign-in | nothing | nothing | none | **yes**, but it does not give Apple what it asked for |
| **B. Review tailnet + demo gateway** | everything, steps 1–6 | a tailnet, an always-on host, a demo-token rule in the fake gateway, a way in for step 1 | nothing (B-account, B-invite); an auth-key login (B-key) | none, or R15 for B-key | no: hours of setup first |
| **C. In-app demo** | the UI around a canned page | a new build | a permanent, visible demo entry | R15 in spirit; R3/R41 if it goes online | no: a code change and a new build |

### 5.0 Option 0: do not go through Beta App Review

Internal testing needs no review (`docs/TESTFLIGHT.md` → Testers). Anyone who
should install the app becomes an App Store Connect user with a role, then an
internal tester (up to 100). Leave the rejected submission, or reply that the
build is withdrawn from external testing.

- To stand up: nothing.
- Stops working if Olof wants a public link, testers outside his App Store
  Connect team, or the App Store.
- Unknown: whether a build stopped in Beta App Review stays installable for
  internal groups. It is believed so, but check the build's page first.

### 5.1 Option A: explain why no demo data can exist

Tell Apple the app is a client for a server the user hosts on their own
private network, and that no shareable QR code or token exists because each
one is minted by the user's own server and expires in five minutes. Attach or
link a screen recording of the full flow. Whether Beta App Review takes
attachments was not verified; a link to an unlisted video works either way.

- To stand up: a recording made on a **demo** tailnet, or blurred. It must
  not show D5's policy names, Olof's gateway hosts or real sessions.
- Honest odds: low. Apple asked for demo data, and this says there is none.
  2.1 exists precisely to reject that. It fits better as the covering
  explanation for B than on its own.

### 5.2 Option B: a review tailnet with a demo gateway

A separate tailnet that holds nothing of Olof's, with one node serving a demo
dashboard. The shipped app is unchanged (except in B-key). Steps 2 and 3 are
set up once. Step 4 is the host. Step 5 is the demo token. Step 1 has three
variants.

**Common to all B variants, to stand up:**

1. **The review tailnet.** A new Tailscale account under a throwaway identity
   (`<REVIEW_TAILNET_OWNER>`). MagicDNS and HTTPS certificates on. Device
   approval off. No tailnet lock. The default allow-all policy.
2. **The gateway host.** A small always-on Linux VM or container on that
   tailnet, **tagged** (e.g. `tag:demo`) so discovery accepts it whoever the
   reviewer signs in as (`GatewayCandidates.swift:70`). Key expiry disabled.
   Its MagicDNS name is `<GATEWAY_HOST>`, e.g.
   `demo.<tailnet>.ts.net`.
3. **The demo dashboard.** `fake_gateway.py` behind `tailscale serve` on 443
   (a publicly trusted `ts.net` certificate, as ATS requires). It needs:
   - a `--demo-token <DEMO_TOKEN>` rule, redeemable repeatedly until a date;
   - its `allowed_hosts` set to `<GATEWAY_HOST>`;
   - optionally some canned sessions. The fake answers auth, slots, folders
     and chat, so the reviewer sees the real KiroCrew shell with little in it.

   **Built** (2026-09-25): `--demo-token`/`--demo-until` (off by default, at
   most 90 days, sessions end at the date too), `--content`
   (`testing/review/demo_content.json`), the service and
   `testing/review/install.sh`. How to stand it up: `../REVIEW-GATEWAY.md`.
   The VM stays on, but the gateway is **socket-activated**: nothing of it
   runs until the reviewer's first connection starts it, and it then stays
   up (one process, so sessions and refresh chains live on). It opens no
   control port.

   A real KiroCrew instance is **not** an alternative. Its 300 s link window
   is a constant (§2), and it would run Claude sessions and tools for a
   stranger.
4. **Before each submission,** check from any node on the review tailnet that
   `https://<GATEWAY_HOST>/manifest.json` names "Kiro Crew", that
   `/api/auth/me` answers 403 with `X-Auth-Required`, and that the demo token
   redeems. `testing/harness/gateway_check.py` is the model.
5. **Redistribution:** this serves KiroCrew's frontend to Apple. Check the
   wheel's licence (§8 Q5).

**Step 1 variants:**

- **B-account: give Apple an identity.** A Google or GitHub account made for
  review, `<REVIEW_LOGIN>` / `<REVIEW_PASSWORD>`, that is a **member** (not the
  admin) of the review tailnet. The risk is the identity provider's
  new-location challenge (a code to a phone or mailbox Apple does not have).
  Point the recovery contact at a mailbox Olof watches, turn off every
  optional second factor the provider allows, and be available during the
  review window. This is the most common cause of a second 2.1. A custom OIDC
  provider with a plain username and password avoids the challenge, but
  needs a domain, WebFinger and an identity provider to run.
- **B-invite: the reviewer uses their own identity.** An invite link to the
  review tailnet, `<INVITE_LINK>`, which the reviewer accepts with any
  account. Then they sign in to Latchkey with that account and pick the
  review tailnet. Nothing secret is handed over. **Unverified:** that
  Tailscale's invite links allow any identity provider on this plan, how many
  times one can be used, and how long it lives. Check before relying on it.
- **B-key: the reviewer pastes an auth key.** A reusable, pre-approved,
  tagged auth key, `<AUTH_KEY>`. This needs a **new build** with a
  user-visible "join with an auth key" path in Release: today it exists only
  under `LATCHKEY_TEST_HOOKS` (R15). Keys last at most 90 days. The key must
  never be persisted or logged (R2's rule). The key is also an attack
  surface: a user talked into joining someone else's tailnet hands that
  tailnet's "gateway" whatever token they paste next. Of the step-1 variants,
  it is the most reliable login for Apple and the most expensive for the
  product.

Invariants: B-account and B-invite conflict with nothing. D1 holds, since the
reviewer's logs stay on the reviewer's device. R32 is exercised as designed.
B-key conflicts with R15.

Upkeep: the host is up during every review window. Remove the expired review
nodes from time to time (Reset logs them out, R32). Renew the demo token
before its date, and the auth key before 90 days.

### 5.3 Option C: a demo mode in the app

A visible "look around without a server" entry on the gate. It must be
visible to every user (guideline 2.3.1 forbids hidden features), and it
needs a new build. It answers "Information Needed" with an app change, which
is the opposite of what was asked. Its costs were set out in the first
version of this spec and are unchanged:

- a permanent entry on the gate;
- a separate, non-persistent data store so R32 still holds;
- no `latchkey://` route into it;
- effectively R11's fixture shipped in Release (R15);
- if it loads a public demo gateway, a hole through R3/R41 and the
  manual-entry gate.

No paste text is given for it, because it cannot be answered tonight.

## 6. What to paste

Fields are App Store Connect → TestFlight → **Test Information** → *Beta App
Review Information* (contact details, **Sign-in required** with user name and
password, **Review Notes**), and a **reply** to the message in App Review.
Placeholders in `<ANGLE_BRACKETS>` are things only Olof can supply. Each
option says what must be true first.

### 6.0 Option 0

**Must be true:** nobody outside the App Store Connect team needs the build.

*Beta App Review Information:* leave as is.

*Reply:*

> Thank you. We are withdrawing this build from external testing and will
> distribute it to internal testers only for now. No further review is needed
> at this time.

### 6.1 Option A

**Must be true:** a recording exists at `<VIDEO_URL>`, made on a demo tailnet
or blurred.

*Sign-in required:* unchecked.

*Review Notes:*

> Latchkey is a client for Kiro Crew, a dashboard that each user runs on
> their own computer and keeps on their own private Tailscale network. It is
> never on the public internet. Latchkey carries its own Tailscale
> connection (no VPN profile is installed) and opens that one dashboard.
>
> The QR code the app can scan is a single-use sign-in link. The user's own
> dashboard shows it, and it expires after five minutes. Because it is minted
> per user by their own server, there is no QR code or AR marker we can
> provide that would work later. Pasting the same link as text works the same
> way.
>
> A recording of the complete flow, from Tailscale sign-in to the dashboard, is
> here: <VIDEO_URL>

*Reply:*

> Thank you for the review. Latchkey does not use AR markers, and its QR
> code is a sign-in link that each user's own server generates and that
> expires after five minutes, so there is no fixed code we can supply. The
> app connects to a dashboard the user runs on their own private network. We
> have added an explanation and a recording of the full flow to the Beta App
> Review Information: <VIDEO_URL>. We are happy to provide anything else that
> helps.

### 6.2 Option B (fill in the variant's lines)

**Must be true, all variants:** the review tailnet exists with approval off.
`<GATEWAY_HOST>` is up, tagged, serving HTTPS on 443, and passes the §5.2
check. `<DEMO_TOKEN>` redeems there and stays valid until at least
`<TOKEN_VALID_UNTIL>`. `../REVIEW-GATEWAY.md` §6 gives the values this work
fixes (`<TOKEN_VALID_UNTIL>` is December 24, 2026) and the B-invite notes
filled in as far as they go.

*Sign-in required:* **checked** for B-account with `<REVIEW_LOGIN>` /
`<REVIEW_PASSWORD>`; unchecked for B-invite and B-key (put the data in the
notes).

*Review Notes:*

> Latchkey is a client for Kiro Crew, a dashboard that each user runs on
> their own computer on their own private Tailscale network. We have set up a
> demo network and a demo dashboard for review. No QR code is needed: the
> sign-in code can be pasted as text.
>
> 1. Open Latchkey and tap "Sign in to Tailscale".
>    [B-account] Choose "Sign in with <PROVIDER>" and use the demo account
>    in the Sign-in fields: <REVIEW_LOGIN> / <REVIEW_PASSWORD>.
>    [B-invite] First open this invite in Safari and accept it with any
>    account: <INVITE_LINK>. Then sign in to Latchkey with that same
>    account and choose the network "<REVIEW_TAILNET_NAME>".
>    [B-key] Tap "Join with an auth key" and paste: <AUTH_KEY>
> 2. Latchkey searches the network and lists the demo dashboard,
>    <GATEWAY_HOST>. Tap it. (If it is not listed, tap "Enter manually" and
>    type <GATEWAY_HOST>.)
> 3. A "Sign in" sheet opens. Tap Paste after copying this code, or type it:
>    <DEMO_TOKEN>
>    (The app can also scan it as a QR code, but pasting is the same.)
> 4. The dashboard opens. Settings (pull down at the top) shows the
>    connection. "Sign out" and "Reset app" there end the demo session.
>
> The demo dashboard is available until <TOKEN_VALID_UNTIL>. Contact
> <CONTACT_EMAIL> / <CONTACT_PHONE> if anything is unreachable.

Step 4 describes F15's app bar, which is absent until a scroll up at the top
of the page summons it. Both builds have F15 (`3fe4e1196`, before either);
check the gesture on the build under review before pasting.

*Reply:*

> Thank you. Latchkey does not use AR markers, and its QR code is a
> sign-in code that can also be pasted as text. The app needs a dashboard on
> a private Tailscale network, so we have set up a demo network and demo
> dashboard for review. The full steps, the demo sign-in and the demo code
> are now in the Beta App Review Information. In short: sign in to Tailscale
> with <REVIEW_LOGIN | the invite link | the auth key>, select
> <GATEWAY_HOST>, and paste the code <DEMO_TOKEN> in the Sign in sheet.
> The demo is available until <TOKEN_VALID_UNTIL>.

## 7. End-to-end tests and acceptance

| Option | Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|---|
| B | review gateway check | owner-run, from a node on the review tailnet: `testing/review/review_check.py` (built) | R26's recognition pair over HTTPS with a trusted certificate; `<DEMO_TOKEN>` redeems twice; `/api/ws` upgrades | stopping the host; a self-signed certificate; a wrong token (all three shown 2026-09-25, against a local fake) |
| B | demo-token rule | host test of `fake_gateway.py`: `make demo-check` in `testing/harness` (built) | the demo token redeems repeatedly until its date and not after; off by default; its sessions and chains end at the date; ordinary links unchanged; the canned content | removing the date check (redemption or refresh), the session cap, the flag's default, the transcript route, the canned reply, or leaking the token into `/__state` (seven mutants, each failed) |
| B-key | auth-key join | L2 | a pasted key joins the fake control plane and reaches no log or file | writing the key to the node log |
| C | demo sealed | L1 | no workspace, node state or default-store cookie; `latchkey://` cannot enter it | the default data store |

Acceptance: the chosen build's Beta App Review status is **Approved** (App
Store Connect). For 0, internal testers install it. Nothing in Release loads
an off-tailnet origin, or holds a login path outside Testing, without a
revision saying so.

## 8. Open questions and owner actions

Most design-changing first.

1. **Do you need external testers?** If not, option 0 is the whole answer and
   nothing needs standing up.
2. **Reply against 202609250336, or submit 202609251549?** A reply is the
   fastest route but shows the pre-F11 gate. Submitting 202609251549 shows
   the introduction and the current UI (the §6.2 steps are written for it),
   and starts a new review.
3. **Will you run a review tailnet and an always-on host** for as long as
   external testing lasts? Without it, only 0 and A remain, and A is unlikely
   to pass.
4. **Is the App Store on the horizon?** If yes, B pays for itself twice: App
   Store review asks the same question more strictly.
5. ~~**May KiroCrew's frontend be served to Apple?**~~ **Settled 2026-09-26**:
   yes. Olof's reading is that the licence terms govern actual product usage,
   not a reviewer being shown the interface, so option B may serve the pinned
   wheel's frontend to App Review.
6. **Keep claiming iPad?** Test on one, or ship iPhone-only.
7. **For B, which step-1 variant?** B-account (credentials, challenge risk),
   B-invite (verify Tailscale's invite rules first), or B-key (a new build
   and an R15 revision). **Recommended: B-invite, B-account as the
   fallback** (`../REVIEW-GATEWAY.md`). Tailscale's invite links are one-time
   and expire after 30 days, on every plan, so give three. Its terms bar
   sharing one account among several people, which counts against B-account.

**Owner actions tonight:**

- Option 0 or A: paste §6.0 or §6.1. Nothing else is needed.
- Option B: create the review tailnet and the VM, then follow
  `../REVIEW-GATEWAY.md` (one `install.sh` run, three invite links). The
  demo-token rule and everything else on our side is built.
- Either way: the share extension's privacy manifest (§3.2) before the next
  `make tf` upload.

## 9. Log

2026-09-25, opened after the 0.1 rejection. Findings:

- 0.1 predates F11 and the share extension (from the build timestamp).
- The encryption declaration is consistent. Every claimed capability is used.
  iPad is claimed and untested. The share extension lacks its own privacy
  manifest.

2026-09-25 evening, revised against the reviewer's message (2.1 Information
Needed, "a demo QR code or AR marker"):

- Re-centred on the chain in §2. The QR code is step 5 of 6. The hard steps
  are the tailnet identity (1) and a reachable dashboard (4).
- Real KiroCrew's five-minute link window is a constant
  (`token_auth.py:704`, 0.7.1), so no real dashboard can supply lasting demo
  data. The fake gateway can, with a demo-token rule.
- Added B-invite, and paste-ready texts per option (§6). Option C is kept
  only as a record, since it answers "Information Needed" with a new build.

2026-09-25 night, option B's own side built (`../REVIEW-GATEWAY.md`):

- The fake gateway takes an opt-in demo token with a date, at most 90 days
  out. Its sessions and refresh chains end at the date too. It also takes
  canned content: four invented sessions, the transcript route, and empty
  `/api/apps` and `/api/instances` so that the 0.7.1 page shows no red
  errors. Without the flags the suites' fake is unchanged
  (`make gateway-check` 37/37).
- `tailscale serve` passes the Host through (read in its source). The fake
  already sees that shape in the suites. The check through the real serve
  runs at the end of `install.sh`, on the owner's VM. It has not run yet.
- B-invite is recommended: invite links are one-time and last 30 days, on
  every plan.

2026-09-25 late, the review gateway made socket-activated (owner's request):

- `latchkey-review-gateway.socket` (`Accept=no`) holds 127.0.0.1:8444; the
  service is not enabled on its own and starts on the first connection, then
  stays up. Not `Accept=yes` (a process per connection loses the in-memory
  sessions), and no idle stop (the reviewer's first probe would pay a cold
  start, and a slow probe reads as "no gateway on your tailnet").
- The fake serves on the socket systemd passes (`LISTEN_FDS`/`LISTEN_PID`)
  and binds as before when none is passed, so the suites are unchanged
  (`make gateway-check` 37/37, contract `--fake-only` ok). On the VM it runs
  with `--no-control`: no control port at all, not even on loopback.
- `make demo-check` now includes `socket_activation_test.py` (6 checks, each
  shown to fail against a mutant). It simulates systemd with a pre-bound
  socket on fd 3. systemd itself has not run it: there is still no Linux VM.
