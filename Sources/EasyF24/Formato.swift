import Foundation

/// Formattazione di date e importi all'italiana.
enum Formato {
    static let locale = Locale(identifier: "it_IT")

    private static let formatoData: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

    private static let formatoOra: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 16/11/2026
    static func data(_ data: Date) -> String {
        formatoData.string(from: data)
    }

    /// 10:32
    static func ora(_ data: Date) -> String {
        formatoOra.string(from: data)
    }

    /// 1.234,56 €
    static func euro(_ centesimi: Int) -> String {
        importo(centesimi) + " €"
    }

    /// 1.234,56 (senza simbolo, per i campi di testo).
    /// Fatto a mano perché il formato italiano di sistema non separa le migliaia sotto 10.000.
    static func importo(_ centesimi: Int) -> String {
        let assoluto = abs(centesimi)
        var cifre = String(assoluto / 100)
        var gruppi: [String] = []
        while cifre.count > 3 {
            gruppi.insert(String(cifre.suffix(3)), at: 0)
            cifre.removeLast(3)
        }
        gruppi.insert(cifre, at: 0)
        let decimali = assoluto % 100
        return (centesimi < 0 ? "-" : "") + gruppi.joined(separator: ".") + "," + (decimali < 10 ? "0" : "") + String(decimali)
    }

    /// Converte il testo scritto dall'utente in centesimi.
    /// Accetta "1234,56", "1.234,56", "1234.56", "€ 50". Restituisce nil se non è un importo valido.
    static func centesimi(da testo: String) -> Int? {
        var s = testo
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        guard !s.isEmpty else { return nil }

        if let virgola = s.lastIndex(of: ","), let punto = s.lastIndex(of: ".") {
            // Ci sono entrambi: l'ultimo dei due separa i decimali.
            if virgola > punto {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if s.contains(",") {
            s = s.replacingOccurrences(of: ",", with: ".")
        } else if s.contains(".") {
            // "1.234" o "1.234.567" → separatore delle migliaia; "12.5" → decimali.
            let parti = s.split(separator: ".", omittingEmptySubsequences: false)
            if parti.count > 2 || parti[1].count == 3 {
                s = s.replacingOccurrences(of: ".", with: "")
            }
        }

        let cifre = "0123456789"
        guard s.filter({ $0 == "." }).count <= 1,
              s.contains(where: { cifre.contains($0) }),
              s.allSatisfy({ cifre.contains($0) || $0 == "." }),
              let valore = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }

        var inCentesimi = valore * 100
        var arrotondato = Decimal()
        NSDecimalRound(&arrotondato, &inCentesimi, 0, .plain)
        return NSDecimalNumber(decimal: arrotondato).intValue
    }

    /// Giorni di calendario da `inizio` a `fine` (negativo se `fine` è prima).
    static func giorni(da inizio: Date, a fine: Date) -> Int {
        let calendario = Calendar.current
        return calendario.dateComponents([.day],
                                         from: calendario.startOfDay(for: inizio),
                                         to: calendario.startOfDay(for: fine)).day ?? 0
    }

    /// "1 giorno", "3 giorni"
    static func giorniTesto(_ numero: Int) -> String {
        numero == 1 ? "1 giorno" : "\(numero) giorni"
    }
}
