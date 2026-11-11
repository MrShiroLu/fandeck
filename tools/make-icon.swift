// wallMatch icon: a fan of paint chips, one palette per wallpaper.
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

// Body, on the macOS icon grid: 824 px with ~185 px corners
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0.35))
ctx.addPath(rounded(body, 185))
ctx.setFillColor(color(0x1D1D22))
ctx.fillPath()
ctx.restoreGState()

// Paint chip: four bands over a paper label with a rivet at the pivot
let pivot = CGPoint(x: 512, y: 742)
let chip = CGRect(x: 397, y: 222, width: 230, height: 570)
let label: CGFloat = 122

func drawChip(_ bands: [UInt32], angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: pivot.x, y: pivot.y)
    ctx.rotate(by: angle * .pi / 180)
    ctx.translateBy(x: -pivot.x, y: -pivot.y)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0, 0.45))
    ctx.addPath(rounded(chip, 22))
    ctx.setFillColor(color(0xF4F0E8))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(rounded(chip, 22))
    ctx.clip()
    let band = (chip.height - label) / CGFloat(bands.count)
    for (i, c) in bands.enumerated() {
        ctx.setFillColor(color(c))
        ctx.fill(CGRect(x: chip.minX, y: chip.minY + CGFloat(i) * band, width: chip.width, height: band + 1))
    }
    ctx.restoreGState()
    ctx.restoreGState()
}

drawChip([0x173F4A, 0x2B6B78, 0x5E9EA0, 0xA8CFC8], angle: -26)
drawChip([0x6E2F1B, 0xA9522B, 0xD98848, 0xF0C285], angle: 26)
drawChip([0x23244A, 0x48508F, 0x8E86C4, 0xDCC5DA], angle: 0)

// Rivet holding the fan together
ctx.setFillColor(color(0x1D1D22))
ctx.fillEllipse(in: CGRect(x: pivot.x - 22, y: pivot.y - 22, width: 44, height: 44))
ctx.setFillColor(color(0xB9B2A6))
ctx.fillEllipse(in: CGRect(x: pivot.x - 12, y: pivot.y - 12, width: 24, height: 24))

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out.path)") }
