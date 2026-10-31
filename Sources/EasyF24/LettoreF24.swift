import AppKit
import Foundation
import PDFKit
import Vision

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

    /// Un F24 letto da un'email, con importo e scadenza come sono stati trovati (nil = non trovati).
    struct Letto {
        let f24: F24
        let importo: (centesimi: Int, sicuro: Bool)?
        let scadenza: (data: Date, sicura: Bool)?
    }

    /// Un F24 per ogni PDF che sembra un modulo F24; se non ce ne sono, un F24 dall'email.
    static func moduli(messaggioId: String, oggetto: String, corpo: String, ricevutoIl: Date, pdf: [PDF]) -> [F24] {
        letti(messaggioId: messaggioId, oggetto: oggetto, corpo: corpo, ricevutoIl: ricevutoIl, pdf: pdf).map { $0.f24 }
    }

    static func letti(messaggioId: String, oggetto: String, corpo: String, ricevutoIl: Date, pdf: [PDF]) -> [Letto] {
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
                            ricevutoIl: Date, messaggioId: String) -> Letto {
        let trovatoImporto = importo(testoPDF: testoPDF, testoEmail: oggetto + "\n" + corpo)
        let trovataScadenza = scadenza(oggetto: oggetto, corpo: corpo, testoPDF: testoPDF, ricevutoIl: ricevutoIl)
        let f24 = F24(descrizione: descrizione,
                      importoCentesimi: trovatoImporto?.centesimi,
                      scadenza: trovataScadenza?.data ?? Calendar.current.startOfDay(for: ricevutoIl),
                      gmailMessageId: messaggioId,
                      daVerificare: trovatoImporto?.sicuro != true || trovataScadenza?.sicura != true)
        return Letto(f24: f24, importo: trovatoImporto, scadenza: trovataScadenza)
    }

    // MARK: - Testi

    /// Il testo di un PDF da cui cercare importo e scadenza: il testo delle pagine, i valori dei
    /// campi compilabili del modulo e, se così non si trova il saldo (PDF scansionato o con il testo
    /// disegnato come immagine), il testo riconosciuto con l'OCR di macOS.
    static func testo(pdf dati: Data) -> String? {
        guard dati.count <= MessaggioGmail.massimaDimensionePDF,
              let documento = PDFDocument(data: dati),
              !documento.isLocked
        else { return nil }
        var testo = String((documento.string ?? "").prefix(massimaLunghezzaTesto))
        let campi = testoCampi(documento)
        if !campi.isEmpty {
            testo += "\n" + campi
        }
        if saldoFinale(in: testo) == nil {
            let riconosciuto = testoOCR(documento)
            if !riconosciuto.isEmpty {
                testo += "\n" + riconosciuto
            }
        }
        return testo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : testo
    }

    /// Pagine lette con l'OCR (è lento: si fa solo sulle prime) e campi del modulo considerati.
    static let massimePagineOCR = 2
    static let massimePagineCampi = 3

    /// I campi compilabili del modulo come righe "nome campo: valore" (es. "Saldo Finale: 264,00"):
    /// i loro valori non fanno parte del testo della pagina.
    static func testoCampi(_ documento: PDFDocument) -> String {
        var righe: [String] = []
        for indice in 0..<min(documento.pageCount, massimePagineCampi) {
            for annotazione in documento.page(at: indice)?.annotations ?? [] {
                let valore = (annotazione.widgetStringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !valore.isEmpty else { continue }
                righe.append(nomeLeggibile(annotazione.fieldName ?? "") + ": " + valore)
            }
        }
        return righe.joined(separator: "\n")
    }

    /// "SaldoFinale", "saldo_finale" → "Saldo Finale", "saldo finale".
    static func nomeLeggibile(_ nome: String) -> String {
        let separato = sostituisci("([a-z])([A-Z])", in: nome, con: "$1 $2", maiuscoleMinuscole: true)
        return sostituisci("[_.\\-]+", in: separato, con: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Testo riconosciuto dalle immagini delle prime pagine (Vision, sul Mac: nessun servizio esterno).
    /// Le parole sulla stessa riga del modulo restano vicine, es. "SALDO FINALE EURO + 264,00".
    static func testoOCR(_ documento: PDFDocument) -> String {
        var testo: [String] = []
        for indice in 0..<min(documento.pageCount, massimePagineOCR) {
            guard let pagina = documento.page(at: indice), let immagine = immagine(di: pagina) else { continue }
            let richiesta = VNRecognizeTextRequest()
            richiesta.recognitionLevel = .accurate
            richiesta.usesLanguageCorrection = false
            if let supportate = try? VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate, revision: richiesta.revision) {
                let lingue = ["it-IT", "en-US"].filter { supportate.contains($0) }
                if !lingue.isEmpty {
                    richiesta.recognitionLanguages = lingue
                }
            }
            try? VNImageRequestHandler(cgImage: immagine, options: [:]).perform([richiesta])
            // Con gli SDK recenti i risultati hanno già il tipo giusto, con quello di Big Sur no.
            let risultati: [Any] = richiesta.results ?? []
            let pezzi = risultati.compactMap { risultato -> (riquadro: CGRect, testo: String)? in
                guard let osservazione = risultato as? VNRecognizedTextObservation,
                      let candidato = osservazione.topCandidates(1).first else { return nil }
                return (osservazione.boundingBox, candidato.string)
            }
            testo += righe(da: pezzi)
        }
        return testo.joined(separator: "\n")
    }

    /// Mette insieme i pezzi riconosciuti che stanno alla stessa altezza, dall'alto in basso.
    private static func righe(da pezzi: [(riquadro: CGRect, testo: String)]) -> [String] {
        let ordinati = pezzi.sorted { $0.riquadro.midY > $1.riquadro.midY }
        var righe: [[(riquadro: CGRect, testo: String)]] = []
        for pezzo in ordinati {
            if let ultima = righe.last?.first, abs(ultima.riquadro.midY - pezzo.riquadro.midY) < max(ultima.riquadro.height, pezzo.riquadro.height) * 0.6 {
                righe[righe.count - 1].append(pezzo)
            } else {
                righe.append([pezzo])
            }
        }
        return righe.map { riga in riga.sorted { $0.riquadro.minX < $1.riquadro.minX }.map { $0.testo }.joined(separator: " ") }
    }

    /// Immagine della pagina a circa 180 dpi, abbastanza per le scritte piccole del modulo.
    private static func immagine(di pagina: PDFPage) -> CGImage? {
        let bordi = pagina.bounds(for: .mediaBox)
        let scala: CGFloat = 2.5
        let miniatura = pagina.thumbnail(of: NSSize(width: bordi.width * scala, height: bordi.height * scala), for: .mediaBox)
        var rettangolo = CGRect(origin: .zero, size: miniatura.size)
        return miniatura.cgImage(forProposedRect: &rettangolo, context: nil, hints: nil)
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

    /// Etichette del totale da pagare, dalla più affidabile.
    private static let etichetteTotale = ["saldo finale", "totale da versare", "importo da versare", "totale da pagare",
                                          "importo da pagare", "totale versamento", "totale delega", "importo totale"]

    /// Il totale scritto accanto a "SALDO FINALE" (o a un'altra etichetta del totale): prima subito dopo
    /// l'etichetta; se lì non c'è, poco prima (in quel caso è meno sicuro).
    static func saldoFinale(in testo: String) -> (centesimi: Int, sicuro: Bool)? {
        let ns = testo as NSString
        for etichetta in etichetteTotale {
            let schema = etichetta.split(separator: " ").joined(separator: #"\s+"#)
            for trovata in corrispondenze(schema, in: testo) {
                let fine = NSMaxRange(trovata.range)
                if let valore = primoImporto(in: ns.substring(with: NSRange(location: fine, length: min(200, ns.length - fine)))) {
                    return (valore, true)
                }
                let inizio = max(0, trovata.range.location - 120)
                if let valore = importi(in: ns.substring(with: NSRange(location: inizio, length: trovata.range.location - inizio))).last {
                    return (valore.centesimi, false)
                }
            }
        }
        return nil
    }

    /// Il primo importo in un tratto breve di testo, scritto come "1.234,56", "1234.56" oppure, come
    /// nel modulo F24, con i centesimi in una casella separata ("1.234 56").
    static func primoImporto(in testo: String) -> Int? {
        let ns = testo as NSString
        var candidati = importi(in: testo).map { (posizione: $0.posizione.location, centesimi: $0.centesimi) }
        for trovato in corrispondenze(#"(?<![\d.,])(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}(?![\d.,])"#, in: testo) {
            if let centesimi = Formato.centesimi(da: ns.substring(with: trovato.range)) {
                candidati.append((posizione: trovato.range.location, centesimi: centesimi))
            }
        }
        for trovato in corrispondenze(#"(?<![\d.,])(\d{1,3}(?:\.\d{3})+|\d+)[ \t]+(\d{2})(?!\d)(?![ \t]*\d)"#, in: testo) {
            let euro = ns.substring(with: trovato.range(at: 1))
            let centesimi = ns.substring(with: trovato.range(at: 2))
            if let valore = Formato.centesimi(da: euro + "," + centesimi) {
                candidati.append((posizione: trovato.range.location, centesimi: valore))
            }
        }
        return candidati.min { $0.posizione < $1.posizione }?.centesimi
    }

    /// Cerca prima il totale del modulo nel PDF, poi un importo in euro nell'email,
    /// infine (senza certezza) l'importo più alto del PDF.
    static func importo(testoPDF: String?, testoEmail: String) -> (centesimi: Int, sicuro: Bool)? {
        if let pdf = testoPDF, let saldo = saldoFinale(in: pdf) {
            return saldo
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
    /// Parole che indicano una data di nascita, da non scambiare per la scadenza.
    private static let paroleNascita = ["nascita", "nato", "nata"]

    /// Una data preceduta da "scadenza", "entro", "da pagare"… cercata prima nel PDF (con più rate
    /// ogni modulo ha la sua scadenza, mentre l'email può citarne una sola), poi nell'oggetto e nel
    /// testo dell'email; poi la "DATA" degli estremi del versamento del modulo (da verificare);
    /// altrimenti la prima data futura dell'email (da verificare).
    static func scadenza(oggetto: String, corpo: String, testoPDF: String?, ricevutoIl: Date) -> (data: Date, sicura: Bool)? {
        for testo in [testoPDF ?? "", oggetto, corpo] {
            let ns = testo as NSString
            for trovata in date(in: testo) {
                let prima = contesto(ns, NSRange(location: trovata.posizione.location, length: 0), prima: 40, dopo: 0).lowercased()
                // "ESTREMI DEL VERSAMENTO … DATA" è la data in cui si paga allo sportello: vale solo come ripiego.
                if paroleScadenza.contains(where: { prima.contains($0) }) && !paroleNascita.contains(where: { prima.contains($0) })
                    && !prima.contains("estremi") {
                    return (trovata.data, true)
                }
            }
        }
        if let pdf = testoPDF {
            let ns = pdf as NSString
            for trovata in date(in: pdf) {
                let prima = contesto(ns, NSRange(location: trovata.posizione.location, length: 0), prima: 15, dopo: 0).lowercased()
                if prima.contains("data") && !paroleNascita.contains(where: { prima.contains($0) }) {
                    return (trovata.data, false)
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
        // Come nelle caselle del modulo F24: "16 11 2026" oppure "16112026".
        for schema in [#"(?<!\d)(\d{1,2})[ \t]+(\d{1,2})[ \t]+(20\d{2})(?!\d)"#, #"(?<!\d)(\d{2})(\d{2})(20\d{2})(?!\d)"#] {
            for trovato in corrispondenze(schema, in: testo) {
                if let data = data(giorno: Int(ns.substring(with: trovato.range(at: 1))) ?? 0,
                                   mese: Int(ns.substring(with: trovato.range(at: 2))) ?? 0,
                                   anno: Int(ns.substring(with: trovato.range(at: 3))) ?? 0) {
                    trovate.append((data: data, posizione: trovato.range))
                }
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

    private static func sostituisci(_ schema: String, in testo: String, con sostituto: String, maiuscoleMinuscole: Bool = false) -> String {
        guard let espressione = try? NSRegularExpression(pattern: schema, options: maiuscoleMinuscole ? [] : [.caseInsensitive]) else { return testo }
        return espressione.stringByReplacingMatches(in: testo, range: NSRange(location: 0, length: (testo as NSString).length),
                                                    withTemplate: sostituto)
    }

    private static func contesto(_ testo: NSString, _ posizione: NSRange, prima: Int, dopo: Int) -> String {
        let inizio = max(0, posizione.location - prima)
        let fine = min(testo.length, NSMaxRange(posizione) + dopo)
        return testo.substring(with: NSRange(location: inizio, length: fine - inizio))
    }
}
