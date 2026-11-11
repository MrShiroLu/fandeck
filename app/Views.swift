import AppKit
import SwiftUI

// MARK: - Shared views

struct Thumbnail: View {
    let url: URL
    let size: CGSize
    @State private var image: CGImage?

    var body: some View {
        // The frame comes from outside; the image must not drive layout, it is clipped into the box
        Rectangle().fill(.black.opacity(0.25))
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .clipped()
        .task(id: url) {
            image = nil
            let pixels = max(size.width, size.height) * (NSScreen.main?.backingScaleFactor ?? 2)
            image = await Task.detached(priority: .utility) { [url] in ImageLoader.thumbnail(url, maxPixel: pixels) }.value
        }
    }
}

/// The palette as one continuous strip; click a cell to copy its hex value. Colors 8-15 are near-copies of 0-7, so they are left out
struct PaletteStrip: View {
    let palette: Palette
    var count = 8
    var height: CGFloat = 34
    @State private var copied: Int?
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let ink = isLight(palette.colors[i]) ? Color.black : Color.white
                Rectangle().fill(palette.colors[i])
                    .overlay {
                        if hovered == i { Rectangle().strokeBorder(ink.opacity(0.7), lineWidth: 1.5) }
                    }
                    .overlay {
                        if copied == i {
                            Image(systemName: "checkmark").font(.system(size: height * 0.4, weight: .bold))
                                .foregroundStyle(ink)
                                .transition(.opacity)
                        } else if hovered == i {
                            // The strip in the menu bar is too short for the hex code, so it gets a copy icon
                            Group {
                                if height >= 28 {
                                    Text(palette.hexes[i].dropFirst()).font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 2)
                                } else {
                                    Image(systemName: "doc.on.doc").font(.system(size: height * 0.5))
                                }
                            }
                            .foregroundStyle(ink.opacity(0.85))
                            .transition(.opacity)
                        }
                    }
                    .contentShape(Rectangle())
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.12)) {
                            if inside { hovered = i } else if hovered == i { hovered = nil }
                        }
                        (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                    }
                    .onTapGesture { copy(i) }
                    .help("\(palette.hexes[i]) · click to copy")
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(palette.foreground.opacity(0.12)))
    }

    private func copy(_ i: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(palette.hexes[i], forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = i }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.3)) { if copied == i { copied = nil } }
        }
    }

    private func isLight(_ color: Color) -> Bool {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Sits in the title bar, level with the window buttons
            Picker("", selection: $model.tab) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .padding(.top, 2)

            Group {
                switch model.tab {
                case .gallery: GalleryView()
                case .collage: CollageView()
                case .schedule: ScheduleView()
                case .setup: SetupView()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(model.fg)
        .tint(model.accent)
        .frame(minWidth: 880, minHeight: 620)
        .background(model.bg)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(model.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(model.bg.opacity(0.75))
                    .overlay(Text("Drop to set as wallpaper").font(.title3.weight(.medium)))
                    .padding(10)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isImage) else { return false }
            model.tab = .gallery
            model.apply(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(.easeInOut(duration: 0.4), value: model.palette?.hexes)
        .onAppear {
            // The tab bar covers the title bar, so let the window move by its background
            NSApp.windows.filter(\.isMainAppWindow).forEach { $0.isMovableByWindowBackground = true }
            // Silent login launch: SwiftUI still creates the window, close it right away
            if AppDelegate.launchedHidden {
                AppDelegate.launchedHidden = false
                DispatchQueue.main.async { NSApp.windows.filter(\.isMainAppWindow).forEach { $0.close() } }
            }
        }
    }
}

struct GalleryView: View {
    @EnvironmentObject var model: AppModel
    @State private var picking = false
    @State private var showFolders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            HStack(spacing: 8) {
                Text("Wallpapers").font(.headline)
                Text("\(model.wallpapers.count)").font(.callout.monospacedDigit()).opacity(0.5)
                Spacer()
                Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rescan folders")
                Button { showFolders = true } label: { Label("Folders", systemImage: "folder") }
                    .popover(isPresented: $showFolders, arrowEdge: .bottom) {
                        FolderList().padding(16).frame(width: 460).environmentObject(model)
                    }
            }
            if model.wallpapers.isEmpty {
                Group {
                    if model.scanning {
                        Text("Loading wallpapers… If macOS asks for access to your folders, click Allow.")
                    } else {
                        Text("No images in these folders. Add a folder, or drop an image onto the window.")
                    }
                }
                .opacity(0.6).frame(maxWidth: .infinity, minHeight: 120)
            }
            gallery
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { model.apply(url) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            Group {
                if let current = model.current {
                    Thumbnail(url: current, size: CGSize(width: 384, height: 240))
                } else {
                    Rectangle().fill(.black.opacity(0.25))
                }
            }
            .frame(width: 384, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.fg.opacity(0.1)))
            .overlay {
                if model.busy { ProgressView().controlSize(.large) }
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current wallpaper").font(.caption).opacity(0.5)
                    Text(model.current?.lastPathComponent ?? "—")
                        .font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                }
                if let palette = model.palette { PaletteStrip(palette: palette).frame(maxWidth: 420) }
                HStack {
                    Button { picking = true } label: { Text("Choose Image…") }
                        .buttonStyle(.borderedProminent)
                    Button { model.applyRandom() } label: { Label("Shuffle", systemImage: "shuffle") }
                }
                .disabled(model.busy)
                Text(model.status.isEmpty ? "Drop an image anywhere on this window to use it." : model.status)
                    .font(.caption).opacity(0.5).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
    }

    private var gallery: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(model.wallpapers, id: \.self) { url in
                    let selected = url.standardizedFileURL == model.current?.standardizedFileURL
                    Button { model.apply(url) } label: {
                        Thumbnail(url: url, size: CGSize(width: 240, height: 150))
                            .frame(height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? model.accent : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                    .help(url.lastPathComponent)
                    .contextMenu {
                        Button("Apply") { model.apply(url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = model.current {
                Thumbnail(url: current, size: CGSize(width: 300, height: 188))
                    .frame(width: 268, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay { if model.busy { ProgressView() } }
            }
            if let palette = model.palette { PaletteStrip(palette: palette, height: 18) }
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Divider()
            row("Shuffle Wallpaper", "shuffle") { model.applyRandom() }.disabled(model.busy)
            row("Regenerate Colors", "arrow.triangle.2.circlepath") { model.refreshColors() }.disabled(model.busy)
            Toggle(isOn: $model.scheduleEnabled) { Label("Schedule", systemImage: "clock") }
                .toggleStyle(.switch).controlSize(.small).padding(.horizontal, 6)
            Divider()
            row("Open Fandeck", "macwindow") { openMain() }
            row("Quit", "power") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 296)
        .tint(model.accent)
    }

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openMain() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }
}
