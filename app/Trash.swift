import AppKit
import SwiftUI

/// An image moved to Fandeck's own trash, with the place to put it back
struct TrashItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var original: String
    var stored: String // file name inside the trash folder
    var deleted = Date()

    var originalURL: URL { URL(fileURLWithPath: original) }
}

/// Files and their index in a folder outside the wallpaper folders, so trashed images drop out of the gallery
struct TrashStore {
    static let keepDays = 30

    let directory: URL
    private var index: URL { directory.appendingPathComponent("index.json") }

    func url(of item: TrashItem) -> URL { directory.appendingPathComponent(item.stored) }

    func load() -> [TrashItem] {
        (try? Data(contentsOf: index)).flatMap { try? JSONDecoder().decode([TrashItem].self, from: $0) } ?? []
    }

    func save(_ items: [TrashItem]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: index, options: .atomic)
    }

    func trash(_ file: URL) throws -> TrashItem {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = TrashItem(original: file.path, stored: UUID().uuidString + "-" + file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: url(of: item))
        return item
    }

    /// Moves the file back where it was, under a new name if another file took its place
    func putBack(_ item: TrashItem) throws -> URL {
        let original = item.originalURL
        let folder = original.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = original.deletingPathExtension().lastPathComponent
        var dest = original
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base)-\(n).\(original.pathExtension)")
            n += 1
        }
        try FileManager.default.moveItem(at: url(of: item), to: dest)
        return dest
    }

    func delete(_ item: TrashItem) {
        try? FileManager.default.removeItem(at: url(of: item))
    }

    func expired(_ items: [TrashItem], now: Date = Date()) -> [TrashItem] {
        items.filter { now.timeIntervalSince($0.deleted) > Double(Self.keepDays) * 86400 }
    }

    func daysLeft(_ item: TrashItem, now: Date = Date()) -> Int {
        max(0, Self.keepDays - Int(now.timeIntervalSince(item.deleted) / 86400))
    }
}

extension AppModel {
    static let trashStore = TrashStore(directory: supportDir.appendingPathComponent("Trash"))

    func trash(_ url: URL) {
        if url.standardizedFileURL == current?.standardizedFileURL {
            guard confirm("Move your current wallpaper to the Trash?",
                          "\(url.lastPathComponent) stays on screen until you choose another wallpaper.",
                          button: "Move to Trash") else { return }
        }
        do {
            trashItems.insert(try Self.trashStore.trash(url), at: 0)
            wallpapers.removeAll { $0 == url }
            collage.selected.removeAll { $0 == url }
            status = "Moved \(url.lastPathComponent) to the Trash"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    func putBack(_ item: TrashItem) {
        do {
            let url = try Self.trashStore.putBack(item)
            trashItems.removeAll { $0.id == item.id }
            status = "Put \(url.lastPathComponent) back"
            scan()
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    func deleteForever(_ items: [TrashItem], ask: Bool = true) {
        guard !items.isEmpty else { return }
        if ask {
            let what = items.count == 1 ? items[0].originalURL.lastPathComponent : "\(items.count) images"
            guard confirm("Delete \(what) for good?", "This can't be undone.", button: "Delete") else { return }
        }
        items.forEach(Self.trashStore.delete)
        let ids = Set(items.map(\.id))
        trashItems.removeAll { ids.contains($0.id) }
    }

    /// Run at launch: images trashed more than 30 days ago are deleted, as the Trash window says
    func purgeTrash() {
        deleteForever(Self.trashStore.expired(trashItems), ask: false)
    }

    private func confirm(_ title: String, _ detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Views

struct TrashView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trash").font(.headline)
                Text("\(model.trashItems.count)").font(.callout.monospacedDigit()).opacity(0.5)
                Spacer()
                Button("Empty Trash") { model.deleteForever(model.trashItems) }
                    .disabled(model.trashItems.isEmpty)
            }
            if model.trashItems.isEmpty {
                Text("Images you move to the Trash show up here.")
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 14) {
                        ForEach(model.trashItems) { TrashCell(item: $0) }
                    }
                }
            }
            Text("Images here are deleted for good \(TrashStore.keepDays) days after you trash them.")
                .font(.caption).opacity(0.55)
        }
        .padding(16)
        .frame(width: 520, height: 420)
    }
}

struct TrashCell: View {
    @EnvironmentObject var model: AppModel
    let item: TrashItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Thumbnail(url: AppModel.trashStore.url(of: item))
                .frame(height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(item.originalURL.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Text(daysLeft).font(.caption2).opacity(0.55)
                Spacer()
                Button("Put Back") { model.putBack(item) }
                Button { model.deleteForever([item]) } label: { Image(systemName: "xmark") }
                    .help("Delete for good")
            }
            .controlSize(.small)
        }
        .help(item.original.replacingOccurrences(of: home.path, with: "~"))
    }

    private var daysLeft: String {
        let days = AppModel.trashStore.daysLeft(item)
        return days == 1 ? "1 day left" : "\(days) days left"
    }
}
