// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause
//
//  latchkey-icon.swift — the Latchkey app icon, drawn with CoreGraphics.
//
//  Regenerate everything (the three catalog PNGs, Contents.json and the
//  contact sheet) from anywhere in the checkout:
//
//      swift design/latchkey-icon.swift
//
//  Write the same set somewhere else instead, to look at a change before it
//  lands in the catalog:
//
//      swift design/latchkey-icon.swift --out /tmp/latchkey
//
//  See design/README.md for the idea, the palette and what was rejected.
//
//  The motif is a latchkey: the small flat key to your own front door, hung
//  upright the way a latchkey kid wore one on a string. Brass on a painted
//  door. It is a picture of ownership — you are letting yourself into your
//  own house from outside — not of a network, a cloud or a service.
//
//  Three appearances, as the iOS 18+ single-size catalog slot allows:
//    - light:  brass key on a deep green door, opaque;
//    - dark:   the same key on a darker green, opaque. Supplied rather than
//              derived because iOS otherwise dims the light icon, and a dimmed
//              brass goes muddy (the previous icon learned this, M8.1);
//    - tinted: the key alone, white on transparent. iOS composites it over its
//              own dark plate and tints it to the user's colour; a grayscale
//              foreground with no background is the documented input.
//
//  Full bleed, no rounded corners of our own: iOS masks the icon. Everything
//  that means something stays well inside the mask's corner radius, which is
//  about 22 % of the side, and nothing is thinner than 3 px at 29x29.
//
//  Small sizes are NOT drawn separately. Xcode derives every size from the
//  1024, so the contact sheet downsamples the 1024 the same way — drawing a
//  29 px icon by hand would check an icon the phone never shows.
//
//  CoreGraphics only, no AppKit, so it runs from any shell with Xcode's
//  toolchain and nothing else. macOS ships no reliable SVG rasteriser; a
//  script that assumed one would fail on a clean machine.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Arguments and paths

let scriptURL = URL(fileURLWithPath: #filePath)
let designDir = scriptURL.deletingLastPathComponent()
let repoRoot = designDir.deletingLastPathComponent()
let catalogDir = repoRoot.appendingPathComponent("app/App/Assets.xcassets/AppIcon.appiconset")

var outDir = catalogDir
var sheetDir = designDir
var args = Array(CommandLine.arguments.dropFirst())
while let flag = args.first {
    args.removeFirst()
    switch flag {
    case "--out":
        guard let path = args.first else { fatalError("--out needs a directory") }
        args.removeFirst()
        outDir = URL(fileURLWithPath: path)
        sheetDir = outDir
    default:
        fatalError("unknown argument \(flag); usage: latchkey-icon.swift [--out DIR]")
    }
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Palette

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// A colour from a hex triplet, so the README's table and this file cannot
/// disagree about what a value is.
func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((value >> 16) & 0xFF) / 255,
        CGFloat((value >> 8) & 0xFF) / 255,
        CGFloat(value & 0xFF) / 255,
        alpha,
    ])!
}

// The door. A deep, slightly blue green: the colour a front door is painted,
// not a "green" from a UI palette. It is neither the previous icon's navy nor
// anything of Tailscale's or Kiro's. Two stops, barely apart, so the plate
// reads as a painted surface rather than a flat swatch; anything stronger
// starts to look like a 2010 gradient.
let doorTop = hex(0x25584A)       // light plate, top
let doorBottom = hex(0x1B4536)    // light plate, bottom
let doorDarkTop = hex(0x143128)   // dark plate, top
let doorDarkBottom = hex(0x0E2219) // dark plate, bottom

// The key. A muted brass — warm, but not a saturated yellow, which would read
// as a warning sign next to it. One flat colour: shading would be noise at
// 29 px, and the shadow does the lifting.
let brass = hex(0xE3BC5E)
let brassDark = hex(0xE8C266)     // a touch brighter on the darker plate
let tintedForeground = hex(0xFFFFFF)

