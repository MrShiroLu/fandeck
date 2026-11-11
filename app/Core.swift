import AppKit
import ImageIO
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser
let walCache = home.appendingPathComponent(".cache/wal")
let defaultLibrary = home.appendingPathComponent("Downloads/Wallpapers")
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
        let r = try await run(python, [script.path] + args)
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

/// QuickLook fails to thumbnail some large PNGs; ImageIO handles all of them
enum ImageLoader {
    private static let cache = NSCache<NSString, CGImage>()

    static func load(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Gallery thumbnails: generated once per file, size and modification date
    static func thumbnail(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)#\(Int(maxPixel))#\(date?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = load(url, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key)
        return image
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
