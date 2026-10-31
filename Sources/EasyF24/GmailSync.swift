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
        /// Quanti F24 contiene ogni email già letta (id del messaggio Gmail → numero di moduli; 0 = email
        /// non valida): serve ad accorgersi, senza rileggere l'email, se qualcuno è stato eliminato.
        var importati: [String: Int] = [:]
        /// Ora di arrivo (ms) della prima email importata: le email più vecchie non vengono mai aggiunte.
        var inizioMs: Int64?
        /// 2 = `importati` contiene i moduli davvero letti dalle email (nella 1.12 era ricavato dalla lista).
        var versioneMemoria = 2
        /// F24 eliminati definitivamente: non vengono più riaggiunti.
        var esclusi: [Escluso] = []

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
            // La memoria della 1.12 era ricavata dagli F24 presenti, quindi non sapeva di quelli già
            // eliminati: si riparte da zero e ogni email viene riletta una volta.
            let versione = try valori.decodeIfPresent(Int.self, forKey: .versioneMemoria) ?? 1
            importati = versione >= 2 ? try valori.decodeIfPresent([String: Int].self, forKey: .importati) ?? [:] : [:]
            inizioMs = try valori.decodeIfPresent(Int64.self, forKey: .inizioMs)
            esclusi = try valori.decodeIfPresent([Escluso].self, forKey: .esclusi) ?? []
        }
    }

    /// Un F24 arrivato da Gmail che l'utente ha eliminato definitivamente.
    struct Escluso: Codable, Equatable {
        var messaggioId: String
        var allegato: String?
        var descrizione: String

        func corrisponde(_ f24: F24) -> Bool {
            f24.gmailMessageId == messaggioId && GmailSync.stessoModulo(f24, allegato: allegato, descrizione: descrizione)
        }
    }

    /// Al massimo tante email riscaricate per ogni controllo per riaggiungere F24 eliminati.
    static let massimeEmailDaRipristinare = 10

    static let intervalloControlli: TimeInterval = 30 * 60
    static let massimoParoleChiave = 10

    @Published private(set) var stato: Stato
    @Published private(set) var impostazioni: Impostazioni
    @Published private(set) var inControllo = false
    /// Si sta rileggendo il PDF di un F24 già importato.
    @Published private(set) var rileggendo = false
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

    // MARK: - Controllo

    /// La ricerca fatta su Gmail: mittente = commercialista (o il suo dominio) e oggetto con
    /// almeno una delle parole chiave, es. `from:x (subject:"MOD. F24" OR subject:"Deleghe")`.
    var query: String {
        query(dopoMs: impostazioni.ultimoModulo?.ricevutoIlMs)
    }

    /// La stessa ricerca, limitata alle email arrivate da `dopoMs` in poi (con un giorno di margine:
    /// il confronto preciso si fa poi sull'ora di arrivo).
    func query(dopoMs: Int64?) -> String {
        let mittente = cercaPerDominio ? (dominioCommercialista ?? "") : impostazioni.emailCommercialista
        let oggetti = paroleChiave.map { "subject:\"\($0)\"" }
        var parti = ["from:\(mittente)", oggetti.count == 1 ? oggetti[0] : "(" + oggetti.joined(separator: " OR ") + ")"]
        if let dopo = dopoMs {
            parti.append("after:\(dopo / 1000 - 86_400)")
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
            case .success(let trovati):
                // Le email già lette (importate, scartate o più vecchie della prima importata) non si riscaricano.
                let ids = trovati.filter { self?.impostazioni.importati[$0] == nil }
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
        // Email che non sono F24 del commercialista (o non autentiche): non contengono F24, inutile riscaricarle.
        for messaggio in messaggi where !validi.contains(where: { $0.id == messaggio.id }) && impostazioni.importati[messaggio.id] == nil {
            impostazioni.importati[messaggio.id] = 0
        }
        guard let piuRecente = validi.last else {
            ripristinaEliminati(con: api) { [weak self] ripristinati in
                self?.termina(nuovi: 0, ripristinati: ripristinati, ignorate: ignorate)
            }
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
                for (messaggio, moduli) in zip(nuovi, gruppi) {
                    self.impostazioni.importati[messaggio.id] = moduli.count
                    self.impostazioni.inizioMs = min(self.impostazioni.inizioMs ?? messaggio.ricevutoIlMs, messaggio.ricevutoIlMs)
                }
                // Email più vecchie della prima importata (es. alla prima volta): non vanno mai aggiunte.
                if let inizio = self.impostazioni.inizioMs {
                    for messaggio in validi where messaggio.ricevutoIlMs < inizio && self.impostazioni.importati[messaggio.id] == nil {
                        self.impostazioni.importati[messaggio.id] = 0
                    }
                }
                if piuRecente.ricevutoIlMs > (self.impostazioni.ultimoModulo?.ricevutoIlMs ?? 0) {
                    self.impostazioni.ultimoModulo = UltimoModulo(messaggioId: piuRecente.id,
                                                                  ricevutoIlMs: piuRecente.ricevutoIlMs,
                                                                  oggetto: piuRecente.oggetto)
                }
                self.salva()
                self.ripristinaEliminati(con: api) { [weak self] ripristinati in
                    self?.termina(nuovi: aggiunti.count, ripristinati: ripristinati, ignorate: ignorate)
                }
            }
        }
    }

    private static func leggiF24(da messaggio: MessaggioGmail, con api: GmailAPI,
                                 fine: @escaping (Result<[F24], ErroreGmail>) -> Void) {
        leggi(messaggio, con: api) { risultato in
            fine(risultato.map { letti in letti.map { $0.f24 } })
        }
    }

    /// Scarica i PDF del messaggio (solo in memoria) e ne legge importo e scadenza. La lettura,
    /// che con l'OCR può durare qualche secondo, avviene in sottofondo: la finestra non si blocca.
    private static func leggi(_ messaggio: MessaggioGmail, con api: GmailAPI,
                              fine: @escaping (Result<[LettoreF24.Letto], ErroreGmail>) -> Void) {
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
            switch risultato {
            case .failure(let errore):
                fine(.failure(errore))
            case .success(let pdf):
                let oggetto = messaggio.oggetto
                let corpo = messaggio.testo
                DispatchQueue.global(qos: .userInitiated).async {
                    let letti = LettoreF24.letti(messaggioId: messaggio.id, oggetto: oggetto, corpo: corpo,
                                                 ricevutoIl: messaggio.ricevutoIl, pdf: pdf)
                    DispatchQueue.main.async { fine(.success(letti)) }
                }
            }
        }
    }

    /// Rilegge dal PDF su Gmail importo e scadenza di un F24 già importato e li aggiorna.
    /// Un importo già inserito a mano non viene cancellato se nel PDF non si trova.
    func rileggi(_ f24: F24) {
        guard let id = f24.gmailMessageId, !inControllo else { return }
        guard stato == .collegato else {
            errore = ErroreGmail.accessoScaduto.localizedDescription
            return
        }
        inControllo = true
        rileggendo = true
        errore = nil
        auth.accessToken { [weak self] risultato in
            guard let self = self else { return }
            switch risultato {
            case .failure(let errore):
                self.termina(errore: errore)
            case .success(let token):
                let api = GmailAPI(token: token)
                api.messaggio(id) { [weak self] risultato in
                    switch risultato {
                    case .failure(let errore):
                        self?.termina(errore: errore)
                    case .success(let messaggio):
                        GmailSync.leggi(messaggio, con: api) { [weak self] risultato in
                            switch risultato {
                            case .failure(let errore):
                                self?.termina(errore: errore)
                            case .success(let letti):
                                self?.aggiorna(f24, con: letti)
                            }
                        }
                    }
                }
            }
        }
    }

    private func aggiorna(_ f24: F24, con letti: [LettoreF24.Letto]) {
        // Con più moduli nella stessa email si riconosce quello giusto dalla descrizione ("… – nome file").
        let letto = letti.count == 1 ? letti.first : letti.first { $0.f24.descrizione == f24.descrizione }
        guard let modulo = letto, let attuale = store.elementi.first(where: { $0.id == f24.id }) else {
            termina(errore: .risposta("non trovo il modulo di questo F24 nell'email"))
            return
        }
        var aggiornato = attuale
        if aggiornato.gmailAllegato == nil {
            aggiornato.gmailAllegato = modulo.f24.gmailAllegato
        }
        if let importo = modulo.importo {
            aggiornato.importoCentesimi = importo.centesimi
        }
        if let scadenza = modulo.scadenza {
            aggiornato.scadenza = scadenza.data
        }
        aggiornato.daVerificare = aggiornato.importoCentesimi == nil || modulo.importo?.sicuro == false
            || modulo.scadenza?.sicura != true
        store.aggiorna(aggiornato)
        rileggendo = false
        inControllo = false
        var parti: [String] = []
        parti.append(modulo.importo.map { "importo " + Formato.euro($0.centesimi) } ?? "importo non trovato nel PDF")
        parti.append(modulo.scadenza.map { "scadenza " + Formato.data($0.data) } ?? "scadenza non trovata")
        esito = "PDF riletto: " + parti.joined(separator: ", ")
    }

    // MARK: - F24 eliminati

    /// Le email da cui mancano F24 rispetto a quelli importati (meno quelli eliminati definitivamente).
    /// È un confronto in memoria: se non manca nulla, Gmail non viene nemmeno interpellato.
    var emailConF24Mancanti: [String] {
        var presenti: [String: Int] = [:]
        for f24 in store.elementi {
            if let id = f24.gmailMessageId {
                presenti[id, default: 0] += 1
            }
        }
        return impostazioni.importati
            .filter { id, numero in (presenti[id] ?? 0) < numero - impostazioni.esclusi.filter { $0.messaggioId == id }.count }
            .map { $0.key }
            .sorted()
    }

    /// Quanti F24 di ogni email ci sono ora nella lista.
    private var presentiPerEmail: [String: Int] {
        var presenti: [String: Int] = [:]
        for f24 in store.elementi {
            if let id = f24.gmailMessageId {
                presenti[id, default: 0] += 1
            }
        }
        return presenti
    }

    /// Cosa si è trovato rileggendo un'email per il ripristino.
    private enum EmailRiletta {
        case moduli([LettoreF24.Letto])
        /// Non è un'email del commercialista con la parola chiave, o non è autentica: nessun F24.
        case nonValida
        /// Non c'è più su Gmail.
        case sparita
    }

    /// Confronta le email del commercialista trovate su Gmail (dalla prima importata in poi) con gli F24
    /// della lista e riaggiunge quelli mancanti: tra i da pagare se la scadenza non è passata, altrimenti
    /// tra i pagati (con la scadenza come data del pagamento). Per restare leggero: una sola ricerca che
    /// restituisce solo gli id; ogni email si scarica una volta per sapere quanti F24 contiene, poi solo
    /// se ne manca qualcuno.
    private func ripristinaEliminati(con api: GmailAPI, fine: @escaping (Int) -> Void) {
        determinaInizio(con: api) { [weak self] inizio in
            guard let self = self, let inizio = inizio else {
                fine(0)
                return
            }
            api.cerca(self.query(dopoMs: inizio), massimo: 100) { [weak self] risultato in
                guard let self = self, case .success(let trovate) = risultato else {
                    fine(0)
                    return
                }
                let presenti = self.presentiPerEmail
                var daRileggere: [String] = []
                for id in trovate + self.emailConF24Mancanti where !daRileggere.contains(id) {
                    let esclusi = self.impostazioni.esclusi.filter { $0.messaggioId == id }.count
                    if let numero = self.impostazioni.importati[id], (presenti[id] ?? 0) >= numero - esclusi {
                        continue
                    }
                    daRileggere.append(id)
                }
                self.rileggiEmail(Array(daRileggere.prefix(GmailSync.massimeEmailDaRipristinare)), dopoMs: inizio, con: api, fine: fine)
            }
        }
    }

    private func rileggiEmail(_ ids: [String], dopoMs inizio: Int64, con api: GmailAPI, fine: @escaping (Int) -> Void) {
        guard !ids.isEmpty else {
            fine(0)
            return
        }
        let email = impostazioni.emailCommercialista
        let perDominio = cercaPerDominio
        let parole = paroleChiave
        inSequenza(ids, passo: { (id: String, fatto: @escaping (Result<EmailRiletta, ErroreGmail>) -> Void) in
            api.messaggio(id) { risultato in
                switch risultato {
                case .success(let messaggio):
                    // Stessi controlli dell'importazione: mittente, parola chiave, email autentica.
                    guard messaggio.ricevutoIlMs >= inizio,
                          GmailSync.eDelCommercialista(messaggio, email: email, tuttoIlDominio: perDominio, paroleChiave: parole),
                          messaggio.autenticato(da: email) else {
                        fatto(.success(.nonValida))
                        return
                    }
                    GmailSync.leggi(messaggio, con: api) { letti in fatto(letti.map { .moduli($0) }) }
                case .failure(.nonTrovato):
                    fatto(.success(.sparita))
                case .failure(let errore):
                    fatto(.failure(errore))
                }
            }
        }) { [weak self] risultato in
            guard let self = self else { return }
            guard case .success(let rilette) = risultato else {
                // Errore di rete o di Gmail: si riproverà al prossimo controllo.
                fine(0)
                return
            }
            var ripristinati = 0
            let oggi = Calendar.current.startOfDay(for: Date())
            for (id, riletta) in zip(ids, rilette) {
                switch riletta {
                case .sparita:
                    self.impostazioni.importati[id] = nil
                case .nonValida:
                    self.impostazioni.importati[id] = 0
                case .moduli(let letti):
                    self.impostazioni.importati[id] = letti.count
                    let presenti = self.store.elementi.filter { $0.gmailMessageId == id }
                    for letto in letti {
                        var modulo = letto.f24
                        let giaPresente = presenti.contains { GmailSync.stessoModulo($0, allegato: modulo.gmailAllegato, descrizione: modulo.descrizione) }
                            || (letti.count == 1 && !presenti.isEmpty)
                        guard !giaPresente, !self.impostazioni.esclusi.contains(where: { $0.corrisponde(modulo) }) else { continue }
                        if modulo.scadenza < oggi {
                            modulo.pagatoIl = modulo.scadenza
                            modulo.daVerificare = false
                        }
                        self.store.aggiungi(modulo)
                        ripristinati += 1
                    }
                }
            }
            self.salva()
            fine(ripristinati)
        }
    }

    /// L'ora di arrivo della prima email importata. Se non è salvata (F24 importati con versioni
    /// precedenti) si ricava una volta sola dalle email degli F24 in lista e dall'ultimo modulo trovato,
    /// chiedendo a Gmail solo la data (non l'email intera).
    private func determinaInizio(con api: GmailAPI, fine: @escaping (Int64?) -> Void) {
        if let inizio = impostazioni.inizioMs {
            fine(inizio)
            return
        }
        var noti: [String] = []
        for id in store.elementi.compactMap({ $0.gmailMessageId }) + [impostazioni.ultimoModulo?.messaggioId].compactMap({ $0 })
        where !noti.contains(id) {
            noti.append(id)
        }
        guard !noti.isEmpty else {
            fine(nil)
            return
        }
        inSequenza(Array(noti.prefix(20)), passo: { (id: String, fatto: @escaping (Result<Int64?, ErroreGmail>) -> Void) in
            api.messaggio(id, soloData: true) { risultato in
                switch risultato {
                case .success(let messaggio): fatto(.success(messaggio.ricevutoIlMs))
                case .failure(.nonTrovato): fatto(.success(nil))
                case .failure(let errore): fatto(.failure(errore))
                }
            }
        }) { [weak self] risultato in
            guard let self = self, case .success(let date) = risultato else {
                fine(nil)
                return
            }
            let ultimo = self.impostazioni.ultimoModulo?.ricevutoIlMs
            let inizio = (date.compactMap { $0 } + [ultimo].compactMap { $0 }).min()
            self.impostazioni.inizioMs = inizio
            self.salva()
            fine(inizio)
        }
    }

    /// Elimina un F24 arrivato da Gmail in modo che non venga più riaggiunto.
    func eliminaDefinitivamente(_ f24: F24) {
        if let id = f24.gmailMessageId {
            impostazioni.esclusi.append(Escluso(messaggioId: id, allegato: f24.gmailAllegato, descrizione: f24.descrizione))
            salva()
        }
        store.elimina(f24)
    }

    /// Lo stesso modulo di un'email: stesso PDF allegato oppure, per gli F24 importati prima che
    /// si salvasse il nome del PDF, stessa descrizione.
    static func stessoModulo(_ f24: F24, allegato: String?, descrizione: String) -> Bool {
        if let suo = f24.gmailAllegato, let altro = allegato {
            return suo == altro
        }
        return f24.descrizione == descrizione
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

    private func termina(nuovi: Int, ripristinati: Int = 0, ignorate: Int) {
        inControllo = false
        ultimoControllo = Date()
        emailIgnorate = ignorate
        switch nuovi {
        case 0: esito = "nessun nuovo F24"
        case 1: esito = "aggiunto 1 nuovo F24"
        default: esito = "aggiunti \(nuovi) nuovi F24"
        }
        if ripristinati > 0 {
            esito = (esito ?? "") + (ripristinati == 1 ? " · riaggiunto 1 F24 eliminato" : " · riaggiunti \(ripristinati) F24 eliminati")
        }
        if ignorate > 0 {
            esito = (esito ?? "") + (ignorate == 1
                ? " · 1 email ignorata: mittente non verificato"
                : " · \(ignorate) email ignorate: mittente non verificato")
        }
    }

    private func termina(errore: ErroreGmail) {
        rileggendo = false
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
func inSequenza<Elemento, Risultato>(
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
