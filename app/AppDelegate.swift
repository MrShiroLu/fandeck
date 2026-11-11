import AppKit

extension NSWindow {
    var isMainAppWindow: Bool { identifier?.rawValue.hasPrefix("main") == true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launchedHidden = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched by launchd as a login item there is no Apple Event; Finder, Dock and `open` send 'oapp'
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if event == nil || loginItem {
            Self.launchedHidden = true
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { NSApp.windows.filter(\.isMainAppWindow).forEach { $0.close() } }
        }
        _ = AppModel.shared
        // When the window closes, leave the Dock and keep running in the menu bar
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard (note.object as? NSWindow)?.isMainAppWindow == true else { return }
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
