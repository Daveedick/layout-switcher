#!/usr/bin/env swift
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4 else {
    fputs("usage: render-menu-icon.swift <1x.png> <2x.png> <qa.png>\n", stderr)
    exit(2)
}
let output1x = URL(fileURLWithPath: args[1])
let output2x = URL(fileURLWithPath: args[2])
let outputQA = URL(fileURLWithPath: args[3])
func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
}

func addText(_ value: String, x: CGFloat, baseline: CGFloat, context: CGContext, clear: Bool) {
    let font = CTFontCreateWithName("Arial-BoldMT" as CFString, 11.5, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    context.saveGState()
    // The icon geometry uses SVG-style top-left coordinates; undo that flip
    // for CoreText around the requested baseline so the glyph stays upright.
    context.translateBy(x: 0, y: baseline * 2)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = CGPoint(x: x, y: baseline)
    if clear { context.setBlendMode(.clear) }
    CTLineDraw(line, context)
    if clear { context.setBlendMode(.normal) }
    context.restoreGState()
}

func drawIcon(_ context: CGContext, scale: CGFloat, tint: NSColor = .black) {
    context.saveGState()
    context.translateBy(x: 0, y: 18 * scale)
    context.scaleBy(x: scale, y: -scale)

    let left = CGMutablePath()
    left.move(to: CGPoint(x: 4, y: 0)); left.addLine(to: CGPoint(x: 16, y: 0))
    left.addLine(to: CGPoint(x: 16, y: 18)); left.addLine(to: CGPoint(x: 4, y: 18))
    left.addQuadCurve(to: CGPoint(x: 0, y: 14), control: CGPoint(x: 0, y: 18))
    left.addLine(to: CGPoint(x: 0, y: 4))
    left.addQuadCurve(to: CGPoint(x: 4, y: 0), control: CGPoint(x: 0, y: 0))
    left.closeSubpath()
    context.addPath(left); context.setFillColor(tint.cgColor); context.fillPath()

    // Knock out the real glyph alpha from the filled half.
    addText("A", x: 4, baseline: 13.6, context: context, clear: true)

    // Я remains opaque on a transparent right half.
    context.setFillColor(tint.cgColor)
    addText("Я", x: 20, baseline: 13.5, context: context, clear: false)

    context.setStrokeColor(tint.cgColor)
    context.setLineWidth(1)
    context.addPath(CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 31, height: 17), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
    context.strokePath()
    context.setAlpha(0.7)
    context.setLineWidth(0.8)
    context.move(to: CGPoint(x: 16, y: 1.5)); context.addLine(to: CGPoint(x: 16, y: 16.5)); context.strokePath()
    context.restoreGState()
}

func savePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}

func renderIcon(scale: Int) -> CGImage {
    let context = makeContext(width: 32 * scale, height: 18 * scale)
    context.interpolationQuality = .high
    drawIcon(context, scale: CGFloat(scale))
    return context.makeImage()!
}

savePNG(renderIcon(scale: 1), to: output1x)
savePNG(renderIcon(scale: 2), to: output2x)

let qaScale = 4
let qa = makeContext(width: 400, height: 200)
qa.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1).cgColor)
qa.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
qa.setFillColor(NSColor(calibratedWhite: 0.92, alpha: 1).cgColor)
qa.fill(CGRect(x: 0, y: 100, width: 400, height: 100))
// Composite the exported template alpha over each background. Drawing the
// clear glyph directly here would also erase the preview background beneath A.
let templateMask = renderIcon(scale: qaScale)
for (y, tint) in [(14.0, NSColor.white), (114.0, NSColor.black)] {
    let rect = CGRect(x: CGFloat(36), y: CGFloat(y),
                      width: CGFloat(32 * qaScale), height: CGFloat(18 * qaScale))
    qa.saveGState()
    qa.clip(to: rect, mask: templateMask)
    qa.setFillColor(tint.cgColor)
    qa.fill(rect)
    qa.restoreGState()
}
savePNG(qa.makeImage()!, to: outputQA)
