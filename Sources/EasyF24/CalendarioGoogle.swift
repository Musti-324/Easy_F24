import AppKit
import Combine
import Foundation

// MARK: - API di Google Calendar

/// Chiamate alle API di Google Calendar. Le risposte arrivano sul main thread.
struct CalendarAPI {
    let token: String
    private static let base = "https://www.googleapis.com/calendar/v3"

    /// I calendari in cui si possono creare eventi.
    func calendari(fine: @escaping (Result<[CalendarioGoogle], ErroreGmail>) -> Void) {
        richiesta("GET", "/users/me/calendarList", parametri: [URLQueryItem(name: "minAccessRole", value: "writer")]) {
            (risultato: Result<ListaCalendari, ErroreGmail>) in fine(risultato.map { $0.items ?? [] })
        }
    }

    /// Gli eventi creati da Easy F24 per un F24 (riconosciuti da una proprietà privata dell'evento).
    func eventi(diF24 id: UUID, calendario: String, fine: @escaping (Result<[EventoGoogle], ErroreGmail>) -> Void) {
        richiesta("GET", "/calendars/\(CalendarAPI.codifica(calendario))/events",
                  parametri: [URLQueryItem(name: "privateExtendedProperty", value: "easyF24=\(id.uuidString)")]) {
            (risultato: Result<ListaEventi, ErroreGmail>) in fine(risultato.map { $0.items ?? [] })
        }
    }

    /// Gli eventi di un giorno che contengono un testo, per riconoscere gli F24 già messi a mano nel calendario.
    func eventi(delGiorno giorno: Date, contenenti testo: String, calendario: String,
                fine: @escaping (Result<[EventoGoogle], ErroreGmail>) -> Void) {
        let inizio = Calendar.current.startOfDay(for: giorno)
        let dopo = Calendar.current.date(byAdding: .day, value: 1, to: inizio) ?? inizio
        let formato = ISO8601DateFormatter()
        formato.timeZone = .current
        richiesta("GET", "/calendars/\(CalendarAPI.codifica(calendario))/events", parametri: [
            URLQueryItem(name: "timeMin", value: formato.string(from: inizio)),
            URLQueryItem(name: "timeMax", value: formato.string(from: dopo)),
            URLQueryItem(name: "q", value: testo),
            URLQueryItem(name: "singleEvents", value: "true"),
        ]) { (risultato: Result<ListaEventi, ErroreGmail>) in fine(risultato.map { $0.items ?? [] }) }
    }

    func crea(_ evento: [String: Any], calendario: String, fine: @escaping (Result<EventoGoogle, ErroreGmail>) -> Void) {
        richiesta("POST", "/calendars/\(CalendarAPI.codifica(calendario))/events", corpo: evento, fine: fine)
    }

    /// Cambia solo i campi indicati (le notifiche dell'evento restano com'erano).
    func modifica(_ eventoId: String, con modifiche: [String: Any], calendario: String,
                  fine: @escaping (Result<EventoGoogle, ErroreGmail>) -> Void) {
        richiesta("PATCH", "/calendars/\(CalendarAPI.codifica(calendario))/events/\(CalendarAPI.codifica(eventoId))",
                  corpo: modifiche, fine: fine)
    }

    func elimina(_ eventoId: String, calendario: String, fine: @escaping (Result<Void, ErroreGmail>) -> Void) {
        invia("DELETE", "/calendars/\(CalendarAPI.codifica(calendario))/events/\(CalendarAPI.codifica(eventoId))") { risultato in
            fine(risultato.map { _ in () })
        }
    }

    // MARK: Richieste

    private func richiesta<T: Decodable>(_ metodo: String, _ percorso: String, parametri: [URLQueryItem] = [],
                                         corpo: [String: Any]? = nil, fine: @escaping (Result<T, ErroreGmail>) -> Void) {
        invia(metodo, percorso, parametri: parametri, corpo: corpo) { risultato in
            switch risultato {
            case .failure(let errore):
                fine(.failure(errore))
            case .success(let dati):
                if let valore = try? JSONDecoder().decode(T.self, from: dati) {
                    fine(.success(valore))
                } else {
                    fine(.failure(.risposta("risposta di Google Calendar non comprensibile")))
                }
            }
        }
    }

