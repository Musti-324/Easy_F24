import SwiftUI

@main
struct EasyF12App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = F12Store()

    var body: some Scene {
        WindowGroup("Easy F12") {
            ContentView()
                .environmentObject(store)
                .environment(\.locale, Formato.locale)
        }
        .commands {
            // Una sola finestra: ⌘N serve per aggiungere un nuovo F12.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
