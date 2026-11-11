import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case gallery = "Gallery", collage = "Collage", schedule = "Schedule", setup = "Setup"

    var id: Self { self }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var tab: Page { didSet { UserDefaults.standard.set(tab.rawValue, forKey: "page") } }
    @Published var current: URL?
    @Published var palette = Palette.load()
    @Published var wallpapers: [URL] = []
    @Published var busy = false
    @Published var status = ""
    @Published var folders: [URL] {
        didSet {
            UserDefaults.standard.set(folders.map(\.path), forKey: "folders")
            scan()
        }
    }
    @Published var followSystem: Bool {
        didSet {
            UserDefaults.standard.set(followSystem, forKey: "followSystem")
            updateWatcher()
        }
    }
    @Published var rules: [ScheduleRule] { didSet { saveSchedule() } }
    @Published var scheduleEnabled: Bool {
        didSet {
            saveSchedule()
            checkSchedule()
        }
    }

    private var watcher: FileWatcher?
    private var timer: Timer?

    /// The first folder: imported images and collages are saved here
    var library: URL { folders.first ?? defaultLibrary }

    var bg: Color { palette?.background ?? Color(nsColor: .windowBackgroundColor) }
    var fg: Color { palette?.foreground ?? .primary }
    var accent: Color { palette?.accent ?? .accentColor }

    private init() {
        folders = (UserDefaults.standard.stringArray(forKey: "folders") ?? [defaultLibrary.path]).map { URL(fileURLWithPath: $0) }
        followSystem = UserDefaults.standard.object(forKey: "followSystem") as? Bool ?? true
        let schedule = ScheduleState.load()
        rules = schedule.rules
        scheduleEnabled = schedule.enabled
        tab = SetupModel.isReady ? UserDefaults.standard.string(forKey: "page").flatMap(Page.init) ?? .gallery : .setup
        reload()
        updateWatcher()
        startTimer()
    }

    func reload() {
        if let screen = NSScreen.main { current = NSWorkspace.shared.desktopImageURL(for: screen) }
        palette = Palette.load()
        scan()
    }

    func scan() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var seen = Set<String>()
        var files: [(url: URL, date: Date)] = []
        for folder in folders {
            guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e where url.isImage && seen.insert(url.standardizedFileURL.path).inserted {
                let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                files.append((url, date))
            }
        }
        wallpapers = files.sorted { $0.date > $1.date }.map(\.url)
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to load wallpapers from"
        guard panel.runModal() == .OK else { return }
        let new = panel.urls.filter { url in !folders.contains { $0.standardizedFileURL == url.standardizedFileURL } }
        if !new.isEmpty { folders += new }
    }

    func apply(_ source: URL) {
        guard !busy else { return }
        busy = true
        status = "Applying…"
        Task {
            do {
                let url = try importIfNeeded(source)
                // fandeck.py --set sets the wallpaper: NSWorkspace only changes the active Space
                let output = try await Tools.runScript(["--force", "--set", url.path])
                status = output.isEmpty ? "Done" : output
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            reload()
            busy = false
        }
    }

    func applyRandom() {
        let others = wallpapers.filter { $0.standardizedFileURL != current?.standardizedFileURL }
        if let url = others.randomElement() { apply(url) }
    }

    /// Regenerate colors without touching the wallpaper
    func refreshColors() {
        guard !busy else { return }
        busy = true
        Task {
            do { status = try await Tools.runScript(["--force"]) } catch { status = "Error: \(error.localizedDescription)" }
            reload()
            busy = false
        }
    }

    /// Copy images from outside the watched folders into the library, so downloads and temp files don't vanish
    private func importIfNeeded(_ url: URL) throws -> URL {
        if folders.contains(where: url.isInside) { return url }
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        var dest = library.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = library.appendingPathComponent("\(base)-\(n).\(url.pathExtension)")
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    // MARK: Changes made in System Settings

    private func updateWatcher() {
        watcher = followSystem ? FileWatcher(url: wallpaperIndex) { [weak self] in
            Task { @MainActor in self?.syncFromSystem() }
        } : nil
    }

    private func syncFromSystem() {
        guard followSystem, !busy else { return }
        Task {
            // If we made the change ourselves, the script sees the cached path and exits early
            _ = try? await Tools.runScript([])
            reload()
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.checkSchedule() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.checkSchedule() }
        }
        DispatchQueue.main.async { self.checkSchedule() }
    }
}
