import SwiftUI

@main
struct FandeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // The delegate has no SwiftUI environment; hand it a way to bring the window back
        let _ = AppDelegate.openMainWindow = { openWindow(id: "main") }

        Window("Fandeck", id: "main") {
            ContentView().environmentObject(model).preferredColorScheme(model.palette?.isLight == true ? .light : .dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 740)

        MenuBarExtra("Fandeck", systemImage: "paintpalette.fill") {
            MenuBarContent().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
