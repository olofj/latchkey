# Upstream report — the dashboard shell paints its dark default before the chosen theme: a quarter-second dark flash on every cold load in light mode

**Not filed.** Prepared 2026-09-26 for [kirodotdev/KiroCrew](https://github.com/kirodotdev/KiroCrew),
to be filed with their **Bug report** form once Olof authorises it, as he did
for the fonts report (KiroCrew#13161). Found while working on F21
(`../features/F21-calm-cold-launch.md`, issue #4 of this repository). Read
from the shipped **0.7.1** bundle (the pin in `testing/harness/fake_gateway.py`)
and measured in WebKit on iOS; the mechanism is in the shell and the CSS, so
it is not platform-specific.

**Duplicate check** (searched 2026-09-26, `gh search issues`: `theme flash`,
`dark flash`, `flash of dark`, `flash`, `FOUC`, `light mode flash`, `dark
mode`, `first paint`, `prefers-color-scheme`, `data-theme`, `theme
bootstrap`, `wrong theme on load`, `flicker theme`). Nothing on this. The
near misses, all different:
- **#13097** (closed) — an installed *custom* theme never loading after a
  gateway restart; about the catalog fetch, not the first paint.
- **#8600** (open) — theme decoration painted at the document root outranking
  the top bar; about z-order of a loaded theme.
- **#2110** (closed) — an MCP app frame always rendered in dark mode; a
  sandboxed frame's own scheme, not the shell's first paint.

Fields to fill in before posting: **KiroCrew version** (the bundle here is the
0.7.1 pin; confirm with `kirocrew --version` on the gateway), **release
channel**, **how it is installed**, **platform** (observed in WebKit on iOS;
the mechanism is not platform-specific).

---

## Title

Dashboard shell is hard-coded `data-theme="dark"`, so a light-theme user gets a
~250 ms dark flash on every cold load

## What happened

On a phone in light appearance, with the dashboard's theme left at its default
("system"), every cold load of the dashboard goes: white page → **a solid dark
shell for about a quarter of a second** → a 250 ms fade to the light theme →
the light dashboard. Recorded at 60 fps on an iPhone: 250 ms at a mean
brightness of 22–25 (of 255) between two white states, then the fade. A
simulator against the same bundle shows the same sequence.

The cause is all in the shipped shell:

1. `static/dist/index.html` starts `<html lang="en" data-theme="dark">` and
   declares `<meta name="theme-color" content="#0d0f12">`. The dark theme is
   the static default, whatever the user chose or the OS prefers.
2. `assets/src-*.css` is attribute-driven only: `[data-theme=dark]{--bg:#12141a;
   … color-scheme:dark}`, `[data-theme=kiro-light]{--bg:#fff; …}`, and no
   `prefers-color-scheme` rule anywhere. So the first paint is the fully
   styled dark shell, not an unstyled one.
3. The choice is made in JavaScript, after boot: `ThemeProvider`
   (`assets/useTheme-*.js`) initialises from `localStorage['mc-theme'] ||
   'system'`, resolves `system` with `matchMedia('(prefers-color-scheme:
   dark)')`, and writes `data-theme`, `data-mode` and `data-mode-pref` onto
   `<html>` from a **`useEffect`** — a passive effect, which runs after the
   first React commit has been painted. And the entry module is a graph of
   some seventy `modulepreload` chunks that evaluates only once every edge has
   loaded (the shell's own comment says so), so the dark default is on screen
   for the whole module load plus the first render.
4. `body { background: var(--bg); transition: background-color .25s, color
   .25s }` turns the correction into a visible fade rather than a cut.

The shell already knows how to avoid exactly this. The two inline scripts at
the end of `<head>` set `data-ui` and `<html lang>` from `localStorage` before
hydration "to prevent flash", and the first of them says it "mirrors the
pattern used by data-theme bootstrapping" — but no such bootstrap ships: the
theme is the one pre-hydration hint the shell is missing.

## Steps to reproduce

1. Put the OS in light appearance and leave the dashboard's theme at
   "system" (or set it to any light theme).
2. Open the dashboard cold, on a client without a warm bfcache: a phone
   browser, an installed PWA, or a desktop tab after a hard reload. Record
   the screen, or watch `getComputedStyle(document.body).backgroundColor`
   from a document-start script: it reads `rgb(18, 20, 26)` first and
   `rgb(255, 255, 255)` after boot.
3. `grep -o '<html[^>]*>' static/dist/index.html` shows the static
   `data-theme="dark"`; `grep -c prefers-color-scheme static/dist/assets/src-*.css`
   shows `0`.

## Suggested fix

1. **A pre-hydration theme bootstrap in `index.html`**, in `<head>` before
   the stylesheets, like the existing `data-ui` and `lang` ones: read
   `mc-theme` (default `system`, resolved with `matchMedia`) and
   `mc-color-theme` (default `kiro`), and set `data-theme`, `data-mode` and
   `data-mode-pref` exactly as `ThemeProvider` would. The first paint is
   then already the chosen theme, `ThemeProvider`'s effect is a no-op, and
   the `.25s` transition never runs at load.
2. Failing that, **let the static default follow the OS**: drop the
   hard-coded `data-theme="dark"` and give the unresolved shell
   (`html:not([data-mode])`) a `prefers-color-scheme` default; and give the
   `theme-color` meta a light variant with a `media` attribute.
3. Either way, consider `transition: none` until `data-mode` is set, so a
   correction that does happen is a cut rather than a fade that draws
   attention to itself.

## Context

Found while building an iOS client that embeds the dashboard in a web view.
The client's workaround is a stylesheet added at document start that, while
the shell is *unresolved* (`html[data-theme="dark"]:not([data-mode])`),
gives the root `color-scheme: light dark`, the body a transparent background
and `#root` `visibility: hidden`, so the view's own appearance-matched
backing shows until the app writes its choice; it hands the paint back by
itself if no choice comes. It removes the flash without
guessing the theme, but it rests on three facts of the 0.7.1 shell (the
static `dark` default, `data-mode` as the "resolved" marker, and the body
taking `--bg`), which is why the durable fix belongs here.
