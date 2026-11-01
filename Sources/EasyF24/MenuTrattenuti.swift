import AppKit

/// Rimedio alla chiusura improvvisa su macOS 11 Big Sur premendo una scorciatoia (⌘ + tasto).
///
/// Quando una finestra o un foglio si chiude, SwiftUI svuota e ricostruisce i menu della
/// barra (Modifica, Vista, Finestra…) e i vecchi sottomenu vengono liberati. Su Big Sur
/// AppKit a volte li tiene ancora in elenco: alla scorciatoia successiva prova a riempirli
/// per cercare la voce giusta e legge memoria già liberata
/// (EXC_BAD_ACCESS in -[NSMenu _populateFromSidebandUpdatersOfSign:withEventRef:]).
///
/// Qui ogni menu agganciato alla barra resta in memoria per tutta la vita dell'app, così
/// quello che AppKit legge è sempre valido. Costa pochi kilobyte per ogni ricostruzione.
enum MenuTrattenuti {
    private static var trattenuti = [ObjectIdentifier: NSMenu]()
    private static var attivo = false

    /// Menu tenuti in memoria finora.
    static var quanti: Int { trattenuti.count }

    /// Va chiamata prima che SwiftUI costruisca la barra dei menu. Le chiamate successive non fanno nulla.
    static func attiva() {
        guard !attivo else { return }
        attivo = true
        scambia(NSMenuItem.self, #selector(setter: NSMenuItem.submenu), #selector(NSMenuItem.easyF24_impostaSottomenu(_:)))
        scambia(NSApplication.self, #selector(setter: NSApplication.mainMenu), #selector(NSApplication.easyF24_impostaMenuPrincipale(_:)))
    }

    fileprivate static func trattieni(_ menu: NSMenu?) {
        guard let menu = menu else { return }
        trattenuti[ObjectIdentifier(menu)] = menu
    }

    private static func scambia(_ classe: AnyClass, _ originale: Selector, _ sostituto: Selector) {
        guard let a = class_getInstanceMethod(classe, originale), let b = class_getInstanceMethod(classe, sostituto) else { return }
        method_exchangeImplementations(a, b)
    }
}

// Dopo lo scambio questi metodi prendono il posto di quelli di AppKit:
// la chiamata a se stessi esegue l'originale.

extension NSMenuItem {
    @objc fileprivate func easyF24_impostaSottomenu(_ sottomenu: NSMenu?) {
        MenuTrattenuti.trattieni(submenu)
        MenuTrattenuti.trattieni(sottomenu)
        easyF24_impostaSottomenu(sottomenu)
    }
}

extension NSApplication {
    @objc fileprivate func easyF24_impostaMenuPrincipale(_ menu: NSMenu?) {
        MenuTrattenuti.trattieni(mainMenu)
        MenuTrattenuti.trattieni(menu)
        easyF24_impostaMenuPrincipale(menu)
    }
}
