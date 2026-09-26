# The review gateway: a demo Kiro Crew dashboard for App Review

F19 option B (`features/F19-app-review-access.md` §5.2). This page takes a bare
Linux VM to a demo dashboard that Apple's reviewer can reach from Latchkey,
and ends with the values for F19 §6.2's paste text.

**What it is.** The fake gateway the suites use (`testing/harness/fake_gateway.py`):
KiroCrew 0.7.1's real frontend, read in place from the pinned wheel and
never installed or run, in front of an emulated auth server. It adds
two things, both off unless configured:

- **a demo token**: one sign-in code that works again and again until a
  date, and never after. Real KiroCrew cannot do this: its links last
  five minutes and are used up (F19 §2). The token is the fake's own
  string. It is not a KiroCrew credential and opens nothing but this fake.
- **canned content**: four invented sessions in three folders, with
  transcripts (`testing/review/demo_content.json`). A message the reviewer
  sends is added to the session with a canned reply saying this is a demo.

**What it is not.** Nothing ships in the app. The build under review is
unchanged, so R15, R32 and R3/R41 are untouched. Nothing runs Claude,
tools or KiroCrew code. It serves only inside the review tailnet, through
`tailscale serve` and never through funnel.

## Which step-1 variant: B-invite, with B-account as the fallback

The reviewer needs a Tailscale identity on the review tailnet (F19 §2 step 1).

