import AppKit

/// The menu bar icon: a paint fan deck, four chips opened from a pivot in the corner.
/// A template image, so macOS tints it for light and dark menu bars.
enum MenuBarIcon {
    static let size: CGFloat = 18

    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: size, height: size))
        // Separate bitmaps per scale: the chips are cut apart with clear outlines, which only works in the icon's own pixels
        for scale in [1, 2, 3] {
            if let rep = bitmap(scale: CGFloat(scale)) { image.addRepresentation(rep) }
        }
        image.isTemplate = true
        image.accessibilityDescription = "Fandeck"
        return image
    }()

    private static func bitmap(scale: CGFloat) -> NSBitmapImageRep? {
        let px = Int(size * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(in: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: size, height: size)
        return rep
    }

    static func draw(in ctx: CGContext) {
        ctx.setFillColor(.black)
        let pivot = CGPoint(x: 3.5, y: 3)
        // Back to front, from the chip lying flat to the one standing up
        for angle in [-8.0, -32.0, -56.0, -80.0] {
            ctx.saveGState()
            ctx.translateBy(x: pivot.x, y: pivot.y)
            ctx.rotate(by: CGFloat(angle) * .pi / 180)
            let chip = CGRect(x: -2.4, y: -1.2, width: 4.8, height: 14.2)
            // A clear outline separates each chip from the one behind it
            ctx.setBlendMode(.clear)
            ctx.addPath(CGPath(roundedRect: chip.insetBy(dx: -0.9, dy: -0.9), cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.normal)
            ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        // The rivet the chips turn on
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: pivot.x - 1, y: pivot.y - 1, width: 2, height: 2))
        ctx.setBlendMode(.normal)
    }
}
