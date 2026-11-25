import AppKit
import CoreGraphics
import Foundation

// Renders a crisp 1024x1024 macOS app icon for BooBox:
// A glowing Ghostty-inspired `>_` phosphor ghost behind brushed-steel jail bars
// inside a tactile metallic CRT bezel squircle.

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/BooBox-1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to allocate bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = nsCtx
let ctx = nsCtx.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

func roundedSquircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

let outerRect = CGRect(x: 96, y: 96, width: 832, height: 832)
let outerPath = roundedSquircle(outerRect, radius: 188)

// 1. Subtle drop shadow behind outer metallic chassis
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: color(0, 0, 0, 0.55))
ctx.addPath(outerPath)
ctx.setFillColor(color(0.18, 0.20, 0.24, 1.0))
ctx.fillPath()
ctx.restoreGState()

// 2. Outer brushed silver/gunmetal bezel
ctx.saveGState()
ctx.addPath(outerPath)
ctx.clip()
let bezelGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        color(0.90, 0.92, 0.95, 1.0),
        color(0.72, 0.75, 0.80, 1.0),
        color(0.45, 0.48, 0.54, 1.0),
        color(0.62, 0.65, 0.71, 1.0),
    ] as CFArray,
    locations: [0.0, 0.35, 0.82, 1.0]
)!
ctx.drawLinearGradient(
    bezelGrad,
    start: CGPoint(x: 512, y: outerRect.maxY),
    end: CGPoint(x: 512, y: outerRect.minY),
    options: []
)
ctx.restoreGState()

// 3. Dark recessed inner frame (CRT gasket)
let frameRect = outerRect.insetBy(dx: 38, dy: 38)
let framePath = roundedSquircle(frameRect, radius: 152)
ctx.saveGState()
ctx.addPath(framePath)
ctx.setFillColor(color(0.06, 0.07, 0.10, 1.0))
ctx.fillPath()
ctx.restoreGState()

// 4. Deep indigo/cobalt CRT screen inside the gasket
let screenRect = frameRect.insetBy(dx: 28, dy: 28)
let screenPath = roundedSquircle(screenRect, radius: 126)

ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()

let bgGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        color(0.08, 0.22, 0.58, 1.0),
        color(0.05, 0.13, 0.40, 1.0),
        color(0.03, 0.06, 0.20, 1.0),
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawRadialGradient(
    bgGrad,
    startCenter: CGPoint(x: 512, y: 540),
    startRadius: 20,
    endCenter: CGPoint(x: 512, y: 512),
    endRadius: 460,
    options: [.drawsAfterEndLocation]
)

// Subtle CRT phosphor dot-matrix grid
ctx.setFillColor(color(0.45, 0.72, 1.0, 0.075))
let step: CGFloat = 14
var gx = screenRect.minX + 6
while gx < screenRect.maxX {
    var gy = screenRect.minY + 6
    while gy < screenRect.maxY {
        ctx.fill(CGRect(x: gx, y: gy, width: 6, height: 6))
        gy += step
    }
    gx += step
}

// 5. Smooth Ghostty-style semicircular dome ghost with sinusoidal 3-lobe skirt
func ghostPath(centerX cx: CGFloat, baseY by: CGFloat, w: CGFloat, h: CGFloat) -> CGMutablePath {
    let p = CGMutablePath()
    let r = w / 2.0
    let left = cx - r
    let right = cx + r
    let domeCenterY = by + h - r
    let waveAmp: CGFloat = 26

    p.move(to: CGPoint(x: left, y: by + waveAmp))
    p.addLine(to: CGPoint(x: left, y: domeCenterY))
    p.addArc(
        center: CGPoint(x: cx, y: domeCenterY),
        radius: r,
        startAngle: .pi,
        endAngle: 0,
        clockwise: true
    )
    p.addLine(to: CGPoint(x: right, y: by + waveAmp))

    let steps = 120
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = right - t * w
        let y = by + waveAmp * 0.5 * (1.0 + cos(t * .pi * 6.0))
        p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

let gPath = ghostPath(centerX: 512, baseY: 288, w: 356, h: 452)

// Outer phosphor halo glow
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 48, color: color(0.42, 0.78, 1.0, 0.92))
ctx.addPath(gPath)
ctx.setFillColor(color(0.76, 0.91, 1.0, 0.96))
ctx.fillPath()
ctx.restoreGState()