// The shadow under the key: a soft one, straight down, so the key sits on the
// door instead of floating in front of it. At small sizes it collapses into
// a faint darkening below the silhouette, which is fine.
let shadowColour = hex(0x000000, alpha: 0.32)

// MARK: - Geometry

// All geometry is in a 1024-unit square with y DOWN, like a design tool;
// `flipped(_:)` puts the context into that frame. Numbers are chosen so the
// silhouette is bold at 1024 and still a key at 29: nothing that matters is
// under ~3 px there (3 / 0.0283 ≈ 106 units).

let side: CGFloat = 1024

// The bow: a thick ring with a small hole. Thick ring and small hole is what
// keeps it from reading as a magnifying glass, whose lens is a thin rim
// around a big empty centre. The hole is the string hole — the latchkey on a
// string — and it is the one detail allowed to vanish at 29 px.
let bowCentre = CGPoint(x: 479, y: 340)
let bowRadius: CGFloat = 168
let holeRadius: CGFloat = 68

// The shank: a straight bar from the bow down to the tip. 108 wide is ~3 px
// at 29x29, the floor for a stroke that must survive.
let shankWidth: CGFloat = 108
let shankBottom: CGFloat = 850

// The bit: two teeth on the RIGHT of the shank, the lower one longer, with a
// notch between them. The teeth are what say "key" rather than "lollipop":
// keep them big. Each tooth is ~2.7 px tall at 29x29 and the notch ~1.8 px,
// so at that size they blur into one stepped lump — still a key.
let toothHeight: CGFloat = 96
let notchHeight: CGFloat = 64
let upperToothReach: CGFloat = 130   // beyond the shank's right edge
let lowerToothReach: CGFloat = 180
let keyCornerRadius: CGFloat = 14    // stamped metal, not a CAD drawing

// The iOS mask, approximated. iOS 26 uses a continuous-curvature superellipse;
// a plain rounded rect at the same nominal radius is slightly tighter in the
// corners, so if a shape survives this mask it survives the real one.
let maskCornerRatio: CGFloat = 0.2237

// MARK: - Drawing helpers

func flipped(_ ctx: CGContext, _ size: CGFloat) {
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
}

/// The key as one path, in 1024 units, y down, without the hole. The hole is
/// punched afterwards with a clear blend so it is transparent in the tinted
/// variant and shows the plate in the others, with one code path for both.
func keyPath(scale: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let shankLeft = bowCentre.x - shankWidth / 2
    let shankRight = bowCentre.x + shankWidth / 2

    path.addEllipse(in: circle(bowCentre, bowRadius))

    // Shank, from the bow centre (hidden inside the bow) to the tip.
    path.addRoundedRect(in: CGRect(x: shankLeft, y: bowCentre.y,
                                   width: shankWidth, height: shankBottom - bowCentre.y),
                        cornerWidth: keyCornerRadius, cornerHeight: keyCornerRadius)

    // Teeth. The lower tooth ends flush with the shank's tip.
    let lowerTop = shankBottom - toothHeight
    let upperTop = lowerTop - notchHeight - toothHeight
    // Each tooth starts inside the shank so the join is solid, not a seam.
    let overlap: CGFloat = 40
    path.addRoundedRect(in: CGRect(x: shankRight - overlap, y: upperTop,
                                   width: overlap + upperToothReach, height: toothHeight),
                        cornerWidth: keyCornerRadius, cornerHeight: keyCornerRadius)
    path.addRoundedRect(in: CGRect(x: shankRight - overlap, y: lowerTop,
                                   width: overlap + lowerToothReach, height: toothHeight),
                        cornerWidth: keyCornerRadius, cornerHeight: keyCornerRadius)

    var transform = CGAffineTransform(scaleX: scale, y: scale)
    return path.copy(using: &transform) ?? path
}