    private func invia(_ metodo: String, _ percorso: String, parametri: [URLQueryItem] = [], corpo: [String: Any]? = nil,
                       fine: @escaping (Result<Data, ErroreGmail>) -> Void) {
        guard var indirizzo = URLComponents(string: CalendarAPI.base + percorso) else {
            fine(.failure(.risposta("indirizzo non valido")))
            return
        }
        if !parametri.isEmpty {
            indirizzo.queryItems = parametri
            indirizzo.percentEncodedQuery = indirizzo.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = indirizzo.url, url.scheme == "https", url.host == "www.googleapis.com" else {
            fine(.failure(.risposta("indirizzo non valido")))
            return
        }
        var richiesta = URLRequest(url: url)
        richiesta.httpMethod = metodo
        richiesta.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let corpo = corpo {
            richiesta.setValue("application/json", forHTTPHeaderField: "Content-Type")
            richiesta.httpBody = try? JSONSerialization.data(withJSONObject: corpo)
        }
        Rete.sessione.dataTask(with: richiesta) { dati, risposta, errore in
            let risultato: Result<Data, ErroreGmail>
            let codice = (risposta as? HTTPURLResponse)?.statusCode ?? 0
            if let errore = errore {
                risultato = .failure(.rete(errore.localizedDescription))
            } else if codice == 404 || codice == 410 {
                risultato = .failure(.nonTrovato)
            } else if (200..<300).contains(codice) {
                risultato = .success(dati ?? Data())
            } else {
                // Es. "Google Calendar API has not been used in project … or it is disabled".
                let json = dati.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                let messaggio = (json?["error"] as? [String: Any])?["message"] as? String
                risultato = .failure(.risposta(messaggio ?? "errore HTTP \(codice)"))
            }
            DispatchQueue.main.async { fine(risultato) }
        }.resume()
    }

    /// Id di calendari ed eventi dentro l'indirizzo (es. "lavoro#gruppo@group.calendar.google.com").
    static func codifica(_ valore: String) -> String {
        var consentiti = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        consentiti.insert(charactersIn: "-._~@")
        return valore.addingPercentEncoding(withAllowedCharacters: consentiti) ?? valore
    }
}

struct CalendarioGoogle: Decodable, Identifiable, Equatable {
    let id: String
    let summary: String?
    let primary: Bool?

    var nome: String {
        primary == true ? "\(summary ?? id) (principale)" : (summary ?? id)
    }
}

struct ListaCalendari: Decodable {
    let items: [CalendarioGoogle]?
}

struct EventoGoogle: Decodable {
    let id: String
    let summary: String?
}

struct ListaEventi: Decodable {
    let items: [EventoGoogle]?
}

// MARK: - Impostazioni

/// Una notifica di Google Calendar prima della scadenza.
struct Notifica: Codable, Equatable, Identifiable {
    enum Metodo: String, Codable, CaseIterable {
        case popup, email

        var nome: String { self == .popup ? "Notifica" : "Email" }
    }

    enum Unita: String, Codable, CaseIterable {
        case minuti, ore, giorni, settimane

        var minuti: Int {
            switch self {
            case .minuti: return 1
            case .ore: return 60
            case .giorni: return 1440
            case .settimane: return 10_080
            }
        }

        var nome: String { rawValue }
    }

    var id = UUID()
    var metodo = Metodo.popup
    var quantita = 1
    var unita = Unita.giorni
    /// Per gli eventi di un giorno intero: l'ora della notifica, in minuti dalla mezzanotte.
    var ora = 9 * 60

    /// Minuti prima dell'inizio dell'evento, come li vuole Google (da 0 a 40.320, cioè 4 settimane).
    /// Un evento di un giorno intero inizia a mezzanotte: "1 giorno prima alle 9:00" = 24 ore − 9 ore = 900.
    func minutiPrima(tuttoIlGiorno: Bool) -> Int {
        let minuti: Int
        if tuttoIlGiorno && (unita == .giorni || unita == .settimane) {
            minuti = max(1, quantita) * unita.minuti - ora
        } else {
            minuti = quantita * unita.minuti
        }
        return min(max(minuti, 0), 40_320)
    }
}

/// L'evento del calendario collegato a un F24, con i dati con cui è stato scritto.
struct EventoSalvato: Codable, Equatable {
    var id: String
    var calendarioId: String
    /// Giorno ("2026-11-16") e titolo dell'evento: se nell'F24 cambiano, l'evento va aggiornato.
    var giorno: String
    var titolo: String
    /// Forma dell'evento quando è stato creato (le nuove impostazioni non cambiano gli eventi già creati).
    var tuttoIlGiorno: Bool
    var ora: Int
}

struct ImpostazioniCalendario: Codable, Equatable {
    var attivo = false
    var calendarioId = "primary"
    var calendarioNome = "Calendario principale"
    var tuttoIlGiorno = true
    /// Ora dell'evento quando non è di un giorno intero, in minuti dalla mezzanotte.
    var oraEvento = 9 * 60
    var notifichePredefinite = false
    var notifiche: [Notifica] = [Notifica()]
    /// Eventi creati o trovati nel calendario: id dell'F24 → evento.
    var eventi: [String: EventoSalvato] = [:]

