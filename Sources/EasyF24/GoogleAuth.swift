import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// Credenziali dell'app creata su Google Cloud ("ID client OAuth" di tipo App desktop)
/// più il token che permette di restare collegati senza rifare l'accesso.
struct CredenzialiGoogle: Codable, Equatable {
    var clientId: String
    var clientSecret: String
    var refreshToken: String?

    /// Legge il file JSON scaricato da Google Cloud.
    static func daFileGoogle(_ dati: Data) -> CredenzialiGoogle? {
        guard let json = (try? JSONSerialization.jsonObject(with: dati)) as? [String: Any],
              let blocco = (json["installed"] ?? json["web"]) as? [String: Any],
              let clientId = blocco["client_id"] as? String,
              let clientSecret = blocco["client_secret"] as? String
        else { return nil }
        return CredenzialiGoogle(clientId: clientId, clientSecret: clientSecret, refreshToken: nil)
    }
}

enum ErroreGmail: LocalizedError {
    case credenzialiMancanti
    case accessoNegato(String)
    case accessoScaduto
    case rete(String)
    case risposta(String)

    var errorDescription: String? {
        switch self {
        case .credenzialiMancanti:
            return "Mancano le credenziali dell'app Google."
        case .accessoNegato(let dettaglio):
            return "Accesso a Google non riuscito (\(dettaglio))."
        case .accessoScaduto:
            return "L'accesso a Gmail è scaduto: ricollegati da «Gmail…»."
        case .rete(let dettaglio):
            return "Gmail non raggiungibile: \(dettaglio)"
        case .risposta(let dettaglio):
            return "Errore da Google: \(dettaglio)"
        }
    }
}

/// Accesso a Google con OAuth 2.0 per app desktop: l'app apre il browser, l'utente
/// acconsente e Google rimanda a un piccolo server locale (127.0.0.1) avviato dall'app.
/// Le credenziali restano nel Portachiavi; l'app non vede mai la password di Google.
final class GoogleAuth {
    static let servizioPredefinito = "Easy F24 – Gmail"
    private static let accountPortachiavi = "google-oauth"
    private static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    private(set) var credenziali: CredenzialiGoogle?
    private let servizioPortachiavi: String?
    private var accessToken: String?
    private var scadenzaAccessToken = Date.distantPast
    private var ricevitore: RicevitoreRedirect?

    /// - Parameter servizioPortachiavi: voce del Portachiavi in cui tenere le credenziali (nil = non salvarle).
    init(servizioPortachiavi: String? = GoogleAuth.servizioPredefinito, credenziali: CredenzialiGoogle? = nil) {
        self.servizioPortachiavi = servizioPortachiavi
        if let credenziali = credenziali {
            self.credenziali = credenziali
        } else if let servizio = servizioPortachiavi,
                  let dati = Portachiavi.leggi(servizio: servizio, account: GoogleAuth.accountPortachiavi) {
            self.credenziali = try? JSONDecoder().decode(CredenzialiGoogle.self, from: dati)
        }
    }

    var collegato: Bool { credenziali?.refreshToken != nil }

    /// Salva ID e secret dell'app Google. Restituisce true se sono cambiati
    /// (in quel caso il collegamento precedente non vale più).
    @discardableResult
    func impostaCredenziali(clientId: String, clientSecret: String) -> Bool {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != credenziali?.clientId || secret != credenziali?.clientSecret else { return false }
        credenziali = CredenzialiGoogle(clientId: id, clientSecret: secret, refreshToken: nil)
        dimenticaAccessToken()
        salva()
        return true
    }