func makeContext(_ pixels: Int, opaque: Bool) -> CGContext {
    let info = opaque
        ? CGImageAlphaInfo.noneSkipLast.rawValue
        : CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                              bytesPerRow: 0, space: sRGB, bitmapInfo: info) else {
        fatalError("could not create a \(pixels) px bitmap context")
    }
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// The key on a transparent layer: silhouette in `colour`, hole punched out.
func keyLayer(pixels: Int, colour: CGColor) -> CGImage {
    let scale = CGFloat(pixels) / side
    let ctx = makeContext(pixels, opaque: false)
    flipped(ctx, CGFloat(pixels))
    ctx.setFillColor(colour)
    ctx.addPath(keyPath(scale: scale))
    ctx.fillPath()
    ctx.setBlendMode(.clear)
    ctx.fillEllipse(in: circle(CGPoint(x: bowCentre.x * scale, y: bowCentre.y * scale),
                               holeRadius * scale))
    ctx.setBlendMode(.normal)
    return ctx.makeImage()!
}

/// A door: the plate with its quiet vertical gradient, opaque.
func plate(pixels: Int, top: CGColor, bottom: CGColor) -> CGContext {
    let ctx = makeContext(pixels, opaque: true)
    let gradient = CGGradient(colorsSpace: sRGB, colors: [top, bottom] as CFArray, locations: [0, 1])!
    // CoreGraphics' origin is bottom-left; "top" is y = pixels.
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(pixels)),
                           end: CGPoint(x: 0, y: 0), options: [])
    return ctx
}

/// The full opaque icon: plate, shadow, key.
func opaqueIcon(pixels: Int, top: CGColor, bottom: CGColor, key: CGColor) -> CGImage {
    let scale = CGFloat(pixels) / side
    let ctx = plate(pixels: pixels, top: top, bottom: bottom)
    let layer = keyLayer(pixels: pixels, colour: key)
    let full = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    // Shadow: offset is in CG coordinates (y up), so "down" is negative.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 36 * scale, color: shadowColour)
    ctx.draw(layer, in: full)
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
    print("wrote \(url.path) (\(image.width)x\(image.height)\(image.alphaInfo == .noneSkipLast ? ", opaque" : ", alpha"))")
}

// MARK: - The three variants

let light = opaqueIcon(pixels: Int(side), top: doorTop, bottom: doorBottom, key: brass)
let dark = opaqueIcon(pixels: Int(side), top: doorDarkTop, bottom: doorDarkBottom, key: brassDark)
let tinted = keyLayer(pixels: Int(side), colour: tintedForeground)

writePNG(light, to: outDir.appendingPathComponent("LatchkeyIcon.png"))
writePNG(dark, to: outDir.appendingPathComponent("LatchkeyIcon-dark.png"))
writePNG(tinted, to: outDir.appendingPathComponent("LatchkeyIcon-tinted.png"))

