// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause
//
//  render-app-icon.swift — the Latchkey app icon, drawn with CoreGraphics.
//
//  Rerun from app/ after changing anything below:
//
//      xcrun swift scripts/render-app-icon.swift
//
//  It overwrites App/Assets.xcassets/AppIcon.appiconset/AppIcon.png, the one
//  1024x1024 image the modern single-size iOS icon slot needs; Xcode derives
//  every other size. Pass a path to write somewhere else (for a preview).
//  To check legibility at the smallest size the icon is shown at:
//
//      sips -z 58 58 AppIcon.png --out /tmp/AppIcon-58.png
//
//  The motif: this phone (a solid disc, bottom left) reaching a remote
//  gateway (a ring, top right) over a dotted path. Two nodes and the hop
//  between them is the whole app. Deep navy, white marks, one amber accent
//  on the destination. Nothing in it is Tailscale's dot grid or Kiro's
//  ghost. Full-bleed and opaque, no rounded corners or alpha: iOS masks the
//  icon itself and rejects transparency.
//
//  CoreGraphics only, no AppKit, so it runs from any shell. The geometry is
//  in CoreGraphics coordinates (origin bottom left, y up).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

// ----- palette ---------------------------------------------------------------
func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, 1])!
}
let navyTop = rgb(0.12, 0.23, 0.38)     // #1F3B61
let navyBottom = rgb(0.05, 0.12, 0.22)  // #0D1F38
let white = rgb(1, 1, 1)
let amber = rgb(0.96, 0.73, 0.29)       // #F5BA4A: the lit destination

// ----- geometry --------------------------------------------------------------
// The two nodes sit on the rising diagonal. The ring is larger than the disc
// so the two weigh the same; the dots are spaced so they stay separate down
// to 58 px (2-3 px gaps), where finer detail would fuse into a bar.
let local = CGPoint(x: 296, y: 296)     // this phone: solid
let localRadius: CGFloat = 112
let remote = CGPoint(x: 728, y: 728)    // the gateway: a ring
let remoteOuterRadius: CGFloat = 152
let ringWidth: CGFloat = 64
let dotRadius: CGFloat = 30
let dotDistances: [CGFloat] = [186, 285.5, 385]  // from the local centre

// ----- render ----------------------------------------------------------------
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("could not create the bitmap context")
}
ctx.setShouldAntialias(true)
ctx.setAllowsAntialiasing(true)

// Background: a quiet vertical gradient, lighter at the top.
let gradient = CGGradient(colorsSpace: space, colors: [navyTop, navyBottom] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(side)),
                       end: CGPoint(x: 0, y: 0), options: [])

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
}

// The path: dots along the line from the local node to the remote one.
let dx = remote.x - local.x, dy = remote.y - local.y
let length = (dx * dx + dy * dy).squareRoot()
let unit = CGPoint(x: dx / length, y: dy / length)
ctx.setFillColor(white)
for d in dotDistances {
    ctx.fillEllipse(in: circle(CGPoint(x: local.x + unit.x * d, y: local.y + unit.y * d), dotRadius))
}

// This phone.
ctx.fillEllipse(in: circle(local, localRadius))

// The gateway: a ring, stroked on its centre line.
ctx.setStrokeColor(amber)
ctx.setLineWidth(ringWidth)
ctx.strokeEllipse(in: circle(remote, remoteOuterRadius - ringWidth / 2))

// ----- write -----------------------------------------------------------------
guard let image = ctx.makeImage() else { fatalError("could not make the image") }
let url = URL(fileURLWithPath: output)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("could not open \(output) for writing")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(output)") }
print("wrote \(output) (\(side)x\(side), opaque)")
