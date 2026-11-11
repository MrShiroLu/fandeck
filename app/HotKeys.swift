import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key combination for a global shortcut
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt // NSEvent.ModifierFlags raw value
    var key: String     // what the key shows, captured when it was recorded

    static let shuffle = Shortcut(keyCode: UInt16(kVK_ANSI_N), modifiers: [.control, .option, .command], key: "N")
    static let previous = Shortcut(keyCode: UInt16(kVK_ANSI_P), modifiers: [.control, .option, .command], key: "P")

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.control, .option, .shift, .command]).rawValue
        self.key = key
    }

    /// Nil unless the event holds ⌘, ⌃ or ⌥: a plain or shift-only key would take over normal typing
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        let key = Self.names[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !key.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: flags, key: key)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    var carbonModifiers: UInt32 {
        var m = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    /// Keys whose characters don't read well on their own
    private static let names: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// A missing value means the default; empty data means the user cleared the shortcut
    static func load(_ name: String, default fallback: Shortcut) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: name) else { return fallback }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func save(_ shortcut: Shortcut?, as name: String) {
        UserDefaults.standard.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: name)
    }
}

/// System-wide shortcuts through Carbon, which needs no Accessibility permission
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.shared.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Replaces the shortcut for `id`. Returns false when macOS or another app already uses the combination.
    @discardableResult
    func register(_ id: UInt32, _ shortcut: Shortcut?, action: @escaping () -> Void) -> Bool {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = action
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4644_4B20), id: id) // "FDK "
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }
}

extension AppModel {
    func registerShortcuts() {
        var taken: Set<String> = []
        let shuffle = shortcutsPaused ? nil : shuffleShortcut
        let previous = shortcutsPaused ? nil : previousShortcut
        if !HotKeys.shared.register(1, shuffle, action: { Task { @MainActor in AppModel.shared.applyRandom() } }) {
            taken.insert("shuffle")
        }
        if !HotKeys.shared.register(2, previous, action: { Task { @MainActor in AppModel.shared.goBack() } }) {
            taken.insert("previous")
        }
        if takenShortcuts != taken { takenShortcuts = taken }
    }
}

// MARK: - Views

/// Click, then press the new keys. Esc cancels.
struct ShortcutRecorder: View {
    @EnvironmentObject var model: AppModel
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press keys…" : shortcut?.display ?? "Record Shortcut")
                    .monospacedDigit()
                    .frame(minWidth: 96)
            }
            .accessibilityValue(recording ? "Recording" : shortcut?.display ?? "Off")
            if shortcut != nil && !recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .opacity(0.6)
                    .help("Turn off this shortcut")
                    .accessibilityLabel("Turn off this shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        // Let the current combination reach this window instead of firing the action
        model.shortcutsPaused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let new = Shortcut(event: event) {
                shortcut = new
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        if model.shortcutsPaused { model.shortcutsPaused = false }
    }
}
