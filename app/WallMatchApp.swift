import SwiftUI

@main
struct WallMatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("wallMatch", id: "main") {
            ContentView().environmentObject(model).preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 740)

        MenuBarExtra("wallMatch", systemImage: "paintpalette.fill") {
            MenuBarContent().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
