# Upstream report — the instance tab bar is unusable at phone widths: chips overlap or are clipped to nothing

**Not filed.** Prepared 2026-09-23 for [kirodotdev/KiroCrew](https://github.com/kirodotdev/KiroCrew),
to be filed with their **Bug report** form once Olof authorises it, as he did
for the fonts report (KiroCrew#13161). Found while working on F5
(`../features/F5-portrait-session-list.md`). Drafted on 0.6.0, re-measured
on **0.7.1** on 2026-09-25 (F5 §13). Stable, pip/venv
service install, observed from an iOS client; the layout facts below are read
from the shipped bundle and are not platform-specific.

**Duplicate check** (searched 2026-09-23, `gh search issues`, single terms:
`instances`, `"tab bar"`, `overlap`, `portrait`, `topbar`, `"remote instance"`,
`"mobile header"`, `chip`; the `fonts` query returning #13161 was the control
that the search works). Nothing on this. The near misses, all different:
- **#8175** (closed) — the same instance tab bar collapsing to the active crew
  *on desktop* when a remote pane is focused (the embedded-mode variant).
  Desktop, and about which entries render, not about width.
- **#7698** (closed) — the mobile top bar's `tb-has-update` collapse ladder
  hiding the CPU/MEM/DSK readouts: a sibling rung of the same `.tb-*`
  container-query ladder this report is about, on the *right* cell. Useful
  precedent that the ladder's thresholds are meant to be tuned for phones.
- **#9581** (closed) — two overlapping error surfaces in the topbar for one
  API error. Different mechanism (duplicate surfaces), not layout width.
- **#9979** (open), **#2895** (closed) — responsive audits of other pages
  (Crew Members, Schedule). Not the header.

Fields to fill in before posting: **KiroCrew version** (take
`kirocrew --version` on the gateway; the bundle here is the 0.7.1 pin),
**release channel**, **how it is installed**, **platform** (not
platform-specific; observed in WebKit on iOS at a 402 px viewport). Attach the
two screenshots from `../features/f5-measurement/` (`portrait-chips-overlap.png`,
`landscape-chips-ok.png`), and the phone's own header screenshot if Olof
supplies one (see F5 §11). The screenshots are 0.6.0's. 0.7.1 shows the
same overlap, measured rather than photographed (below). The client-side
stop-gap has shipped (F5 B, `9b90224`), so the two "stop-gap" sentences are
in the present tense. **Before posting, decide on face 2**: the clipping of
pinned remotes could not be shown failing in 0.7.1 at 402 pt (F5 §13), so
it is reasoned from the markup, not observed. Either keep it marked as such
or cut it.

---

## Title

Instance tab bar at phone widths: chips are drawn over each other when the
list fails, and pinned remote chips are clipped to a sliver when it loads

## What happened

On a phone-width viewport (402 px, iPhone portrait) the instance tab bar in the
top-left of the header — `Local`, the *Switch instance* chevron, and the pinned
remote crews — is not usable. Two faces of it, same cause:

1. **When `GET /api/instances` fails with anything other than 403** (the
   component hides itself on 403), the inline error chip that the bar renders
   next to the chips squeezes the chip group, and the `Local` chip, the
   chevron and the error text (`not found` / *Ask the agent* in the attached
   screenshot) are painted **on top of one another**. Nothing in the row is
   readable or reliably tappable. Measured on 0.7.1 at 402 px: `Local` at
   x 56–124, the chevron at x 127–152, and the error's `not found` at x 124,
   17 px wide and 146 px tall, its text wrapped into a column.
2. **When the list loads** (reasoned from the markup; not reproduced in
   0.7.1), `Local` and the chevron take the ≈100 px they need
   and the pinned remote chips (`crew-chip-row`) are clipped to what remains —
   about 30 px — with the 1 px `data-cut` mark. The remotes are effectively
   invisible; the only way to them is the 24 px chevron's dropdown.

At 874 px (the same phone, landscape) the header uses its desktop grid and the
same chips lay out cleanly (second screenshot). So it is the width, and only
the width.

Expected: at phone widths the bar either scrolls, wraps, or degrades in a way
that keeps every chip legible and reachable — the same intent the existing
`@container` rungs express, which never engage here (below).

## Steps to reproduce

1. Enable the Instances feature (`instances.enabled = true`) and configure at
   least one remote crew; pin it from the *Switch instance* menu so it renders
   as a chip.
2. Open the dashboard at a 402 px-wide viewport (a phone in portrait, or
   DevTools responsive mode at 402 × 874).
3. Observe `.tb-left` (the header's left cell) is ≈180 px wide, that
   `crew-chip-row` has `data-cut="true"`, and that the pinned chip is clipped
   to a sliver next to `Local` and the chevron.
4. Now make the list request fail without a 403 — in DevTools, block the URL
   `/api/instances` (it fails as a network error), or return any 5xx — and
   reload at the same width. The inline error chip appears in the bar and the
   `Local` chip, the chevron and the error text overlap (first screenshot).
5. Rotate to 874 px: both cases lay out correctly.

## Cause, from the shipped bundle

Header grid (0.6.0 `static/dist/assets/src-DcpTXSeK.css`; unchanged in
0.7.1's `src-BB9Pem3r.css`, which adds a 208 px `tb-drop-navhistory` rung):

```css
.topbar{grid-template-columns:minmax(0,1fr) clamp(240px,22vw,480px) minmax(0,1fr);align-items:center;gap:12px;display:grid}
@media (width<=767px){.topbar{grid-template-columns:minmax(0,1fr) auto minmax(0,1fr)}}
.tb-left,.tb-right{align-items:center;min-width:0;display:flex;overflow:hidden;container-type:inline-size}
@container (width<=152px){.tb-left .tb-drop-crew-name{display:none}}
@container (width<=128px){.tb-left .tb-crew-active-chip{display:none}}
```

At 402 px the left cell gets roughly half of the width left after the header
padding, the two 12 px gaps and the centre cell: **≈180 px**. That is *above*
both container-query thresholds, so neither fallback fires — yet the content
the cell must hold is already ≈150 px before any remote chip: the mobile
*Open menu* button (`shrink-0`, 40 px) + the `Local` chip (≈75 px) + the
chevron (24 px) + gaps.

Markup (0.6.0 `static/dist/assets/App-GOBYv73C.js`; the same structure in
0.7.1's `App-e17PGpKz.js`, where the error chip is `line-clamp-1`; the `InstanceTabBar` component
`E8` with `T8`/`nCe`/`w8`/`QSe`, mounted by the header at
`<div class="tb-left relative h-full">`):

```html
<div class="instance-tab-bar-inline flex items-center h-full gap-1 min-w-0" role="group" aria-label="Remote instances">
  <div class="flex items-center gap-1 min-w-0">
    <div class="flex items-center gap-1 min-w-0">                   <!-- T8 -->
      <button class="tb-crew-active-chip … whitespace-nowrap … shrink-0">Local</button>
      <div data-testid="crew-chip-row" class="crew-chip-row relative flex flex-nowrap items-center gap-1 min-w-0 overflow-hidden">…pinned chips…</div>
      <button aria-label="Switch instance" class="… h-6 w-6 shrink-0">…</button>
    </div>
    <!-- only when the list query failed with a non-403: -->
    <div class="ml-2 min-w-0 truncate max-w-[320px]" data-testid="instance-tab-bar-list-error">⚠ not found  Ask the agent</div>
  </div>
</div>
```

- Every wrapper is `min-w-0`, so each may shrink below its content; the leaves
  (`Local`, the chevron) are `shrink-0` + `whitespace-nowrap`, so they cannot.
- **Overlap:** with the error chip present, the `T8` wrapper and the error chip
  are siblings that shrink in proportion to their base sizes. The `T8` wrapper
  ends up narrower than its two `shrink-0` leaves, which overflow it
  (overflow is visible there) and are painted over the error chip that starts
  at the wrapper's shrunken edge.
- **Clipping:** without the error chip the wrapper gets the whole bar, the two
  leaves take ≈100 px, and `crew-chip-row` — `min-w-0 overflow-hidden` — gets
  the ≈30 px left over. Its `ResizeObserver` (`tCe`) correctly reports the cut,
  but the fallback that would help (hiding names, then the active chip) is
  keyed on `.tb-left` being ≤152/128 px, and it is ≈180 px.

In short: the bar's degrade ladder assumes a cell narrower than a phone's
actually is, while the content it must show is wider than that cell.

## Suggested fix

Any one of these keeps the chips legible; the first is the one we carry
client-side as a stop-gap, and is the least invasive:

1. **Make the inline bar a horizontal strip on phones** — at `(width<=767px)`,
   `.tb-left > .instance-tab-bar-inline { overflow-x: auto }` and
   `flex-shrink: 0` on its wrapper child, so nothing is squeezed below its
   content and the row scrolls. Two declarations, nothing hidden, desktop
   untouched.
2. **Move the error chip out of the bar on phones** — put the list error in the
   *Switch instance* dropdown (or a toast) below the breakpoint. This removes
   the overlap case entirely; the clipping case still needs (1) or (3).
3. **Retune the ladder** — raise the `@container` rungs so they engage at the
   width phones actually produce (≈180 px), and give `crew-chip-row` a minimum
   width or its own row below the header on phones.

## Context

Found while building an iOS client for a self-hosted gateway over Tailscale,
where the dashboard is used in portrait most of the time. The rest of the
dashboard is fine at 402 px — the sessions panel, the composer, the chat all
work — which is what made this one row stand out. The client carries fix
(1) as an injected stylesheet gated to the gateway's origin until a release
includes a fix, and will drop it when one does.