**Recommended: B-invite.** The reviewer accepts an invite link with an
account they already have (every reviewer has an Apple ID, and Tailscale
offers Sign in with Apple), then signs in to Latchkey with it. Nothing
secret is handed over, and there is no new-location challenge, because
the reviewer signs in as themselves. Verified against
[Tailscale's docs](https://tailscale.com/docs/features/sharing/how-to/invite-any-user)
on 2026-09-25:

- it is available on every plan, including Personal (6 users);
- each link is **one-time**, so give **three** links, one per reviewer or
  device;
- **unused links expire after 30 days**. Create them just before
  submitting. They, not the demo token, set how long the notes work;
- links carry the role you pick (**Member**). If *user approval* is on,
  each invitee also waits for an admin, so turn it off.

The risk is Apple's reading of guideline 2.1, which expects the developer to
supply the account. If the reviewer answers that they cannot use their own
account, switch to B-account.

**Fallback: B-account.** A Google or GitHub account made for review, put in
*Sign-in required*. Its costs are in F19 §5.2. The provider's new-location
challenge is the usual cause of a second 2.1, and Tailscale's terms say an
account "may not be shared or used by multiple individuals", which a team of
reviewers is.

**Not B-key**: it needs a new build and an R15 revision (F19 §5.2).

The gateway is the same for both variants. It is **tagged**, so Latchkey's
discovery lists it whichever user the reviewer signs in as
(`GatewayCandidates.exclusion`).

## 1. The review tailnet (owner, once)

A new Tailscale account under a throwaway identity, holding nothing of yours.
In its admin console:

1. **DNS**: MagicDNS **on**; **HTTPS certificates on** (`tailscale serve`
   needs them for the `ts.net` certificate; ATS rejects anything else on a
   real phone).
2. **Settings → Device management**: device approval **off**. **Settings →
   User management**: user approval **off**. No tailnet lock.
3. **Access controls**: let the admin own `tag:demo`, and let members reach
   only the gateway's HTTPS port. Replace the default policy with:

   ```json
   {
     "tagOwners": { "tag:demo": ["autogroup:admin"] },
     "grants": [
       { "src": ["autogroup:member"], "dst": ["tag:demo"], "ip": ["tcp:443"] }
     ]
   }
   ```

   Every user (admins are members too) then reaches the gateway's 443 and
   nothing else. Reviewers do not see each other. Latchkey's probe is HTTPS
   on 443 only. Reach the VM itself through your cloud provider's console
   or SSH.

## 2. The VM (owner)

Any small always-on Linux VM with systemd and Python 3.9 or newer: Debian
12 or Ubuntu 22.04/24.04, 1 vCPU and 512 MB are plenty. It needs outbound
HTTPS (Tailscale, and the wheel from `download.crew.kiro.dev`, once) and no
inbound ports at all.

```sh
sudo apt-get update && sudo apt-get install -y python3 openssl git
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --hostname=demo --advertise-tags=tag:demo
#   open the printed URL and sign in as the review tailnet's admin.
#   Tagged nodes do not expire, so there is no key expiry to turn off.
```

## 3. Install the gateway (owner, one command)

```sh
git clone https://github.com/olofj/latchkey.git && cd latchkey
sudo testing/review/install.sh --until 2026-12-24
```

(The clone needs the review-gateway commits pushed first. Otherwise copy
`testing/harness/` and `testing/review/` over with `scp -r`, keeping the two
directories side by side.)

`install.sh` is idempotent. It:

1. refuses unless the node is on the tailnet, **tagged**, and has a
   `*.ts.net` MagicDNS name;
2. copies the fake gateway, the content and the check to
   `/opt/latchkey-review`, and fetches the pinned 0.7.1 wheel there. The
   wheel is sha256-checked, and the fake refuses to start on any other;
3. makes a loopback-only self-signed certificate (`/etc/latchkey-review/`),
   which only `tailscale serve` ever sees;
4. writes `/etc/latchkey-review/env` (mode 0600): the host, the date, and a
   fresh demo token. Re-runs keep both token and date, unless given
   `--new-token` or `--until`;
5. installs and starts `latchkey-review-gateway.service` as the system user
   `latchkey-review`: loopback only, read-only filesystem, restart on
   failure. The token reaches the fake through the environment, not its
   command line;
6. runs `tailscale serve --bg --https=443 https+insecure://127.0.0.1:8444`, and
   refuses if funnel is on;
7. runs the review check through serve (below), and prints the three values
   for §6.

## 4. Check it, before every submission

From **another** node on the review tailnet, for example your Mac after
`tailscale switch` to the review account (switch back afterwards):

```sh
REVIEW_DEMO_TOKEN='<DEMO_TOKEN>' python3 testing/review/review_check.py <GATEWAY_HOST>
```

It asks exactly what Latchkey asks:

- the certificate is trusted by the **system** store;
- `/manifest.json` is named "Kiro Crew";
- `/api/auth/me` answers 403 with `X-Auth-Required`;
- the demo token redeems twice, in two fresh sessions;
- the session works;
- `/api/ws` upgrades through serve;
- a made-up token is refused.

It prints `review check: ok (7 checks)` or the first thing that failed. The
token comes from the environment (or `REVIEW_DEMO_TOKEN_FILE`), never an
argument.

**Then do the reviewer's path once on a phone.** Install the build under
review from TestFlight. Sign Latchkey in to Tailscale with a spare account
that accepted one of the invites (or as the admin). The picker should list
`<GATEWAY_HOST>`. Paste the token. Afterwards, **Reset app** in Latchkey's
settings (R32 logs the node out), and remove the node in the admin console.

## 5. Invites (B-invite)

Admin console → **Users → Invite users** → create **three** invite links with
the role **Member**. Put them in the notes as `<INVITE_LINK>` (§6). They are
single-use and last 30 days, so make them on the day you submit.

## 6. The values for F19 §6.2

| Placeholder | Value | From |
|---|---|---|
| `<GATEWAY_HOST>` | `demo.<your review tailnet's DNS name>.ts.net`, e.g. `demo.tail1234ab.ts.net` | `install.sh`'s last lines; the tailnet part is random per tailnet |
| `<DEMO_TOKEN>` | `fk1.` and 32 characters, e.g. `fk1.EXAMPLEonlyEXAMPLEonlyEXAMPLE01` (the shape only) | `install.sh`'s last lines, or `/etc/latchkey-review/env` |
| `<TOKEN_VALID_UNTIL>` | **December 24, 2026** (through 23:59 UTC) | `--until 2026-12-24`: build 202609251549's TestFlight expiry (uploaded 2026-09-25, 90 days), which is also the fake's 90-day cap |
| `<REVIEW_TAILNET_NAME>` | the review tailnet's name as its Users page shows it | yours |
| `<INVITE_LINK>` | three links, one per line | §5 |
| `<REVIEW_LOGIN>` / `<REVIEW_PASSWORD>` / `<PROVIDER>` | B-account only | yours |
| `<CONTACT_EMAIL>` / `<CONTACT_PHONE>` | | yours |

In the notes, write the date as "December 24, 2026". If invites are the
limit (§5), give the earlier of the token's date and the invites' expiry.

**Review Notes for B-invite, filled as far as this work determines them:**

> Latchkey is a client for Kiro Crew, a dashboard that each user runs on
> their own computer on their own private Tailscale network. We have set up a
> demo network and a demo dashboard for review. No QR code is needed: the
> sign-in code can be pasted as text.
>
> 1. First open one of these invite links in Safari and accept it with any
>    account you already have ("Sign in with Apple" works). Each link can be
>    used once:
>    <INVITE_LINK>
>    <INVITE_LINK>
>    <INVITE_LINK>
>    Then open Latchkey, tap "Sign in to Tailscale", sign in with that same
>    account and choose the network "<REVIEW_TAILNET_NAME>".
> 2. Latchkey searches the network and lists the demo dashboard,
>    <GATEWAY_HOST>. Tap it. (If it is not listed, tap "Enter manually" and
>    type <GATEWAY_HOST>.)
> 3. A "Sign in" sheet opens. Copy this code, then tap Paste, or type it:
>    <DEMO_TOKEN>
>    (The app can also scan it as a QR code, but pasting is the same.)
> 4. The dashboard opens with a few example sessions. Messages you send get
>    a canned reply, since no assistant runs behind the demo. Settings (pull
>    down at the top) shows the connection. "Sign out" and "Reset app" there
>    end the demo session.
>
> The demo dashboard is available until December 24, 2026. Contact
> <CONTACT_EMAIL> / <CONTACT_PHONE> if anything is unreachable.

Step 4's gesture is F15's (F19 §6.2's note): check it on the build under
review before pasting.

## Upkeep

| When | Do |
|---|---|
| a new submission | step 4's check; new invite links |
| a new build or a later date | `sudo testing/review/install.sh --until <date>` (at most 90 days out) |
| the token may have leaked | `sudo testing/review/install.sh --new-token`, and update the notes |
| logs | `journalctl -u latchkey-review-gateway`. The fake logs no requests and no message text |
| after a review | remove the reviewers' nodes and users in the admin console |
| done with external testing | `sudo tailscale serve reset`; `sudo systemctl disable --now latchkey-review-gateway`; delete the VM and the account |

A restart of the service (or the VM) forgets the sessions and anything a
reviewer typed. The token keeps working, so the reviewer only pastes it
again. Nothing is written to disk.

## What was verified, and where

On the development Mac, 2026-09-25:

- **`make gateway-check`**: 37/37 before and after the change, so the
  suites' fake is unchanged without the new flags.
- **`make demo-check`** (`testing/review/demo_token_test.py`, 9 checks): off
  by default; reusable; survives restart, reset and logout-all; never in
  `/__state`; ordinary links unchanged; sessions and refresh chains end at
  the date; the content; the canned reply. Each check was shown to fail
  against a fake with that behaviour removed (seven mutants). It passes on
  Python 3.14 and 3.10.
- **`review_check.py`** passes against the fake, and fails on a private CA
  checked against the system store, on a wrong token, and on a stopped host.
- **The unit's `ExecStart`**, fed the env file `install.sh` writes, serves
  the recognition pair, the sign-in and the content to requests shaped like
  `serve`'s.
- **The content in the real 0.7.1 frontend** (simulator Safari): the
  sessions and transcripts render without error banners. This needed two
  empty answers in content mode (`/api/apps`, `/api/instances`), which the
  page otherwise shows as red errors.

**Through `tailscale serve`: by reading its source, not yet by running it.**
Tailscale's proxy passes the client's `Host` through to a TCP backend and
adds only `X-Forwarded-*` and `Tailscale-User-*` headers
([ipn/ipnlocal/serve.go](https://github.com/tailscale/tailscale/blob/main/ipn/ipnlocal/serve.go)).
The fake then sees what the suites already give it: a port-less Host from a
loopback peer, so the cookies are named `mc_*_5476`. It passes WebSocket
upgrades, and `https+insecure://` skips verification of the loopback
certificate. Serving on the owner's tailnet from here would have published
the fake there, so it was not run. **`install.sh` ends with the check through
the real serve on the VM, and step 4 repeats it from another node.** Until
one of those passes, treat "works through serve" as unverified.

`install.sh` as a whole has not run on Linux: there was no VM, and the
sandbox blocked Docker. Its parts were run separately: the status parsing,
the date guard, the certificate command and the unit's command line. It
passes `sh -n` and `dash -n`.

## Open

- **Licence** (F19 §8 Q5): this serves KiroCrew's frontend to Apple. Check
  before submitting.
- **Apple's reading of B-invite** (above): fall back to B-account if asked.
