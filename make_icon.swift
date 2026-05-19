#!/usr/bin/env swift
import CoreGraphics
import ImageIO
import Foundation

func makeIcon(size: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                       bytesPerRow: size * 4, space: cs,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size)
    let cx = s / 2

    // ── Background gradient ──────────────────────────────────────────
    let g = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(srgbRed: 0.29, green: 0.11, blue: 0.78, alpha: 1),   // deep violet
            CGColor(srgbRed: 0.56, green: 0.18, blue: 0.82, alpha: 1),   // purple
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Subtle inner glow at top
    let glow = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(glow,
        startCenter: CGPoint(x: cx, y: s * 0.75), startRadius: 0,
        endCenter:   CGPoint(x: cx, y: s * 0.75), endRadius: s * 0.55,
        options: [])

    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    // ── Microphone body (capsule) ────────────────────────────────────
    let mW: CGFloat = s * 0.175
    let mH: CGFloat = s * 0.28
    let mCX = cx
    let mCY = s * 0.57               // body centre (y-up)
    let mR  = mW / 2

    let bodyPath = CGPath(roundedRect:
        CGRect(x: mCX - mW/2, y: mCY - mH/2, width: mW, height: mH),
        cornerWidth: mR, cornerHeight: mR, transform: nil)
    ctx.setFillColor(white)
    ctx.addPath(bodyPath)
    ctx.fillPath()

    // Grille lines across body
    ctx.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.15, blue: 0.75, alpha: 0.25))
    ctx.setLineWidth(s * 0.0065)
    for f: CGFloat in [-0.17, 0, 0.17] {
        let y = mCY + mH * f
        let inset = sqrt(max(0, mR * mR - (y - mCY - mH/2 + mR) * (y - mCY - mH/2 + mR)))
        let lx = mCX - mW * 0.38
        let rx = mCX + mW * 0.38
        ctx.move(to: CGPoint(x: lx, y: y))
        ctx.addLine(to: CGPoint(x: rx, y: y))
        ctx.strokePath()
    }

    // ── Stand: U-shaped arc + vertical stem + base ───────────────────
    ctx.setStrokeColor(white)
    ctx.setLineWidth(s * 0.022)
    ctx.setLineCap(.round)

    let arcCY = mCY - mH / 2          // arc centre = bottom of body
    let arcR:  CGFloat = s * 0.14

    // U-arc: from left (π) clockwise through bottom to right (0)
    ctx.addArc(center: CGPoint(x: mCX, y: arcCY),
               radius: arcR,
               startAngle: .pi, endAngle: 0,
               clockwise: true)
    ctx.strokePath()

    // Vertical stem
    let stemTop    = arcCY - arcR
    let stemBottom = stemTop - s * 0.035
    ctx.move(to: CGPoint(x: mCX, y: stemTop))
    ctx.addLine(to: CGPoint(x: mCX, y: stemBottom))
    ctx.strokePath()

    // Horizontal base
    let baseHalfW: CGFloat = s * 0.105
    ctx.move(to: CGPoint(x: mCX - baseHalfW, y: stemBottom))
    ctx.addLine(to: CGPoint(x: mCX + baseHalfW, y: stemBottom))
    ctx.strokePath()

    // ── Lips / Mouth ─────────────────────────────────────────────────
    let lipsY:  CGFloat = stemBottom - s * 0.095   // lips centre
    let lW:     CGFloat = s * 0.285
    let lH:     CGFloat = s * 0.095

    let lL = CGPoint(x: cx - lW/2, y: lipsY)       // left corner
    let lR = CGPoint(x: cx + lW/2, y: lipsY)       // right corner
    let lMid = CGPoint(x: cx, y: lipsY + lH * 0.22)  // centre of cupid's bow dip
    let lPkL = CGPoint(x: cx - lW * 0.22, y: lipsY + lH * 0.62)  // left peak
    let lPkR = CGPoint(x: cx + lW * 0.22, y: lipsY + lH * 0.62)  // right peak
    let lBot = CGPoint(x: cx, y: lipsY - lH * 0.55) // lower lip bottom

    // Full lips path
    let lips = CGMutablePath()
    // Upper lip (cupid's bow)
    lips.move(to: lL)
    lips.addCurve(to: lPkL,
        control1: CGPoint(x: cx - lW * 0.44, y: lipsY + lH * 0.25),
        control2: CGPoint(x: cx - lW * 0.33, y: lipsY + lH * 0.62))
    lips.addCurve(to: lMid,
        control1: CGPoint(x: cx - lW * 0.10, y: lipsY + lH * 0.60),
        control2: CGPoint(x: cx - lW * 0.04, y: lipsY + lH * 0.22))
    lips.addCurve(to: lPkR,
        control1: CGPoint(x: cx + lW * 0.04, y: lipsY + lH * 0.22),
        control2: CGPoint(x: cx + lW * 0.10, y: lipsY + lH * 0.60))
    lips.addCurve(to: lR,
        control1: CGPoint(x: cx + lW * 0.33, y: lipsY + lH * 0.62),
        control2: CGPoint(x: cx + lW * 0.44, y: lipsY + lH * 0.25))
    // Lower lip
    lips.addCurve(to: lBot,
        control1: CGPoint(x: cx + lW * 0.44, y: lipsY - lH * 0.08),
        control2: CGPoint(x: cx + lW * 0.16, y: lipsY - lH * 0.58))
    lips.addCurve(to: lL,
        control1: CGPoint(x: cx - lW * 0.16, y: lipsY - lH * 0.58),
        control2: CGPoint(x: cx - lW * 0.44, y: lipsY - lH * 0.08))
    lips.closeSubpath()

    // Fill lips with coral-pink
    ctx.addPath(lips)
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.42, blue: 0.52, alpha: 1))
    ctx.fillPath()

    // Lip centre line (parting)
    let partition = CGMutablePath()
    partition.move(to: lL)
    partition.addCurve(to: lR,
        control1: CGPoint(x: cx - lW * 0.12, y: lipsY + lH * 0.12),
        control2: CGPoint(x: cx + lW * 0.12, y: lipsY + lH * 0.12))
    ctx.addPath(partition)
    ctx.setStrokeColor(CGColor(srgbRed: 0.80, green: 0.22, blue: 0.38, alpha: 1))
    ctx.setLineWidth(s * 0.011)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // Highlight on upper lip
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
    ctx.fillEllipse(in: CGRect(x: cx - lW * 0.10, y: lipsY + lH * 0.12,
                                width: lW * 0.20, height: lH * 0.25))

    return ctx.makeImage()!
}

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png"
let icon = makeIcon(size: 1024)
let url  = URL(fileURLWithPath: outPath)
let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, icon, nil)
CGImageDestinationFinalize(dest)
print("Saved: \(url.path)")
