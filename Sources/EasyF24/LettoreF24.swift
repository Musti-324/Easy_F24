import Foundation
import PDFKit

/// Ricava descrizione, importo e scadenza degli F24 da un'email del commercialista
/// (oggetto, testo e PDF allegati). È un'euristica: quando non trova i dati con
/// sicurezza, l'F24 viene segnato "da verificare".
enum LettoreF24 {
    struct PDF {
        let nome: String
        let dati: Data
    }

    /// Un F24 per ogni PDF che sembra un modulo F24; se non ce ne sono, un F24 dall'email.
    static func moduli(messaggioId: String, oggetto: String, corpo: String, ricevutoIl: Date, pdf: [PDF]) -> [F24] {
        let conTesto = pdf.map { (nome: $0.nome, testo: testo(pdf: $0.dati)) }
        var moduli = conTesto.filter { sembraF24(testo: $0.testo, nomeFile: $0.nome) }
        if moduli.isEmpty && conTesto.count == 1 {
            // Es. un PDF scansionato, senza testo leggibile.
            moduli = conTesto
        }
        let base = descrizione(oggetto: oggetto)
        if moduli.isEmpty {
            return [f24(descrizione: base, testoPDF: nil, oggetto: oggetto, corpo: corpo,
                        ricevutoIl: ricevutoIl, messaggioId: messaggioId)]
        }
        return moduli.map { modulo in
            let nome = (modulo.nome as NSString).deletingPathExtension
            return f24(descrizione: moduli.count > 1 ? "\(base) – \(nome)" : base,
                       testoPDF: modulo.testo, oggetto: oggetto, corpo: corpo,
                       ricevutoIl: ricevutoIl, messaggioId: messaggioId)
        }
    }

    private static func f24(descrizione: String, testoPDF: String?, oggetto: String, corpo: String,
                            ricevutoIl: Date, messaggioId: String) -> F24 {
        let trovatoImporto = importo(testoPDF: testoPDF, testoEmail: oggetto + "\n" + corpo)
        let trovataScadenza = scadenza(oggetto: oggetto, corpo: corpo, testoPDF: testoPDF, ricevutoIl: ricevutoIl)
        return F24(descrizione: descrizione,
                   importoCentesimi: trovatoImporto?.centesimi,
                   scadenza: trovataScadenza?.data ?? Calendar.current.startOfDay(for: ricevutoIl),
                   gmailMessageId: messaggioId,
                   daVerificare: trovatoImporto?.sicuro != true || trovataScadenza?.sicura != true)
    }

    // MARK: - Testi

    static func testo(pdf dati: Data) -> String? {
        guard let testo = PDFDocument(data: dati)?.string,
              !testo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return testo
    }

    static func sembraF24(testo: String?, nomeFile: String) -> Bool {
        if nomeFile.lowercased().contains("f24") {
            return true
        }
        guard let testo = testo?.lowercased() else { return false }
        return testo.contains("f24") || testo.contains("saldo finale") || testo.contains("delega irrevocabile")
    }

