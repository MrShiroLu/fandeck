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
    @Published var scanning = false
    @Published var busy = false
    @Published var status = ""
    @Published var collage = CollageDraft()
    @Published var trashItems: [TrashItem] { didSet { try? Self.trashStore.save(trashItems) } }
    @Published var folders: [URL] {
        didSet {
            UserDefaults.standard.set(folders.map(\.path), forKey: "folders")
            watchFolders()
            scan()
        }
    }
    @Published var theme: PaletteTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            refreshColors()
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
    /// Recently shown wallpapers, oldest first; the last entry is the current one
    @Published var history: [URL] { didSet { UserDefaults.standard.set(history.map(\.path), forKey: "history") } }
    @Published var shuffleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(shuffleEnabled, forKey: "shuffleEnabled")
            if shuffleEnabled { lastChange = Date() }
        }
    }
    @Published var shuffleMinutes: Int { didSet { UserDefaults.standard.set(shuffleMinutes, forKey: "shuffleMinutes") } }
    @Published var shuffleShortcut: Shortcut? {
        didSet {
            Shortcut.save(shuffleShortcut, as: "shuffleShortcut")
            registerShortcuts()
        }
    }
    @Published var previousShortcut: Shortcut? {
        didSet {
            Shortcut.save(previousShortcut, as: "previousShortcut")
            registerShortcuts()
        }
    }
    /// True while a shortcut is being recorded, so pressing the old one doesn't fire it
    @Published var shortcutsPaused = false { didSet { registerShortcuts() } }
    /// Shortcuts that macOS or another app already uses
    @Published var takenShortcuts: Set<String> = []
    /// When the wallpaper last changed; the shuffle countdown starts from here
    @Published var lastChange: Date {
        didSet { UserDefaults.standard.set(lastChange.timeIntervalSince1970, forKey: "lastWallpaperChange") }
    }

    private var watcher: FileWatcher?
    private var folderWatcher: FolderWatcher?
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?

    /// The first folder: imported images and collages are saved here
    var library: URL { folders.first ?? defaultLibrary }

    var bg: Color { palette?.background ?? Color(nsColor: .windowBackgroundColor) }
    var fg: Color { palette?.foreground ?? .primary }
    var accent: Color { palette?.accent ?? .accentColor }

    private init() {
        folders = (UserDefaults.standard.stringArray(forKey: "folders") ?? [defaultLibrary.path]).map { URL(fileURLWithPath: $0) }
        followSystem = UserDefaults.standard.object(forKey: "followSystem") as? Bool ?? true
        trashItems = Self.trashStore.load()
        theme = UserDefaults.standard.string(forKey: "theme").flatMap(PaletteTheme.init) ?? .dark
        let schedule = ScheduleState.load()
        rules = schedule.rules
        scheduleEnabled = schedule.enabled
        history = (UserDefaults.standard.stringArray(forKey: "history") ?? []).map { URL(fileURLWithPath: $0) }
        shuffleEnabled = UserDefaults.standard.bool(forKey: "shuffleEnabled")
        shuffleMinutes = UserDefaults.standard.object(forKey: "shuffleMinutes") as? Int ?? 60
        let changed = UserDefaults.standard.double(forKey: "lastWallpaperChange")
        lastChange = changed > 0 ? Date(timeIntervalSince1970: changed) : Date()
        shuffleShortcut = Shortcut.load("shuffleShortcut", default: .shuffle)
        previousShortcut = Shortcut.load("previousShortcut", default: .previous)
        tab = SetupModel.isReady ? UserDefaults.standard.string(forKey: "page").flatMap(Page.init) ?? .gallery : .setup
        reload()
        updateWatcher()
        watchFolders()
        startTimer()
        registerShortcuts()
        purgeTrash()
    }

    func reload() {
        if let screen = NSScreen.main { current = NSWorkspace.shared.desktopImageURL(for: screen) }
        if let current { remember(current) }
        palette = Palette.load()
        scan()
    }

    /// Scans off the main thread: reading ~/Downloads can block on the macOS privacy prompt,
    /// and doing that on the main thread froze the whole app until the prompt was answered
    func scan() {
        let folders = self.folders
        scanTask?.cancel()
        scanning = true
        scanTask = Task {
            let found = await Task.detached(priority: .userInitiated) { Self.listImages(in: folders) }.value
            if !Task.isCancelled {
                wallpapers = found
                scanning = false
                ImageLoader.prefetch(found, maxPixel: Thumbnail.standardPixels)
                checkShuffle()
            }
        }
    }

    private func watchFolders() {
        folderWatcher = FolderWatcher(folders: folders) { [weak self] in
            Task { @MainActor in self?.scan() }
        }
    }

    nonisolated static func listImages(in folders: [URL]) -> [URL] {
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
        return files.sorted { $0.date > $1.date }.map(\.url)
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
        if let url = Shuffle.pick(from: wallpapers, current: current, history: history) { apply(url) }
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
            Task { @MainActor in AppModel.shared.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.tick() }
        }
        DispatchQueue.main.async { self.tick() }
    }

    /// Schedule rules go first: when both are due, the rule wins and the shuffle countdown restarts
    private func tick() {
        checkSchedule()
        checkShuffle()
    }
}
