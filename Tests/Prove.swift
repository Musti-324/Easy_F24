// Prove automatiche di Easy F24 (lettura F24, Gmail simulato, sicurezza, accesso Google).
// Si eseguono con ./scripts/test.sh: nessuna connessione a Gmail vera.
import AppKit
import Foundation
import PDFKit

var falliti = 0
var superati = 0
func verifica(_ condizione: Bool, _ descrizione: String) {
    print(condizione ? "ok  " : "ERR ", descrizione)
    if condizione { superati += 1 } else { falliti += 1 }
}
func attendi(_ secondi: Double = 0.3, finché condizione: () -> Bool) {
    let limite = Date().addingTimeInterval(10)
    while condizione() && Date() < limite { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.current.run(until: Date().addingTimeInterval(secondi))
}
let cartella = CommandLine.arguments[1]
let cal = Calendar.current
func giorno(_ g: Int, _ m: Int, _ a: Int) -> Date { cal.date(from: DateComponents(year: a, month: m, day: g))! }

/// PDF con testo, come quelli dei programmi del commercialista.
func pdf(_ righe: [String]) -> Data {
    let dati = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(consumer: CGDataConsumer(data: dati as CFMutableData)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (i, riga) in righe.enumerated() {
        (riga as NSString).draw(at: NSPoint(x: 40, y: 800 - i * 20), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
    }
    ctx.endPDFPage()
    ctx.closePDF()
    return dati as Data
}
let pdfIMU = pdf(["MODELLO DI PAGAMENTO UNIFICATO F24", "CONTRIBUENTE  ROSSI MARIO  nato il 03/04/1970",
                  "SEZIONE IMU  3918  2026  625,00", "SALDO FINALE  EURO  1.250,00"])
let pdfINPS = pdf(["F24 - DELEGA IRREVOCABILE", "INPS  CXX  482,30", "SALDO FINALE 482,30"])
let pdfIVA = pdf(["F24", "ERARIO 6031 2026 2.150,75", "SALDO FINALE 2.150,75"])
let pdfLettera = pdf(["Gentile cliente, in allegato i modelli."])

// MARK: - Lettura di importo e scadenza

print("— Lettura di importo e scadenza")
verifica(LettoreF24.testo(pdf: pdfIMU)?.contains("SALDO FINALE") == true, "PDFKit legge il testo del PDF")
let imu = LettoreF24.moduli(messaggioId: "m1", oggetto: "R: MOD. F24 saldo IMU - scadenza 16/12/2026", corpo: "Buongiorno, in allegato.",
                            ricevutoIl: giorno(28, 10, 2026), pdf: [.init(nome: "F24_IMU.pdf", dati: pdfIMU)])
verifica(imu.count == 1 && imu[0].importoCentesimi == 125000, "importo dal SALDO FINALE: 1.250,00")
verifica(imu[0].scadenza == giorno(16, 12, 2026), "scadenza dall'oggetto (non la data di nascita del PDF)")
verifica(imu[0].descrizione == "MOD. F24 saldo IMU - scadenza 16/12/2026", "descrizione senza «R:»")
verifica(imu[0].daVerificare == false && imu[0].gmailMessageId == "m1", "dati sicuri, non da verificare")
let corpo = LettoreF24.moduli(messaggioId: "m2", oggetto: "Deleghe", corpo: "Le invio il modello da pagare entro il 16 novembre 2026, importo € 310,00.",
                              ricevutoIl: giorno(28, 10, 2026), pdf: [])
verifica(corpo.count == 1 && corpo[0].importoCentesimi == 31000 && corpo[0].scadenza == giorno(16, 11, 2026) && !corpo[0].daVerificare,
         "senza PDF: importo e data scritta a parole dal testo dell'email")
let ignoto = LettoreF24.moduli(messaggioId: "m3", oggetto: "F24", corpo: "In allegato.", ricevutoIl: giorno(28, 10, 2026), pdf: [])
verifica(ignoto[0].daVerificare && ignoto[0].importoCentesimi == nil && ignoto[0].scadenza == giorno(28, 10, 2026),
         "dati non trovati: segnato da verificare, scadenza = giorno di arrivo")
let due = LettoreF24.moduli(messaggioId: "m4", oggetto: "MOD. F24 scad. 16.11.26", corpo: "", ricevutoIl: giorno(28, 10, 2026),
                            pdf: [.init(nome: "lettera.pdf", dati: pdfLettera), .init(nome: "INPS.pdf", dati: pdfINPS), .init(nome: "IVA.pdf", dati: pdfIVA)])
verifica(due.map { $0.importoCentesimi ?? 0 } == [48230, 215075], "un F24 per ogni PDF-modulo, la lettera è ignorata")
verifica(due.map { $0.descrizione } == ["MOD. F24 scad. 16.11.26 – INPS", "MOD. F24 scad. 16.11.26 – IVA"], "descrizioni con il nome del file")
verifica(due.allSatisfy { $0.scadenza == giorno(16, 11, 2026) }, "data con anno a due cifre")
let html = LettoreF24.togliHTML("<p>Totale&nbsp;<b>&euro; 1.000,00</b></p><style>p{}</style>")
verifica(LettoreF24.importo(testoPDF: nil, testoEmail: html)?.centesimi == 100000, "email in HTML")

// MARK: - Gmail simulato

print("— Gmail simulato")
final class GmailFinto: URLProtocol {
    static var messaggi: [[String: Any]] = []
    static var query: [String] = []
    static var refreshScaduto = false
    /// Indirizzi chiesti a Gmail, per controllare che non si scarichi più del necessario.
    static var richieste: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("googleapis.com") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        GmailFinto.richieste.append(url.path)
        var json: Any = [:]
        var codice = 200
        if url.host == "oauth2.googleapis.com" {
            json = GmailFinto.refreshScaduto ? ["error": "invalid_grant"] as [String: Any] : ["access_token": "tok", "expires_in": 3600] as [String: Any]
            if GmailFinto.refreshScaduto { codice = 400 }
        } else if request.value(forHTTPHeaderField: "Authorization") != "Bearer tok" {
            codice = 401
        } else if url.path.hasSuffix("/profile") {
            json = ["emailAddress": "diego@gmail.com"]
        } else if url.path.hasSuffix("/messages") {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
            GmailFinto.query.append(q)
            let dopo = q.components(separatedBy: "after:").dropFirst().first.flatMap { Int64($0) } ?? 0
            let trovati = GmailFinto.messaggi.filter { Int64($0["internalDate"] as! String)! / 1000 > dopo }
                .sorted { ($0["internalDate"] as! String) > ($1["internalDate"] as! String) }
            json = ["messages": trovati.map { ["id": $0["id"]!] }]
        } else if url.path.contains("/attachments/") {
            let dati = ["att-imu": pdfIMU, "att-inps": pdfINPS, "att-iva": pdfIVA][url.lastPathComponent]!
            json = ["data": dati.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")]
        } else {
            if let trovato = GmailFinto.messaggi.first(where: { $0["id"] as? String == url.lastPathComponent }) {
                json = trovato
            } else {
                codice = 404
                json = ["error": ["message": "Requested entity was not found."]]
            }
        }
        let corpo = try! JSONSerialization.data(withJSONObject: json)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: codice, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: corpo)
        client?.urlProtocolDidFinishLoading(self)
    }
}
func b64(_ s: String) -> String {
    Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
}
let autentico = "mx.google.com;\r\n       dkim=pass header.i=@bianchi.it header.s=s1 header.b=AbC;\r\n       spf=pass (google.com: domain of studio@bianchi.it designates 1.2.3.4 as permitted sender) smtp.mailfrom=studio@bianchi.it;\r\n       dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=bianchi.it"
func messaggio(_ id: String, _ data: Date, da: String, oggetto: String, testo: String, allegati: [(String, String)],
               autenticazione: [String] = [autentico], dimensione: Int = 1000) -> [String: Any] {
    var parti: [[String: Any]] = [["mimeType": "text/plain", "filename": "", "body": ["data": b64(testo)]]]
    for (nome, att) in allegati {
        parti.append(["mimeType": "application/pdf", "filename": nome, "body": ["attachmentId": att, "size": dimensione]])
    }
    let intestazioni = autenticazione.map { ["name": "Authentication-Results", "value": $0] }
        + [["name": "Subject", "value": oggetto], ["name": "From", "value": da]]
    return ["id": id, "internalDate": String(Int64(data.timeIntervalSince1970 * 1000) + 123), "snippet": testo,
            "payload": ["mimeType": "multipart/mixed", "headers": intestazioni, "parts": parti]]
}
func decodifica(_ dizionario: [String: Any]) -> MessaggioGmail {
    try! JSONDecoder().decode(MessaggioGmail.self, from: JSONSerialization.data(withJSONObject: dizionario))
}
let configurazione = Rete.configurazione()
configurazione.protocolClasses = [GmailFinto.self]
Rete.sessione = URLSession(configuration: configurazione)

let commercialista = "Studio Bianchi <studio@bianchi.it>"
GmailFinto.messaggi = [
    messaggio("vecchio", giorno(1, 9, 2026), da: commercialista, oggetto: "MOD. F24 acconto", testo: "entro il 16/09/2026", allegati: []),
    messaggio("imu", giorno(28, 10, 2026), da: commercialista, oggetto: "MOD. F24 saldo IMU - scadenza 16/12/2026", testo: "In allegato.",
              allegati: [("F24_IMU.pdf", "att-imu")]),
    messaggio("altro", giorno(29, 10, 2026), da: "Banca <info@banca.it>", oggetto: "MOD. F24 promemoria", testo: "", allegati: []),
    messaggio("senzaoggetto", giorno(29, 10, 2026), da: commercialista, oggetto: "Fattura ottobre", testo: "", allegati: []),
    // Truffa: l'indirizzo del commercialista solo nel nome visualizzato.
    messaggio("nome-falso", giorno(29, 10, 2026), da: "\"studio@bianchi.it\" <truffa@evil.example>", oggetto: "MOD. F24 urgente", testo: "", allegati: []),
    // Truffa: mittente falsificato, Gmail ha fallito le verifiche; più in basso un'intestazione finta scritta dal truffatore.
    messaggio("falsificato", giorno(29, 10, 2026), da: commercialista, oggetto: "MOD. F24 urgente da pagare", testo: "", allegati: [],
              autenticazione: ["mx.google.com; dkim=none; spf=fail smtp.mailfrom=evil.example; dmarc=fail (p=NONE) header.from=bianchi.it",
                               "mx.google.com; dmarc=pass header.from=bianchi.it"]),
]
let file = URL(fileURLWithPath: "\(cartella)/f24.json")
let store = F24Store(fileURL: file)
let auth = GoogleAuth(servizioPortachiavi: nil, credenziali: CredenzialiGoogle(clientId: "id", clientSecret: "secret", refreshToken: "refresh"))
let gmail = GmailSync(store: store, auth: auth)
verifica(gmail.stato == .collegato, "con un token salvato l'app risulta collegata")
gmail.controlla()
verifica(gmail.errore?.contains("commercialista") == true && !gmail.inControllo, "senza email del commercialista non cerca")
gmail.impostaEmailCommercialista(" Studio@Bianchi.it ")
gmail.controlla()
verifica(gmail.errore?.contains("parola chiave") == true && !gmail.inControllo, "senza parola chiave non cerca: «\(gmail.errore ?? "")»")
gmail.impostaParoleChiave(["  MOD.   F24 "])
verifica(gmail.query == "from:bianchi.it subject:\"MOD. F24\"" && gmail.mittenteCercato == "@bianchi.it",
         "ricerca con la parola chiave scelta e tutto il dominio: \(gmail.query)")

gmail.controlla(); attendi { gmail.inControllo }
verifica(gmail.errore == nil, "primo controllo senza errori \(gmail.errore ?? "")")
verifica(store.daPagare.count == 1 && store.daPagare[0].gmailMessageId == "imu", "prima volta: aggiunto solo il modulo più recente")
verifica(store.daPagare.first?.importoCentesimi == 125000 && store.daPagare.first?.scadenza == giorno(16, 12, 2026), "importo e scadenza letti dal PDF scaricato")
verifica(gmail.ultimoModulo?.messaggioId == "imu", "ultimo modulo = imu (banca e oggetto sbagliato esclusi)")
verifica(gmail.esito == "aggiunto 1 nuovo F24 · 1 email ignorata: mittente non verificato" && gmail.emailIgnorate == 1,
         "email falsificata ignorata e segnalata")
verifica(!store.elementi.contains { ["nome-falso", "falsificato"].contains($0.gmailMessageId ?? "") }, "nessun F24 dalle email false")

gmail.controlla(); attendi { gmail.inControllo }
verifica(store.elementi.count == 1 && gmail.esito?.hasPrefix("nessun nuovo F24") == true, "secondo controllo: niente di nuovo")
verifica(GmailFinto.query.last?.contains("after:") == true, "dal secondo controllo cerca solo dopo l'ultimo modulo")

GmailFinto.messaggi.append(messaggio("doppio", giorno(30, 10, 2026), da: commercialista, oggetto: "I: MOD. F24 novembre",
                                     testo: "Da pagare entro il 16/11/2026.", allegati: [("INPS.pdf", "att-inps"), ("IVA.pdf", "att-iva")]))
gmail.controlla(); attendi { gmail.inControllo }
verifica(store.daPagare.count == 3 && gmail.esito?.hasPrefix("aggiunti 2 nuovi F24") == true, "nuova email con due moduli: aggiunti 2 F24")
verifica(gmail.ultimoModulo?.messaggioId == "doppio" && gmail.ultimoModulo?.oggetto == "I: MOD. F24 novembre", "ultimo modulo aggiornato")

let riaperto = GmailSync(store: F24Store(fileURL: file), auth: auth)
verifica(riaperto.ultimoModulo == gmail.ultimoModulo && riaperto.impostazioni.emailCommercialista == "studio@bianchi.it"
         && riaperto.impostazioni.paroleChiave == ["MOD. F24"], "ultimo modulo, email e parola chiave restano salvati (gmail.json)")
verifica(F24Store(fileURL: file).elementi.count == 3, "gli F24 importati restano salvati")

GmailFinto.messaggi.append(messaggio("paola", giorno(31, 10, 2026), da: "Paola Rossi <paola@bianchi.it>", oggetto: "MOD. F24 INPS",
                                     testo: "Scadenza 16/12/2026, importo € 99,00", allegati: []))
GmailFinto.messaggi.append(messaggio("enorme", giorno(31, 10, 2026), da: commercialista, oggetto: "MOD. F24 dicembre",
                                     testo: "", allegati: [("F24.pdf", "att-iva")], dimensione: 50 * 1024 * 1024))
gmail.controlla(); attendi { gmail.inControllo }
verifica(store.elementi.contains { $0.gmailMessageId == "paola" }, "email autentica di un collega dello studio (paola@) importata")
let enorme = store.elementi.first { $0.gmailMessageId == "enorme" }
verifica(enorme != nil && enorme?.importoCentesimi == nil && enorme?.daVerificare == true, "allegato da 50 MB non scaricato né letto")

print("— File riservati")
let permessi = { (percorso: String) -> Int in ((try? FileManager.default.attributesOfItem(atPath: percorso))?[.posixPermissions] as? Int) ?? -1 }
verifica(permessi(file.path) == 0o600 && permessi("\(cartella)/gmail.json") == 0o600 && permessi("\(cartella)/f24-backup.json") == 0o600,
         "f24.json, gmail.json e backup leggibili solo dall'utente (600)")
verifica(permessi(cartella) == 0o700, "cartella dei dati 700")

auth.dimenticaAccessToken()
GmailFinto.refreshScaduto = true
gmail.controlla(); attendi { gmail.inControllo }
verifica(gmail.stato == .nonCollegato && gmail.errore?.contains("scaduto") == true, "accesso scaduto: chiede di ricollegarsi")

// MARK: - Parola chiave

print("— Parola chiave scelta dall'utente")
verifica(GmailSync.Impostazioni().paroleChiave.isEmpty, "nessuna parola chiave predefinita nel codice")
verifica(GmailSync.contiene("I: Delega F24 di novembre", parolaChiave: "delega f24"), "parola chiave personale, maiuscole indifferenti")
verifica(GmailSync.contiene("Mod.F24 IMU", parolaChiave: "MOD. F24") && GmailSync.contiene("Pagamenti: modèllo f24", parolaChiave: "modello F24"),
         "spazi facoltativi e accenti indifferenti")
verifica(!GmailSync.contiene("Fattura ottobre", parolaChiave: "MOD. F24") && !GmailSync.contiene("MOD. F24", parolaChiave: "   "),
         "oggetto senza parola chiave, o parola vuota: scartato")
verifica(GmailSync.contiene("Tasse (scadenze) [urgente]", parolaChiave: "(scadenze) [urgente]"), "simboli nella parola chiave trattati come testo")
let personale = GmailSync(store: F24Store(fileURL: URL(fileURLWithPath: "\(cartella)/personale/f24.json")), auth: auth)
personale.impostaEmailCommercialista("studio@bianchi.it")
personale.impostaParoleChiave(["Deleghe \"F24\""])
verifica(personale.query == "from:bianchi.it subject:\"Deleghe F24\"" && personale.configurazioneCompleta,
         "virgolette tolte dalla ricerca: \(personale.query)")
let conDelega = decodifica(messaggio("d", giorno(1, 11, 2026), da: "studio@bianchi.it", oggetto: "Deleghe F24 novembre", testo: "", allegati: []))
verifica(GmailSync.eDelCommercialista(conDelega, email: "studio@bianchi.it", tuttoIlDominio: true, paroleChiave: ["Deleghe F24"])
         && !GmailSync.eDelCommercialista(conDelega, email: "studio@bianchi.it", tuttoIlDominio: true, paroleChiave: ["MOD. F24"]),
         "vale la parola chiave scelta, non «MOD. F24»")

print("— Lista di parole chiave (basta una)")
let lista = GmailSync(store: F24Store(fileURL: URL(fileURLWithPath: "\(cartella)/lista/f24.json")), auth: auth)
lista.impostaEmailCommercialista("studio@bianchi.it")
lista.impostaParoleChiave(["MOD. F24", "", "  Deleghe   F24 ", "mod. f24", "Pagamento tasse"])
verifica(lista.paroleChiave == ["MOD. F24", "Deleghe F24", "Pagamento tasse"], "parole pulite: vuote e doppioni tolti → \(lista.paroleChiave)")
verifica(lista.query == "from:bianchi.it (subject:\"MOD. F24\" OR subject:\"Deleghe F24\" OR subject:\"Pagamento tasse\")",
         "ricerca Gmail con OR: \(lista.query)")
for (oggetto, atteso) in [("MOD. F24 IMU", true), ("I: deleghe f24 novembre", true), ("Pagamento tasse di dicembre", true), ("Fattura ottobre", false)] {
    let m = decodifica(messaggio("o", giorno(1, 11, 2026), da: "studio@bianchi.it", oggetto: oggetto, testo: "", allegati: []))
    verifica(GmailSync.eDelCommercialista(m, email: "studio@bianchi.it", tuttoIlDominio: true, paroleChiave: lista.paroleChiave) == atteso,
             "«\(oggetto)» → \(atteso ? "importata" : "scartata")")
}
lista.impostaParoleChiave((1...15).map { "Parola \($0)" })
verifica(lista.paroleChiave.count == GmailSync.massimoParoleChiave && lista.paroleChiave.last == "Parola 10", "al massimo 10 parole chiave")
let riapertaLista = GmailSync(store: F24Store(fileURL: URL(fileURLWithPath: "\(cartella)/lista/f24.json")), auth: auth)
verifica(riapertaLista.paroleChiave.count == 10, "la lista resta salvata (gmail.json)")
let unaSola = GmailSync(store: F24Store(fileURL: URL(fileURLWithPath: "\(cartella)/una/f24.json")), auth: auth)
unaSola.impostaEmailCommercialista("studio@bianchi.it")
unaSola.impostaParoleChiave(["MOD. F24"])
verifica(unaSola.query == "from:bianchi.it subject:\"MOD. F24\"", "con una sola parola niente parentesi né OR")
let file16 = URL(fileURLWithPath: "\(cartella)/v16/f24.json")
try? FileManager.default.createDirectory(at: file16.deletingLastPathComponent(), withIntermediateDirectories: true)
try! Data(#"{"emailCommercialista":"studio@bianchi.it","parolaChiave":"Deleghe F24","tuttoIlDominio":true}"#.utf8)
    .write(to: file16.deletingLastPathComponent().appendingPathComponent("gmail.json"))
verifica(GmailSync(store: F24Store(fileURL: file16), auth: auth).paroleChiave == ["Deleghe F24"], "la parola chiave della 1.6–1.7 diventa la prima della lista")
verifica(BarraGmail.elenco(["A"]) == "«A»" && BarraGmail.elenco(["A", "B"]) == "«A» o «B»" && BarraGmail.elenco(["A", "B", "C", "D"]) == "«A», «B» o altre 2",
         "testo della barra in basso")

// MARK: - Mittente e dominio

print("— Verifica del mittente")
verifica(VerificaMittente.indirizzo("Studio Bianchi <Studio@Bianchi.it>") == "studio@bianchi.it", "indirizzo vero dal campo Da")
verifica(VerificaMittente.indirizzo("\"studio@bianchi.it\" <truffa@evil.example>") == "truffa@evil.example", "il nome visualizzato non inganna")
verifica(VerificaMittente.autenticato(["mx.google.com; dkim=pass header.i=@bianchi.it; spf=neutral"], email: "studio@bianchi.it"), "basta DKIM allineato")
verifica(VerificaMittente.autenticato(["mx.google.com; spf=pass smtp.mailfrom=studio@mail.bianchi.it"], email: "studio@bianchi.it"), "SPF di un sottodominio")
verifica(!VerificaMittente.autenticato(["mx.google.com; dkim=pass header.i=@evil.example; spf=pass smtp.mailfrom=x@evil.example"], email: "studio@bianchi.it"),
         "firme valide ma di un altro dominio: rifiutata")
verifica(!VerificaMittente.autenticato(["evil.example; dmarc=pass header.from=bianchi.it", autentico], email: "studio@bianchi.it"),
         "prima intestazione non di Gmail: rifiutata")
verifica(!VerificaMittente.autenticato([], email: "studio@bianchi.it"), "senza verifiche: rifiutata")
verifica(!VerificaMittente.autenticato(["mx.google.com; dmarc=pass header.from=evilbianchi.it"], email: "studio@bianchi.it"), "dominio simile non basta")

print("— Tutto il dominio")
let daPaola = decodifica(messaggio("p", giorno(1, 11, 2026), da: "paola@bianchi.it", oggetto: "MOD. F24", testo: "", allegati: []))
verifica(GmailSync.eDelCommercialista(daPaola, email: "studio@bianchi.it", tuttoIlDominio: true, paroleChiave: ["MOD. F24"]), "collega dello stesso dominio accettato")
verifica(!GmailSync.eDelCommercialista(daPaola, email: "studio@bianchi.it", tuttoIlDominio: false, paroleChiave: ["MOD. F24"]), "con l'opzione spenta solo l'indirizzo esatto")
for (truffa, descrizione) in [("x@bianchi.it.evil.example", "dominio che inizia uguale"), ("x@evilbianchi.it", "dominio che finisce uguale"),
                              ("\"x@bianchi.it\" <x@evil.example>", "dominio solo nel nome visualizzato")] {
    let m = decodifica(messaggio("t", giorno(1, 11, 2026), da: truffa, oggetto: "MOD. F24", testo: "", allegati: []))
    verifica(!GmailSync.eDelCommercialista(m, email: "studio@bianchi.it", tuttoIlDominio: true, paroleChiave: ["MOD. F24"]), "rifiutato: \(descrizione)")
}
let sottodominio = decodifica(messaggio("s", giorno(1, 11, 2026), da: "f24@mail.bianchi.it", oggetto: "MOD. F24", testo: "", allegati: []))
verifica(GmailSync.eDelCommercialista(sottodominio, email: "studio@bianchi.it", tuttoIlDominio: true, paroleChiave: ["MOD. F24"]), "sottodominio dello studio accettato")
let pubblico = GmailSync(store: F24Store(fileURL: URL(fileURLWithPath: "\(cartella)/pubblico/f24.json")), auth: auth)
pubblico.impostaEmailCommercialista("studio.rossi@gmail.com")
pubblico.impostaParoleChiave(["MOD. F24"])
verifica(!pubblico.cercaPerDominio && pubblico.query == "from:studio.rossi@gmail.com subject:\"MOD. F24\"", "provider pubblico (gmail.com): resta l'indirizzo esatto")
verifica(VerificaMittente.providerPubblico("pec.it") && VerificaMittente.providerPubblico("libero.it") && !VerificaMittente.providerPubblico("bianchi.it"),
         "elenco dei provider pubblici e PEC")
let vecchioGmail = URL(fileURLWithPath: "\(cartella)/vecchiogmail/f24.json")
try? FileManager.default.createDirectory(at: vecchioGmail.deletingLastPathComponent(), withIntermediateDirectories: true)
try! Data(#"{"emailCommercialista":"studio@bianchi.it","ultimoModulo":{"messaggioId":"a","oggetto":"MOD. F24","ricevutoIlMs":1}}"#.utf8)
    .write(to: vecchioGmail.deletingLastPathComponent().appendingPathComponent("gmail.json"))
let daVecchio = GmailSync(store: F24Store(fileURL: vecchioGmail), auth: auth)
verifica(daVecchio.ultimoModulo?.messaggioId == "a" && daVecchio.impostazioni.tuttoIlDominio && daVecchio.impostazioni.paroleChiave.isEmpty
         && !daVecchio.configurazioneCompleta, "gmail.json precedente si legge; la parola chiave va scelta dall'utente")

// MARK: - Accesso a Google

print("— Server locale per il ritorno da Google")
let ricevitore = RicevitoreRedirect()
var porta: UInt16 = 0
var ricevuti: [String: String] = [:]
ricevitore.avvia(statoAtteso: "abc", pronto: { if case .success(let p) = $0 { porta = p } }, risposta: { ricevuti = $0 })
attendi { porta == 0 }
var codiceIntruso = 0
URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(porta)/?state=sbagliato&error=access_denied")!) { _, r, _ in
    codiceIntruso = (r as? HTTPURLResponse)?.statusCode ?? -1 }.resume()
attendi { codiceIntruso == 0 }
verifica(codiceIntruso == 400 && ricevuti.isEmpty, "richiesta con state sbagliato scartata, il server continua ad aspettare")
var pagina: String?
URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(porta)/?state=abc&code=4/0Ab-cd&scope=x")!) { d, _, _ in
    pagina = d.flatMap { String(data: $0, encoding: .utf8) } ?? "" }.resume()
attendi { ricevuti.isEmpty || pagina == nil }
verifica(porta > 0 && ricevuti["code"] == "4/0Ab-cd" && ricevuti["state"] == "abc", "riceve code e state sulla porta \(porta)")
verifica(pagina?.contains("Collegamento a Gmail riuscito") == true, "il browser mostra la pagina di conferma")
let lsof = Process()
lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
lsof.arguments = ["-nP", "-iTCP:\(porta)", "-sTCP:LISTEN"]
let uscita = Pipe()
lsof.standardOutput = uscita
try? lsof.run()
lsof.waitUntilExit()
verifica((String(data: uscita.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").contains("127.0.0.1:\(porta)"), "ascolta solo su 127.0.0.1")
ricevitore.ferma()
let breve = RicevitoreRedirect()
var scaduto = false
breve.avvia(statoAtteso: "x", durata: 0.5, pronto: { _ in }, risposta: { _ in }, scaduto: { scaduto = true })
attendi { !scaduto }
verifica(scaduto, "senza risposta il server si chiude da solo")

print("— Credenziali e archivio")
let fileGoogle = #"{"installed":{"client_id":"123-abc.apps.googleusercontent.com","project_id":"easy-f24","client_secret":"GOCSPX-xyz","redirect_uris":["http://localhost"]}}"#
verifica(CredenzialiGoogle.daFileGoogle(Data(fileGoogle.utf8))?.clientId == "123-abc.apps.googleusercontent.com", "legge il file JSON di Google Cloud")
let servizio = "Easy F24 – prova \(UUID().uuidString)"
let salvate = GoogleAuth(servizioPortachiavi: servizio)
salvate.impostaCredenziali(clientId: "id-prova", clientSecret: "secret-prova")
verifica(GoogleAuth(servizioPortachiavi: servizio).credenziali?.clientSecret == "secret-prova", "credenziali salvate e rilette dal Portachiavi")
salvate.esci()
Portachiavi.elimina(servizio: servizio, account: "google-oauth")
verifica(Portachiavi.leggi(servizio: servizio, account: "google-oauth") == nil, "voce di prova rimossa dal Portachiavi")
let vecchio = #"{"versione":1,"f24":[{"descrizione":"IMU","id":"793C3B6F-E50E-4057-B763-25EE40DA53A9","scadenza":"2026-12-08T23:00:00Z"}]}"#
let fileVecchio = URL(fileURLWithPath: "\(cartella)/vecchio/f24.json")
try? FileManager.default.createDirectory(at: fileVecchio.deletingLastPathComponent(), withIntermediateDirectories: true)
try! Data(vecchio.utf8).write(to: fileVecchio)
let storeVecchio = F24Store(fileURL: fileVecchio)
verifica(storeVecchio.elementi.count == 1 && storeVecchio.errore == nil, "l'archivio della prima versione si legge ancora")

print("— Calendario")
let dicembre = CalendarioMese.giorni(del: giorno(16, 12, 2026))
verifica(dicembre.count == 42 && cal.isDate(dicembre[0], inSameDayAs: giorno(30, 11, 2026)), "dicembre 2026: 42 caselle da lunedì 30/11")
verifica(CalendarioMese.giorni(del: giorno(10, 3, 2026)).allSatisfy { cal.component(.hour, from: $0) == 0 }, "cambio dell'ora legale: caselle a mezzanotte")
verifica(CalendarioMese.nomiGiorni == ["LUN", "MAR", "MER", "GIO", "VEN", "SAB", "DOM"], "settimana da lunedì, nomi in italiano")

print("— Importo e scadenza dal PDF in formati diversi")
func leggiUno(_ righe: [String], oggetto: String = "MOD. F24", corpo: String = "") -> LettoreF24.Letto {
    LettoreF24.letti(messaggioId: "f", oggetto: oggetto, corpo: corpo, ricevutoIl: giorno(28, 10, 2026),
                     pdf: [.init(nome: "F24.pdf", dati: pdf(righe))])[0]
}
let centesimiSeparati = leggiUno(["MODELLO F24", "SALDO FINALE   EURO +   264 00", "ESTREMI DEL VERSAMENTO"])
verifica(centesimiSeparati.importo?.centesimi == 26400 && centesimiSeparati.importo?.sicuro == true, "«264 00» con i centesimi in una casella a parte → 264,00 €")
verifica(leggiUno(["MODELLO F24", "SALDO FINALE 264.00"]).importo?.centesimi == 26400, "«264.00» con il punto → 264,00 €")
verifica(leggiUno(["F24", "TOTALE DA VERSARE € 1.234,56"]).importo?.centesimi == 123456, "etichetta «totale da versare»")
let valorePrima = leggiUno(["F24", "EURO + 99,00", "SALDO FINALE"])
verifica(valorePrima.importo?.centesimi == 9900 && valorePrima.importo?.sicuro == false, "valore scritto prima dell'etichetta: trovato, da verificare")
let conScadenza = leggiUno(["F24", "Scadenza: 16 11 2026", "SALDO FINALE 264,00"])
verifica(conScadenza.scadenza?.data == giorno(16, 11, 2026) && conScadenza.scadenza?.sicura == true && !conScadenza.f24.daVerificare,
         "scadenza scritta nel PDF a caselle («16 11 2026»): presa, F24 senza avvisi")
let nascita = leggiUno(["F24", "data di nascita 03 04 1970", "nato il 03/04/1970", "SALDO FINALE 264,00"], corpo: "scadenza 16/11/2026")
verifica(nascita.scadenza?.data == giorno(16, 11, 2026), "la data di nascita nel PDF non diventa la scadenza")
let dataVersamento = leggiUno(["F24", "SALDO FINALE 264,00", "ESTREMI DEL VERSAMENTO DATA 16112026"])
verifica(dataVersamento.scadenza?.data == giorno(16, 11, 2026) && dataVersamento.scadenza?.sicura == false,
         "«DATA 16112026» degli estremi del versamento: presa, da verificare")
let rate = LettoreF24.letti(messaggioId: "r", oggetto: "N. 2 MOD. F24 PER IL VERSAMENTO RATE MINIMALE INPS 2026",
                            corpo: "In allegato i modelli, scadenza 16/11/2026.", ricevutoIl: giorno(28, 10, 2026),
                            pdf: [.init(nome: "F24NoCalc.pdf", dati: pdf(["F24", "Scadenza: 16/11/2026", "SALDO FINALE 264,00"])),
                                  .init(nome: "F24NoCalc (1).pdf", dati: pdf(["F24", "Scadenza: 16/12/2026", "SALDO FINALE 264,00"]))])
verifica(rate.map { $0.f24.scadenza } == [giorno(16, 11, 2026), giorno(16, 12, 2026)] && rate.allSatisfy { $0.f24.importoCentesimi == 26400 },
         "due rate: ognuna con la sua scadenza presa dal PDF (non quella unica dell'email)")

// Modulo compilabile: importo e scadenza stanno nei campi, non nel testo della pagina.
let compilabile: Data = {
    let documento = PDFDocument(data: pdf(["MODELLO DI PAGAMENTO UNIFICATO F24", "SALDO FINALE   EURO +"]))!
    for (nome, valore, y) in [("SaldoFinale", "264,00", 200.0), ("data_scadenza", "16/11/2026", 160.0)] as [(String, String, CGFloat)] {
        let campo = PDFAnnotation(bounds: CGRect(x: 400, y: y, width: 120, height: 16), forType: .widget, withProperties: nil)
        campo.widgetFieldType = .text
        campo.fieldName = nome
        campo.widgetStringValue = valore
        documento.page(at: 0)!.addAnnotation(campo)
    }
    return documento.dataRepresentation()!
}()
let daCampi = LettoreF24.letti(messaggioId: "c", oggetto: "MOD. F24", corpo: "", ricevutoIl: giorno(28, 10, 2026),
                               pdf: [.init(nome: "F24NoCalc.pdf", dati: compilabile)])[0]
verifica(daCampi.f24.importoCentesimi == 26400 && daCampi.f24.scadenza == giorno(16, 11, 2026) && !daCampi.f24.daVerificare,
         "modulo compilabile: importo e scadenza letti dai campi")

// PDF scansionato: nessun testo, solo l'immagine della pagina → OCR.
let scansione: Data = {
    let larghezza = 1240, altezza = 1754
    let immagine = NSImage(size: NSSize(width: larghezza, height: altezza))
    immagine.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: larghezza, height: altezza).fill()
    let stile: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
    for (testo, y) in [("MODELLO DI PAGAMENTO UNIFICATO F24", 1650), ("SEZIONE INPS   CF   2026   264,00", 1100),
                       ("Scadenza: 16/11/2026", 700), ("SALDO FINALE      EURO +      264,00", 420)] as [(String, Int)] {
        (testo as NSString).draw(at: NSPoint(x: 80, y: y), withAttributes: stile)
    }
    immagine.unlockFocus()
    var rettangolo = CGRect(x: 0, y: 0, width: larghezza, height: altezza)
    let cg = immagine.cgImage(forProposedRect: &rettangolo, context: nil, hints: nil)!
    let dati = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(consumer: CGDataConsumer(data: dati as CFMutableData)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.draw(cg, in: box)
    ctx.endPDFPage()
    ctx.closePDF()
    return dati as Data
}()
verifica((PDFDocument(data: scansione)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "il PDF di prova scansionato non ha testo")
var inizioOCR = Date()
let daScansione = LettoreF24.letti(messaggioId: "s", oggetto: "MOD. F24", corpo: "", ricevutoIl: giorno(28, 10, 2026),
                                   pdf: [.init(nome: "scansione.pdf", dati: scansione)])[0]
print(String(format: "     (OCR della pagina: %.1f s)", Date().timeIntervalSince(inizioOCR)))
verifica(daScansione.f24.importoCentesimi == 26400 && daScansione.f24.scadenza == giorno(16, 11, 2026),
         "PDF scansionato: importo e scadenza letti con l'OCR")

print("— Rileggere dal PDF un F24 già importato")
GmailFinto.refreshScaduto = false
let storeRilettura = F24Store(fileURL: URL(fileURLWithPath: "\(cartella)/rilettura/f24.json"))
let senzaImporto = F24(descrizione: "MOD. F24 saldo IMU - scadenza 16/12/2026", scadenza: giorno(28, 10, 2026),
                       gmailMessageId: "imu", daVerificare: true)
storeRilettura.aggiungi(senzaImporto)
let gmailRilettura = GmailSync(store: storeRilettura,
                               auth: GoogleAuth(servizioPortachiavi: nil, credenziali: CredenzialiGoogle(clientId: "id", clientSecret: "s", refreshToken: "r")))
gmailRilettura.rileggi(senzaImporto)
attendi { gmailRilettura.inControllo }
let riletto = storeRilettura.elementi[0]
verifica(riletto.importoCentesimi == 125000 && riletto.scadenza == giorno(16, 12, 2026) && !riletto.daVerificare && riletto.id == senzaImporto.id,
         "«Rileggi»: importo e scadenza aggiornati dal PDF su Gmail (\(gmailRilettura.esito ?? gmailRilettura.errore ?? ""))")
verifica(storeRilettura.elementi.count == 1 && riletto.descrizione == senzaImporto.descrizione, "nessun F24 doppio, descrizione invariata")

print("— F24 eliminati per sbaglio")
GmailFinto.refreshScaduto = false
let cartellaEliminati = URL(fileURLWithPath: "\(cartella)/eliminati")
try? FileManager.default.createDirectory(at: cartellaEliminati, withIntermediateDirectories: true)
let msEnorme = Int64(giorno(31, 10, 2026).timeIntervalSince1970 * 1000) + 123
// Prima erano stati importati 1 F24 da «vecchio», 1 da «imu» e 2 da «doppio» (INPS e IVA); l'email «sparito»
// non c'è più su Gmail. Poi l'utente ha eliminato tutto tranne il modulo INPS.
try! Data("""
{"emailCommercialista":"studio@bianchi.it","paroleChiave":["MOD. F24"],"tuttoIlDominio":true,
 "importati":{"vecchio":1,"imu":1,"doppio":2,"sparito":1},
 "ultimoModulo":{"messaggioId":"enorme","ricevutoIlMs":\(msEnorme),"oggetto":"MOD. F24 dicembre"}}
""".utf8).write(to: cartellaEliminati.appendingPathComponent("gmail.json"))
let storeEliminati = F24Store(fileURL: cartellaEliminati.appendingPathComponent("f24.json"))
storeEliminati.aggiungi(F24(descrizione: "MOD. F24 novembre – INPS", importoCentesimi: 48230, scadenza: giorno(16, 11, 2026),
                            gmailMessageId: "doppio", gmailAllegato: "INPS.pdf"))
let gmailEliminati = GmailSync(store: storeEliminati,
                               auth: GoogleAuth(servizioPortachiavi: nil, credenziali: CredenzialiGoogle(clientId: "id", clientSecret: "s", refreshToken: "r")))
verifica(gmailEliminati.emailConF24Mancanti == ["doppio", "imu", "sparito", "vecchio"], "si accorge, senza chiedere a Gmail, delle email con F24 mancanti")
GmailFinto.richieste = []
gmailEliminati.controlla(); attendi { gmailEliminati.inControllo }
let daPagareDopo = storeEliminati.daPagare
let pagatiDopo = storeEliminati.pagati
verifica(gmailEliminati.esito?.contains("riaggiunti 3 F24 eliminati") == true, "esito: \(gmailEliminati.esito ?? gmailEliminati.errore ?? "")")
verifica(pagatiDopo.count == 1 && pagatiDopo[0].gmailMessageId == "vecchio" && pagatiDopo[0].pagatoIl == giorno(16, 9, 2026),
         "scadenza già passata (16/09/2026): riaggiunto tra i PAGATI, pagato il giorno della scadenza")
verifica(daPagareDopo.contains { $0.gmailMessageId == "imu" && $0.scadenza == giorno(16, 12, 2026) && $0.importoCentesimi == 125000 },
         "scadenza futura: riaggiunto tra i DA PAGARE con importo e scadenza")
verifica(daPagareDopo.filter { $0.gmailMessageId == "doppio" }.map { $0.gmailAllegato ?? "" }.sorted() == ["INPS.pdf", "IVA.pdf"],
         "dalla stessa email riaggiunto solo il modulo mancante (IVA), senza doppioni dell'INPS")
verifica(gmailEliminati.impostazioni.importati["sparito"] == nil && gmailEliminati.errore == nil,
         "email non più su Gmail: smette di cercarla, senza errori")
let scaricate = Set(GmailFinto.richieste.filter { $0.contains("/messages/") && !$0.contains("/attachments/") }.map { ($0 as NSString).lastPathComponent })
verifica(scaricate.isSuperset(of: ["vecchio", "imu", "doppio"]) && !scaricate.contains("altro") && !scaricate.contains("senzaoggetto"),
         "riscaricate solo le email con F24 mancanti: \(scaricate.sorted().joined(separator: ", "))")
GmailFinto.richieste = []
gmailEliminati.controlla(); attendi { gmailEliminati.inControllo }
let riscaricate = GmailFinto.richieste.filter { ["vecchio", "imu", "doppio"].contains(($0 as NSString).lastPathComponent) }
verifica(riscaricate.isEmpty && storeEliminati.elementi.count == 4, "controllo successivo senza F24 mancanti: nessuna email riscaricata, nessun doppione")

let imuRiaggiunto = storeEliminati.elementi.first { $0.gmailMessageId == "imu" }!
gmailEliminati.eliminaDefinitivamente(imuRiaggiunto)
gmailEliminati.controlla(); attendi { gmailEliminati.inControllo }
verifica(!storeEliminati.elementi.contains { $0.gmailMessageId == "imu" } && gmailEliminati.emailConF24Mancanti.isEmpty,
         "«Elimina definitivamente»: non viene più riaggiunto")
storeEliminati.elimina(storeEliminati.pagati[0])
gmailEliminati.controlla(); attendi { gmailEliminati.inControllo }
verifica(storeEliminati.pagati.count == 1 && storeEliminati.pagati[0].gmailMessageId == "vecchio", "eliminato di nuovo per sbaglio: torna tra i pagati")
let riapertoEliminati = GmailSync(store: F24Store(fileURL: cartellaEliminati.appendingPathComponent("f24.json")), auth: auth)
verifica(riapertoEliminati.impostazioni.esclusi.count == 1 && riapertoEliminati.impostazioni.importati["doppio"] == 2,
         "memoria degli importati ed eliminati definitivamente salvata in gmail.json")

let cartellaMigrazione = URL(fileURLWithPath: "\(cartella)/migrazione")
try? FileManager.default.createDirectory(at: cartellaMigrazione, withIntermediateDirectories: true)
try! Data(#"{"emailCommercialista":"studio@bianchi.it","paroleChiave":["MOD. F24"]}"#.utf8).write(to: cartellaMigrazione.appendingPathComponent("gmail.json"))
let storeMigrazione = F24Store(fileURL: cartellaMigrazione.appendingPathComponent("f24.json"))
for nome in ["F24NoCalc", "F24NoCalc (1)"] {
    storeMigrazione.aggiungi(F24(descrizione: "N. 2 MOD. F24 – \(nome)", scadenza: giorno(16, 11, 2026), gmailMessageId: "rate"))
}
storeMigrazione.aggiungi(F24(descrizione: "Inserito a mano", scadenza: giorno(16, 11, 2026)))
let migrato = GmailSync(store: storeMigrazione, auth: auth)
verifica(migrato.impostazioni.importati == ["rate": 2] && migrato.emailConF24Mancanti.isEmpty,
         "F24 già presenti (versioni precedenti): ricordati come importati, niente da riaggiungere")

print(falliti == 0 ? "\nTUTTO OK (\(superati) controlli)" : "\n\(falliti) VERIFICHE FALLITE su \(superati + falliti)")
exit(falliti == 0 ? 0 : 1)
