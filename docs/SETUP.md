# Setting up Latchkey for yourself

Latchkey is a single-purpose iPhone app that loads **one** self-hosted
[KiroCrew](https://github.com/kirodotdev/KiroCrew) dashboard over an embedded
Tailscale node — no system VPN, no address bar, no second destination.

This page is for **someone who is not the author** getting it running. It says
what your tailnet, your gateway and your Mac each need, and it separates the
parts everyone needs from the parts that only apply to a locked-down tailnet.

> The author's own bring-up runbook is [`DEVICE-CHECK.md`](DEVICE-CHECK.md). It
> names his hosts and his tailnet policy on purpose. Read this page instead, and
> that one only if your tailnet is restricted in the same way.

## The short version

On a **flat tailnet** — every device can reach every other, no ACLs, no device
approval — there are four steps and none of them involves access control:

1. Run KiroCrew on a computer, with authentication on.
2. Put its dashboard on the tailnet with `tailscale serve`.
3. Build the app onto your iPhone with your own signing team and bundle id,
   set once in `app/Local.xcconfig` before the first install.
4. Sign the app's node into your tailnet, pick the gateway, paste a token.

Everything below is the detail, plus what changes if your tailnet is not flat.

## 1. What your tailnet needs

**Nothing, if it is flat.** The app makes no assumption about addressing,
grants, tags or approval. It asks the node for its peers, probes the plausible
ones, and loads the one you choose. There is no configuration in the app for
ACLs because the app has no concept of them.

Two things about your tailnet will change what you see, and both are
Tailscale's behaviour rather than the app's:

| Your tailnet has | What happens | What to do |
|---|---|---|
| **Device approval** | The connection gate says the node is waiting for approval and connects by itself once you approve it | Approve the new machine in the admin console |
| **Tailnet lock** | The node signs in but stays "Locked Out" and reaches nothing | Sign the node's key: `tailscale lock sign <nodekey>` from an already-trusted machine |
| **ACLs / grants** | The node connects, and can still reach **nothing**. Discovery finds no gateway | Grant the node access to the gateway. See [§6](#6-if-your-tailnet-restricts-access) |
| **Nothing (flat)** | The node connects and discovery finds the gateway | — |

The state worth naming in advance is the third one: **connected but unable to
reach anything looks exactly like a broken app.** It is not. The node is fine;
the tailnet is refusing the traffic.

## 2. What the gateway needs

A computer on the same tailnet, running KiroCrew with **authentication
enabled** (the app signs in with a token; it will not load an open dashboard by
accident, and an unauthenticated dashboard is not something you want on a
tailnet anyway).

Then publish it on the tailnet over HTTPS:

```sh
tailscale serve --bg --https=443 http://127.0.0.1:<kirocrew-port>
```

**Use 443.** It is what the app probes first, it needs no further
configuration, and — importantly — KiroCrew's own allowed-origins list is built
as `https://<your-host>` with **no port**. Serving on a non-default port means
the dashboard's origin is no longer in that list, so GETs succeed while the
WebSocket, the token refresh and sign-out are all refused: the page looks fine
and does nothing. If you must use another port, see
[`features/F1-gateway-port.md`](features/F1-gateway-port.md) — it is possible,
and it needs `KIROCREW_CORS_ORIGINS` set on the gateway and a restart.

Check it from another machine on the tailnet before touching the phone:

```sh
curl -sI https://<your-host>.<your-tailnet>.ts.net/ | head -1
```

### What discovery looks for

The app finds gateways by probing peers, so it helps to know what it skips
(`app/App/Discovery/GatewayCandidates.swift`). A peer is **not** probed when it
is offline, key-expired, a shared-in node from another tailnet, owned by a
different user while untagged, or reports an OS other than Linux, macOS or
Windows.

That last pair matters if your setup is unusual: a gateway on a **NAS or a BSD**
may be skipped for its OS, and a gateway **owned by someone else** on a shared
tailnet may be skipped for its owner unless it is tagged. In both cases *Enter
manually* still works and is the answer. (Loosening these filters is tracked as
[`features/F7-portable-discovery.md`](features/F7-portable-discovery.md).)

## 3. What your Mac needs

- Xcode (the author builds with Xcode 27; the app targets iOS 26), with an
  Apple ID added under Xcode → Settings → Accounts. A **free personal team is
  enough** for sideloading; TestFlight needs the paid Developer Program and
  is optional ([TESTFLIGHT.md](TESTFLIGHT.md)). Note the
  ten-character **Team ID** the Accounts pane shows next to it.
- Go (the author builds with 1.27), for the embedded Tailscale library.
- Your iPhone on iOS 26 or later, paired to this Mac by cable — unlock it and
  tap *Trust* — with **Developer Mode** on (Settings → Privacy & Security →
  Developer Mode; the switch only appears once the phone has been connected to
  a Mac running Xcode, and turning it on restarts the phone).

### Your identity: set once, before the first install

Two build settings are yours to choose, and once an install exists, yours to
keep: the **signing team** and the **bundle id**. The project ships with no
team and with the author's bundle id as the default, which you must not reuse.
Put both in `app/Local.xcconfig` (gitignored). The project reads that file, so
Xcode's Run and `make device` see the same two values:

```
DEVELOPMENT_TEAM = ABCDE12345
LATCHKEY_BUNDLE_ID = com.example.latchkey
```

`ABCDE12345` is your Team ID; the bundle id is any reverse-DNS name you own.
Do **not** `export` these in your shell instead: Xcode inherits nothing from a
shell, and two builds that disagree on the bundle id install two apps — the
second one empty, i.e. a brand-new Tailscale node. An exported value is ignored
by design, and `make device` says so if it sees one.

Why "once": the bundle id decides the app's container on the phone, and the
container holds the tsnet node's identity (its key), the gateway choice and the
dashboard session. The team decides who signed the app. Changing either after
the first install:

| You change | What the phone does | What it costs |
|---|---|---|
| the bundle id | Installs a **second** app beside the first, with an empty container | The new app is a new node: new login, new approval or grant, new token. The old node stays in your tailnet until you remove it |
| the team | **Refuses the install** — same bundle id, different signer | Nothing yet. The tempting fix, delete the app and install again, deletes the node with it |

The safe order for either change is to open the app first and run **Settings →
Reset app**, which signs out of the dashboard, logs the node out of the tailnet
(expiring its key) and deletes everything stored on the phone. Then delete the
app, change the setting, install. What is left is an expired node in your admin
console to remove, not a live orphan.

### Build and install

```sh
cd app
make framework     # embedded Tailscale library; needs Go, slow the first time
make app           # optional: simulator build, to check the toolchain
make device        # build (Release), install and launch on the paired phone
```

`make app` builds for a simulator named "iPhone 17"; pass
`SIM_NAME="<a simulator Xcode lists>"` if you have no such device, or skip it.

`make device` checks the phone first (paired, reachable, Developer Mode on) and
explains what is missing rather than failing obscurely. It signs with the team
in `Local.xcconfig`, installs, and launches whichever bundle id it just built.

The very first install may still need Xcode: minting the signing certificate
needs your Apple ID to be usable from the command line, and an account added in
Xcode's UI sometimes is not (`make device` reports "no usable Apple ID here").
If so, open `app/Latchkey.xcodeproj`, choose your phone as the destination and
press Run once. There is nothing to pick under Signing & Capabilities — the
team is already there from `Local.xcconfig`. After that `make device` works on
its own, against the profile Xcode made. Both paths install the same app: same
bundle id, same team.

On the phone, the first time only: Settings → General → VPN & Device Management
→ trust your developer profile. Until you do, the icon is there and the app
refuses to open.

**A free team's profile lasts 7 days.** After that the app stops launching; its
data is intact, and `make device` (or Run) over the installed app renews the
profile without touching the node. Deleting the app is the only thing that does.

## 4. First run on the phone

1. **Connect the node.** The gate shows Tailscale's status and a Login button.
   Sign in with your own account so the node is yours and untagged. It appears
   in your tailnet as `latchkey-iphone`.
2. **Approve it** if your tailnet asks (§1).
3. **Pick the gateway.** The app sweeps the tailnet and lists what answered.
   Nothing listed? Use *Enter manually* with the host name — and if manual entry
   works while the sweep found nothing, that is a discovery filter (§2), not a
   network fault.
4. **Sign in.** Mint a token on the gateway and paste it. Tokens are per-gateway
   and short-lived, so mint it when you are ready to type it.

**Do not rename the node afterwards.** KiroCrew ties a session to your login
*and* the node name, so renaming signs the app out.

## 5. When it does not work

The app keeps its own logs on the device, and they are the fastest route to an
answer: **Settings → Diagnostics → Logs** for the app, **Settings → Node log**
for the embedded Tailscale node. Nothing is uploaded anywhere — there is no
telemetry in this app, by design — so reading them means reading them on the
phone, or pulling the container while the phone is attached and
development-signed:

```sh
xcrun devicectl device copy from --device <udid> \
  --domain-type appDataContainer --domain-identifier <your-bundle-id> \
  --source "Library/Application Support/Latchkey/Logs/tsnet.log" --destination .
```

That path says `Latchkey` and is not a typo: the product was renamed and the
storage directory deliberately was not, so existing installs keep their node.

| Symptom | Most likely cause |
|---|---|
| Node connects, discovery finds nothing, manual entry also fails | The tailnet is refusing traffic: ACLs (§6), tailnet lock, or approval |
| Discovery finds nothing but manual entry works | A discovery filter skipped the gateway (§2) |
| Page loads, then never updates; sign-out fails | The gateway is served on a non-default port and its origin list has no port (§2) |
| Blank page after the token | Known KiroCrew/WebKit issue; check the app log for what the page actually did |

## 6. If your tailnet restricts access

You only need this section if your tailnet has ACLs. The app needs exactly one
thing: **the phone's node must be allowed to reach the gateway on its serve
port.** How you express that is your tailnet's business — a grant by tag, by
user, or by address range.

The author's tailnet does it by address range, and deliberately makes new
devices useless until moved: a new admin-owned device lands in a no-grant pool,
and a separate range is allowed to reach the gateway. That design is described
in `DECISIONS.md` (D5) and its runbook is `DEVICE-CHECK.md`. **It is one
example, not a requirement** — nothing in the app knows it exists.

If you use something similar, the thing to remember is the diagnosis: a node
that is connected and reaches nothing is almost always a missing grant, and the
app's own node log will show the packet filter it was given.
