// menubar-icon.swift — draws the menu bar icon (a mihrab: two nested pointed arches) into
// GoPray/Assets.xcassets/MenuBarIcon.imageset at 18 pt @1x and @2x. Owner: PM.
//   swift scripts/menubar-icon.swift
// Pixel-tuned: at @1x the strokes are 1 px on half-pixel centres, at @2x 1.5 pt (3 px),
// so every vertical edge lands on a whole pixel. Black on clear; the asset is a template.

import AppKit
import CoreGraphics

/// Two-centred pointed arch: sides from `base` to `spring`, then two arcs meeting at the apex.
/// `k` = how far each arc centre sits past the axis, as a share of the half width.
func archPath(cx: CGFloat, halfW w: CGFloat, base y0: CGFloat, spring ys: CGFloat, k: CGFloat, closeBase: Bool = true) -> CGMutablePath {
    let r = w * (1 + k)
    let apexH = sqrt(r * r - (w * k) * (w * k))
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - w, y: y0))
    p.addLine(to: CGPoint(x: cx - w, y: ys))
    p.addArc(center: CGPoint(x: cx + w * k, y: ys), radius: r, startAngle: .pi, endAngle: atan2(apexH, -w * k), clockwise: true)
    p.addArc(center: CGPoint(x: cx - w * k, y: ys), radius: r, startAngle: atan2(apexH, w * k), endAngle: 0, clockwise: true)
    p.addLine(to: CGPoint(x: cx + w, y: y0))
    if closeBase { p.closeSubpath() }
    return p
}

func render(scale: CGFloat) -> CGImage {
    let px = Int(18 * scale)
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: scale, y: scale)
    c.setStrokeColor(.black)
    let lw: CGFloat = scale >= 2 ? 1.5 : 1
    let off = lw / 2
    c.setLineWidth(lw); c.setLineJoin(.miter); c.setMiterLimit(10)
    c.addPath(archPath(cx: 9, halfW: 6 - off, base: 1 + off, spring: 7, k: 0.8)); c.strokePath()          // the niche frame
    c.addPath(archPath(cx: 9, halfW: 3 - off, base: 1 + off, spring: 4.5, k: 0.8, closeBase: false)); c.strokePath()   // the inner niche
    return c.makeImage()!
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = here.appendingPathComponent("GoPray/Assets.xcassets/MenuBarIcon.imageset")
for (scale, name) in [(1.0, "MenuBarIcon.png"), (2.0, "MenuBarIcon@2x.png")] {
    let rep = NSBitmapImageRep(cgImage: render(scale: scale))
    try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    print("wrote \(name)")
}
