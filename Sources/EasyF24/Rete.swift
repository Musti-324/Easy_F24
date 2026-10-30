import Foundation

/// Connessione verso Google senza cache su disco né cookie: email, allegati
/// e token non restano salvati nella cartella Cache dell'app.
/// (Le connessioni sono sempre HTTPS: macOS impone almeno TLS 1.2.)
enum Rete {
    static var sessione: URLSession = URLSession(configuration: configurazione())

    static func configurazione() -> URLSessionConfiguration {
        let configurazione = URLSessionConfiguration.ephemeral
        configurazione.urlCache = nil
        configurazione.requestCachePolicy = .reloadIgnoringLocalCacheData
        configurazione.httpCookieStorage = nil
        configurazione.httpShouldSetCookies = false
        configurazione.timeoutIntervalForRequest = 30
        return configurazione
    }
}
