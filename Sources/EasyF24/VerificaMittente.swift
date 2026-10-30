import Foundation

/// Controlli contro le email false: il campo "Da" di un'email si può falsificare,
/// quindi si guarda l'indirizzo vero (non il nome visualizzato) e l'esito delle
/// verifiche SPF, DKIM e DMARC che Gmail fa quando l'email arriva.
enum VerificaMittente {
    /// "Studio Bianchi <studio@bianchi.it>" → "studio@bianchi.it".
    static func indirizzo(_ intestazioneDa: String) -> String {
        if let apertura = intestazioneDa.lastIndex(of: "<"),
           let chiusura = intestazioneDa.lastIndex(of: ">"), apertura < chiusura {
            return String(intestazioneDa[intestazioneDa.index(after: apertura)..<chiusura])
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return intestazioneDa.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True se Gmail ha verificato che l'email viene davvero dal dominio di `email`
    /// (DMARC superato, oppure firma DKIM o SPF validi e dello stesso dominio).
    ///
    /// Vale solo la prima intestazione "Authentication-Results", quella aggiunta da Gmail
    /// all'arrivo: eventuali altre più in basso possono essere state scritte dal mittente.
    static func autenticato(_ intestazioniAutenticazione: [String], email: String) -> Bool {
        guard let dominio = dominio(di: email), let prima = intestazioniAutenticazione.first else { return false }
        let senzaCommenti = prima.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        let clausole = senzaCommenti.lowercased().split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard clausole.first == "mx.google.com" else { return false }

        for clausola in clausole.dropFirst() {
            let parole = clausola.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
            guard let esito = parole.first else { continue }
            var proprieta: [String: String] = [:]
            for parola in parole.dropFirst() {
                let parti = parola.split(separator: "=", maxSplits: 1).map(String.init)
                if parti.count == 2 && proprieta[parti[0]] == nil {
                    proprieta[parti[0]] = parti[1]
                }
            }
            switch esito {
            case "dmarc=pass":
                if allineato(proprieta["header.from"], dominio) { return true }
            case "dkim=pass":
                if allineato(proprieta["header.d"] ?? self.dominio(di: proprieta["header.i"] ?? ""), dominio) { return true }
            case "spf=pass":
                if allineato(self.dominio(di: proprieta["smtp.mailfrom"] ?? ""), dominio) { return true }
            default:
                break
            }
        }
        return false
    }

    /// "studio@bianchi.it", "@bianchi.it" o "bianchi.it" → "bianchi.it".
    static func dominio(di testo: String) -> String? {
        let dominio = (testo.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " <>\"")).lowercased()
        return dominio.contains(".") ? dominio : nil
    }

    /// Stesso dominio, o uno sottodominio dell'altro (come fa DMARC).
    private static func allineato(_ verificato: String?, _ atteso: String) -> Bool {
        guard let verificato = verificato?.lowercased(), !verificato.isEmpty else { return false }
        return verificato == atteso || verificato.hasSuffix("." + atteso) || atteso.hasSuffix("." + verificato)
    }
}