    static let massimoNotifiche = 5

    init() {}

    init(from decoder: Decoder) throws {
        let valori = try decoder.container(keyedBy: CodingKeys.self)
        let predefinite = ImpostazioniCalendario()
        attivo = try valori.decodeIfPresent(Bool.self, forKey: .attivo) ?? predefinite.attivo
        calendarioId = try valori.decodeIfPresent(String.self, forKey: .calendarioId) ?? predefinite.calendarioId
        calendarioNome = try valori.decodeIfPresent(String.self, forKey: .calendarioNome) ?? predefinite.calendarioNome
        tuttoIlGiorno = try valori.decodeIfPresent(Bool.self, forKey: .tuttoIlGiorno) ?? predefinite.tuttoIlGiorno
        oraEvento = try valori.decodeIfPresent(Int.self, forKey: .oraEvento) ?? predefinite.oraEvento
        notifichePredefinite = try valori.decodeIfPresent(Bool.self, forKey: .notifichePredefinite) ?? predefinite.notifichePredefinite
        notifiche = try valori.decodeIfPresent([Notifica].self, forKey: .notifiche) ?? predefinite.notifiche
        eventi = try valori.decodeIfPresent([String: EventoSalvato].self, forKey: .eventi) ?? [:]
    }
}

// MARK: - Sincronizzazione

/// Tiene gli F24 da pagare in Google Calendar: un evento nel giorno della scadenza, tolto quando
/// l'F24 è pagato o eliminato. Si confronta in memoria la lista con gli eventi già creati e si
/// chiama Google solo se c'è qualcosa da aggiungere, spostare o togliere.
final class CalendarioSync: ObservableObject {
    /// Cosa fare per allineare il calendario alla lista.
    enum Operazione {
        case crea(F24)
        case aggiorna(F24, EventoSalvato)
        case elimina(f24Id: String, EventoSalvato)
    }

    @Published private(set) var impostazioni: ImpostazioniCalendario
    @Published private(set) var inCorso = false
    @Published private(set) var inAutorizzazione = false
    @Published private(set) var ultimaSincronizzazione: Date?
    @Published private(set) var esito: String?
    @Published private(set) var errore: String?
    @Published private(set) var calendari: [CalendarioGoogle] = []

    let auth: GoogleAuth
    private let store: F24Store
    private let fileURL: URL
    private var osservatore: AnyCancellable?
    private var daRifare = false

    /// Dopo una modifica alla lista si aspetta un attimo, così più modifiche vicine fanno una sola sincronizzazione.
    static var attesa: TimeInterval = 1.5

    init(store: F24Store, auth: GoogleAuth) {
        self.store = store
        self.auth = auth
        fileURL = store.fileURL.deletingLastPathComponent().appendingPathComponent("calendario.json")
        impostazioni = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(ImpostazioniCalendario.self, from: $0) } ?? ImpostazioniCalendario()
        FileRiservato.proteggi(fileURL)
        osservatore = store.$elementi
            .dropFirst()
            .debounce(for: .seconds(CalendarioSync.attesa), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.sincronizza() }
    }

    var autorizzato: Bool { auth.autorizzato(GoogleAuth.permessiCalendario) }

    func avvia() {
        sincronizza()
    }

    // MARK: Impostazioni

    /// Salva le nuove impostazioni (valgono per gli eventi creati da ora in poi) e, se il calendario
    /// è attivo, fa subito il confronto con la lista.
    func applica(_ nuove: ImpostazioniCalendario) {
        var aggiornate = nuove
        aggiornate.eventi = impostazioni.eventi
        aggiornate.notifiche = Array(nuove.notifiche.prefix(ImpostazioniCalendario.massimoNotifiche))
        guard aggiornate != impostazioni else { return }
        impostazioni = aggiornate
        errore = nil
        salva()
        sincronizza()
    }

