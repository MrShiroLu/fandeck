import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let home = FileManager.default.homeDirectoryForCurrentUser
let walCache = home.appendingPathComponent(".cache/wal")
let defaultLibrary = home.appendingPathComponent("Pictures/Wallpapers")
let supportDir = home.appendingPathComponent("Library/Application Support/Fandeck")
let wallpaperIndex = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "bmp"]

extension URL {
    var isImage: Bool { imageExtensions.contains(pathExtension.lowercased()) }

    func isInside(_ folder: URL) -> Bool {
        standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    var tildePath: String {
        path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }
}

// MARK: - Colors

extension Color {
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var vividness: CGFloat {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
        return c.saturationComponent * c.brightnessComponent
    }
}

struct Palette {
    var background: Color
    var foreground: Color
    var colors: [Color]
    var hexes: [String]

    // Same pick as fandeck.py: the most vivid of color1...color6
    var accent: Color { colors[1...6].max { $0.vividness < $1.vividness } ?? foreground }

    /// pywal's light palettes have a light background
    var isLight: Bool {
        guard let c = NSColor(background).usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.5
    }

    static func load() -> Palette? {
        guard let data = try? Data(contentsOf: walCache.appendingPathComponent("colors.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let special = json["special"] as? [String: String],
              let colors = json["colors"] as? [String: String],
              let bg = special["background"].flatMap(Color.init(hex:)),
              let fg = special["foreground"].flatMap(Color.init(hex:))
        else { return nil }
        let hexes = (0..<16).compactMap { colors["color\($0)"]?.uppercased() }
        let list = hexes.compactMap(Color.init(hex:))
        guard list.count == 16 else { return nil }
        return Palette(background: bg, foreground: fg, colors: list, hexes: hexes)
    }
}

enum PaletteTheme: String, CaseIterable, Identifiable {
    case auto, dark, light

    var id: Self { self }
    var label: String { rawValue.capitalized }
}

// MARK: - External commands

enum Tools {
    // GUI apps don't inherit the shell PATH, so add the brew and pipx locations ourselves
    static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
                             "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func find(_ name: String) -> URL? {
        searchPath.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs a command off the main thread; returns stdout and stderr combined
    static func run(_ exe: URL, _ args: [String]) async throws -> (status: Int32, output: String) {
        try await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = searchPath.joined(separator: ":")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    /// pywal's default backend calls ImageMagick: `magick` in version 7, `convert` in version 6
    static func findMagick() -> URL? { find("magick") ?? find("convert") }

    static func shell(_ script: String) async throws -> (status: Int32, output: String) {
        try await run(URL(fileURLWithPath: "/bin/zsh"), ["-c", script])
    }

    /// Runs the bundled fandeck.py and returns the last line of its output
    static func runScript(_ args: [String]) async throws -> String {
        guard let script = Bundle.main.url(forResource: "fandeck", withExtension: "py") else {
            throw Failure("fandeck.py is missing from the app bundle")
        }
        guard let python = find("python3") else { throw Failure("Python 3 not found, see the Setup page") }
        // The palette style from the Setup page applies to every run
        let theme = UserDefaults.standard.string(forKey: "theme") ?? PaletteTheme.dark.rawValue
        let r = try await run(python, [script.path] + args + ["--theme", theme])
        if r.status != 0 { throw Failure(r.output.isEmpty ? "fandeck.py failed" : r.output) }
        return r.output.components(separatedBy: "\n").last ?? ""
    }
}

// MARK: - File watching

/// Watches a single file. Atomic saves replace the file, so it re-attaches after every delete or rename.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { source?.cancel() }

    private func arm() {
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self, unowned s] in
            guard let self else { return }
            if !s.data.isDisjoint(with: [.delete, .rename]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.arm() }
            }
            // Coalesce bursts of writes into one event
            pending?.cancel()
            let item = DispatchWorkItem(block: onChange)
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}

/// Watches folders and their subfolders, so images added or removed in Finder show up without a rescan
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(folders: [URL], onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        // One second of latency coalesces a copy of many files into one callback
        guard let s = FSEventStreamCreate(nil, callback, &context, folders.map(\.path) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

// MARK: - Image loading

/// QuickLook fails to thumbnail some large PNGs; ImageIO handles all of them.
/// Thumbnails are kept in memory and on disk, so each image is decoded once, not on every launch.
enum ImageLoader {
    private static let memory: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 200 << 20 // bytes; a gallery thumbnail is about 0.6 MB
        return cache
    }()

    /// Decoding a large PNG takes a core for a while; a few at a time keeps scrolling smooth
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 3)
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Background fill of the disk cache, after the main queue so it never delays what's on screen
    private static let prefetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()

    static var diskDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Fandeck").appendingPathComponent("Thumbnails")

    /// Decodes `url` scaled to fit `maxPixel`, in the pixel format the screen draws without converting
    static func load(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return displayReady(image)
    }

    /// Already loaded thumbnail, cheap enough to call while building a view
    static func cached(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        memory.object(forKey: memoryKey(url, maxPixel))
    }

    /// Gallery thumbnail from memory, then disk, then the image itself
    static func thumbnail(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        let key = memoryKey(url, maxPixel)
        if let hit = memory.object(forKey: key) { return hit }
        let file = diskFile(url, maxPixel)
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                .flatMap(displayReady) {
            memory.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            return image
        }
        guard let image = load(url, maxPixel: maxPixel) else { return nil }
        memory.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        save(image, to: file)
        return image
    }

    /// Off the main thread and queued; returns nil without decoding if the caller was cancelled while waiting,
    /// which is what happens to cells that scroll out of view
    static func thumbnail(_ url: URL, maxPixel: CGFloat) async -> CGImage? {
        if let hit = cached(url, maxPixel: maxPixel) { return hit }
        let cancelled = Flag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    continuation.resume(returning: cancelled.isSet ? nil : thumbnail(url, maxPixel: maxPixel))
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// Writes missing thumbnails to the disk cache in the background, without keeping them in memory,
    /// so the first scroll through a large folder reads small files instead of decoding full images
    static func prefetch(_ urls: [URL], maxPixel: CGFloat) {
        prefetchQueue.cancelAllOperations()
        for url in urls {
            prefetchQueue.addOperation {
                let file = diskFile(url, maxPixel)
                guard memory.object(forKey: memoryKey(url, maxPixel)) == nil,
                      !FileManager.default.fileExists(atPath: file.path),
                      let image = load(url, maxPixel: maxPixel) else { return }
                save(image, to: file)
            }
        }
    }

    /// Named after the path, modification date, size and pixel size, so an edited image gets a new thumbnail
    private static func diskFile(_ url: URL, _ maxPixel: CGFloat) -> URL {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)|\(Int(maxPixel))"
        return diskDirectory.appendingPathComponent(SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg")
    }

    private static func memoryKey(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.path)#\(Int(maxPixel))" as NSString
    }

    /// Redraws into 32-bit BGRA, the format Core Animation draws directly; RGB JPEG and PNG data would be converted on every draw
    private static func displayReady(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    private static func save(_ image: CGImage, to file: URL) {
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}

// MARK: - File picking

@MainActor
func pickImageFile() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
}
