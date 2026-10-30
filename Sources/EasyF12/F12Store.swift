import Combine
import Foundation

/// Tiene in memoria gli F12 e li salva in un file JSON in
/// ~/Library/Application Support/Easy F12/f12.json
final class F12Store: ObservableObject {
    @Published private(set) var elementi: [F12] = []
    /// Messaggio da mostrare all'utente se qualcosa va storto con il file.
    @Published var errore: String?

    let fileURL: URL
    /// Diventa true se il file esiste ma non si riesce né a leggere né a spostare:
    /// in quel caso non lo sovrascriviamo per non perdere dati.
    private var salvataggioBloccato = false

    init(fileURL: URL = F12Store.percorsoPredefinito) {
        self.fileURL = fileURL
        carica()
    }

    static var percorsoPredefinito: URL {
        let supporto = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supporto
            .appendingPathComponent("Easy F12", isDirectory: true)
            .appendingPathComponent("f12.json")
    }

    // MARK: - Elenchi ordinati

    /// F12 non ancora pagati, dalla scadenza più vicina.
    var daPagare: [F12] {
        elementi.filter { !$0.isPagato }.sorted { $0.scadenza < $1.scadenza }
    }

    /// F12 pagati, dal pagamento più recente.
    var pagati: [F12] {
        elementi.filter { $0.isPagato }.sorted { ($0.pagatoIl ?? .distantPast) > ($1.pagatoIl ?? .distantPast) }
    }

    // MARK: - Modifiche

    func aggiungi(_ f12: F12) {
        elementi.append(f12)
        salva()
    }

    func aggiorna(_ f12: F12) {
        guard let indice = elementi.firstIndex(where: { $0.id == f12.id }) else { return }
        elementi[indice] = f12
        salva()
    }

    func segnaPagato(_ f12: F12, il data: Date) {
        var aggiornato = f12
        aggiornato.pagatoIl = Calendar.current.startOfDay(for: data)
        aggiorna(aggiornato)
    }

    func riportaDaPagare(_ f12: F12) {
        var aggiornato = f12
        aggiornato.pagatoIl = nil
        aggiorna(aggiornato)
    }

    func elimina(_ f12: F12) {
        elementi.removeAll { $0.id == f12.id }
        salva()
    }

    // MARK: - File

    private struct Archivio: Codable {
        var versione: Int
        var f12: [F12]
    }

    private func carica() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let cartella = fileURL.deletingLastPathComponent()
        do {
            let dati = try Data(contentsOf: fileURL)
            elementi = try F12Store.decoder.decode(Archivio.self, from: dati).f12
            // Copia di sicurezza di com'era l'archivio all'apertura dell'app.
            let copia = cartella.appendingPathComponent("f12-backup.json")
            try? fm.removeItem(at: copia)
            try? fm.copyItem(at: fileURL, to: copia)
        } catch {
            // Non sovrascriviamo un file che non riusciamo a leggere: lo mettiamo da parte.
            let destinazione = cartella.appendingPathComponent("f12-illeggibile-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try fm.moveItem(at: fileURL, to: destinazione)
                errore = "Non è stato possibile leggere l'archivio degli F12. Il file è stato messo da parte in:\n\(destinazione.path)"
            } catch {
                salvataggioBloccato = true
                errore = "Non è stato possibile leggere l'archivio degli F12 (\(fileURL.path)). Per non perdere dati, le modifiche non verranno salvate."
            }
        }
    }

    private func salva() {
        guard !salvataggioBloccato else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
            let dati = try F12Store.encoder.encode(Archivio(versione: 1, f12: elementi))
            try dati.write(to: fileURL, options: .atomic)
        } catch {
            errore = "Non è stato possibile salvare gli F12: \(error.localizedDescription)"
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