// Ghost luminous gradient + phosphor grid
ctx.saveGState()
ctx.addPath(gPath)
ctx.clip()
let ghostGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        color(0.95, 0.98, 1.0, 1.0),
        color(0.75, 0.90, 1.0, 0.98),
        color(0.55, 0.78, 1.0, 0.94),
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawLinearGradient(
    ghostGrad,
    start: CGPoint(x: 512, y: 745),
    end: CGPoint(x: 512, y: 285),
    options: []
)
ctx.setFillColor(color(0.35, 0.62, 0.98, 0.20))
var px = screenRect.minX
while px < screenRect.maxX {
    var py = screenRect.minY
    while py < screenRect.maxY {
        ctx.fill(CGRect(x: px, y: py, width: 5, height: 5))
        py += 12
    }
    px += 12
}
ctx.restoreGState()

// Luminous ghost outline
ctx.saveGState()
ctx.addPath(gPath)
ctx.setStrokeColor(color(0.92, 0.97, 1.0, 0.95))
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

// Crisp `>_` face centered in the window between the two inner jail bars
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(color(0.05, 0.14, 0.42, 0.98))
ctx.setLineWidth(21)

let chevron = CGMutablePath()
chevron.move(to: CGPoint(x: 454, y: 598))
chevron.addLine(to: CGPoint(x: 492, y: 568))
chevron.addLine(to: CGPoint(x: 454, y: 538))
ctx.addPath(chevron)
ctx.strokePath()

let dash = CGMutablePath()
dash.move(to: CGPoint(x: 526, y: 566))
dash.addLine(to: CGPoint(x: 570, y: 566))
ctx.addPath(dash)
ctx.strokePath()
ctx.restoreGState()

// 6. Jail bars — horizontal top & bottom crossbars + 4 cylindrical brushed-steel bars
let barXs: [CGFloat] = [278, 422, 602, 746]
let barWidth: CGFloat = 30

for crossY in [screenRect.minY + 84, screenRect.maxY - 108] {
    let crossRect = CGRect(x: screenRect.minX - 10, y: crossY, width: screenRect.width + 20, height: 26)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: color(0, 0, 0, 0.65))
    ctx.setFillColor(color(0.24, 0.27, 0.33, 1.0))
    ctx.fill(crossRect)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.clip(to: crossRect)
    let crossGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            color(0.70, 0.74, 0.80, 1.0),
            color(0.42, 0.46, 0.54, 1.0),
            color(0.20, 0.23, 0.29, 1.0),
        ] as CFArray,
        locations: [0.0, 0.45, 1.0]
    )!
    ctx.drawLinearGradient(
        crossGrad,
        start: CGPoint(x: 512, y: crossRect.maxY),
        end: CGPoint(x: 512, y: crossRect.minY),
        options: []
    )
    ctx.restoreGState()
}

