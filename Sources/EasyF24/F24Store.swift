import Combine
import Foundation

/// Tiene in memoria gli F24 e li salva in un file JSON in
/// ~/Library/Application Support/Easy F24/f24.json
final class F24Store: ObservableObject {
    @Published private(set) var elementi: [F24] = []
    /// Messaggio da mostrare all'utente se qualcosa va storto con il file.
    @Published var errore: String?

    let fileURL: URL
    /// Diventa true se il file esiste ma non si riesce né a leggere né a spostare:
    /// in quel caso non lo sovrascriviamo per non perdere dati.
    private var salvataggioBloccato = false

    init(fileURL: URL = F24Store.percorsoPredefinito) {
        self.fileURL = fileURL
        carica()
    }

    static var percorsoPredefinito: URL {
        let supporto = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supporto
            .appendingPathComponent("Easy F24", isDirectory: true)
            .appendingPathComponent("f24.json")
    }

    // MARK: - Elenchi ordinati

    /// F24 non ancora pagati, dalla scadenza più vicina.
    var daPagare: [F24] {
        elementi.filter { !$0.isPagato }.sorted { $0.scadenza < $1.scadenza }
    }

    /// F24 pagati, dal pagamento più recente.
    var pagati: [F24] {
        elementi.filter { $0.isPagato }.sorted { ($0.pagatoIl ?? .distantPast) > ($1.pagatoIl ?? .distantPast) }
    }

    // MARK: - Modifiche

    func aggiungi(_ f24: F24) {
        elementi.append(f24)
        salva()
    }

    func aggiorna(_ f24: F24) {
        guard let indice = elementi.firstIndex(where: { $0.id == f24.id }) else { return }
        elementi[indice] = f24
        salva()
    }

    func segnaPagato(_ f24: F24, il data: Date) {
        var aggiornato = f24
        aggiornato.pagatoIl = Calendar.current.startOfDay(for: data)
        aggiornato.daVerificare = false
        aggiorna(aggiornato)
    }

    func riportaDaPagare(_ f24: F24) {
        var aggiornato = f24
        aggiornato.pagatoIl = nil
        aggiorna(aggiornato)
    }

    /// True se c'è già un F24 importato da questo messaggio Gmail.
    func contiene(gmailMessageId id: String) -> Bool {
        elementi.contains { $0.gmailMessageId == id }
    }

    func elimina(_ f24: F24) {
        elementi.removeAll { $0.id == f24.id }
        salva()
    }

    // MARK: - File

    private struct Archivio: Codable {
        var versione: Int
        var f24: [F24]
    }

    private func carica() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let cartella = fileURL.deletingLastPathComponent()
        do {
            let dati = try Data(contentsOf: fileURL)
            elementi = try F24Store.decoder.decode(Archivio.self, from: dati).f24
            // Copia di sicurezza di com'era l'archivio all'apertura dell'app.
            let copia = cartella.appendingPathComponent("f24-backup.json")
            try? fm.removeItem(at: copia)
            try? fm.copyItem(at: fileURL, to: copia)
        } catch {
            // Non sovrascriviamo un file che non riusciamo a leggere: lo mettiamo da parte.
            let destinazione = cartella.appendingPathComponent("f24-illeggibile-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try fm.moveItem(at: fileURL, to: destinazione)
                errore = "Non è stato possibile leggere l'archivio degli F24. Il file è stato messo da parte in:\n\(destinazione.path)"
            } catch {
                salvataggioBloccato = true
                errore = "Non è stato possibile leggere l'archivio degli F24 (\(fileURL.path)). Per non perdere dati, le modifiche non verranno salvate."
            }
        }
    }

    private func salva() {
        guard !salvataggioBloccato else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
            let dati = try F24Store.encoder.encode(Archivio(versione: 1, f24: elementi))
            try dati.write(to: fileURL, options: .atomic)
        } catch {
            errore = "Non è stato possibile salvare gli F24: \(error.localizedDescription)"
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
