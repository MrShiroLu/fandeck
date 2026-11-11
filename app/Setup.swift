import AppKit
import ServiceManagement
import SwiftUI

/// First-launch install: live in /Applications and open at login
@MainActor
enum Installer {
    static let target = URL(fileURLWithPath: "/Applications/Fandeck.app")

    static var inApplications: Bool { Bundle.main.bundleURL.standardizedFileURL == target }

    /// Moves the app to /Applications and relaunches it from there. Returns false if nothing was relaunched.
    static func moveToApplications() -> Bool {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        others.forEach { $0.terminate() }
        do {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
        } catch {
            return false
        }
        // A move, not a copy: don't leave a second app behind. Fails harmlessly on read-only volumes.
        try? fm.removeItem(at: source)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Turns on open at login once; if the user turns it off later, it stays off
    static func enableLoginItemOnce() {
        guard inApplications, !UserDefaults.standard.bool(forKey: "loginItemSetUp") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemSetUp")
        try? SMAppService.mainApp.register()
    }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var brew: URL?
    @Published var python: URL?
    @Published var magick: URL?
    @Published var wal: URL?
    @Published var kittyFound = false
    @Published var kittyLinked = false
    @Published var hasPalette = false
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var running: String?
    @Published var log = ""

    static let kittyConf = home.appendingPathComponent(".config/kitty/kitty.conf")
    static var isReady: Bool { Tools.find("python3") != nil && Tools.findMagick() != nil && Tools.find("wal") != nil }
    var inApplications: Bool { Installer.inApplications }

    init() { refresh() }

    func refresh() {
        brew = Tools.find("brew")
        python = Tools.find("python3")
        magick = Tools.findMagick()
        wal = Tools.find("wal")
        let conf = (try? String(contentsOf: Self.kittyConf, encoding: .utf8)) ?? ""
        kittyLinked = conf.contains("colors-kitty.conf")
        kittyFound = kittyLinked || FileManager.default.fileExists(atPath: "/Applications/kitty.app")
            || Tools.find("kitty") != nil || FileManager.default.fileExists(atPath: Self.kittyConf.path)
        hasPalette = FileManager.default.fileExists(atPath: walCache.appendingPathComponent("colors.json").path)
        loginStatus = SMAppService.mainApp.status
    }

    func run(_ id: String, _ script: String) {
        running = id
        log = "$ \(script)\n"
        Task {
            do {
                let r = try await Tools.shell(script)
                log += r.output + (r.status == 0 ? "\nDone." : "\nFailed with exit code \(r.status).")
            } catch {
                log += error.localizedDescription
            }
            running = nil
            refresh()
        }
    }

    func generatePalette() {
        running = "palette"
        Task {
            do { log = try await Tools.runScript(["--force"]) } catch { log = error.localizedDescription }
            AppModel.shared.reload()
            running = nil
            refresh()
        }
    }

    func linkKitty() {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.kittyConf.deletingLastPathComponent(), withIntermediateDirectories: true)
            var old = ""
            if fm.fileExists(atPath: Self.kittyConf.path) {
                old = try String(contentsOf: Self.kittyConf, encoding: .utf8)
                let backup = Self.kittyConf.appendingPathExtension("fandeck-backup")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: Self.kittyConf, to: backup)
            }
            // Put it first so the user's own settings (opacity etc.) can still override it.
            // Not atomic, so a dotfiles symlink stays a symlink.
            let line = "# Fandeck: colors generated from the wallpaper\ninclude ~/.cache/wal/colors-kitty.conf\n\n"
            try (line + old).write(to: Self.kittyConf, atomically: false, encoding: .utf8)
            log = "Updated kitty.conf." + (old.isEmpty ? "" : " The old file is saved as kitty.conf.fandeck-backup.")
        } catch {
            log = "Could not write kitty.conf: \(error.localizedDescription)"
        }
        refresh()
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log = "Login item: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }

    func installToApplications() {
        running = "apps"
        if !Installer.moveToApplications() {
            log = "Could not copy the app to /Applications"
            running = nil
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var setup = SetupModel()

    var body: some View {
        Form {
            Section {
                SetupRow(state: setup.brew != nil ? .ok : .optional, title: "Homebrew",
                         detail: setup.brew?.tildePath ?? "Needed to install Python, ImageMagick and pipx") {
                    if setup.brew == nil { Link("brew.sh", destination: URL(string: "https://brew.sh")!) }
                }
                SetupRow(state: setup.python != nil ? .ok : .missing, title: "Python 3",
                         detail: setup.python?.tildePath ?? "Not found") {
                    if setup.python == nil {
                        actionButton("Install", id: "python") { setup.run("python", "brew install python") }
                            .disabled(setup.brew == nil)
                    }
                }
                SetupRow(state: setup.magick != nil ? .ok : .missing, title: "ImageMagick",
                         detail: setup.magick?.tildePath ?? "pywal uses it to read the image") {
                    if setup.magick == nil {
                        actionButton("Install", id: "magick") { setup.run("magick", "brew install imagemagick") }
                            .disabled(setup.brew == nil)
                    }
                }
                SetupRow(state: setup.wal != nil ? .ok : .missing, title: "pywal16",
                         detail: setup.wal?.tildePath ?? "Extracts a 16-color palette from the wallpaper") {
                    if setup.wal == nil {
                        actionButton("Install", id: "wal") {
                            setup.run("wal", "command -v pipx >/dev/null || brew install pipx; pipx install pywal16")
                        }
                        .disabled(setup.brew == nil && Tools.find("pipx") == nil)
                    }
                }
                SetupRow(state: setup.hasPalette ? .ok : .missing, title: "Color palette",
                         detail: setup.hasPalette ? "~/.cache/wal/colors.json" : "Generate the first palette from the current wallpaper") {
                    actionButton(setup.hasPalette ? "Regenerate" : "Generate", id: "palette") { setup.generatePalette() }
                        .disabled(setup.python == nil || setup.magick == nil || setup.wal == nil)
                }
            } header: {
                Text("Requirements")
            } footer: {
                Text("Fandeck uses pywal to pull colors out of the wallpaper.").font(.caption).opacity(0.55)
            }

            Section("Integrations") {
                SetupRow(state: setup.kittyLinked ? .ok : setup.kittyFound ? .missing : .optional, title: "kitty",
                         detail: setup.kittyLinked ? "kitty.conf includes the wal colors"
                            : setup.kittyFound ? "Adds an include line to the top of kitty.conf and keeps a backup"
                            : "kitty not found") {
                    if setup.kittyFound && !setup.kittyLinked { Button("Connect") { setup.linkKitty() } }
                }
                SetupRow(state: .ok, title: "macOS accent color", detail: accentDetail) { EmptyView() }
            }

            Section("App") {
                SetupRow(state: setup.inApplications ? .ok : .missing, title: "Applications folder",
                         detail: setup.inApplications ? "/Applications/Fandeck.app"
                            : "Running from \(Bundle.main.bundleURL.tildePath)") {
                    if !setup.inApplications {
                        actionButton("Install & Relaunch", id: "apps") { setup.installToApplications() }
                    }
                }
                SetupRow(state: setup.loginStatus == .enabled ? .ok : .optional, title: "Open at login",
                         detail: loginDetail) {
                    if setup.loginStatus == .requiresApproval {
                        Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Toggle("", isOn: Binding { setup.loginStatus == .enabled } set: { setup.setLogin($0) })
                        .labelsHidden().toggleStyle(.switch)
                }
                SetupRow(state: model.followSystem ? .ok : .optional, title: "Follow System Settings",
                         detail: "Re-match colors when the wallpaper is changed outside the app") {
                    Toggle("", isOn: $model.followSystem).labelsHidden().toggleStyle(.switch)
                }
            }

            Section {
                shortcutRow("Shuffle wallpaper", "shuffle", $model.shuffleShortcut)
                shortcutRow("Previous wallpaper", "previous", $model.previousShortcut)
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                Text("These work from any app. Click one and press new keys to change it, or Esc to cancel.")
                    .font(.caption).opacity(0.55)
            }

            Section("Wallpaper folders") {
                FolderList()
            }

            if !setup.log.isEmpty {
                Section("Output") {
                    ScrollView {
                        Text(setup.log).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, -20) // the grouped form adds its own side insets
        .onAppear { setup.refresh() }
    }

    private var loginDetail: String {
        switch setup.loginStatus {
        case .enabled: "Starts in the menu bar when you log in"
        case .requiresApproval: "Approve it in System Settings › Login Items"
        default: setup.inApplications ? "Keeps the schedule and System Settings sync running" : "Install to Applications first"
        }
    }

    /// Reads the current accent so the row reports a real value
    private var accentDetail: String {
        let names = [-1: "Graphite", 0: "Red", 1: "Orange", 2: "Yellow", 3: "Green", 4: "Blue", 5: "Purple", 6: "Pink"]
        let value = UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int
        let name = value.flatMap { names[$0] } ?? "Multicolor"
        return "Currently \(name), the system color closest to the wallpaper"
    }

    private func shortcutRow(_ title: String, _ id: String, _ shortcut: Binding<Shortcut?>) -> some View {
        let taken = model.takenShortcuts.contains(id)
        return SetupRow(state: shortcut.wrappedValue == nil ? .optional : taken ? .missing : .ok, title: title,
                        detail: shortcut.wrappedValue == nil ? "Off" : taken ? "Already used by macOS or another app, pick another" : "On") {
            ShortcutRecorder(shortcut: shortcut)
        }
    }

    private func actionButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if setup.running == id { ProgressView().controlSize(.small) } else { Text(title) }
        }
        .disabled(setup.running != nil)
    }
}

enum SetupState { case ok, missing, optional }

struct SetupRow<Trailing: View>: View {
    @EnvironmentObject var model: AppModel
    var state: SetupState
    var title: String
    var detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        LabeledContent {
            HStack { trailing() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(state == .ok ? Color.green : state == .missing ? Color.orange : model.fg.opacity(0.25))
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).opacity(0.55).lineLimit(2).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct FolderList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.folders.enumerated()), id: \.element) { i, folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder").opacity(0.7)
                    Text(folder.tildePath).lineLimit(1).truncationMode(.middle)
                    if i == 0 { Text("Primary").font(.caption).opacity(0.5) }
                    Spacer()
                    if i > 0 {
                        Button("Make Primary") { model.folders.move(fromOffsets: [i], toOffset: 0) }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    Button { NSWorkspace.shared.open(folder) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.borderless).help("Show in Finder")
                    Button { model.folders.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove from the list. The files stay on disk.")
                }
            }
            if model.folders.isEmpty { Text("No folders.").opacity(0.6) }
            HStack {
                Button { model.chooseFolders() } label: { Label("Add Folder…", systemImage: "plus") }
                Spacer()
            }
            Text("Subfolders are scanned too. Imported images and collages are saved to the primary folder.")
                .font(.caption).opacity(0.55)
        }
    }
}
