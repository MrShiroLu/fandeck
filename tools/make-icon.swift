// Fandeck icon: a picture on the left, the same picture reduced to flat palette bands on the right.
// Usage: swift tools/make-icon.swift out.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Draw with a top-left origin
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func color(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let ink: UInt32 = 0x141419
// Night sky, its horizon glow, and the hill: the same four colors fill the palette half
let bands: [UInt32] = [0x10283C, 0x1F5C6B, 0xE3A857, 0x2A1B2E]

// Body, on the macOS icon grid: 824 px with ~185 px corners
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0.35))
ctx.addPath(rounded(body, 185))
ctx.setFillColor(color(ink))
ctx.fillPath()
ctx.restoreGState()

let card = CGRect(x: 196, y: 236, width: 632, height: 552)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 30, color: color(0, 0.5))
ctx.addPath(rounded(card, 44))
ctx.setFillColor(color(bands[0]))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(rounded(card, 44))
ctx.clip()

// Picture half
let left = CGRect(x: card.minX, y: card.minY, width: card.width / 2, height: card.height)
ctx.saveGState()
ctx.clip(to: left)
let sky = CGGradient(colorsSpace: space, colors: [color(bands[0]), color(bands[1]), color(bands[2])] as CFArray,
                     locations: [0, 0.6, 0.82])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: card.minY), end: CGPoint(x: 0, y: card.maxY), options: [.drawsAfterEndLocation])
ctx.setFillColor(color(0xF4E9D0))
ctx.fillEllipse(in: CGRect(x: left.midX - 46, y: card.minY + 110, width: 92, height: 92))
let hill = CGMutablePath()
hill.move(to: CGPoint(x: left.minX, y: card.maxY))
hill.addLine(to: CGPoint(x: left.minX, y: card.minY + 430))
hill.addQuadCurve(to: CGPoint(x: left.maxX + 40, y: card.minY + 470), control: CGPoint(x: left.midX, y: card.minY + 360))
hill.addLine(to: CGPoint(x: left.maxX + 40, y: card.maxY))
hill.closeSubpath()
ctx.addPath(hill)
ctx.setFillColor(color(bands[3]))
ctx.fillPath()
ctx.restoreGState()

// Palette half
let right = CGRect(x: left.maxX, y: card.minY, width: card.width / 2, height: card.height)
let band = right.height / CGFloat(bands.count)
for (i, c) in bands.enumerated() {
    ctx.setFillColor(color(c))
    ctx.fill(CGRect(x: right.minX, y: right.minY + CGFloat(i) * band, width: right.width, height: band + 1))
}
ctx.restoreGState()

// Seam between picture and palette
ctx.setFillColor(color(ink))
ctx.fill(CGRect(x: card.midX - 5, y: card.minY, width: 10, height: card.height))

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out.path)") }