    /// L'oggetto senza "R:", "I:", "Fwd:" davanti.
    static func descrizione(oggetto: String) -> String {
        let pulito = sostituisci(#"^\s*((re|r|i|fw|fwd|inoltro)\s*:\s*)+"#, in: oggetto, con: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pulito.isEmpty ? "F24 da Gmail" : pulito
    }

    static func togliHTML(_ html: String) -> String {
        var testo = sostituisci(#"(?s)<(style|script)[^>]*>.*?</\1>"#, in: html, con: " ")
        testo = sostituisci(#"<br\s*/?>|</p>|</div>|</tr>|</li>"#, in: testo, con: "\n")
        testo = sostituisci("<[^>]+>", in: testo, con: " ")
        let entita = ["&nbsp;": " ", "&euro;": "€", "&#8364;": "€", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                      "&#39;": "'", "&agrave;": "à", "&egrave;": "è", "&eacute;": "é", "&igrave;": "ì",
                      "&ograve;": "ò", "&ugrave;": "ù", "&amp;": "&"]
        for (codice, carattere) in entita {
            testo = testo.replacingOccurrences(of: codice, with: carattere)
        }
        return sostituisci("[ \t]+", in: testo, con: " ")
    }

    // MARK: - Importo

    private static let schemaImporto = #"(?<![\d.,])(?:\d{1,3}(?:\.\d{3})+|\d+),\d{2}(?![\d,])"#

    /// Cerca prima il "SALDO FINALE" del modulo, poi un importo in euro nell'email,
    /// infine (senza certezza) l'importo più alto del PDF.
    static func importo(testoPDF: String?, testoEmail: String) -> (centesimi: Int, sicuro: Bool)? {
        if let pdf = testoPDF {
            let testo = pdf as NSString
            let etichetta = testo.range(of: "saldo finale", options: .caseInsensitive)
            if etichetta.location != NSNotFound {
                let dopo = String(testo.substring(from: NSMaxRange(etichetta)).prefix(300))
                if let primo = importi(in: dopo).first {
                    return (primo.centesimi, true)
                }
            }
        }
        let email = testoEmail as NSString
        for trovato in importi(in: testoEmail) {
            let intorno = contesto(email, trovato.posizione, prima: 15, dopo: 8).lowercased()
            if intorno.contains("€") || intorno.contains("euro") {
                return (trovato.centesimi, true)
            }
        }
        if let pdf = testoPDF, let massimo = importi(in: pdf).map({ $0.centesimi }).max(), massimo > 0 {
            return (massimo, false)
        }
        return nil
    }

    static func importi(in testo: String) -> [(centesimi: Int, posizione: NSRange)] {
        let ns = testo as NSString
        return corrispondenze(schemaImporto, in: testo).compactMap { trovato in
            Formato.centesimi(da: ns.substring(with: trovato.range)).map { (centesimi: $0, posizione: trovato.range) }
        }
    }

    // MARK: - Scadenza

    private static let mesi = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio",
                               "agosto", "settembre", "ottobre", "novembre", "dicembre"]
    private static let paroleScadenza = ["scad", "entro", "pagar", "pagament", "versament", "termine"]

    /// Una data preceduta da "scadenza", "entro", "da pagare"… nell'oggetto o nel testo
    /// dell'email (sicura) o nel PDF (da verificare); altrimenti la prima data futura dell'email.
    static func scadenza(oggetto: String, corpo: String, testoPDF: String?, ricevutoIl: Date) -> (data: Date, sicura: Bool)? {
        let fonti: [(testo: String, sicura: Bool)] = [(oggetto, true), (corpo, true), (testoPDF ?? "", false)]
        for fonte in fonti {
            let ns = fonte.testo as NSString
            for trovata in date(in: fonte.testo) {
                let prima = contesto(ns, NSRange(location: trovata.posizione.location, length: 0), prima: 40, dopo: 0).lowercased()
                if paroleScadenza.contains(where: { prima.contains($0) }) {
                    return (trovata.data, fonte.sicura)
                }
            }
        }
        let giorno = Calendar.current.startOfDay(for: ricevutoIl)
        for testo in [oggetto, corpo] {
            if let futura = date(in: testo).first(where: { $0.data >= giorno }) {
                return (futura.data, false)
            }
        }
        return nil
    }

    /// Date come 16/11/2026, 16-11-26, 16.11.2026 o 16 novembre 2026, nell'ordine in cui compaiono.
    static func date(in testo: String) -> [(data: Date, posizione: NSRange)] {
        let ns = testo as NSString
        var trovate: [(data: Date, posizione: NSRange)] = []
        for trovato in corrispondenze(#"(?<!\d)(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4}|\d{2})(?!\d)"#, in: testo) {
            let anno = Int(ns.substring(with: trovato.range(at: 3))) ?? 0
            if let data = data(giorno: Int(ns.substring(with: trovato.range(at: 1))) ?? 0,
                               mese: Int(ns.substring(with: trovato.range(at: 2))) ?? 0,
                               anno: anno < 100 ? anno + 2000 : anno) {
                trovate.append((data: data, posizione: trovato.range))
            }
        }
        let schemaMesi = #"(?<!\d)(\d{1,2})\s+("# + mesi.joined(separator: "|") + #")\s+(\d{4})"#
        for trovato in corrispondenze(schemaMesi, in: testo) {
            let mese = (mesi.firstIndex(of: ns.substring(with: trovato.range(at: 2)).lowercased()) ?? -1) + 1
            if let data = data(giorno: Int(ns.substring(with: trovato.range(at: 1))) ?? 0,
                               mese: mese,
                               anno: Int(ns.substring(with: trovato.range(at: 3))) ?? 0) {
                trovate.append((data: data, posizione: trovato.range))
            }
        }
        return trovate.sorted { $0.posizione.location < $1.posizione.location }
    }

    private static func data(giorno: Int, mese: Int, anno: Int) -> Date? {
        guard (1...31).contains(giorno), (1...12).contains(mese), (2000...2100).contains(anno) else { return nil }
        var componenti = DateComponents()
        componenti.year = anno
        componenti.month = mese
        componenti.day = giorno
        let calendario = Calendar.current
        // Scarta date impossibili come il 31/02.
        guard let data = calendario.date(from: componenti), calendario.component(.day, from: data) == giorno else { return nil }
        return data
    }

    // MARK: - Espressioni regolari

    private static func corrispondenze(_ schema: String, in testo: String) -> [NSTextCheckingResult] {
        guard let espressione = try? NSRegularExpression(pattern: schema, options: [.caseInsensitive]) else { return [] }
        return espressione.matches(in: testo, range: NSRange(location: 0, length: (testo as NSString).length))
    }

    private static func sostituisci(_ schema: String, in testo: String, con sostituto: String) -> String {
        guard let espressione = try? NSRegularExpression(pattern: schema, options: [.caseInsensitive]) else { return testo }
        return espressione.stringByReplacingMatches(in: testo, range: NSRange(location: 0, length: (testo as NSString).length),
                                                    withTemplate: sostituto)
    }

    private static func contesto(_ testo: NSString, _ posizione: NSRange, prima: Int, dopo: Int) -> String {
        let inizio = max(0, posizione.location - prima)
        let fine = min(testo.length, NSMaxRange(posizione) + dopo)
        return testo.substring(with: NSRange(location: inizio, length: fine - inizio))
    }
}
