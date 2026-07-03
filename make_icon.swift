#!/usr/bin/env swift
// Lexora app icon — glowing spectral waveform on deep space-violet.
// Regenerate: swift make_icon.swift "Lexora/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
import CoreGraphics
import ImageIO
import Foundation

func makeIcon(size: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    // noneSkipLast → fully opaque PNG (App Store icons must have no alpha).
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let s = CGFloat(size)
    let cx = s / 2
    let cy = s / 2

    // ── Background: deep indigo → rich violet, diagonal ──────────────────
    let bg = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.055, green: 0.012, blue: 0.16, alpha: 1),   // near-black indigo
        CGColor(srgbRed: 0.16,  green: 0.05,  blue: 0.38, alpha: 1),   // deep violet
        CGColor(srgbRed: 0.30,  green: 0.10,  blue: 0.58, alpha: 1),   // royal purple
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg,
        start: CGPoint(x: 0, y: 0),
        end:   CGPoint(x: s, y: s), options: [])

    // Aurora glow behind the glyph (violet core fading out)
    let aura = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.55, green: 0.30, blue: 1.0, alpha: 0.55),
        CGColor(srgbRed: 0.40, green: 0.15, blue: 0.85, alpha: 0.18),
        CGColor(srgbRed: 0.30, green: 0.10, blue: 0.60, alpha: 0.0),
    ] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(aura,
        startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
        endCenter:   CGPoint(x: cx, y: cy), endRadius: s * 0.62, options: [])

    // Gentle vignette so corners recede
    let vig = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.0),
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28),
    ] as CFArray, locations: [0.62, 1])!
    ctx.drawRadialGradient(vig,
        startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
        endCenter:   CGPoint(x: cx, y: cy), endRadius: s * 0.78,
        options: .drawsAfterEndLocation)

    // Sparse starfield — tiny, deterministic
    var seed: UInt64 = 0x1EC0DA
    func rand() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
    for _ in 0..<26 {
        let x = rand() * s, y = rand() * s
        let dx = abs(x - cx) / s, dy = abs(y - cy) / s
        guard dx > 0.26 || dy > 0.30 else { continue }     // keep clear of the glyph
        let r = s * (0.0012 + rand() * 0.0028)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1,
                                 alpha: 0.10 + rand() * 0.22))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // ── Waveform glyph: 7 rounded bars, voice-envelope heights ───────────
    let heights: [CGFloat] = [0.13, 0.25, 0.38, 0.52, 0.38, 0.25, 0.13]
    let barW = s * 0.062
    let gap  = s * 0.036
    let totalW = barW * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
    var x0 = cx - totalW / 2

    let bars = CGMutablePath()
    for h in heights {
        let bh = s * h
        bars.addRoundedRect(in: CGRect(x: x0, y: cy - bh / 2, width: barW, height: bh),
                            cornerWidth: barW / 2, cornerHeight: barW / 2)
        x0 += barW + gap
    }

    // Glow pass: bars drawn with a heavy violet-pink shadow (twice for strength)
    for blur in [s * 0.085, s * 0.035] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur,
                      color: CGColor(srgbRed: 0.75, green: 0.45, blue: 1.0, alpha: 0.85))
        ctx.addPath(bars)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Spectral fill: aqua → ice white → pink swept across the bars
    ctx.saveGState()
    ctx.addPath(bars)
    ctx.clip()
    let spectral = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.42, green: 0.88, blue: 1.0,  alpha: 1),   // aqua
        CGColor(srgbRed: 0.88, green: 0.92, blue: 1.0,  alpha: 1),   // ice white
        CGColor(srgbRed: 1.0,  green: 0.55, blue: 0.85, alpha: 1),   // pink
    ] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(spectral,
        start: CGPoint(x: cx - totalW / 2, y: cy - s * 0.10),
        end:   CGPoint(x: cx + totalW / 2, y: cy + s * 0.10), options: [])
    // Vertical sheen so the bars feel dimensional
    let sheen = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(sheen,
        start: CGPoint(x: cx, y: cy - s * 0.30),
        end:   CGPoint(x: cx, y: cy + s * 0.30), options: [])
    ctx.restoreGState()

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
