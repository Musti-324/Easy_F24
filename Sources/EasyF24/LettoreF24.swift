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

    /// Oltre questa lunghezza i testi non vengono analizzati (evita rallentamenti con email enormi).
    static let massimaLunghezzaTesto = 200_000
    static let massimaLunghezzaDescrizione = 200

    /// Un F24 per ogni PDF che sembra un modulo F24; se non ce ne sono, un F24 dall'email.
    static func moduli(messaggioId: String, oggetto: String, corpo: String, ricevutoIl: Date, pdf: [PDF]) -> [F24] {
        let letti = pdf.map { (nome: $0.nome, lettura: leggi(pdf: $0.dati)) }
        var moduli = letti.filter { sembraF24($0.lettura, nomeFile: $0.nome) }
        if moduli.isEmpty && letti.count == 1 {
            // Es. un PDF scansionato, senza testo leggibile.
            moduli = letti
        }
        let base = descrizione(oggetto: oggetto)
        if moduli.isEmpty {
            return [f24(descrizione: base, lettura: nil, oggetto: oggetto, corpo: corpo,
                        ricevutoIl: ricevutoIl, messaggioId: messaggioId)]
        }
        return moduli.map { modulo in
            let nome = (modulo.nome as NSString).deletingPathExtension
            return f24(descrizione: moduli.count > 1 ? "\(base) – \(nome)" : base,
                       lettura: modulo.lettura, oggetto: oggetto, corpo: corpo,
                       ricevutoIl: ricevutoIl, messaggioId: messaggioId)
        }
    }

    private static func f24(descrizione: String, lettura: LetturaPDF?, oggetto: String, corpo: String,
                            ricevutoIl: Date, messaggioId: String) -> F24 {
        let trovatoImporto = importo(lettura: lettura, testoEmail: oggetto + "\n" + corpo)
        let trovataScadenza = scadenza(oggetto: oggetto, corpo: corpo, testoPDF: lettura?.testoLetto, ricevutoIl: ricevutoIl)
        return F24(descrizione: descrizione,
                   importoCentesimi: trovatoImporto?.centesimi,
                   scadenza: trovataScadenza?.data ?? Calendar.current.startOfDay(for: ricevutoIl),
                   gmailMessageId: messaggioId,
                   daVerificare: trovatoImporto?.sicuro != true || trovataScadenza?.sicura != true)
    }

    // MARK: - Lettura del PDF (solo dove serve)

    /// Quello che si è letto di un PDF: solo alcune fasce delle prime pagine, mai tutto il documento.
    struct LetturaPDF {
        /// Il saldo finale del modulo; `sicuro` è false se il valore è stato trovato prima dell'etichetta.
        var saldo: (centesimi: Int, sicuro: Bool)?
        /// Il testo delle fasce lette, per cercare una data di scadenza.
        var testoLetto = ""
        /// La fascia alta della prima pagina, letta solo se il saldo non c'è, per capire se è un F24.
        var intestazione = ""
        var pagineLette = 0
        var zoneLette = 0
    }

    /// Fasce della pagina in cui cercare il saldo, in frazioni dell'altezza misurate dal basso.
    /// Nel modello F24 il "SALDO FINALE" è stampato in basso, sopra gli estremi del versamento:
    /// si parte da lì e solo se non c'è si sale alla parte centrale. Le fasce si sovrappongono un po'
    /// per non spezzare una riga sul confine. La parte alta (dati del contribuente, data di nascita)
    /// non viene mai letta per cercare il saldo.
    static let zoneSaldo: [(da: CGFloat, a: CGFloat)] = [(0.0, 0.40), (0.35, 0.75)]
    /// Fascia alta della prima pagina ("MODELLO DI PAGAMENTO UNIFICATO F24").
    static let zonaIntestazione: (da: CGFloat, a: CGFloat) = (0.75, 1.0)
    /// Limiti di sicurezza: superati questi si rinuncia (F24 "da verificare") invece di leggere tutto.
    static let massimoPagine = 3
    static let massimiCaratteriPerZona = 20_000

    /// Cerca il saldo finale partendo da dove il modello F24 lo stampa, fascia per fascia e pagina
    /// per pagina, fermandosi appena lo trova o quando finiscono le fasce e le pagine previste.
    static func leggi(pdf dati: Data) -> LetturaPDF? {
        guard dati.count <= MessaggioGmail.massimaDimensionePDF,
              let documento = PDFDocument(data: dati),
              !documento.isLocked,
              documento.pageCount > 0
        else { return nil }
        var lettura = LetturaPDF()
        for indice in 0..<min(documento.pageCount, massimoPagine) {
            guard let pagina = documento.page(at: indice) else { continue }
            lettura.pagineLette += 1
            for zona in zoneSaldo(della: pagina) {
                let testo = testo(di: pagina, in: zona)
                lettura.zoneLette += 1
                lettura.testoLetto += testo + "\n"
                if let saldo = saldoFinale(in: testo) {
                    lettura.saldo = saldo
                    return lettura
                }
            }
        }
        // Nessun saldo nelle fasce previste: ci si ferma qui. Si legge solo l'intestazione
        // della prima pagina, per capire se il PDF è comunque un F24.
        if let prima = documento.page(at: 0), prima.rotation % 360 == 0 {
            lettura.intestazione = testo(di: prima, in: fascia(zonaIntestazione, di: prima))
        }
        return lettura
    }

    /// Il valore accanto all'etichetta "SALDO FINALE": prima si guarda subito dopo l'etichetta;
    /// se lì non c'è (in alcuni PDF il valore è scritto prima, cioè lo si è già superato) si torna
    /// indietro di poco. Il valore trovato all'indietro è meno sicuro.
    static func saldoFinale(in testo: String) -> (centesimi: Int, sicuro: Bool)? {
        let ns = testo as NSString
        guard let etichetta = corrispondenze(#"saldo\s+finale"#, in: testo).first?.range else { return nil }
        let fine = NSMaxRange(etichetta)
        let dopo = ns.substring(with: NSRange(location: fine, length: min(200, ns.length - fine)))
        if let primo = importi(in: dopo).first {
            return (primo.centesimi, true)
        }
        let inizio = max(0, etichetta.location - 120)
        let prima = ns.substring(with: NSRange(location: inizio, length: etichetta.location - inizio))
        if let ultimo = importi(in: prima).last {
            return (ultimo.centesimi, false)
        }
        return nil
    }

    private static func zoneSaldo(della pagina: PDFPage) -> [CGRect] {
        // Pagina ruotata (es. scansione in orizzontale): le fasce non corrispondono più,
        // si legge la pagina intera, sempre con il limite di caratteri.
        guard pagina.rotation % 360 == 0 else { return [pagina.bounds(for: .cropBox)] }
        return zoneSaldo.map { fascia($0, di: pagina) }
    }

    private static func fascia(_ zona: (da: CGFloat, a: CGFloat), di pagina: PDFPage) -> CGRect {
        let bordi = pagina.bounds(for: .cropBox)
        return CGRect(x: bordi.minX, y: bordi.minY + bordi.height * zona.da,
                      width: bordi.width, height: bordi.height * (zona.a - zona.da))
    }

    private static func testo(di pagina: PDFPage, in zona: CGRect) -> String {
        String((pagina.selection(for: zona)?.string ?? "").prefix(massimiCaratteriPerZona))
    }

    static func sembraF24(_ lettura: LetturaPDF?, nomeFile: String) -> Bool {
        if nomeFile.lowercased().contains("f24") || lettura?.saldo != nil {
            return true
        }
        guard let lettura = lettura else { return false }
        let testo = (lettura.intestazione + "\n" + lettura.testoLetto).lowercased()
        return testo.contains("f24") || testo.contains("saldo finale") || testo.contains("delega irrevocabile")
    }

    /// L'oggetto senza "R:", "I:", "Fwd:" davanti.
    static func descrizione(oggetto: String) -> String {
        let pulito = sostituisci(#"^\s*((re|r|i|fw|fwd|inoltro)\s*:\s*)+"#, in: oggetto, con: "")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pulito.isEmpty ? "F24 da Gmail" : String(pulito.prefix(massimaLunghezzaDescrizione))
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
    /// infine (senza certezza) l'importo più alto tra le fasce del PDF già lette.
    static func importo(lettura: LetturaPDF?, testoEmail: String) -> (centesimi: Int, sicuro: Bool)? {
        if let saldo = lettura?.saldo, saldo.sicuro {
            return saldo
        }
        let email = testoEmail as NSString
        for trovato in importi(in: testoEmail) {
            let intorno = contesto(email, trovato.posizione, prima: 15, dopo: 8).lowercased()
            if intorno.contains("€") || intorno.contains("euro") {
                return (trovato.centesimi, true)
            }
        }
        if let saldo = lettura?.saldo {
            return saldo
        }
        if let letto = lettura?.testoLetto, let massimo = importi(in: letto).map({ $0.centesimi }).max(), massimo > 0 {
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
