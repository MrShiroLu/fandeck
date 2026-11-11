// Logic tests for the app sources. Run with ./build.sh test
import AppKit
import ImageIO
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
        collageLayouts()
        files(in: dir)

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

        // Thumbnails are scaled down and cached
        let thumb = ImageLoader.thumbnail(images[0], maxPixel: 480)
        check(thumb.map { max($0.width, $0.height) == 480 } == true, "thumbnail is scaled to 480 px")
        check(ImageLoader.thumbnail(images[0], maxPixel: 480) === thumb, "second thumbnail comes from the cache")

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
