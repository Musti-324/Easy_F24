import AppKit
import Combine
import Foundation

/// Controlla Gmail e aggiunge tra gli F24 da pagare i moduli che arrivano dal commercialista:
/// email inviate dal suo indirizzo con nell'oggetto la parola chiave scelta dall'utente.
final class GmailSync: ObservableObject {
    enum Stato: Equatable {
        /// Mancano le credenziali dell'app Google.
        case daConfigurare
        /// Credenziali presenti ma accesso non fatto (o scaduto).
        case nonCollegato
        /// Accesso in corso nel browser.
        case attesaBrowser
        case collegato
    }

    /// L'ultimo modulo F24 trovato su Gmail: le email arrivate dopo sono i nuovi F24.
    struct UltimoModulo: Codable, Equatable {
        var messaggioId: String
        /// Ora di arrivo in millisecondi, come la dà Gmail, per confronti esatti.
        var ricevutoIlMs: Int64
        var oggetto: String

        var ricevutoIl: Date { Date(timeIntervalSince1970: Double(ricevutoIlMs) / 1000) }
    }

    struct Impostazioni: Codable, Equatable {
        var emailCommercialista = ""
        /// Testi da cercare nell'oggetto delle email con gli F24 (li sceglie l'utente, al massimo 10):
        /// basta che l'oggetto ne contenga uno.
        var paroleChiave: [String] = []
        /// Accetta le email di qualsiasi indirizzo del dominio del commercialista (es. tutto lo studio),
        /// non solo del suo indirizzo. Non vale per i provider pubblici come gmail.com.
        var tuttoIlDominio = true
        /// Account Gmail collegato (solo per mostrarlo).
        var account: String?
        var ultimoModulo: UltimoModulo?

        init() {}

        /// Nome del campo nella versione 1.6–1.7, che aveva una sola parola chiave.
        private enum ChiaviVecchie: String, CodingKey {
            case parolaChiave
        }

        // I gmail.json delle versioni precedenti non hanno tutti i campi.
        init(from decoder: Decoder) throws {
            let valori = try decoder.container(keyedBy: CodingKeys.self)
            emailCommercialista = try valori.decodeIfPresent(String.self, forKey: .emailCommercialista) ?? ""
            if let parole = try valori.decodeIfPresent([String].self, forKey: .paroleChiave) {
                paroleChiave = parole
            } else {
                let vecchia = try decoder.container(keyedBy: ChiaviVecchie.self).decodeIfPresent(String.self, forKey: .parolaChiave) ?? ""
                paroleChiave = vecchia.isEmpty ? [] : [vecchia]
            }
            tuttoIlDominio = try valori.decodeIfPresent(Bool.self, forKey: .tuttoIlDominio) ?? true
            account = try valori.decodeIfPresent(String.self, forKey: .account)
            ultimoModulo = try valori.decodeIfPresent(UltimoModulo.self, forKey: .ultimoModulo)
        }
    }

    static let intervalloControlli: TimeInterval = 30 * 60
    static let massimoParoleChiave = 10

    @Published private(set) var stato: Stato
    @Published private(set) var impostazioni: Impostazioni
    @Published private(set) var inControllo = false
    @Published private(set) var ultimoControllo: Date?
    /// Esito dell'ultimo controllo, es. "Aggiunto 1 nuovo F24".
    @Published private(set) var esito: String?
    @Published private(set) var errore: String?
    /// Email con mittente e oggetto giusti ma non verificate da Gmail (possibili falsi): non importate.
    @Published private(set) var emailIgnorate = 0

    var ultimoModulo: UltimoModulo? { impostazioni.ultimoModulo }
    var emailCommercialistaValida: Bool { GmailSync.emailValida(impostazioni.emailCommercialista) }
    var paroleChiave: [String] { GmailSync.pulisci(paroleChiave: impostazioni.paroleChiave) }
    /// Email del commercialista e almeno una parola chiave inserite: si può cercare.
    var configurazioneCompleta: Bool { emailCommercialistaValida && !paroleChiave.isEmpty }

    /// Es. "studio-esempio.it".
    var dominioCommercialista: String? { VerificaMittente.dominio(di: impostazioni.emailCommercialista) }

    /// Si cercano le email di tutto il dominio: solo se scelto e se il dominio non è un provider pubblico.
    var cercaPerDominio: Bool {
        guard impostazioni.tuttoIlDominio, let dominio = dominioCommercialista else { return false }
        return !VerificaMittente.providerPubblico(dominio)
    }

    /// Chi viene cercato: "@studio-esempio.it" (tutto il dominio) o "studio@studio-esempio.it".
    var mittenteCercato: String {
        cercaPerDominio ? "@" + (dominioCommercialista ?? "") : impostazioni.emailCommercialista
    }

