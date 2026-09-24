# M1 device check — runbook

The M1 acceptance check that only a real iPhone can answer: **does the KiroCrew
dashboard render in Latchkey, over the embedded Tailscale node, with the
system Tailscale VPN off?** It is also the live re-test of
[KiroCrew #9399](https://github.com/kirodotdev/KiroCrew/issues/9399)
("dashboard renders blank in all WebKit browsers over Tailscale").

Revision R8 moved device bring-up ahead of this check. The steps must happen
**in this order**: the node has to be out of purgatory before the first token
is redeemed.

Steps marked **(Olof)** are §C owner actions in `PLAN-REVISIONS.md` that an
agent cannot do.

> **This runbook is written for one environment: Olof's.** It names his
> gateway and assumes his tailnet policy — new devices land in a no-grant
> address pool and a separate range is allowed to reach the gateway (D5). Step
> O3 exists only because of that policy and is **meaningless on a flat
> tailnet**, where a signed-in node can reach its peers immediately.
>
> If you are setting this up for yourself, use [`SETUP.md`](SETUP.md) instead.
> Nothing in the app knows about purgatory, grants or address ranges; the
> ordering constraint above is a property of this tailnet, not of the product.

---

## 1. Prerequisites

| # | Who | Step | Done |
|---|---|---|---|
| O1 | Olof | Xcode → Settings → Accounts → add your Apple ID (a free personal team is fine). Note the **Team ID** it shows and give it to the session. | ☑ 2026-09-21: "Olof Johansson (Personal Team)", `DX33PQ7J4A`, kept in `app/.dev-team` (gitignored) |
| O2 | Olof | **At chonk, with the phone.** Connect the iPhone to chonk with a cable and tap *Trust*. Then Settings → Privacy & Security → **Developer Mode** on (the phone restarts). The Developer Mode switch appears only after the phone has been connected to a Mac with Xcode. `make device` then checks the pairing and Developer Mode itself and prints the **iOS version**, so there is nothing to report. | ☐ |
| O3 | Olof | Apply the "admin purgatory" tailnet policy (decision D5) through the infra workspace. Afterwards a new admin-owned device lands in `100.81.0.0/24` with **no grants**, and `kiro-clients` (`100.82.1.0/24`) is allowed to reach `byskebox:443` only. | ☑ 2026-09-21 |

**Why O2 needs you at the Mac.** A free personal team can only install by
Xcode, from a Mac the phone is paired with: no TestFlight and no ad-hoc
builds, which need the paid Developer Program. Pairing needs the phone at
chonk, on the cable (or, on recent iOS, the same Wi-Fi). Each install needs
the phone on the cable or on chonk's local network. A remote link such as
Tailscale is not enough. Once the app is installed, nothing else in this
check needs the Mac, and M6.6's timings are meant to be run untethered.

## 2. Install

With the phone paired and on the cable (or on chonk's network):

1. `make -C app device`: a Release build signed with the team in
   `app/.dev-team`, installed and launched on the paired iPhone. A session can
   run this for you. The first build creates the signing certificate and a
   7-day profile, and registers the phone.
   *Or in Xcode:* open `app/Latchkey.xcodeproj`, check `Latchkey` → Signing &
   Capabilities → Team (the app target carries the Team ID since Xcode wrote it
   there on the first Run, 2026-09-23), pick the iPhone and press **Run**. That
   installs a Debug build.
2. The first time only, on the phone: Settings → General → VPN & Device
   Management → trust your developer profile. Then open Latchkey.

## 3. Tailnet login

1. **Turn the Tailscale app's VPN off** on the phone. That is the point of this
   check.
2. In Latchkey, tap **Login** and complete the Tailscale sign-in as
   `owner@example.com`.
3. The node appears in the admin console as **`latchkey-iphone`**, owned by
   you, **untagged**, with an address in the purgatory pool (`100.81.0.x`).
   Check all three.

**If the console shows the node "Locked Out"** (seen on the first real
install, 2026-09-23): the tailnet has **tailnet lock** on, and a new node's
key must be signed before any peer will talk to it. It is a device state, not
a tag, and no address change fixes it. On a signing node, in a terminal (the
App Store build's CLI does not run from an agent shell):

```bash
tailscale lock status                    # this node can sign; locked-out nodes listed
tailscale lock sign nodekey:<the phone's node key>
```

The node key is on the machine's page in the admin console. Signing happens
on a signing node because the key never leaves it; the console cannot do it.
**Every new node needs this**: rebuilding over the installed app keeps the
node, but deleting the app creates a new one, locked out again.

At this point the app is connected but finds no gateway, because the node
has no grants yet. That is expected, not a bug. *Choose a gateway* says one
of two things, depending on whether the policy lets the node see its peers:
- **"No Kiro Crew gateway answered among N computer(s) on your tailnet"**:
  the peers are visible but drop the node's traffic. The search ends in
  about 4 s: every probe runs at once and each waits out the per-request
  timeout (`GatewayDiscovery.requestTimeout`, 4 s since R39; it was 1.5 s
  when this was written). In Settings → Logs, each `socks[n] CONNECT … request reached
  the tailnet proxy` is followed by `relay finished`, with no OK or FAILED
  line.
- **"No computers on your tailnet could be a gateway"**: the node sees no
  peers at all.

## 4. Out of purgatory — O3b (Olof)

Move the node's address into the next free `kiro-clients` address
(`100.82.1.x`) via the admin console or the API, with the app still running.
Record the address here: `100.82.1.___`.

Give it a few seconds to reach the phone, then tap **Search again** in Kiro
Roam. byskebox is listed, and as the only gateway it is chosen by itself; the
Sign in sheet opens (step 5). If the node saw no peers before, the picker
searches again by itself when they appear. If a search still finds nothing,
tap Search again once more before reading it as a fault. Settings → Status
should show the new address under Addresses.

The L2 harness rehearses exactly this step: the running node's address
changes, and nothing in the app has to restart (`DiscoveryTests.
testDeviceCheckRehearsalPurgatoryThenAddressMove`, 2026-09-21).

Reinstalling the app creates a *new* node, which lands back in purgatory and
must be moved again.

## 5. First token — O5 (Olof)

1. On byskebox, mint a token: `kirocrew token` (the CLI prints up to three
   URLs; any one of them works), or use the dashboard's *Phone access* QR.
2. Within **5 minutes**, in Latchkey's **Sign in** sheet, tap Paste (it
   accepts the whole URL or the bare token), or Scan the QR code. The sheet
   (M4) opens by itself when the dashboard has no session.

CLI links carry no boot binding, so their sessions and 30-day refresh chains
survive gateway restarts. QR sessions end at a restart by default (R24).

## 6. What to check and record

Record each result in `docs/DECISIONS.md` under a new "M1 device check" entry.

| Check | Expected | Result |
|---|---|---|
| iOS version | — (for #9399, reported on 26.6.1) | |
| Dashboard renders (not blank) after the token | a live KiroCrew chat | |
| System Tailscale VPN was off throughout | yes | |
| A chat streams (WebSocket) | messages arrive live | |
| Settings → Routing shows the gateway as `PROXY` | `byskebox… → PROXY via tailnet` | |
| Settings → Diagnostics → Web page restarts | `none` | |
| Local Network permission **allowed** | dashboard loads | |
| Local Network permission **denied** (Settings → Privacy & Security → Local Network → Latchkey off, then relaunch) | dashboard still loads, perhaps more slowly; note any `-1000` | |

## 7. If it goes wrong

| Symptom | First thing to check |
|---|---|
| Connected, but the dashboard never loads | **O3b** — is the node still in purgatory (`100.81.0.x`)? |
| Blank white page after the token | This is #9399. Stop and record it (stop gate R35). The fallbacks are the reporter's published fix patched into byskebox's gateway venv, or a client-side `WKUserScript`. |
| Red banner says the token is invalid or expired | Tokens are signed per gateway and last 5 minutes. Mint a fresh one on byskebox itself. |
| `-1000` "invalid URL" on the dashboard | Settings → Routing: is the gateway `PROXY`? Try with Local Network allowed. |
| App stops launching after 7 days | The free provisioning profile expired: rebuild and Run again. The app's data survives. |

Settings → Diagnostics → **Logs** shows the app's own log, including a
`socks[n]` line for every proxy connection. Nothing in it leaves the phone
(D1), and URLs appear without their query strings.
