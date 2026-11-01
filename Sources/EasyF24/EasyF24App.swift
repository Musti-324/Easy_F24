import SwiftUI

@main
struct EasyF24App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: F24Store
    @StateObject private var gmail: GmailSync
    @StateObject private var calendario: CalendarioSync

    init() {
        // Solo su macOS 11, dove si chiudeva premendo ⌘ + tasto dopo aver chiuso un foglio.
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)) {
            MenuTrattenuti.attiva()
        }
        let store = F24Store()
        let gmail = GmailSync(store: store)
        _store = StateObject(wrappedValue: store)
        _gmail = StateObject(wrappedValue: gmail)
        // Stesso accesso a Google di Gmail.
        _calendario = StateObject(wrappedValue: CalendarioSync(store: store, auth: gmail.auth))
    }

    var body: some Scene {
        WindowGroup("Easy F24") {
            ContentView()
                .environmentObject(store)
                .environmentObject(gmail)
                .environmentObject(calendario)
                .environment(\.locale, Formato.locale)
        }
        .commands {
            // Una sola finestra: ⌘N serve per aggiungere un nuovo F24.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