    let auth: GoogleAuth
    private let store: F24Store
    private let fileURL: URL
    private var timer: Timer?

    init(store: F24Store, auth: GoogleAuth = GoogleAuth()) {
        self.store = store
        self.auth = auth
        fileURL = store.fileURL.deletingLastPathComponent().appendingPathComponent("gmail.json")
        impostazioni = (try? Data(contentsOf: fileURL))
            .flatMap { try? GmailSync.decoder.decode(Impostazioni.self, from: $0) } ?? Impostazioni()
        FileRiservato.proteggi(fileURL)
        stato = auth.credenziali == nil ? .daConfigurare : (auth.collegato ? .collegato : .nonCollegato)
    }

    /// Primo controllo e poi uno ogni mezz'ora, finché l'app resta aperta.
    func avvia() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: GmailSync.intervalloControlli, repeats: true) { [weak self] _ in
            self?.controlla()
        }
        controlla()
    }

    // MARK: - Impostazioni

    func impostaEmailCommercialista(_ email: String) {
        let pulita = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard pulita != impostazioni.emailCommercialista else { return }
        impostazioni.emailCommercialista = pulita
        // Con un altro commercialista si riparte dal suo modulo più recente.
        impostazioni.ultimoModulo = nil
        salva()
    }

    func impostaParoleChiave(_ parole: [String]) {
        let pulite = GmailSync.pulisci(paroleChiave: parole)
        guard pulite != impostazioni.paroleChiave else { return }
        impostazioni.paroleChiave = pulite
        salva()
    }

    /// Parole pulite, senza vuote né doppioni (maiuscole indifferenti), al massimo 10.
    static func pulisci(paroleChiave: [String]) -> [String] {
        var viste = Set<String>()
        var risultato: [String] = []
        for parola in paroleChiave.map({ pulisci(parolaChiave: $0) }) where !parola.isEmpty {
            if viste.insert(parola.lowercased()).inserted {
                risultato.append(parola)
            }
        }
        return Array(risultato.prefix(massimoParoleChiave))
    }

    /// Senza virgolette (romperebbero la ricerca di Gmail) né spazi doppi.
    static func pulisci(parolaChiave: String) -> String {
        parolaChiave.replacingOccurrences(of: "\"", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func impostaTuttoIlDominio(_ attivo: Bool) {
        guard attivo != impostazioni.tuttoIlDominio else { return }
        impostazioni.tuttoIlDominio = attivo
        salva()
    }

    func impostaCredenziali(clientId: String, clientSecret: String) {
        if auth.impostaCredenziali(clientId: clientId, clientSecret: clientSecret) {
            stato = auth.credenziali == nil ? .daConfigurare : .nonCollegato
        }
    }

    /// Apre il browser per l'accesso a Google.
    func collega() {
        stato = .attesaBrowser
        errore = nil
        auth.accedi { [weak self] risultato in
            guard let self = self else { return }
            switch risultato {
            case .success:
                NSApp.activate(ignoringOtherApps: true)
                self.stato = .collegato
                self.leggiAccount()
            case .failure(let errore):
                self.stato = self.auth.credenziali == nil ? .daConfigurare : .nonCollegato
                self.errore = errore.localizedDescription
            }
        }
    }

    func annullaCollegamento() {
        auth.annullaAccesso()
        stato = auth.credenziali == nil ? .daConfigurare : .nonCollegato
    }

    func scollega() {
        auth.esci()
        impostazioni.account = nil
        salva()
        stato = .nonCollegato
        esito = nil
        errore = nil
    }

    /// Apre in Gmail l'email da cui è stato importato un F24.
    func apriEmail(_ messaggioId: String) {
        let utente = impostazioni.account?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "0"
        if let url = URL(string: "https://mail.google.com/mail/u/\(utente)/#all/\(messaggioId)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Controllo

    /// La ricerca fatta su Gmail: mittente = commercialista (o il suo dominio) e oggetto con
    /// almeno una delle parole chiave, es. `from:x (subject:"MOD. F24" OR subject:"Deleghe")`.
    var query: String {
        let mittente = cercaPerDominio ? (dominioCommercialista ?? "") : impostazioni.emailCommercialista
        let oggetti = paroleChiave.map { "subject:\"\($0)\"" }
        var parti = ["from:\(mittente)", oggetti.count == 1 ? oggetti[0] : "(" + oggetti.joined(separator: " OR ") + ")"]
        if let ultimo = impostazioni.ultimoModulo {
            // Un giorno di margine: il confronto preciso si fa poi sull'ora di arrivo.
            parti.append("after:\(ultimo.ricevutoIlMs / 1000 - 86_400)")
        }
        return parti.joined(separator: " ")
    }

    func controlla() {
        guard stato == .collegato, !inControllo else { return }
        guard emailCommercialistaValida else {
            errore = "Inserisci l'email del commercialista da «Gmail…»."
            return
        }
        guard !paroleChiave.isEmpty else {
            errore = "Inserisci almeno una parola chiave dell'oggetto da «Gmail…»."
            return
        }
        inControllo = true
        errore = nil
        auth.accessToken { [weak self] risultato in
            guard let self = self else { return }
            switch risultato {
            case .failure(let errore):
                self.termina(errore: errore)
            case .success(let token):
                self.cerca(con: GmailAPI(token: token))
            }
        }
    }

    private func cerca(con api: GmailAPI) {
        let primaVolta = impostazioni.ultimoModulo == nil
        api.cerca(query, massimo: primaVolta ? 5 : 25) { [weak self] risultato in
            switch risultato {
            case .failure(let errore):
                self?.termina(errore: errore)
            case .success(let ids):
                inSequenza(ids, passo: { id, fatto in api.messaggio(id, fine: fatto) }) { [weak self] risultato in
                    switch risultato {
                    case .failure(let errore):
                        self?.termina(errore: errore)
                    case .success(let messaggi):
                        self?.importa(messaggi, con: api)
                    }
                }
            }
        }
    }

    /// Confronta i messaggi trovati con l'ultimo modulo salvato e aggiunge quelli nuovi.
    private func importa(_ messaggi: [MessaggioGmail], con api: GmailAPI) {
        // Gmail cerca per parole: qui si controlla che indirizzo e oggetto siano proprio quelli giusti
        // e che l'email sia autentica, perché il mittente di un'email si può falsificare.
        let email = impostazioni.emailCommercialista
        let perDominio = cercaPerDominio
        let parole = paroleChiave
        let candidati = messaggi.filter {
            GmailSync.eDelCommercialista($0, email: email, tuttoIlDominio: perDominio, paroleChiave: parole)
        }
        let validi = candidati.filter { $0.autenticato(da: email) }.sorted { $0.ricevutoIlMs < $1.ricevutoIlMs }
        let ultimoMs = impostazioni.ultimoModulo?.ricevutoIlMs ?? 0
        let ignorate = candidati.filter { !$0.autenticato(da: email) && $0.ricevutoIlMs > ultimoMs }.count
        guard let piuRecente = validi.last else {
            termina(nuovi: 0, ignorate: ignorate)
            return
        }
        var nuovi: [MessaggioGmail]
        if let ultimo = impostazioni.ultimoModulo {
            nuovi = validi.filter { $0.ricevutoIlMs > ultimo.ricevutoIlMs && $0.id != ultimo.messaggioId }
        } else {
            // Prima volta: solo il modulo più recente, per non riempire la lista con quelli vecchi.
            nuovi = [piuRecente]
        }
        nuovi = nuovi.filter { !store.contiene(gmailMessageId: $0.id) }

        inSequenza(nuovi, passo: { messaggio, fatto in
            GmailSync.leggiF24(da: messaggio, con: api, fine: fatto)
        }) { [weak self] risultato in
            guard let self = self else { return }
            switch risultato {
            case .failure(let errore):
                self.termina(errore: errore)
            case .success(let gruppi):
                let aggiunti = gruppi.flatMap { $0 }
                aggiunti.forEach { self.store.aggiungi($0) }
                if piuRecente.ricevutoIlMs > (self.impostazioni.ultimoModulo?.ricevutoIlMs ?? 0) {
                    self.impostazioni.ultimoModulo = UltimoModulo(messaggioId: piuRecente.id,
                                                                  ricevutoIlMs: piuRecente.ricevutoIlMs,
                                                                  oggetto: piuRecente.oggetto)
                    self.salva()
                }
                self.termina(nuovi: aggiunti.count, ignorate: ignorate)
            }
        }
    }

    private static func leggiF24(da messaggio: MessaggioGmail, con api: GmailAPI,
                                 fine: @escaping (Result<[F24], ErroreGmail>) -> Void) {
        inSequenza(messaggio.allegatiPDF, passo: { (allegato: MessaggioGmail.PDF, fatto: @escaping (Result<LettoreF24.PDF, ErroreGmail>) -> Void) in
            if let dati = allegato.dati {
                fatto(.success(LettoreF24.PDF(nome: allegato.nome, dati: dati)))
            } else if let id = allegato.attachmentId {
                api.allegato(messaggio: messaggio.id, allegato: id) { risultato in
                    switch risultato {
                    case .failure(let errore):
                        fatto(.failure(errore))
                    case .success(let dati) where dati.count > MessaggioGmail.massimaDimensionePDF:
                        fatto(.failure(.risposta("allegato troppo grande")))
                    case .success(let dati):
                        fatto(.success(LettoreF24.PDF(nome: allegato.nome, dati: dati)))
                    }
                }
            } else {
                fatto(.failure(.risposta("allegato senza contenuto")))
            }
        }) { risultato in
            fine(risultato.map { pdf in
                LettoreF24.moduli(messaggioId: messaggio.id, oggetto: messaggio.oggetto, corpo: messaggio.testo,
                                  ricevutoIl: messaggio.ricevutoIl, pdf: pdf)
            })
        }
    }

    /// Indirizzo vero del mittente (non basta che compaia nel nome) uguale a quello del commercialista,
    /// oppure dello stesso dominio se `tuttoIlDominio`; e almeno una delle parole chiave nell'oggetto.
    static func eDelCommercialista(_ messaggio: MessaggioGmail, email: String, tuttoIlDominio: Bool, paroleChiave: [String]) -> Bool {
        let oggettoGiusto = paroleChiave.contains { contiene(messaggio.oggetto, parolaChiave: $0) }
        let mittente = VerificaMittente.indirizzo(messaggio.mittente)
        let mittenteGiusto: Bool
        if tuttoIlDominio, let dominio = VerificaMittente.dominio(di: email) {
            mittenteGiusto = VerificaMittente.delDominio(mittente, dominio)
        } else {
            mittenteGiusto = mittente == email.lowercased()
        }
        return oggettoGiusto && mittenteGiusto
    }

    /// L'oggetto contiene la parola chiave: maiuscole/minuscole e accenti non contano,
    /// e gli spazi sono facoltativi ("Mod.F24" va bene per la parola chiave "MOD. F24").
    static func contiene(_ oggetto: String, parolaChiave: String) -> Bool {
        // Le espressioni regolari ignorano l'opzione "senza accenti": gli accenti si tolgono prima.
        let senzaAccenti = { (testo: String) in testo.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
        let parti = pulisci(parolaChiave: senzaAccenti(parolaChiave)).split(separator: " ")
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parti.isEmpty else { return false }
        return senzaAccenti(oggetto).range(of: parti.joined(separator: #"\s*"#), options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func emailValida(_ email: String) -> Bool {
        email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    private func leggiAccount() {
        auth.accessToken { [weak self] risultato in
            guard case .success(let token) = risultato else {
                self?.controlla()
                return
            }
            GmailAPI(token: token).profilo { risultato in
                guard let self = self else { return }
                if case .success(let email) = risultato {
                    self.impostazioni.account = email
                    self.salva()
                }
                self.controlla()
            }
        }
    }

    private func termina(nuovi: Int, ignorate: Int) {
        inControllo = false
        ultimoControllo = Date()
        emailIgnorate = ignorate
        switch nuovi {
        case 0: esito = "nessun nuovo F24"
        case 1: esito = "aggiunto 1 nuovo F24"
        default: esito = "aggiunti \(nuovi) nuovi F24"
        }
        if ignorate > 0 {
            esito = (esito ?? "") + (ignorate == 1
                ? " · 1 email ignorata: mittente non verificato"
                : " · \(ignorate) email ignorate: mittente non verificato")
        }
    }

    private func termina(errore: ErroreGmail) {
        inControllo = false
        auth.dimenticaAccessToken()
        if case .accessoScaduto = errore {
            stato = auth.credenziali == nil ? .daConfigurare : .nonCollegato
        }
        self.errore = errore.localizedDescription
    }

    // MARK: - File

    private func salva() {
        if let dati = try? GmailSync.encoder.encode(impostazioni) {
            try? FileRiservato.scrivi(dati, in: fileURL)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

/// Esegue `passo` su ogni elemento, uno dopo l'altro; si ferma al primo errore.
private func inSequenza<Elemento, Risultato>(
    _ elementi: [Elemento],
    passo: @escaping (Elemento, @escaping (Result<Risultato, ErroreGmail>) -> Void) -> Void,
    fine: @escaping (Result<[Risultato], ErroreGmail>) -> Void
) {
    var risultati: [Risultato] = []
    func prossimo(_ indice: Int) {
        guard indice < elementi.count else {
            fine(.success(risultati))
            return
        }
        passo(elementi[indice]) { risultato in
            switch risultato {
            case .failure(let errore):
                fine(.failure(errore))
            case .success(let valore):
                risultati.append(valore)
                prossimo(indice + 1)
            }
        }
    }
    prossimo(0)
}
