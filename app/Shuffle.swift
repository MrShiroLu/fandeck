import SwiftUI

enum Shuffle {
    static let intervals: [(minutes: Int, label: String)] = [
        (15, "15 minutes"), (30, "30 minutes"), (60, "hour"), (180, "3 hours"), (360, "6 hours"), (1440, "day"),
    ]
    static let historyLimit = 30

    static func label(_ minutes: Int) -> String {
        intervals.first { $0.minutes == minutes }?.label ?? "\(minutes) minutes"
    }

    /// A random image other than the current one, avoiding the last few shown when the folders have enough images
    static func pick(from wallpapers: [URL], current: URL?, history: [URL]) -> URL? {
        let currentPath = current?.standardizedFileURL.path
        let others = wallpapers.filter { $0.standardizedFileURL.path != currentPath }
        let recent = Set(history.suffix(min(10, others.count / 2)).map(\.standardizedFileURL.path))
        let fresh = others.filter { !recent.contains($0.standardizedFileURL.path) }
        return (fresh.isEmpty ? others : fresh).randomElement()
    }

    /// Adds `url` unless it is already the last entry, and drops the oldest entries past the limit
    static func appending(_ url: URL, to history: [URL]) -> [URL] {
        guard history.last?.standardizedFileURL != url.standardizedFileURL else { return history }
        return Array((history + [url]).suffix(historyLimit))
    }
}

extension AppModel {
    func remember(_ url: URL) {
        let updated = Shuffle.appending(url, to: history)
        guard updated != history else { return }
        history = updated
        lastChange = Date()
    }

    /// Earlier wallpapers that still exist, newest first, without the current one
    var recent: [URL] {
        history.dropLast().reversed().filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func goBack() {
        guard !busy, let target = recent.first else { return }
        // Drop everything after the target, so pressing Previous again keeps walking back
        while let last = history.last, last != target { history.removeLast() }
        apply(target)
    }

    var nextShuffle: Date? {
        shuffleEnabled ? lastChange.addingTimeInterval(Double(shuffleMinutes) * 60) : nil
    }

    func checkShuffle() {
        // Until the first scan finishes there is nothing to pick; the end of the scan checks again
        guard let next = nextShuffle, !busy, Date() >= next,
              let url = Shuffle.pick(from: wallpapers, current: current, history: history) else { return }
        // Restart the countdown even if this shuffle fails, so it doesn't retry every 30 seconds
        lastChange = Date()
        apply(url)
    }
}

// MARK: - Views

struct ShuffleRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shuffle").font(.title3).frame(width: 96).opacity(0.7)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Shuffle every")
                    Picker("Interval", selection: $model.shuffleMinutes) {
                        ForEach(Shuffle.intervals, id: \.minutes) { Text($0.label).tag($0.minutes) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(detail).font(.caption).opacity(0.55)
            }
            Spacer()
            Toggle("", isOn: $model.shuffleEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(model.fg.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var detail: String {
        guard let next = model.nextShuffle else {
            return "Picks a random image from your folders and skips the ones shown recently."
        }
        return "Next shuffle \(ScheduleView.formatter.string(from: next)). Choosing a wallpaper yourself restarts the countdown."
    }
}
