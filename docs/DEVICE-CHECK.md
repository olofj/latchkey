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

---

## 1. Prerequisites

| # | Who | Step | Done |
|---|---|---|---|
| O1 | Olof | Xcode → Settings → Accounts → add your Apple ID (a free personal team is fine). Note the **Team ID** it shows and give it to the session. | ☐ |
| O2 | Olof | iPhone: Settings → Privacy & Security → **Developer Mode** on (the phone restarts). Connect it to chonk and tap *Trust*. Note the **iOS version** (Settings → General → About). | ☐ |
| O3 | Olof | Apply the "admin purgatory" tailnet policy (decision D5) through the infra workspace. Afterwards a new admin-owned device lands in `100.81.0.0/24` with **no grants**, and `kiro-clients` (`100.82.1.0/24`) is allowed to reach `byskebox:443` only. | ☐ |

## 2. Install

1. Open `app/Latchkey.xcodeproj` in Xcode.
2. `Latchkey` target → Signing & Capabilities → Team: your personal team.
   (`DEVELOPMENT_TEAM` is blank in the project on purpose, so Xcode asks.)
3. Select the iPhone as the run destination and press **Run**. The first run
   builds TailscaleKit into the app, which takes a few minutes.
4. On the phone: Settings → General → VPN & Device Management → trust your
   developer profile. Launch Latchkey.

## 3. Tailnet login

1. **Turn the Tailscale app's VPN off** on the phone. That is the point of this
   check.
2. In Latchkey, tap **Login** and complete the Tailscale sign-in as
   `owner@example.com`.
3. The node appears in the admin console as **`latchkey-iphone`**, owned by
   you, **untagged**, with an address in the purgatory pool (`100.81.0.x`).
   Check all three.

At this point the app shows the dashboard view, but **the dashboard will not
load** — the node has no grants yet. That is expected, not a bug.

## 4. Out of purgatory — O3b (Olof)

Move the node's address into the next free `kiro-clients` address
(`100.82.1.x`) via the admin console or the API. Record the address here:
`100.82.1.___`.

Reinstalling the app creates a *new* node, which lands back in purgatory and
must be moved again.

## 5. First token — O5 (Olof)

1. On byskebox, mint a token: `kirocrew token` (the CLI prints up to three
   URLs; any one of them works), or use the dashboard's *Phone access* QR.
2. Within **5 minutes**, in Latchkey, paste it into the **dashboard's own red
   banner**. It accepts the whole URL or the bare token. (The app's native
   token sheet is M4 and does not exist yet; the banner is the page's own UI.)

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