    /// Apre il browser sulla pagina di accesso di Google. `fine` arriva sul main thread.
    func accedi(fine: @escaping (Result<Void, ErroreGmail>) -> Void) {
        guard let credenziali = credenziali else {
            fine(.failure(.credenzialiMancanti))
            return
        }
        annullaAccesso()
        let verificatore = GoogleAuth.casuale(lunghezza: 64)
        let sfida = GoogleAuth.base64url(Data(SHA256.hash(data: Data(verificatore.utf8))))
        let stato = GoogleAuth.casuale(lunghezza: 32)
        var redirect = ""
        let ricevitore = RicevitoreRedirect()
        self.ricevitore = ricevitore
        ricevitore.avvia(pronto: { risultato in
            switch risultato {
            case .failure(let errore):
                fine(.failure(.rete(errore.localizedDescription)))
            case .success(let porta):
                redirect = "http://127.0.0.1:\(porta)/"
                var indirizzo = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                indirizzo.queryItems = [
                    URLQueryItem(name: "client_id", value: credenziali.clientId),
                    URLQueryItem(name: "redirect_uri", value: redirect),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "scope", value: GoogleAuth.scope),
                    URLQueryItem(name: "access_type", value: "offline"),
                    URLQueryItem(name: "prompt", value: "consent"),
                    URLQueryItem(name: "code_challenge", value: sfida),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "state", value: stato),
                ]
                NSWorkspace.shared.open(indirizzo.url!)
            }
        }, risposta: { [weak self] parametri in
            guard let self = self else { return }
            self.annullaAccesso()
            if let errore = parametri["error"] {
                fine(.failure(.accessoNegato(errore)))
            } else if let codice = parametri["code"], parametri["state"] == stato {
                self.scambia(codice: codice, verificatore: verificatore, redirect: redirect, fine: fine)
            } else {
                fine(.failure(.accessoNegato("risposta inattesa")))
            }
        })
    }

    /// Smette di aspettare il ritorno dal browser.
    func annullaAccesso() {
        ricevitore?.ferma()
        ricevitore = nil
    }

    /// Restituisce un access token valido, rinnovandolo quando scade (dura circa un'ora).
    func accessToken(fine: @escaping (Result<String, ErroreGmail>) -> Void) {
        if let token = accessToken, scadenzaAccessToken > Date().addingTimeInterval(60) {
            fine(.success(token))
            return
        }
        guard let credenziali = credenziali, let refresh = credenziali.refreshToken else {
            fine(.failure(.accessoScaduto))
            return
        }
        richiestaToken([
            "client_id": credenziali.clientId,
            "client_secret": credenziali.clientSecret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ]) { [weak self] risultato in
            guard let self = self else { return }
            switch risultato {
            case .failure(let errore):
                if case .accessoScaduto = errore {
                    self.credenziali?.refreshToken = nil
                    self.salva()
                }
                fine(.failure(errore))
            case .success(let json):
                if let token = self.memorizza(json) {
                    fine(.success(token))
                } else {
                    fine(.failure(.risposta("token mancante")))
                }
            }
        }
    }

    /// Scollega l'account: revoca il permesso su Google e lo toglie dal Portachiavi.
    func esci() {
        if let token = credenziali?.refreshToken,
           let url = URL(string: "https://oauth2.googleapis.com/revoke") {
            var richiesta = URLRequest(url: url)
            richiesta.httpMethod = "POST"
            richiesta.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            richiesta.httpBody = GoogleAuth.codificaForm(["token": token])
            URLSession.shared.dataTask(with: richiesta).resume()
        }
        credenziali?.refreshToken = nil
        dimenticaAccessToken()
        salva()
    }

    func dimenticaAccessToken() {
        accessToken = nil
        scadenzaAccessToken = .distantPast
    }

    // MARK: - Token

    private func scambia(codice: String, verificatore: String, redirect: String,
                         fine: @escaping (Result<Void, ErroreGmail>) -> Void) {
        guard let credenziali = credenziali else {
            fine(.failure(.credenzialiMancanti))
            return
        }
        richiestaToken([
            "code": codice,
            "client_id": credenziali.clientId,
            "client_secret": credenziali.clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verificatore,
        ]) { [weak self] risultato in
            guard let self = self else { return }
            switch risultato {
            case .failure(let errore):
                fine(.failure(errore))
            case .success(let json):
                guard self.memorizza(json) != nil, let refresh = json["refresh_token"] as? String else {
                    fine(.failure(.risposta("Google non ha restituito i token di accesso")))
                    return
                }
                self.credenziali?.refreshToken = refresh
                self.salva()
                fine(.success(()))
            }
        }
    }

    private func memorizza(_ json: [String: Any]) -> String? {
        guard let token = json["access_token"] as? String else { return nil }
        accessToken = token
        scadenzaAccessToken = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        return token
    }

    private func richiestaToken(_ parametri: [String: String],
                                fine: @escaping (Result<[String: Any], ErroreGmail>) -> Void) {
        var richiesta = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        richiesta.httpMethod = "POST"
        richiesta.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        richiesta.httpBody = GoogleAuth.codificaForm(parametri)
        URLSession.shared.dataTask(with: richiesta) { dati, _, errore in
            let risultato: Result<[String: Any], ErroreGmail>
            if let errore = errore {
                risultato = .failure(.rete(errore.localizedDescription))
            } else if let dati = dati, let json = (try? JSONSerialization.jsonObject(with: dati)) as? [String: Any] {
                switch json["error"] as? String {
                case nil:
                    risultato = .success(json)
                case "invalid_grant"?:
                    risultato = .failure(.accessoScaduto)
                case "invalid_client"?:
                    risultato = .failure(.risposta("Client ID o client secret non validi"))
                case let codice?:
                    risultato = .failure(.risposta(json["error_description"] as? String ?? codice))
                }
            } else {
                risultato = .failure(.risposta("risposta non valida"))
            }
            DispatchQueue.main.async { fine(risultato) }
        }.resume()
    }

    private func salva() {
        guard let servizio = servizioPortachiavi else { return }
        if let credenziali = credenziali, let dati = try? JSONEncoder().encode(credenziali) {
            Portachiavi.salva(dati, servizio: servizio, account: GoogleAuth.accountPortachiavi)
        } else {
            Portachiavi.elimina(servizio: servizio, account: GoogleAuth.accountPortachiavi)
        }
    }

    // MARK: - Utilità

    private static func casuale(lunghezza: Int) -> String {
        let caratteri = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var byte = [UInt8](repeating: 0, count: lunghezza)
        _ = SecRandomCopyBytes(kSecRandomDefault, lunghezza, &byte)
        return String(byte.map { caratteri[Int($0) % caratteri.count] })
    }

    private static func base64url(_ dati: Data) -> String {
        dati.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codificaForm(_ parametri: [String: String]) -> Data? {
        var consentiti = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        consentiti.insert(charactersIn: "-._~")
        return parametri
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: consentiti) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
    }
}

