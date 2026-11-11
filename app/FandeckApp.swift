import SwiftUI

@main
struct FandeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Fandeck", id: "main") {
            ContentView().environmentObject(model).preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 740)

        MenuBarExtra("Fandeck", systemImage: "paintpalette.fill") {
            MenuBarContent().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
