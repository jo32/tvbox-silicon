// Three artistic "S" icon previews with a large S (matching the Rex mark footprint)
// and flowing paint that drips down past the glyph edges — a wet, running-paint look.
//
// Usage: swift Design/preview-s-variants.swift /tmp
import AppKit
import CoreGraphics
import CoreText

let size = 1024
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let scale: CGFloat = 0.72   // visual cap-height fraction of the canvas

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// MARK: - Background

func drawBackground(_ ctx: CGContext, canvas: CGRect) {
    let base = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgb(255,255,255), rgb(244,241,238)] as CFArray, locations: [0,1])!
    ctx.drawLinearGradient(base, start: CGPoint(x:0,y:canvas.height), end: CGPoint(x:0,y:0), options: [])

    let pinkC = CGPoint(x: canvas.width*0.08, y: canvas.height*0.02)
    ctx.drawRadialGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgb(234,178,208,0.85), rgb(234,178,208,0)] as CFArray, locations:[0,1])!,
        startCenter: pinkC, startRadius: 0, endCenter: pinkC, endRadius: canvas.width*0.72, options: [])

    let lavC = CGPoint(x: canvas.width*0.98, y: canvas.height*0.98)
    ctx.drawRadialGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgb(214,208,232,0.55), rgb(214,208,232,0)] as CFArray, locations:[0,1])!,
        startCenter: lavC, startRadius: 0, endCenter: lavC, endRadius: canvas.width*0.6, options: [])

    let ivC = CGPoint(x: canvas.width*0.5, y: canvas.height*0.52)
    ctx.drawRadialGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgb(255,250,238,0.8), rgb(255,250,238,0)] as CFArray, locations:[0,1])!,
        startCenter: ivC, startRadius: 0, endCenter: ivC, endRadius: canvas.width*0.5, options: [])
}

// MARK: - S outline path (precise, so we can hang drips off its bottom edge)

/// Returns (path in canvas coords, bbox). The path is the exact S glyph outline,
/// scaled so its cap height = `targetH`, centered on `center`.
func makeSPath(center: CGPoint, targetH: CGFloat) -> (CGPath, CGRect) {
    let ctFont = NSFont.systemFont(ofSize: 100, weight: .black) as CTFont   // 100pt for stable metrics
    let upm = CGFloat(CTFontGetUnitsPerEm(ctFont))                          // font units per em (1000)
    let cap = CGFloat(CTFontGetCapHeight(ctFont))                           // cap height in font units

    var glyph = CTFontGetGlyphWithName(ctFont, "S" as CFString)
    var flip = CGAffineTransform(scaleX: 1, y: -1)
    let raw = CTFontCreatePathForGlyph(ctFont, glyph, &flip)!               // y already flipped to CG coords

    let bb = CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, nil, 1)
    // glyph bbox in font units; scale to pixels at 100pt: 1pt = 1px here.
    let s = targetH / cap
    var tx = CGAffineTransform(translationX: center.x, y: center.y)
    tx = tx.scaledBy(x: s, y: s)
    // center the glyph bbox on origin before translating
    tx = tx.translatedBy(x: -bb.midX, y: -bb.midY)
    let path = raw.copy(using: &tx)!

    let rect = CGRect(x: center.x - bb.width*s/2, y: center.y - bb.height*s/2,
                      width: bb.width*s, height: bb.height*s)
    return (path, rect)
}

// MARK: - Drips (paint running down past the glyph)

/// Draws a teardrop drip hanging from `top` downward to `bottom`, width `w`.
func drawDrip(_ ctx: CGContext, top: CGPoint, bottom: CGPoint, w: CGFloat, color: CGColor) {
    let mid = CGPoint(x: top.x, y: top.y)          // attach point
    let len = bottom.y - top.y
    guard len < -4 else { return }
    ctx.setFillColor(color)
    ctx.beginPath()
    // tapered stem from the attach point widening to a rounded bulb at the tip
    let tipX = bottom.x, tipY = bottom.y
    let half = w/2
    ctx.move(to: CGPoint(x: mid.x - half, y: mid.y))
    ctx.addQuadCurve(to: CGPoint(x: tipX - half*0.4, y: tipY + half*0.2),
                     control: CGPoint(x: mid.x - half*1.3, y: mid.y + len*0.35))
    ctx.addArc(center: CGPoint(x: tipX, y: tipY + half*0.2), radius: half*0.4,
               startAngle: .pi, endAngle: 0, clockwise: false)
    ctx.addQuadCurve(to: CGPoint(x: mid.x + half, y: mid.y),
                     control: CGPoint(x: mid.x + half*1.3, y: mid.y + len*0.35))
    ctx.closePath()
    ctx.fillPath()
}

