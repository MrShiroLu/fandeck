import SwiftUI

struct ScheduleRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var days: Set<Int> = Set(1...7) // Calendar.weekday: 1 = Sunday, 2 = Monday …
    var hour = 8
    var minute = 0
    var path: String
    var enabled = true

    var url: URL { URL(fileURLWithPath: path) }

    /// Most recent firing at or before `now`, within the last 7 days
    func lastOccurrence(before now: Date, calendar: Calendar = .current) -> Date? {
        occurrence(around: now, in: (0...7).map { -$0 }, calendar: calendar) { $0 <= now }
    }

    func nextOccurrence(after now: Date, calendar: Calendar = .current) -> Date? {
        occurrence(around: now, in: Array(0...7), calendar: calendar) { $0 > now }
    }

    private func occurrence(around now: Date, in offsets: [Int], calendar: Calendar, where valid: (Date) -> Bool) -> Date? {
        guard enabled, !days.isEmpty else { return nil }
        for offset in offsets {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  days.contains(calendar.component(.weekday, from: day)),
                  let t = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  valid(t) else { continue }
            return t
        }
        return nil
    }
}

struct ScheduleState: Codable {
    var enabled = false
    var rules: [ScheduleRule] = []

    static let file = supportDir.appendingPathComponent("schedule.json")

    static func load() -> ScheduleState {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ScheduleState.self, from: $0) } ?? ScheduleState()
    }
}

extension AppModel {
    func saveSchedule() {
        let state = ScheduleState(enabled: scheduleEnabled, rules: rules)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: ScheduleState.file, options: .atomic)
    }

    /// The rule in effect now: the one that fired most recently. A rule stays in effect until the next one fires.
    var activeRule: (rule: ScheduleRule, at: Date)? {
        let now = Date()
        return rules.compactMap { r in r.lastOccurrence(before: now).map { (r, $0) } }.max { $0.1 < $1.1 }
    }

    var nextRule: (rule: ScheduleRule, at: Date)? {
        let now = Date()
        return rules.compactMap { r in r.nextOccurrence(after: now).map { (r, $0) } }.min { $0.1 < $1.1 }
    }

    func checkSchedule() {
        guard scheduleEnabled, !busy, let (rule, at) = activeRule else { return }
        // Apply each firing once; changing the image changes the key too
        let key = "\(rule.id.uuidString)@\(Int(at.timeIntervalSince1970))@\(rule.path)"
        guard key != UserDefaults.standard.string(forKey: "lastScheduleFire") else { return }
        UserDefaults.standard.set(key, forKey: "lastScheduleFire")
        guard FileManager.default.fileExists(atPath: rule.path) else {
            status = "Schedule: \(rule.url.lastPathComponent) not found"
            return
        }
        apply(rule.url)
    }

    func addRule() {
        let hour = Calendar.current.component(.hour, from: Date())
        let path = (current ?? wallpapers.first)?.path ?? ""
        rules.append(ScheduleRule(hour: (hour + 1) % 24, path: path))
    }
}

// MARK: - Views

struct ScheduleView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Schedule").font(.title2.weight(.semibold))
                    Text("Switch wallpapers on chosen days and times. Each rule holds until the next one fires.")
                        .font(.callout).opacity(0.65)
                }
                Spacer()
                Toggle("Enabled", isOn: $model.scheduleEnabled).toggleStyle(.switch)
                Button { model.addRule() } label: { Label("Add Rule", systemImage: "plus") }
            }

            if model.rules.isEmpty {
                emptyState
            } else {
                summary
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($model.rules) { $rule in
                            RuleRow(rule: $rule) { model.rules.removeAll { $0.id == rule.id } }
                            if rule.id != model.rules.last?.id { Divider().opacity(0.5) }
                        }
                    }
                    .background(model.fg.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No rules yet").font(.headline)
            Text("For example: a bright wallpaper on weekday mornings at 08:00, a darker one every evening at 19:00.")
                .font(.callout).opacity(0.65)
            Button("Add the first rule") { model.addRule() }.padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var summary: some View {
        HStack(spacing: 20) {
            if let active = model.activeRule {
                Text("Now: ").foregroundStyle(model.fg.opacity(0.55)) + Text(active.rule.url.lastPathComponent)
            }
            if let next = model.nextRule {
                Text("Next: ").foregroundStyle(model.fg.opacity(0.55)) + Text("\(Self.formatter.string(from: next.at)) · \(next.rule.url.lastPathComponent)")
            }
        }
        .font(.callout).lineLimit(1).truncationMode(.middle)
        .opacity(model.scheduleEnabled ? 1 : 0.45)
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()
}

struct RuleRow: View {
    @EnvironmentObject var model: AppModel
    @Binding var rule: ScheduleRule
    let onDelete: () -> Void
    @State private var picking = false

    var body: some View {
        HStack(spacing: 14) {
            Button { picking = true } label: {
                Thumbnail(url: rule.url, size: CGSize(width: 140, height: 88))
                    .frame(width: 96, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Change image")
            .popover(isPresented: $picking) {
                WallpaperPicker { url in
                    rule.path = url.path
                    picking = false
                }
                .environmentObject(model)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    DatePicker("", selection: time, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                    Text(rule.url.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle).opacity(0.6)
                }
                DayPicker(days: $rule.days)
            }
            Spacer()
            Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete rule")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(rule.enabled ? 1 : 0.5)
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: Date()) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            rule.hour = c.hour ?? 0
            rule.minute = c.minute ?? 0
        }
    }
}

struct DayPicker: View {
    @EnvironmentObject var model: AppModel
    @Binding var days: Set<Int>

    private static let order = [2, 3, 4, 5, 6, 7, 1]
    private static let names = [1: "S", 2: "M", 3: "T", 4: "W", 5: "T", 6: "F", 7: "S"]
    private static let full = Calendar.current.weekdaySymbols

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.order, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(Self.names[day] ?? "")
                        .font(.caption.weight(.semibold).monospaced())
                        .frame(width: 22, height: 22)
                        .background(on ? model.accent : model.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(on ? model.bg : model.fg.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(Self.full[day - 1])
            }
            Menu {
                Button("Every day") { days = Set(1...7) }
                Button("Weekdays") { days = [2, 3, 4, 5, 6] }
                Button("Weekends") { days = [1, 7] }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.leading, 4)
        }
    }
}

/// Popover for picking one image from the gallery or from disk
struct WallpaperPicker: View {
    @EnvironmentObject var model: AppModel
    let onPick: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose an image").font(.headline)
                Spacer()
                Button("From File…") { if let url = pickImageFile() { onPick(url) } }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(model.wallpapers, id: \.self) { url in
                        Button { onPick(url) } label: {
                            Thumbnail(url: url, size: CGSize(width: 160, height: 100))
                                .frame(height: 66)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(url.lastPathComponent)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 520, height: 420)
    }
}