// Contents.json is written too, so a filename change here cannot leave the
// catalog pointing at a PNG that no longer exists. The set is still called
// AppIcon.appiconset: the project references it by that name and the
// project file is not this script's to edit.
let contents = """
{
  "images" : [
    {
      "filename" : "LatchkeyIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "LatchkeyIcon-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "LatchkeyIcon-tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
let contentsURL = outDir.appendingPathComponent("Contents.json")
try! contents.write(to: contentsURL, atomically: true, encoding: .utf8)
print("wrote \(contentsURL.path)")

// MARK: - The contact sheet: what the phone will actually show

/// Downsample the way an asset pipeline does: halve until within 2x of the
/// target, then one final resample. A single 1024 -> 29 step aliases the
/// teeth; this does not, and it is the fairer test.
func downsample(_ image: CGImage, to pixels: Int) -> CGImage {
    var current = image
    while current.width > pixels * 2 {
        let half = current.width / 2
        let ctx = makeContext(half, opaque: false)
        ctx.draw(current, in: CGRect(x: 0, y: 0, width: half, height: half))
        current = ctx.makeImage()!
    }
    let ctx = makeContext(pixels, opaque: false)
    ctx.draw(current, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return ctx.makeImage()!
}

/// Apply the iOS mask at a given size.
func masked(_ image: CGImage, pixels: Int) -> CGImage {
    let ctx = makeContext(pixels, opaque: false)
    let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    let radius = CGFloat(pixels) * maskCornerRatio
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(image, in: rect)
    return ctx.makeImage()!
}

/// What iOS does with the tinted variant, approximately: composite the
/// grayscale foreground, multiplied by a tint, over a dark plate. The tint is
/// whatever the user picked; a soft blue is a common one.
func tintedPreview(pixels: Int) -> CGImage {
    let ctx = plate(pixels: pixels, top: hex(0x3A3A3C), bottom: hex(0x1C1C1E))
    let fg = keyLayer(pixels: pixels, colour: hex(0xA8C7FA))
    ctx.draw(fg, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return ctx.makeImage()!
}

func nearestNeighbour(_ image: CGImage, factor: Int) -> CGImage {
    let n = image.width * factor
    let ctx = makeContext(n, opaque: false)
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
    return ctx.makeImage()!
}

func sheet() -> CGImage {
    let W = 1500, H = 1180
    let ctx = makeContext(W, opaque: true)
    flipped(ctx, CGFloat(H))
    // The context is W x H; flipping used H so y runs down from the top.
    ctx.translateBy(x: 0, y: 0)

    // Two backgrounds: the light half is a plausible light home screen, the
    // dark half a plausible dark one.
    ctx.setFillColor(hex(0xEDEDF0))
    ctx.fill(CGRect(x: 0, y: 0, width: W / 2, height: H))
    ctx.setFillColor(hex(0x0B0B0D))
    ctx.fill(CGRect(x: W / 2, y: 0, width: W / 2, height: H))

    func place(_ image: CGImage, x: CGFloat, y: CGFloat, size: CGFloat) {
        ctx.saveGState()
        // Undo the flip for the draw so the image is not upside down.
        ctx.translateBy(x: x, y: y + size)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        ctx.restoreGState()
    }

    // Row 1: the three variants at 320, masked.
    let big = 320
    place(masked(light, pixels: big), x: 60, y: 50, size: CGFloat(big))
    place(masked(tintedPreview(pixels: Int(side)), pixels: big), x: 400, y: 50, size: CGFloat(big))
    place(masked(dark, pixels: big), x: CGFloat(W) / 2 + 60, y: 50, size: CGFloat(big))
    place(masked(light, pixels: big), x: CGFloat(W) / 2 + 400, y: 50, size: CGFloat(big))

    // Row 2: true pixel sizes, light on light and dark on dark, plus the light
    // icon on dark (a light-appearance user with a dark wallpaper).
    let sizes = [29, 40, 60, 76, 120, 180]
    func row(_ image: CGImage, x0: CGFloat, y: CGFloat) {
        var x = x0
        for s in sizes {
            place(masked(downsample(image, to: s), pixels: s), x: x, y: y, size: CGFloat(s))
            x += CGFloat(s) + 28
        }
    }
    row(light, x0: 60, y: 430)
    row(dark, x0: CGFloat(W / 2 + 60), y: 430)
    row(tintedPreview(pixels: Int(side)), x0: CGFloat(W / 2 + 60), y: 630)
    row(light, x0: CGFloat(W / 2 + 60), y: 830)

    // Row 3: the 29 and 40 renders at 6x nearest-neighbour, so every pixel is
    // visible. This is the honesty check for "still reads at 29".
    func zoom(_ image: CGImage, x0: CGFloat, y: CGFloat) {
        var x = x0
        for s in [29, 40] {
            let small = masked(downsample(image, to: s), pixels: s)
            let z = nearestNeighbour(small, factor: 6)
            place(z, x: x, y: y, size: CGFloat(z.width))
            x += CGFloat(z.width) + 40
        }
    }
    zoom(light, x0: 60, y: 660)
    zoom(dark, x0: CGFloat(W / 2 + 60), y: 660 + 380)

    return ctx.makeImage()!
}

writePNG(sheet(), to: sheetDir.appendingPathComponent("latchkey-icon-sheet.png"))
