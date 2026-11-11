import AppKit

extension NSWindow {
    var isMainAppWindow: Bool { identifier?.rawValue.hasPrefix("main") == true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launchedHidden = false
    static var openMainWindow: (() -> Void)?

    /// Brings the main window back from the menu bar, Finder, Spotlight or the Dock
    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: \.isMainAppWindow) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Installer.inApplications && Installer.moveToApplications() {
            NSApp.windows.forEach { $0.orderOut(nil) }
            return
        }
        Installer.enableLoginItemOnce()
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
        // SwiftUI doesn't reopen a closed Window scene by itself while the app is a menu bar accessory
        if !hasVisibleWindows { Self.showMainWindow() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