    /// Chiede a Google il permesso di gestire gli eventi del calendario (resta valido anche quello di Gmail).
    func autorizza() {
        inAutorizzazione = true
        errore = nil
        auth.accedi(permessi: [GoogleAuth.permessoGmail] + GoogleAuth.permessiCalendario) { [weak self] risultato in
            guard let self = self else { return }
            self.inAutorizzazione = false
            switch risultato {
            case .success:
                NSApp.activate(ignoringOtherApps: true)
                self.caricaCalendari()
                self.sincronizza()
            case .failure(let errore):
                self.errore = errore.localizedDescription
            }
        }
    }

    func annullaAutorizzazione() {
        auth.annullaAccesso()
        inAutorizzazione = false
    }

    func caricaCalendari() {
        guard autorizzato else { return }
        auth.accessToken { [weak self] risultato in
            guard case .success(let token) = risultato else { return }
            CalendarAPI(token: token).calendari { risultato in
                if case .success(let calendari) = risultato {
                    self?.calendari = calendari
                }
            }
        }
    }

    // MARK: Confronto

    static func giorno(_ data: Date) -> String {
        let formato = DateFormatter()
        formato.locale = Locale(identifier: "en_US_POSIX")
        formato.dateFormat = "yyyy-MM-dd"
        return formato.string(from: data)
    }

    static func titolo(_ f24: F24) -> String {
        let importo = f24.importoCentesimi.map { " · " + Formato.euro($0) } ?? ""
        return String(("F24 da pagare" + importo + " · " + f24.descrizione).prefix(150))
    }

    /// Le operazioni necessarie, calcolate senza chiamare Google: vuoto = calendario già allineato.
    var operazioni: [Operazione] {
        var perId: [String: F24] = [:]
        for f24 in store.elementi {
            perId[f24.id.uuidString] = f24
        }
        var operazioni: [Operazione] = []
        for (id, evento) in impostazioni.eventi.sorted(by: { $0.key < $1.key }) {
            if let f24 = perId[id], !f24.isPagato {
                if evento.giorno != CalendarioSync.giorno(f24.scadenza) || evento.titolo != CalendarioSync.titolo(f24) {
                    operazioni.append(.aggiorna(f24, evento))
                }
            } else {
                // Pagato o eliminato: l'evento va tolto.
                operazioni.append(.elimina(f24Id: id, evento))
            }
        }
        for f24 in store.daPagare where impostazioni.eventi[f24.id.uuidString] == nil {
            operazioni.append(.crea(f24))
        }
        return operazioni
    }

    func sincronizza() {
        guard impostazioni.attivo else { return }
        guard autorizzato else {
            errore = "Autorizza Google Calendar da «Calendario…»."
            return
        }
        if inCorso {
            daRifare = true
            return
        }
        let daFare = operazioni
        guard !daFare.isEmpty else { return }
        inCorso = true
        errore = nil
        auth.accessToken { [weak self] risultato in
            guard let self = self else { return }
            switch risultato {
            case .failure(let errore):
                self.termina(conteggi: [:], errore: errore)
            case .success(let token):
                let api = CalendarAPI(token: token)
                var conteggi: [String: Int] = [:]
                inSequenza(daFare, passo: { (operazione: Operazione, fatto: @escaping (Result<Void, ErroreGmail>) -> Void) in
                    self.esegui(operazione, con: api) { risultato in
                        if case .success(let tipo) = risultato {
                            conteggi[tipo, default: 0] += 1
                        }
                        fatto(risultato.map { _ in () })
                    }
                }) { risultato in
                    if case .failure(let errore) = risultato {
                        self.termina(conteggi: conteggi, errore: errore)
                    } else {
                        self.termina(conteggi: conteggi, errore: nil)
                    }
                }
            }
        }
    }

