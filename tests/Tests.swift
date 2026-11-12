// Logic tests for the app sources. Run with ./build.sh test
import AppKit
import ImageIO
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print(ok ? "ok  " : "FAIL", message)
    if !ok { failures += 1 }
}

/// Writes a solid color image, so the tests never depend on anyone's wallpapers
func writeImage(_ url: URL, width: Int, height: Int, gray: CGFloat) {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

/// Runs the main run loop until `done` returns true or the timeout passes
func wait(_ seconds: TimeInterval, until done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
}

@main
struct Tests {
    static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        schedule()
        shuffle()
        shortcuts()
        terminalConfig()
        palette()
        menuBarIcon()
        collageLayouts()
        files(in: dir)
        trash(in: dir.deletingLastPathComponent().appendingPathComponent("test-trash"))

        print(failures == 0 ? "\nAll tests passed" : "\n\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func schedule() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        func d(_ s: String) -> Date { f.date(from: s)! }

        check(Calendar.current.component(.weekday, from: d("2026-11-11 12:00")) == 4, "2026-11-11 is a Wednesday")
        var r = ScheduleRule(hour: 8, minute: 30, path: "/x")
        check(r.lastOccurrence(before: d("2026-11-11 12:00")) == d("2026-11-11 08:30"), "daily rule: last firing is today")
        check(r.lastOccurrence(before: d("2026-11-11 08:00")) == d("2026-11-10 08:30"), "before the time: last firing is yesterday")
        check(r.lastOccurrence(before: d("2026-11-11 08:30")) == d("2026-11-11 08:30"), "fires exactly on time")
        check(r.nextOccurrence(after: d("2026-11-11 08:30")) == d("2026-11-12 08:30"), "next firing is tomorrow")
        r.days = [2, 3, 4, 5, 6]
        check(r.lastOccurrence(before: d("2026-11-16 07:00")) == d("2026-11-13 08:30"), "weekdays: Monday morning goes back to Friday")
        check(r.nextOccurrence(after: d("2026-11-14 10:00")) == d("2026-11-16 08:30"), "weekdays: Saturday goes on to Monday")
        r.days = []
        check(r.lastOccurrence(before: Date()) == nil, "a rule with no days never fires")
        r.days = Set(1...7)
        r.enabled = false
        check(r.nextOccurrence(after: Date()) == nil, "a disabled rule never fires")

        let state = ScheduleState(enabled: true, rules: [ScheduleRule(days: [1, 7], hour: 22, minute: 5, path: "/a b.png")])
        let back = try! JSONDecoder().decode(ScheduleState.self, from: JSONEncoder().encode(state))
        check(back.rules == state.rules && back.enabled, "schedule survives a JSON round trip")
    }

    static func shuffle() {
        let urls = (1...12).map { URL(fileURLWithPath: "/w/\($0).jpg") }
        let history = Array(urls[6...11])
        var picks = Set<URL>()
        for _ in 0..<300 { if let u = Shuffle.pick(from: urls, current: urls[11], history: history) { picks.insert(u) } }
        check(!picks.contains(urls[11]), "shuffle never picks the current wallpaper")
        check(picks.isDisjoint(with: urls[7...11]), "shuffle skips the last five shown when there are 12 images")
        check(picks == Set(urls[0...6]), "shuffle still reaches every other image")
        let two = Array(urls[0...1])
        check(Shuffle.pick(from: two, current: two[0], history: two) == two[1], "with two images shuffle alternates")
        check(Shuffle.pick(from: [urls[0]], current: urls[0], history: []) == nil, "with one image there is nothing to shuffle to")

        var h: [URL] = []
        for u in urls + urls + urls { h = Shuffle.appending(u, to: h) }
        check(h.count == Shuffle.historyLimit && h.last == urls[11], "history keeps the newest \(Shuffle.historyLimit) entries")
        check(Shuffle.appending(urls[11], to: h) == h, "the same wallpaper twice in a row is stored once")
        check(Shuffle.label(60) == "hour" && Shuffle.label(1440) == "day", "interval labels read as \"every hour\", \"every day\"")
    }

    static func shortcuts() {
        check(Shortcut.shuffle.display == "⌃⌥⌘N" && Shortcut.previous.display == "⌃⌥⌘P", "default shortcuts read ⌃⌥⌘N and ⌃⌥⌘P")
        check(Shortcut.shuffle.carbonModifiers == UInt32(controlKey | optionKey | cmdKey), "modifiers convert to Carbon flags")
        func key(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
        }
        check(Shortcut(event: key(kVK_ANSI_B, "b", [])) == nil, "a key without modifiers is rejected")
        check(Shortcut(event: key(kVK_ANSI_B, "B", [.shift])) == nil, "shift alone is rejected")
        check(Shortcut(event: key(kVK_ANSI_B, "b", [.option, .shift]))?.display == "⌥⇧B", "⌥⇧B is recorded")
        check(Shortcut(event: key(kVK_RightArrow, "\u{F703}", [.control, .command]))?.display == "⌃⌘→", "arrow keys get a readable name")

        let name = "testShortcut"
        UserDefaults.standard.removeObject(forKey: name)
        check(Shortcut.load(name, default: .shuffle) == .shuffle, "an unset shortcut uses the default")
        Shortcut.save(.previous, as: name)
        check(Shortcut.load(name, default: .shuffle) == .previous, "a saved shortcut loads back")
        Shortcut.save(nil, as: name)
        check(Shortcut.load(name, default: .shuffle) == nil, "a cleared shortcut stays off")
        UserDefaults.standard.removeObject(forKey: name)
    }

    static func terminalConfig() {
        let line = "config-file = ?/x/ghostty.conf"
        let block = "# Fandeck: colors generated from the wallpaper\n\(line)\n"
        check(SetupModel.adding(line, to: "", atTop: false) == block, "empty config gets just the Fandeck lines")
        check(SetupModel.adding(line, to: "font-size = 14", atTop: false) == "font-size = 14\n\n" + block,
              "a config without a final newline gets a blank line before the Fandeck lines")
        check(SetupModel.adding(line, to: "font-size = 14\n", atTop: false) == "font-size = 14\n\n" + block,
              "a config with a final newline gets one blank line")
        check(SetupModel.adding("include x", to: "opacity 0.9\n", atTop: true).hasSuffix("\n\nopacity 0.9\n"),
              "kitty's line goes on top, above the user's settings")
    }

    static func palette() {
        func make(_ bg: String) -> Palette {
            let hexes = Array(repeating: "#808080", count: 16)
            return Palette(background: Color(hex: bg)!, foreground: Color(hex: "#808080")!,
                           colors: hexes.compactMap(Color.init(hex:)), hexes: hexes)
        }
        check(make("#F2EEE8").isLight && !make("#1F0D14").isLight, "a light background makes a light palette, a dark one does not")
        check(PaletteTheme(rawValue: "auto") == .auto && PaletteTheme.light.label == "Light", "palette styles match the script's --theme values")
    }

    static func menuBarIcon() {
        let image = MenuBarIcon.image
        let scales = image.representations.map { Int($0.pixelsWide) / Int(MenuBarIcon.size) }.sorted()
        check(image.isTemplate && scales == [1, 2, 3], "menu bar icon is a template with 1x, 2x and 3x bitmaps")
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == 36 }!
        var ink = 0, center = rep.colorAt(x: 7, y: 36 - 6)?.alphaComponent ?? 1
        for x in 0..<36 { for y in 0..<36 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { ink += 1 } }
        check(ink > 200 && ink < 1000, "menu bar icon covers part of its box (\(ink) of 1296 pixels)")
        check(center < 0.1, "the pivot rivet is cut out of the icon")
    }

    static func trash(in root: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        let folder = root.appendingPathComponent("Wallpapers")
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("unwanted.png")
        writeImage(image, width: 64, height: 40, gray: 0.3)
        let store = TrashStore(directory: root.appendingPathComponent("Trash"))

        let item = try! store.trash(image)
        check(!fm.fileExists(atPath: image.path) && fm.fileExists(atPath: store.url(of: item).path),
              "trashing moves the file out of the wallpaper folder into the trash folder")
        check(AppModel.listImages(in: [folder]).isEmpty, "a trashed image drops out of the folder scan")
        try! store.save([item])
        check(store.load() == [item], "the trash index survives a save and load")

        let back = try! store.putBack(item)
        check(back.standardizedFileURL.path == image.standardizedFileURL.path && fm.fileExists(atPath: image.path),
              "Put Back restores the original path")

        let again = try! store.trash(image)
        writeImage(image, width: 64, height: 40, gray: 0.6)
        let renamed = try! store.putBack(again)
        check(renamed.lastPathComponent == "unwanted-2.png" && fm.fileExists(atPath: image.path),
              "Put Back picks a new name when another file took the old one")

        let gone = try! store.trash(renamed)
        store.delete(gone)
        check(!fm.fileExists(atPath: store.url(of: gone).path), "deleting removes the file from the trash folder")

        let now = Date()
        let fresh = TrashItem(original: "/a.png", stored: "a.png", deleted: now.addingTimeInterval(-29 * 86400))
        let old = TrashItem(original: "/b.png", stored: "b.png", deleted: now.addingTimeInterval(-31 * 86400))
        check(store.expired([fresh, old], now: now) == [old], "only items older than 30 days expire")
        check(store.daysLeft(fresh, now: now) == 1, "an item trashed 29 days ago has 1 day left")
    }

    static func collageLayouts() {
        let area = CGRect(x: 10, y: 10, width: 1000, height: 600)
        var ok = true
        for layout in CollageLayout.allCases {
            for n in 1...Collage.maxCount {
                let frames = Collage.frames(n, layout, in: area, gap: 10)
                let inside = frames.allSatisfy { area.insetBy(dx: -0.01, dy: -0.01).contains($0) && $0.width > 0 && $0.height > 0 }
                var overlap = false
                for i in frames.indices {
                    for j in frames.indices where i < j && frames[i].insetBy(dx: 0.01, dy: 0.01).intersects(frames[j]) { overlap = true }
                }
                if frames.count != n || !inside || overlap {
                    check(false, "\(layout.rawValue) with \(n): \(frames.count) frames, inside \(inside), overlap \(overlap)")
                    ok = false
                }
            }
        }
        check(ok, "every layout fits 1 to \(Collage.maxCount) images without overlap")
        let rows = Collage.frames(7, .grid, in: area, gap: 0).map(\.minY)
        check(Dictionary(grouping: rows) { $0 }.values.map(\.count).sorted(by: >) == [3, 2, 2], "grid of 7 splits into rows of 3, 2, 2")
    }

    static func files(in dir: URL) {
        let images = (1...4).map { dir.appendingPathComponent("image-\($0).png") }
        for (i, url) in images.enumerated() { writeImage(url, width: 1600, height: 1000, gray: CGFloat(i) / 4) }

        // Collage written at full size
        let spec = CollageSpec(layout: .feature, gap: 0.012, radius: 0.01, background: CGColor(gray: 0.1, alpha: 1))
        do {
            let url = try Collage.write(images, spec: spec, size: CGSize(width: 3024, height: 1964), to: dir.appendingPathComponent("Collages"))
            let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
            check(props[kCGImagePropertyPixelWidth] as? Int == 3024 && props[kCGImagePropertyPixelHeight] as? Int == 1964,
                  "collage is written at 3024×1964")
        } catch {
            check(false, "collage write: \(error)")
        }

        // Thumbnails are scaled down, kept in memory and written to the disk cache
        // Next to the test folder, not inside it, so the folder scan below doesn't count it
        ImageLoader.diskDirectory = dir.deletingLastPathComponent().appendingPathComponent("test-thumbnails")
        try? FileManager.default.removeItem(at: ImageLoader.diskDirectory)
        let thumb = ImageLoader.thumbnail(images[0], maxPixel: 480)
        check(thumb.map { max($0.width, $0.height) == 480 } == true, "thumbnail is scaled to 480 px")
        check(ImageLoader.thumbnail(images[0], maxPixel: 480) === thumb, "second thumbnail comes from the cache")
        check(ImageLoader.cached(images[0], maxPixel: 480) === thumb, "views can read the cached thumbnail directly")
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: ImageLoader.diskDirectory.path)) ?? []
        check(onDisk.count == 1 && onDisk[0].hasSuffix(".jpg"), "thumbnail is saved to the disk cache")
        check(thumb.map { $0.bitsPerPixel == 32 && $0.alphaInfo == .premultipliedFirst } == true,
              "thumbnail is 32-bit BGRA, so drawing it needs no conversion")
        var asyncThumb: CGImage?
        Task { asyncThumb = await ImageLoader.thumbnail(images[1], maxPixel: 300) }
        wait(5) { asyncThumb != nil }
        check(asyncThumb.map { max($0.width, $0.height) == 300 } == true, "queued thumbnail loads off the main thread")
        func cachedFiles() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: ImageLoader.diskDirectory.path)) ?? []).count }
        let before = cachedFiles()
        ImageLoader.prefetch(Array(images[2...3]), maxPixel: 480)
        wait(10) { cachedFiles() == before + 2 }
        check(cachedFiles() == before + 2, "prefetch writes missing thumbnails to the disk cache")
        check(ImageLoader.cached(images[2], maxPixel: 480) == nil, "prefetch leaves memory alone")

        // Folder scan finds images in subfolders and skips other files
        try? "notes".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let found = AppModel.listImages(in: [dir, dir])
        check(found.count == 5 && found.allSatisfy(\.isImage), "scan finds 5 images, including the collage, without duplicates")

        // File watcher: atomic replace and in-place write
        let watched = dir.appendingPathComponent("watched.plist")
        try? "a".write(to: watched, atomically: true, encoding: .utf8)
        var hits = 0
        let fileWatcher = FileWatcher(url: watched) { hits += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { try? "b".write(to: watched, atomically: true, encoding: .utf8) }
        wait(4) { hits == 1 }
        check(hits == 1, "file watcher sees an atomic replace")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let h = FileHandle(forWritingAtPath: watched.path)!
            h.seekToEndOfFile()
            h.write(Data("c".utf8))
            try? h.close()
        }
        wait(4) { hits == 2 }
        check(hits == 2, "file watcher re-attaches and sees an in-place write")
        _ = fileWatcher

        // Folder watcher: a file added to a subfolder
        let sub = dir.appendingPathComponent("More")
        try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        var changes = 0
        let folderWatcher = FolderWatcher(folders: [dir]) { changes += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { writeImage(sub.appendingPathComponent("new.png"), width: 64, height: 64, gray: 0.5) }
        wait(5) { changes > 0 }
        check(changes > 0, "folder watcher sees a new image in a subfolder")
        _ = folderWatcher
    }
}
