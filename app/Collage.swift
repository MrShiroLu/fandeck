import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum CollageLayout: String, CaseIterable, Identifiable {
    case grid = "Grid", feature = "Feature", columns = "Columns", rows = "Rows"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .feature: "sidebar.left"
        case .columns: "rectangle.split.3x1"
        case .rows: "rectangle.split.1x2"
        }
    }
}

struct CollageSpec {
    var layout: CollageLayout
    var gap: CGFloat     // fraction of canvas width
    var radius: CGFloat  // fraction of canvas width
    var background: CGColor
}

enum Collage {
    static let maxCount = 9

    /// Pixel size of the main screen
    @MainActor static var canvasSize: CGSize {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2
        let size = screen?.frame.size ?? CGSize(width: 1512, height: 982)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Frames with a top-left origin
    static func frames(_ n: Int, _ layout: CollageLayout, in area: CGRect, gap: CGFloat) -> [CGRect] {
        guard n > 0 else { return [] }
        switch layout {
        case .columns:
            return split(area, n, vertical: false, gap: gap)
        case .rows:
            return split(area, n, vertical: true, gap: gap)
        case .grid:
            // Extra images go to the top rows: 7 -> 3, 2, 2
            let cols = Int(Double(n).squareRoot().rounded(.up))
            let rows = (n + cols - 1) / cols
            return split(area, rows, vertical: true, gap: gap).enumerated().flatMap { i, row in
                split(row, n / rows + (i < n % rows ? 1 : 0), vertical: false, gap: gap)
            }
        case .feature:
            guard n > 1 else { return [area] }
            let big = CGRect(x: area.minX, y: area.minY, width: (area.width - gap) * 0.62, height: area.height)
            let rest = CGRect(x: big.maxX + gap, y: area.minY, width: area.maxX - big.maxX - gap, height: area.height)
            return [big] + frames(n - 1, n > 4 ? .grid : .rows, in: rest, gap: gap)
        }
    }

    private static func split(_ r: CGRect, _ n: Int, vertical: Bool, gap: CGFloat) -> [CGRect] {
        let length = ((vertical ? r.height : r.width) - gap * CGFloat(n - 1)) / CGFloat(n)
        return (0..<n).map { i in
            let offset = CGFloat(i) * (length + gap)
            return vertical ? CGRect(x: r.minX, y: r.minY + offset, width: r.width, height: length)
                            : CGRect(x: r.minX + offset, y: r.minY, width: length, height: r.height)
        }
    }

    static func render(_ urls: [URL], spec: CollageSpec, size: CGSize) -> CGImage? {
        guard size.width >= 1, size.height >= 1,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(spec.background)
        ctx.fill(CGRect(origin: .zero, size: size))

        let gap = spec.gap * size.width
        let radius = spec.radius * size.width
        let area = CGRect(origin: .zero, size: size).insetBy(dx: gap, dy: gap)
        for (url, f) in zip(urls, frames(urls.count, spec.layout, in: area, gap: gap)) {
            // CoreGraphics uses a bottom-left origin
            let rect = CGRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)
            guard rect.width >= 1, rect.height >= 1,
                  let image = ImageLoader.load(url, maxPixel: max(rect.width, rect.height) * 2) else { continue }
            // Aspect-fill the cell and clip the overflow
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = max(rect.width / iw, rect.height / ih)
            let drawn = CGRect(x: rect.midX - iw * scale / 2, y: rect.midY - ih * scale / 2, width: iw * scale, height: ih * scale)
            let r = min(radius, rect.width / 2, rect.height / 2)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.clip()
            ctx.draw(image, in: drawn)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    static func write(_ urls: [URL], spec: CollageSpec, size: CGSize, to dir: URL) throws -> URL {
        guard let image = render(urls, spec: spec, size: size) else { throw Tools.Failure("Could not render the collage") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("collage-\(f.string(from: Date())).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Tools.Failure("Could not create the collage file")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Tools.Failure("Could not save the collage") }
        return url
    }
}

// MARK: - View

struct CollageView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: [URL] = []
    @State private var layout = CollageLayout.grid
    @State private var gap = 0.012
    @State private var radius = 0.01
    @State private var background: Color?
    @State private var preview: CGImage?
    @State private var saving = false
    @State private var message = ""

    private struct PreviewKey: Hashable {
        var urls: [URL], layout: CollageLayout, gap: Double, radius: Double, background: Color
    }

    private var spec: CollageSpec {
        CollageSpec(layout: layout, gap: gap, radius: radius, background: NSColor(background ?? model.bg).cgColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 24) {
                previewBox
                controls.frame(width: 250)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("Pick images in order").font(.headline)
                Text("\(selected.count) of \(Collage.maxCount)").font(.callout.monospacedDigit()).opacity(0.55)
                Spacer()
                if !selected.isEmpty { Button("Clear Selection") { selected = [] }.buttonStyle(.borderless) }
            }
            ScrollView { grid }
        }
        .task(id: PreviewKey(urls: selected, layout: layout, gap: gap, radius: radius, background: background ?? model.bg)) {
            guard !selected.isEmpty else { preview = nil; return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let urls = selected, spec = spec
            let full = Collage.canvasSize
            let size = CGSize(width: 1100, height: (1100 * full.height / full.width).rounded())
            let image = await Task.detached(priority: .userInitiated) { Collage.render(urls, spec: spec, size: size) }.value
            if !Task.isCancelled { preview = image }
        }
    }

    private var previewBox: some View {
        let size = Collage.canvasSize
        let height: CGFloat = 300
        return ZStack {
            Rectangle().fill(model.fg.opacity(0.05))
            if let preview {
                Image(decorative: preview, scale: 1).resizable().scaledToFit()
            } else {
                Text("Select images below to build a collage")
                    .font(.callout).opacity(0.5).multilineTextAlignment(.center).padding()
            }
        }
        .frame(width: height * size.width / size.height, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.fg.opacity(0.1)))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Collage").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Layout").font(.caption).opacity(0.6)
                Picker("Layout", selection: $layout) {
                    ForEach(CollageLayout.allCases) { Image(systemName: $0.symbol).help($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Spacing").font(.caption).opacity(0.6)
                Slider(value: $gap, in: 0...0.04)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Corner radius").font(.caption).opacity(0.6)
                Slider(value: $radius, in: 0...0.04)
            }
            ColorPicker("Background", selection: Binding { background ?? model.bg } set: { background = $0 }, supportsOpacity: false)
            HStack {
                Button("Save") { save(apply: false) }
                Button("Save & Apply") { save(apply: true) }.buttonStyle(.borderedProminent)
                if saving { ProgressView().controlSize(.small) }
            }
            .disabled(selected.isEmpty || saving || model.busy)
            if !message.isEmpty { Text(message).font(.caption).opacity(0.6).lineLimit(3) }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
            ForEach(model.wallpapers, id: \.self) { url in
                let index = selected.firstIndex(of: url)
                Button { toggle(url) } label: {
                    Thumbnail(url: url, size: CGSize(width: 200, height: 125))
                        .frame(height: 82)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(index != nil ? model.accent : .clear, lineWidth: 2))
                        .overlay(alignment: .topLeading) {
                            if let index {
                                Text("\(index + 1)").font(.caption.weight(.bold).monospacedDigit())
                                    .frame(width: 20, height: 20)
                                    .background(model.accent, in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(model.bg)
                                    .padding(5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(url.lastPathComponent)
            }
        }
    }

    private func toggle(_ url: URL) {
        if let i = selected.firstIndex(of: url) {
            selected.remove(at: i)
        } else if selected.count < Collage.maxCount {
            selected.append(url)
        }
    }

    private func save(apply: Bool) {
        saving = true
        message = ""
        let urls = selected, spec = spec, size = Collage.canvasSize
        let dir = model.library.appendingPathComponent("Collages")
        Task {
            do {
                let url = try await Task.detached { try Collage.write(urls, spec: spec, size: size, to: dir) }.value
                message = "Saved to \(url.tildePath)"
                model.scan()
                if apply { model.apply(url) }
            } catch {
                message = "Error: \(error.localizedDescription)"
            }
            saving = false
        }
    }
}
