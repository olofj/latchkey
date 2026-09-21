# Decisions

Append-only. Newest at the bottom. One entry per decision that a future reader
would otherwise have to reverse-engineer: why a divergence from upstream exists,
what was measured, what was rejected and why.

Format:

```
## YYYY-MM-DD — short title
**Decision:** what was decided.
**Why:** the reasoning, including what was rejected.
**Evidence:** measurements, file references, links.
```

---

## 2026-09-20 — Fork aperture-plus rather than build fresh

**Decision:** base the app on [tailscale/aperture-plus](https://github.com/tailscale/aperture-plus)
@ `dba0555`, keeping `upstream` as a remote and tracking it.

**Why:** aperture-plus already solves the parts that are genuinely hard on iOS —
the split-tunnel `matchDomains` computation, the `NSURLErrorBadURL (-1000)` proxy
semantics, the `node.up()` actor-starvation workaround, and failure-driven
recovery when iOS reclaims the loopback listener. Building on `tunnelless` (MIT,
~250 lines) was considered; it would mean rediscovering those by hitting the same
bugs. The cost is carrying code we delete once, plus upstream tracking.

**Evidence:** `docs/PLAN.md` §2.2, and the file map in §10.

## 2026-09-20 — Do not build a native session-refresh loop

**Decision:** the app will not call `POST /api/auth/refresh`. The dashboard's own
JS client already does, single-flight, triggered by HTTP 403 + `X-Auth-Required: true`.
The app hooks the page's `mc-auth-required` / `mc-auth-cleared` events instead.

**Why:** reusing a rotated refresh token outside its grace window revokes the
entire 30-day chain. A native loop racing the page's would eventually do exactly
that. There is also no durable token to cache — the link window is 300 seconds —
so the refresh chain is the only long-lived credential and must not be endangered.

**Evidence:** `dashboard/token_auth.py:3097-3111` (the 403 + header pair),
`client-oM83i081.js` (memoised single-flight refresh, 401 terminal latch);
`docs/PLAN.md` §3.3.