/// Piccolo server HTTP su 127.0.0.1 che riceve il ritorno di Google dopo l'accesso.
final class RicevitoreRedirect {
    private var listener: NWListener?

    /// `pronto` riceve la porta su cui ascolta; `risposta` i parametri rimandati da Google.
    func avvia(pronto: @escaping (Result<UInt16, Error>) -> Void,
               risposta: @escaping ([String: String]) -> Void) {
        let parametri = NWParameters.tcp
        parametri.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parametri)
        } catch {
            pronto(.failure(error))
            return
        }
        self.listener = listener
        var avvisato = false
        listener.stateUpdateHandler = { stato in
            switch stato {
            case .ready:
                if !avvisato, let porta = listener.port {
                    avvisato = true
                    pronto(.success(porta.rawValue))
                }
            case .failed(let errore):
                if !avvisato {
                    avvisato = true
                    pronto(.failure(errore))
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { connessione in
            RicevitoreRedirect.gestisci(connessione, risposta: risposta)
        }
        listener.start(queue: .main)
    }

    func ferma() {
        listener?.cancel()
        listener = nil
    }

    private static func gestisci(_ connessione: NWConnection, risposta: @escaping ([String: String]) -> Void) {
        connessione.start(queue: .main)
        connessione.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { dati, _, _, _ in
            // Prima riga della richiesta: "GET /?code=...&state=... HTTP/1.1"
            let richiesta = dati.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let percorso = richiesta.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let valori = parametri(da: percorso)
            let utile = valori["code"] != nil || valori["error"] != nil
            let http: String
            if utile {
                let corpo = pagina(valori["code"] != nil
                    ? "Collegamento a Gmail riuscito. Puoi chiudere questa pagina e tornare a Easy F24."
                    : "Accesso annullato. Puoi chiudere questa pagina e tornare a Easy F24.")
                http = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(corpo.utf8.count)\r\nConnection: close\r\n\r\n" + corpo
            } else {
                http = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            connessione.send(content: http.data(using: .utf8), completion: .contentProcessed { _ in
                connessione.cancel()
                if utile {
                    risposta(valori)
                }
            })
        }
    }

    static func parametri(da percorso: String) -> [String: String] {
        var valori: [String: String] = [:]
        for elemento in URLComponents(string: "http://127.0.0.1" + percorso)?.queryItems ?? [] {
            valori[elemento.name] = elemento.value ?? ""
        }
        return valori
    }

    private static func pagina(_ messaggio: String) -> String {
        "<!doctype html><html lang=\"it\"><head><meta charset=\"utf-8\"><title>Easy F24</title></head>"
            + "<body style=\"font-family:-apple-system,Helvetica,sans-serif;text-align:center;padding-top:80px\">"
            + "<h2>Easy F24</h2><p>\(messaggio)</p></body></html>"
    }
}
