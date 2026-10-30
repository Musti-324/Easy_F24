import AppKit
import Combine
import Foundation

/// Controlla Gmail e aggiunge tra gli F24 da pagare i moduli che arrivano dal commercialista:
/// email inviate dal suo indirizzo con almeno "MOD. F24" nell'oggetto.
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
        /// Account Gmail collegato (solo per mostrarlo).
        var account: String?
        var ultimoModulo: UltimoModulo?
    }

    /// Testo che l'oggetto dell'email deve contenere.
    static let oggettoRichiesto = "MOD. F24"
    static let intervalloControlli: TimeInterval = 30 * 60

    @Published private(set) var stato: Stato
    @Published private(set) var impostazioni: Impostazioni
    @Published private(set) var inControllo = false
    @Published private(set) var ultimoControllo: Date?
    /// Esito dell'ultimo controllo, es. "Aggiunto 1 nuovo F24".
    @Published private(set) var esito: String?
    @Published private(set) var errore: String?

    var ultimoModulo: UltimoModulo? { impostazioni.ultimoModulo }
    var emailCommercialistaValida: Bool { GmailSync.emailValida(impostazioni.emailCommercialista) }

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

    /// La ricerca fatta su Gmail: mittente = commercialista, oggetto con "MOD. F24".
    var query: String {
        var parti = ["from:\(impostazioni.emailCommercialista)", "subject:\"\(GmailSync.oggettoRichiesto)\""]
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
        // Gmail cerca per parole: qui si controlla che mittente e oggetto siano proprio quelli giusti.
        let validi = messaggi
            .filter { GmailSync.eDelCommercialista($0, email: impostazioni.emailCommercialista) }
            .sorted { $0.ricevutoIlMs < $1.ricevutoIlMs }
        guard let piuRecente = validi.last else {
            termina(nuovi: 0)
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
                self.termina(nuovi: aggiunti.count)
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
                    fatto(risultato.map { LettoreF24.PDF(nome: allegato.nome, dati: $0) })
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

    static func eDelCommercialista(_ messaggio: MessaggioGmail, email: String) -> Bool {
        let oggettoGiusto = messaggio.oggetto.range(of: #"MOD\.\s*F24"#, options: [.regularExpression, .caseInsensitive]) != nil
        return oggettoGiusto && messaggio.mittente.lowercased().contains(email.lowercased())
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

    private func termina(nuovi: Int) {
        inControllo = false
        ultimoControllo = Date()
        switch nuovi {
        case 0: esito = "nessun nuovo F24"
        case 1: esito = "aggiunto 1 nuovo F24"
        default: esito = "aggiunti \(nuovi) nuovi F24"
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
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true, attributes: nil)
        if let dati = try? GmailSync.encoder.encode(impostazioni) {
            try? dati.write(to: fileURL, options: .atomic)
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
