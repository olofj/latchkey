# F27 — Update vendored libtailscale to 0.2.0

| | |
|---|---|
| **Status** | spec |
| **Requested** | 2026-10-15, by Olof: "Bring the vendored libtailscale up to upstream 0.2.0 and rebuild TailscaleKit." (issue #13) |
| **Revision** | none: no documented behaviour changes |
| **Touches** | `app/ThirdParty/libtailscale` (vendored, R16), `app/ThirdParty/VENDORED.md`, the TailscaleKit xcframework |
| **Testers** | The embedded Tailscale library is updated; sign in, open the dashboard and share as usual |

## 1. Why

The vendored tree was imported from the aperture-plus fork network at
`f55900d`, which branched from upstream `tailscale/libtailscale` at
`5e89501` (2026-02-28; the ruby and python trees match it blob for blob).
Upstream has since released 0.2.0 (`d1dc45d`, 2026-10-14; upstream does
not tag, the version lives in the bindings). Nine upstream commits are
not in our tree.

## 2. What the owner sees

Nothing new. The app signs in, connects and loads the dashboard as
before. A failure would show as a node that does not start (F8's
screen), or as a suite regression.

## 3. Non-goals

- `tailscale-patched/` stays at `b5adfd8`. Upstream 0.2.0 moves its
  `tailscale.com` requirement to v1.104.1, but our `go.mod` replaces the
  module with the patched tree (the apenwarr/aperture netmap-cache patch,
  R16). Rebasing that patch onto v1.104.1 is a separate piece of work.
  The `require` version, the `go` directive and `go.sum` refreshes from
  the two upstream module bumps are therefore not taken.
- No app (`App/`, `TSNet/`) changes.

## 4. Design

Cherry-pick (R16), in upstream order, each as its own commit naming the
upstream SHA, conflicts resolved against the fork's existing changes:

| Upstream | Subject |
|---|---|
| `80771313` | add `tailscale_status_json` |
| `8564835` | swift: gate the listener API by availability |
| `61e8513` | swift: run `tailscale_up` off the `TailscaleNode` actor |
| `59d4bb8` | build: let the environment override `MACOS_TARGET` |
| `4e3b222` | listener address passing, test simplification (module bump not taken) |
| `019b925` | tailscale v1.104.1 bump (not taken, see §3; nothing else in it applies) |
| `775e7e3` | ruby: regenerate `Gemfile.lock` |
| `258321b` | frame the listener fd-passing records |
| `d1dc45d` | binding versions to 0.2.0 |

Every Latchkey delta commit above the R16 import is kept as is. Then
`make framework`, which restamps the xcframework.

**Invariants this must not break** (see `../../app/AGENTS.md`):
- the split tunnel decides what goes through the proxy; only tailnet hosts do;
- `allowFailover` stays false;
- ATS stays on with no exceptions; HTTPS only;
- D1: no app or node logs leave the device;
- a vendored-tree change is its own commit (R16).

## 5. State and migration

Nothing persisted changes. The tsnet state directory is read by the same
`tailscale-patched` tree, so the node keeps its identity.

## 6. End-to-end tests

No new tests of ours. Upstream's own Go tests come with the cherry-picks.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| vendored Go tests | `scripts/test-all.sh` Go step | upstream and Latchkey Go tests pass on the updated tree | upstream's new listener test, run against the pre-update tree |
| L1, L2, session, discovery, lifecycle | `scripts/test-*.sh --build` | no regression | existing |

**Device check**

1. Sign in, open the dashboard, and share a link into a session.

## 7. Acceptance criteria

- `make check-framework` passes on the new tree.
- The vendored Go tests, `make test-policy`, L1, L2, session, discovery
  and lifecycle pass (known flakes noted in `../DECISIONS.md`).

## 8. Open questions and owner actions

- Moving `tailscale-patched` to v1.104.1 (§3).
- The device check (§6).

## 9. Log
