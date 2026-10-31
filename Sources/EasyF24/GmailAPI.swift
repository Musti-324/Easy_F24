import Foundation

/// Chiamate all'API di Gmail in sola lettura. Le risposte arrivano sul main thread.
struct GmailAPI {
    let token: String
    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    /// Indirizzo email dell'account collegato.
    func profilo(fine: @escaping (Result<String, ErroreGmail>) -> Void) {
        richiesta("/profile") { (risultato: Result<ProfiloGmail, ErroreGmail>) in
            fine(risultato.map { $0.emailAddress })
        }
    }

    /// Id dei messaggi che rispondono alla ricerca, dal più recente.
    func cerca(_ query: String, massimo: Int, fine: @escaping (Result<[String], ErroreGmail>) -> Void) {
        let parametri = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(massimo))]
        richiesta("/messages", parametri: parametri) { (risultato: Result<ListaGmail, ErroreGmail>) in
            fine(risultato.map { ($0.messages ?? []).map { $0.id } })
        }
    }

    /// Un messaggio. Con `soloData` arrivano solo id e ora di arrivo (molto più leggero).
    func messaggio(_ id: String, soloData: Bool = false, fine: @escaping (Result<MessaggioGmail, ErroreGmail>) -> Void) {
        guard GmailAPI.idValido(id) else {
            fine(.failure(.risposta("identificativo di messaggio non valido")))
            return
        }
        richiesta("/messages/\(id)", parametri: [URLQueryItem(name: "format", value: soloData ? "minimal" : "full")], fine: fine)
    }

    func allegato(messaggio: String, allegato: String, fine: @escaping (Result<Data, ErroreGmail>) -> Void) {
        guard GmailAPI.idValido(messaggio), GmailAPI.idValido(allegato) else {
            fine(.failure(.risposta("identificativo di allegato non valido")))
            return
        }
        richiesta("/messages/\(messaggio)/attachments/\(allegato)") { (risultato: Result<AllegatoGmail, ErroreGmail>) in
            switch risultato {
            case .failure(let errore):
                fine(.failure(errore))
            case .success(let allegato):
                if let dati = Base64URL.dati(allegato.data) {
                    fine(.success(dati))
                } else {
                    fine(.failure(.risposta("allegato illeggibile")))
                }
            }
        }
    }

    private func richiesta<T: Decodable>(_ percorso: String, parametri: [URLQueryItem] = [],
                                         fine: @escaping (Result<T, ErroreGmail>) -> Void) {
        guard var indirizzo = URLComponents(string: GmailAPI.base + percorso) else {
            fine(.failure(.risposta("indirizzo non valido")))
            return
        }
        if !parametri.isEmpty {
            indirizzo.queryItems = parametri
            // "+" (es. in un indirizzo email) altrimenti verrebbe letto come spazio.
            indirizzo.percentEncodedQuery = indirizzo.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = indirizzo.url, url.scheme == "https", url.host == "gmail.googleapis.com" else {
            fine(.failure(.risposta("indirizzo non valido")))
            return
        }
        var richiesta = URLRequest(url: url)
        richiesta.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        Rete.sessione.dataTask(with: richiesta) { dati, risposta, errore in
            let risultato: Result<T, ErroreGmail> = GmailAPI.interpreta(dati: dati, risposta: risposta, errore: errore)
            DispatchQueue.main.async { fine(risultato) }
        }.resume()
    }

    /// Gli id di Gmail sono fatti solo di lettere, cifre, "-" e "_": altro non finisce nell'indirizzo.
    static func idValido(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 1024 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    private static func interpreta<T: Decodable>(dati: Data?, risposta: URLResponse?, errore: Error?) -> Result<T, ErroreGmail> {
        if let errore = errore {
            return .failure(.rete(errore.localizedDescription))
        }
        guard let dati = dati else {
            return .failure(.risposta("risposta vuota"))
        }
        let codice = (risposta as? HTTPURLResponse)?.statusCode ?? 0
        if codice == 404 {
            return .failure(.nonTrovato)
        }
        guard codice == 200 else {
            // Es. "Gmail API has not been used in project … or it is disabled".
            let json = (try? JSONSerialization.jsonObject(with: dati)) as? [String: Any]
            let messaggio = (json?["error"] as? [String: Any])?["message"] as? String
            return .failure(.risposta(messaggio ?? "errore HTTP \(codice)"))
        }
        do {
            return .success(try JSONDecoder().decode(T.self, from: dati))
        } catch {
            return .failure(.risposta("risposta di Gmail non comprensibile"))
        }
    }
}

// MARK: - Risposte di Gmail

struct ProfiloGmail: Decodable {
    let emailAddress: String
}

struct ListaGmail: Decodable {
    struct Riferimento: Decodable {
        let id: String
    }
    let messages: [Riferimento]?
}

struct AllegatoGmail: Decodable {
    let data: String
}

struct MessaggioGmail: Decodable {
    let id: String
    /// Ora di arrivo in millisecondi, come stringa.
    let internalDate: String?
    let snippet: String?
    let payload: ParteGmail?

    /// Allegato PDF: i dati sono già nel messaggio oppure vanno scaricati con `attachmentId`.
    struct PDF {
        let nome: String
        let attachmentId: String?
        let dati: Data?
    }

    /// Limiti agli allegati letti, contro email costruite per bloccare o attaccare l'app.
    static let massimoPDF = 10
    static let massimaDimensionePDF = 10 * 1024 * 1024

    var ricevutoIlMs: Int64 { Int64(internalDate ?? "") ?? 0 }
    var ricevutoIl: Date { Date(timeIntervalSince1970: Double(ricevutoIlMs) / 1000) }
    var oggetto: String { intestazione("Subject") ?? "" }
    var mittente: String { intestazione("From") ?? "" }

    func intestazione(_ nome: String) -> String? {
        intestazioni(nome).first
    }

    /// Tutte le intestazioni con questo nome, nell'ordine del messaggio (dalla più recente).
    func intestazioni(_ nome: String) -> [String] {
        (payload?.headers ?? []).filter { $0.name.lowercased() == nome.lowercased() }.map { $0.value }
    }

    /// Gmail ha verificato (SPF/DKIM/DMARC) che l'email viene davvero dal dominio di `email`.
    func autenticato(da email: String) -> Bool {
        VerificaMittente.autenticato(intestazioni("Authentication-Results"), email: email)
    }

    /// Il testo dell'email (preferisce la versione senza formattazione).
    var testo: String {
        let parti = payload?.tutte ?? []
        func testi(_ tipo: String) -> [String] {
            parti.filter { $0.mimeType?.lowercased() == tipo && ($0.filename ?? "").isEmpty }
                .compactMap { $0.body?.data.flatMap(Base64URL.testo) }
        }
        let semplice = testi("text/plain")
        if !semplice.isEmpty {
            return String(semplice.joined(separator: "\n").prefix(LettoreF24.massimaLunghezzaTesto))
        }
        let html = testi("text/html")
        if !html.isEmpty {
            return LettoreF24.togliHTML(String(html.joined(separator: "\n").prefix(LettoreF24.massimaLunghezzaTesto)))
        }
        return snippet ?? ""
    }

    var allegatiPDF: [PDF] {
        (payload?.tutte ?? []).compactMap { parte in
            let nome = parte.filename ?? ""
            let ePDF = parte.mimeType?.lowercased() == "application/pdf" || nome.lowercased().hasSuffix(".pdf")
            let dimensione = parte.body?.size ?? 0
            guard ePDF, dimensione <= MessaggioGmail.massimaDimensionePDF else { return nil }
            let dati = parte.body?.data.flatMap(Base64URL.dati)
            guard parte.body?.attachmentId != nil || dati != nil else { return nil }
            return PDF(nome: nome.isEmpty ? "modulo.pdf" : nome, attachmentId: parte.body?.attachmentId, dati: dati)
        }
        .prefix(MessaggioGmail.massimoPDF)
        .map { $0 }
    }
}

struct ParteGmail: Decodable {
    struct Intestazione: Decodable {
        let name: String
        let value: String
    }
    struct Corpo: Decodable {
        let attachmentId: String?
        let size: Int?
        let data: String?
    }

    let mimeType: String?
    let filename: String?
    let headers: [Intestazione]?
    let body: Corpo?
    let parts: [ParteGmail]?

    /// Questa parte e tutte quelle contenute, in ordine.
    var tutte: [ParteGmail] {
        [self] + (parts ?? []).flatMap { $0.tutte }
    }
}

/// Gmail codifica testi e allegati in Base64 "URL safe".
enum Base64URL {
    static func dati(_ testo: String) -> Data? {
        var base64 = testo
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base64.count % 4 != 0 {
            base64 += "="
        }
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    static func testo(_ base64: String) -> String? {
        guard let dati = dati(base64) else { return nil }
        return String(data: dati, encoding: .utf8) ?? String(data: dati, encoding: .windowsCP1252)
    }
}