/// Paints the S with a vertical gradient, a specular streak, and running drips
/// hanging off the bottom of the glyph.
func paintS(_ ctx: CGContext, path: CGPath, rect: CGRect,
            colors: [CGColor], locations: [CGFloat],
            streak: (colors: [CGColor], from: CGFloat, to: CGFloat)?,
            dripColor: CGColor, drips: [CGFloat]) {
    // 1. gradient fill clipped to the glyph
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()

    // 2. specular streak (also clipped)
    if let s = streak {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let hg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                            colors: s.colors as CFArray, locations: [0,0.5,1])!
        let x0 = rect.minX + rect.width*s.from
        let x1 = rect.minX + rect.width*s.to
        ctx.drawLinearGradient(hg, start: CGPoint(x:x0,y:rect.maxY), end: CGPoint(x:x1,y:rect.minY), options: [])
        ctx.restoreGState()
    }

    // 3. drips running down off the glyph's bottom edge
    for frac in drips {
        let x = rect.minX + rect.width * frac
        let top = CGPoint(x: x, y: rect.minY)
        // drip length varies with position (sides longer, like paint pooling then running)
        let len = rect.height * (0.18 + abs(frac - 0.5) * 0.3)
        let bottom = CGPoint(x: x, y: rect.minY - len)
        drawDrip(ctx, top: top, bottom: bottom, w: rect.width * 0.09, color: dripColor)
    }
}

// MARK: - Variants

func variant1(_ ctx: CGContext, center: CGPoint, h: CGFloat) {
    let (path, rect) = makeSPath(center: center, targetH: h)
    paintS(ctx, path: path, rect: rect,
           colors: [rgb(20,14,48), rgb(58,32,120), rgb(120,72,178), rgb(40,24,90)],
           locations: [0,0.4,0.78,1],
           streak: (colors: [rgb(255,255,255,0.0), rgb(210,200,255,0.9), rgb(255,255,255,0.0)], from:0.22, to:0.78),
           dripColor: rgb(48,28,100), drips: [0.18, 0.42, 0.68, 0.88])
}

func variant2(_ ctx: CGContext, center: CGPoint, h: CGFloat) {
    let (path, rect) = makeSPath(center: center, targetH: h)
    paintS(ctx, path: path, rect: rect,
           colors: [rgb(238,240,244), rgb(168,174,186), rgb(84,88,100), rgb(26,28,34), rgb(140,144,156)],
           locations: [0,0.32,0.58,0.8,1],
           streak: (colors: [rgb(255,255,255,0.0), rgb(255,255,255,1.0), rgb(255,255,255,0.0)], from:0.28, to:0.72),
           dripColor: rgb(52,56,68), drips: [0.22, 0.46, 0.72, 0.9])
}

func variant3(_ ctx: CGContext, center: CGPoint, h: CGFloat) {
    let (path, rect) = makeSPath(center: center, targetH: h)
    paintS(ctx, path: path, rect: rect,
           colors: [rgb(196,32,120), rgb(128,56,188), rgb(52,96,212), rgb(22,168,200)],
           locations: [0,0.35,0.7,1],
           streak: (colors: [rgb(255,255,255,0.0), rgb(255,235,250,0.85), rgb(255,255,255,0.0)], from:0.26, to:0.74),
           dripColor: rgb(90,70,180), drips: [0.2, 0.44, 0.7, 0.88])
}

// MARK: - Compose

func render(_ name: String, paint: (CGContext, CGPoint, CGFloat) -> Void) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    drawBackground(ctx, canvas: canvas)
    paint(ctx, CGPoint(x: canvas.midX, y: canvas.midY), CGFloat(size) * scale)
    let data = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try! data.write(to: root.appendingPathComponent(name))
    print("Wrote \(name)")
}

render("s-v1-flowing-paint.png", paint: variant1)
render("s-v2-liquid-chrome.png", paint: variant2)
render("s-v3-iridescent.png", paint: variant3)
