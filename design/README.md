# The Latchkey icon

Regenerate everything — the three catalog PNGs, their `Contents.json`, and the
contact sheet — from the repository root:

```sh
swift design/latchkey-icon.swift
```

To look at a change before it lands in the app's asset catalog, write the same
set somewhere else instead:

```sh
swift design/latchkey-icon.swift --out /tmp/latchkey
```

The icon is **drawn, not stored**: the generator is the source and the PNGs are
output. Edit the geometry in `latchkey-icon.swift` and rerun it; do not touch
the PNGs, they will be overwritten. CoreGraphics only — no AppKit and no SVG
rasteriser, so it runs from any shell with Xcode installed, which is the reason
it is Swift rather than a design file.

## The idea

A latchkey: the small flat key to your own front door. The name was chosen
because that is what the app is — you are not connecting to a service, you are
letting yourself into your own house from outside — and the icon says the same
thing. Brass on a painted door. Deliberately not a network, a cloud, a globe or
a pair of nodes with a line between them.

The icon it replaced was exactly that last thing: two nodes and the hop between
them, which described the *mechanism*. This one describes the *relationship*.

## Palette

| Role | Light | Dark |
|---|---|---|
| Door (background) | deep green | a darker green of the same hue |
| Key | brass | brass, unchanged |

Read the hex values in `latchkey-icon.swift`; they are named constants at the
top rather than repeated, so the file is the single source.

The dark appearance is **supplied, not derived**. Left to itself iOS dims the
light icon for dark mode, and dimmed brass goes muddy — which the previous icon
had already learned (M8.1). The tinted appearance is the key alone in grayscale
on transparency, which is the documented input: iOS composites it over its own
plate and tints it to the user's colour.

## What it has to survive

- **iOS masks the icon**, so nothing draws its own rounded corners and
  everything meaningful stays well inside a corner radius of about 22% of the
  side.
- **29×29 is the smallest size it is ever shown at** (Settings, Spotlight).
  Nothing is thinner than about 3 px there. Small sizes are not drawn by hand:
  Xcode derives every size from the 1024, so the contact sheet downsamples the
  1024 the same way — hand-drawing a 29 px variant would be checking an icon the
  phone never renders.
- The 1024 is **opaque with no alpha**; iOS rejects transparency in the app
  icon. Only the tinted variant carries alpha, which is correct for that slot.

## The contact sheet

`latchkey-icon-sheet.png` is regenerated alongside the icons: the three
appearances at a legible size, then true-pixel rows at 29, 40, 60, 76, 120 and
180 on both light and dark, plus the light icon on a dark background (a
light-appearance user with a dark wallpaper). Look at it after any change —
an icon nobody has looked at small is a guess.

## Known reservations

Recorded rather than glossed over, for whoever picks this up next:

- The key glyph is close to a **generic key** — nearer an SF Symbol than a
  specifically *latchkey* silhouette. It is legible and distinctive in colour,
  but the shape is not yet doing as much work as the name does.
- The bit (the teeth) reads a little like a letter **E** at large sizes, which
  invites being misread as a lettermark.

Both are shape problems, fixable in the generator without touching anything
else. The icon is committed as a working first version, not as a finished one.