    /// Esegue un'operazione; `fine` riceve "aggiunti", "aggiornati", "tolti" o "trovati".
    private func esegui(_ operazione: Operazione, con api: CalendarAPI, fine: @escaping (Result<String, ErroreGmail>) -> Void) {
        switch operazione {
        case .elimina(let id, let evento):
            api.elimina(evento.id, calendario: evento.calendarioId) { [weak self] risultato in
                switch risultato {
                case .success, .failure(.nonTrovato):
                    self?.impostazioni.eventi[id] = nil
                    self?.salva()
                    fine(.success("tolti"))
                case .failure(let errore):
                    fine(.failure(errore))
                }
            }
        case .aggiorna(let f24, let evento):
            var modifiche = CalendarioSync.date(f24, tuttoIlGiorno: evento.tuttoIlGiorno, ora: evento.ora)
            modifiche["summary"] = CalendarioSync.titolo(f24)
            modifiche["description"] = CalendarioSync.descrizione(f24)
            api.modifica(evento.id, con: modifiche, calendario: evento.calendarioId) { [weak self] risultato in
                guard let self = self else { return }
                switch risultato {
                case .success:
                    self.ricorda(f24, eventoId: evento.id, calendarioId: evento.calendarioId, tuttoIlGiorno: evento.tuttoIlGiorno, ora: evento.ora)
                    fine(.success("aggiornati"))
                case .failure(.nonTrovato):
                    // Evento cancellato a mano in Google Calendar: lo si ricrea.
                    self.impostazioni.eventi[f24.id.uuidString] = nil
                    self.crea(f24, con: api, fine: fine)
                case .failure(let errore):
                    fine(.failure(errore))
                }
            }
        case .crea(let f24):
            cercaEsistente(f24, con: api, fine: fine)
        }
    }

    /// Prima di creare l'evento si guarda se nel calendario c'è già: creato in passato da Easy F24
    /// oppure messo a mano (un evento di quel giorno con "F24" nel titolo e lo stesso importo o descrizione).
    private func cercaEsistente(_ f24: F24, con api: CalendarAPI, fine: @escaping (Result<String, ErroreGmail>) -> Void) {
        let calendario = impostazioni.calendarioId
        api.eventi(diF24: f24.id, calendario: calendario) { [weak self] risultato in
            guard let self = self else { return }
            switch risultato {
            case .failure(let errore):
                fine(.failure(errore))
            case .success(let nostri):
                if let evento = nostri.first {
                    self.ricorda(f24, eventoId: evento.id, calendarioId: calendario,
                                 tuttoIlGiorno: self.impostazioni.tuttoIlGiorno, ora: self.impostazioni.oraEvento, titolo: evento.summary)
                    fine(.success("trovati"))
                    return
                }
                api.eventi(delGiorno: f24.scadenza, contenenti: "F24", calendario: calendario) { [weak self] risultato in
                    guard let self = self else { return }
                    switch risultato {
                    case .failure(let errore):
                        fine(.failure(errore))
                    case .success(let delGiorno):
                        if let evento = delGiorno.first(where: { CalendarioSync.corrisponde($0, a: f24) }) {
                            // Messo a mano dall'utente: non lo si tocca, lo si ricorda solo (verrà tolto quando è pagato).
                            self.ricorda(f24, eventoId: evento.id, calendarioId: calendario,
                                         tuttoIlGiorno: self.impostazioni.tuttoIlGiorno, ora: self.impostazioni.oraEvento)
                            fine(.success("trovati"))
                        } else {
                            self.crea(f24, con: api, fine: fine)
                        }
                    }
                }
            }
        }
    }

    static func corrisponde(_ evento: EventoGoogle, a f24: F24) -> Bool {
        let titolo = (evento.summary ?? "").lowercased()
        guard titolo.contains("f24") else { return false }
        if let importo = f24.importoCentesimi {
            let testo = Formato.importo(importo)
            return titolo.contains(testo.lowercased()) || titolo.contains(testo.replacingOccurrences(of: ".", with: ""))
        }
        return titolo.contains(String(f24.descrizione.lowercased().prefix(20)))
    }

    private func crea(_ f24: F24, con api: CalendarAPI, fine: @escaping (Result<String, ErroreGmail>) -> Void) {
        let calendario = impostazioni.calendarioId
        let tuttoIlGiorno = impostazioni.tuttoIlGiorno
        let ora = impostazioni.oraEvento
        api.crea(corpoEvento(f24), calendario: calendario) { [weak self] risultato in
            switch risultato {
            case .success(let evento):
                self?.ricorda(f24, eventoId: evento.id, calendarioId: calendario, tuttoIlGiorno: tuttoIlGiorno, ora: ora)
                fine(.success("aggiunti"))
            case .failure(let errore):
                fine(.failure(errore))
            }
        }
    }

