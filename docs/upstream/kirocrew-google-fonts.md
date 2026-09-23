# Upstream report draft — KiroCrew fetches two fonts from Google on every dashboard load

Prepared 2026-09-23 for [kirodotdev/KiroCrew](https://github.com/kirodotdev/KiroCrew),
to be filed with their **Bug report** form. Found while building F6
(`../features/F6-single-origin-web-view.md`).

**Duplicate check** (searched 2026-09-23, `gh search issues`): "google fonts",
"fonts.googleapis", "self-host", "privacy CDN", "external request",
"air-gapped", "offline install", "egress", "third-party CDN", "preconnect".
Nothing on this. The near misses, both different:
- **#6578** (open) — egress filtering below the *Design Critique capture
  browser*, about DNS rebinding on cross-origin subresources. Different code
  path; notably it argues for *preserving* legitimate CDN fonts in that context.
- **#8091** (closed) — "make the 13MB CJK canvas font a deployment-time choice",
  a useful precedent that fonts are treated as a deployment concern.
- **#9399** (open) — the WebKit blank dashboard, root-caused to an inline import
  map and es-module-shims blocked by CSP. Unrelated to fonts.

Fields to fill in before posting: **KiroCrew version** (no `dist-info` in the
venv on chonk — take `kirocrew --version`), **release channel**, **how it is
installed**, **platform**.

---

## Title

Dashboard shell fetches Space Grotesk and JetBrains Mono from
fonts.googleapis.com on every load

## What happened

`static/dist/index.html` links the webfont CSS from Google on every dashboard
load:

```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap">
```

So a **self-hosted** dashboard makes a third-party request to Google, from every
client, on every load. Three consequences:

1. **It discloses use of the deployment to a third party.** Each load tells
   Google (and anything on the client's network path) that this client is using
   a KiroCrew dashboard, with timing that maps the operator's working day. For a
   product people self-host partly for privacy, that is a surprising default.
2. **It does not work where the dashboard does.** A dashboard reached over
   Tailscale, a VPN-only network or an air-gapped install is reachable while
   `fonts.googleapis.com` is not, so the typography silently falls back — and
   the stylesheet is render-blocking, so first paint waits for the request to
   fail or time out. On a mobile client that is the slowest part of the load.
3. **It conflicts with locked-down clients.** A client that restricts the
   dashboard to its own origin (a kiosk, a CSP, or an app that blocks
   cross-origin subresources) loses the fonts, even though everything else works.

Expected: a self-hosted dashboard serves its own fonts, as it already does for
its other font assets.

## Steps to reproduce

1. Install KiroCrew and open the dashboard.
2. Watch the network panel, or on a host with no route to the public internet:
   `grep -o 'fonts\.googleapis\.com[^"]*' $(python -c "import kiro_crew, pathlib; print(pathlib.Path(kiro_crew.__file__).parent / 'static/dist/index.html')")`
3. The request to `fonts.googleapis.com/css2?family=Space+Grotesk…` is made on
   every load; with no public egress the fonts never arrive and the page paints
   in fallback faces.

## Why this is a small fix: the build already self-hosts fonts

In the same `static/dist`:

- `fonts/opendyslexic/` — `OpenDyslexic-{Regular,Bold,Italic,BoldItalic}.woff2`
  **with `OFL.txt` beside them**, i.e. already done correctly, licence included;
- `assets/Assistant-{Regular,Medium,Bold}-*.woff2` — Assistant is itself a
  Google Fonts family, already vendored into the bundle;
- `assets/KaTeX_*.woff2` / `.ttf` — the KaTeX faces.

So the pipeline already vendors webfonts. These two families are the outlier.

## Licensing is not an obstacle

Both are SIL Open Font License 1.1, and **neither declares a Reserved Font
Name**, so even a subset needs no rename:

| Family | Copyright line | Reserved Font Name |
|---|---|---|
| JetBrains Mono | `Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)` | none |
| Space Grotesk | `Copyright 2020 The Space Grotesk Project Authors (https://github.com/floriankarsten/space-grotesk)` | none |

OFL 1.1 permits bundling with software, commercial or not; the obligation is to
ship the licence text and copyright notice with the files — exactly what
`fonts/opendyslexic/OFL.txt` already does.

## Suggested fix

1. Vendor the two families as woff2 into `static/dist/assets` (subset to the
   weights the CSS asks for: Space Grotesk 400/500/600/700, JetBrains Mono
   400/500), with an `OFL.txt` alongside as for OpenDyslexic.
2. Declare them with `@font-face` in the bundle's CSS.
3. Remove the two `preconnect` hints and the Google stylesheet `<link>` from
   `index.html`.

That also removes a render-blocking third-party request from the critical path
for every deployment. If bundle size is a concern, #8091's precedent applies: a
deployment-time choice, defaulting to self-hosted.

## Context

Found while building an iOS client that restricts its web view to the gateway's
own origin over Tailscale. With that restriction the dashboard works fully and
only the fonts change, which is what prompted the look at where the request
goes.