for bx in barXs {
    let rect = CGRect(x: bx - barWidth / 2, y: screenRect.minY - 10, width: barWidth, height: screenRect.height + 20)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 10, height: -4), blur: 20, color: color(0, 0, 0, 0.72))
    ctx.setFillColor(color(0.25, 0.28, 0.34, 1.0))
    ctx.fill(rect)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.clip(to: rect)
    let barGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            color(0.22, 0.25, 0.32, 1.0),
            color(0.68, 0.73, 0.82, 1.0),
            color(0.95, 0.97, 1.0, 1.0),
            color(0.54, 0.59, 0.68, 1.0),
            color(0.24, 0.27, 0.34, 1.0),
            color(0.38, 0.43, 0.52, 1.0),
        ] as CFArray,
        locations: [0.0, 0.20, 0.36, 0.62, 0.86, 1.0]
    )!
    ctx.drawLinearGradient(
        barGrad,
        start: CGPoint(x: rect.minX, y: 512),
        end: CGPoint(x: rect.maxX, y: 512),
        options: []
    )
    let bounceGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            color(0.45, 0.85, 1.0, 0.26),
            color(0.45, 0.85, 1.0, 0.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        bounceGrad,
        startCenter: CGPoint(x: 512, y: 520),
        startRadius: 40,
        endCenter: CGPoint(x: 512, y: 520),
        endRadius: 290,
        options: []
    )
    ctx.restoreGState()

    for rivetY in [screenRect.minY + 97, screenRect.maxY - 95] {
        let rRect = CGRect(x: bx - 4.5, y: rivetY - 4.5, width: 9, height: 9)
        ctx.setFillColor(color(0.16, 0.19, 0.25, 0.85))
        ctx.fillEllipse(in: rRect)
        ctx.setFillColor(color(0.88, 0.92, 0.98, 0.75))
        ctx.fillEllipse(in: CGRect(x: bx - 3.0, y: rivetY - 1.5, width: 4.5, height: 4.5))
    }
}

// 7. Cute glowing ghost paws gripping the two center prison bars
for (hx, isLeft) in [(422.0, true), (602.0, false)] {
    let pawW: CGFloat = 54
    let pawH: CGFloat = 44
    let pawX = hx - pawW / 2 + (isLeft ? -3 : 3)
    let pawY: CGFloat = 446
    let handRect = CGRect(x: pawX, y: pawY, width: pawW, height: pawH)
    let handPath = CGPath(roundedRect: handRect, cornerWidth: 21, cornerHeight: 21, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: isLeft ? 4 : -4, height: -6), blur: 16, color: color(0.02, 0.08, 0.25, 0.55))
    ctx.addPath(handPath)
    ctx.setFillColor(color(0.88, 0.96, 1.0, 0.99))
    ctx.fillPath()
    ctx.setStrokeColor(color(0.58, 0.84, 1.0, 0.85))
    ctx.setLineWidth(3)
    ctx.addPath(handPath)
    ctx.strokePath()

    ctx.setStrokeColor(color(0.42, 0.66, 0.92, 0.50))
    ctx.setLineWidth(2.8)
    ctx.setLineCap(.round)
    let fx1 = isLeft ? handRect.maxX - 18 : handRect.minX + 6
    let fx2 = isLeft ? handRect.maxX - 5 : handRect.minX + 19
    for fy in [pawY + 15.0, pawY + 29.0] {
        ctx.move(to: CGPoint(x: fx1, y: fy))
        ctx.addLine(to: CGPoint(x: fx2, y: fy))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

// 8. Curved CRT glass sheen across upper half
ctx.saveGState()
let sheen = CGMutablePath()
sheen.move(to: CGPoint(x: screenRect.minX, y: screenRect.maxY))
sheen.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.maxY))
sheen.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.midY + 60))
sheen.addQuadCurve(
    to: CGPoint(x: screenRect.minX, y: screenRect.midY - 20),
    control: CGPoint(x: screenRect.midX, y: screenRect.midY - 60)
)
sheen.closeSubpath()
ctx.addPath(sheen)
ctx.clip()
let sheenGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        color(1, 1, 1, 0.16),
        color(1, 1, 1, 0.03),
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    sheenGrad,
    start: CGPoint(x: 512, y: screenRect.maxY),
    end: CGPoint(x: 512, y: screenRect.midY - 40),
    options: []
)
ctx.restoreGState()

// Inner screen vignette
ctx.addPath(screenPath)
ctx.setStrokeColor(color(0, 0, 0, 0.65))
ctx.setLineWidth(14)
ctx.strokePath()

ctx.restoreGState()

// Specular ring on outer metal rim
ctx.saveGState()
ctx.addPath(outerPath)
ctx.setStrokeColor(color(1, 1, 1, 0.35))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("Generated icon: \(outPath)")