    private func ricorda(_ f24: F24, eventoId: String, calendarioId: String, tuttoIlGiorno: Bool, ora: Int, titolo: String? = nil) {
        impostazioni.eventi[f24.id.uuidString] = EventoSalvato(id: eventoId, calendarioId: calendarioId,
                                                               giorno: CalendarioSync.giorno(f24.scadenza),
                                                               titolo: titolo ?? CalendarioSync.titolo(f24),
                                                               tuttoIlGiorno: tuttoIlGiorno, ora: ora)
        salva()
    }

    // MARK: Contenuto dell'evento

    /// L'evento per un F24, con le impostazioni attuali (notifiche comprese).
    func corpoEvento(_ f24: F24) -> [String: Any] {
        var corpo = CalendarioSync.date(f24, tuttoIlGiorno: impostazioni.tuttoIlGiorno, ora: impostazioni.oraEvento)
        corpo["summary"] = CalendarioSync.titolo(f24)
        corpo["description"] = CalendarioSync.descrizione(f24)
        corpo["transparency"] = "transparent"
        corpo["extendedProperties"] = ["private": ["easyF24": f24.id.uuidString]]
        if impostazioni.notifichePredefinite {
            corpo["reminders"] = ["useDefault": true]
        } else {
            var viste: [String] = []
            var notifiche: [[String: Any]] = []
            for notifica in impostazioni.notifiche.prefix(ImpostazioniCalendario.massimoNotifiche) {
                let minuti = notifica.minutiPrima(tuttoIlGiorno: impostazioni.tuttoIlGiorno)
                let chiave = notifica.metodo.rawValue + "\(minuti)"
                if !viste.contains(chiave) {
                    viste.append(chiave)
                    notifiche.append(["method": notifica.metodo.rawValue, "minutes": minuti])
                }
            }
            corpo["reminders"] = ["useDefault": false, "overrides": notifiche]
        }
        return corpo
    }

    /// Inizio e fine dell'evento: tutto il giorno della scadenza, oppure mezz'ora a un orario.
    static func date(_ f24: F24, tuttoIlGiorno: Bool, ora: Int) -> [String: Any] {
        let calendario = Calendar.current
        let giornoScadenza = calendario.startOfDay(for: f24.scadenza)
        if tuttoIlGiorno {
            let dopo = calendario.date(byAdding: .day, value: 1, to: giornoScadenza) ?? giornoScadenza
            return ["start": ["date": giorno(giornoScadenza)], "end": ["date": giorno(dopo)]]
        }
        let inizio = giornoScadenza.addingTimeInterval(TimeInterval(ora * 60))
        let fine = inizio.addingTimeInterval(30 * 60)
        let formato = DateFormatter()
        formato.locale = Locale(identifier: "en_US_POSIX")
        formato.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let zona = TimeZone.current.identifier
        return ["start": ["dateTime": formato.string(from: inizio), "timeZone": zona],
                "end": ["dateTime": formato.string(from: fine), "timeZone": zona]]
    }

    static func descrizione(_ f24: F24) -> String {
        var righe: [String] = [f24.descrizione]
        if let importo = f24.importoCentesimi {
            righe.append("Importo: " + Formato.euro(importo))
        }
        righe.append("Scadenza: " + Formato.data(f24.scadenza))
        righe.append("")
        righe.append("Aggiunto da Easy F24: quando lo segni come pagato nell'app, questo evento viene tolto.")
        return righe.joined(separator: "\n")
    }

    // MARK: Fine

    private func termina(conteggi: [String: Int], errore: ErroreGmail?) {
        inCorso = false
        ultimaSincronizzazione = Date()
        if let errore = errore {
            auth.dimenticaAccessToken()
            self.errore = errore.localizedDescription
        }
        let parti = [("aggiunti", "aggiunti"), ("trovati", "già presenti"), ("aggiornati", "spostati"), ("tolti", "tolti")]
            .compactMap { chiave, nome in conteggi[chiave].map { "\($0) \(nome)" } }
        esito = parti.isEmpty ? "calendario già aggiornato" : "eventi " + parti.joined(separator: ", ")
        if daRifare {
            daRifare = false
            sincronizza()
        }
    }

    private func salva() {
        if let dati = try? JSONEncoder().encode(impostazioni) {
            try? FileRiservato.scrivi(dati, in: fileURL)
        }
    }
}
