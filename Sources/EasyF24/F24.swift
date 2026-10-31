import Foundation

/// Un modello F24. Finché `pagatoIl` è nil è considerato "da pagare".
struct F24: Identifiable, Codable, Equatable {
    var id: UUID
    var descrizione: String
    /// Importo in centesimi di euro; nil se non indicato.
    var importoCentesimi: Int?
    var scadenza: Date
    var pagatoIl: Date?
    /// Id del messaggio Gmail da cui è stato importato (nil se inserito a mano).
    var gmailMessageId: String?
    /// Importato da Gmail senza essere sicuri di importo o scadenza: va controllato.
    var daVerificare: Bool

    init(id: UUID = UUID(), descrizione: String, importoCentesimi: Int? = nil, scadenza: Date, pagatoIl: Date? = nil,
         gmailMessageId: String? = nil, daVerificare: Bool = false) {
        self.id = id
        self.descrizione = descrizione
        self.importoCentesimi = importoCentesimi
        self.scadenza = scadenza
        self.pagatoIl = pagatoIl
        self.gmailMessageId = gmailMessageId
        self.daVerificare = daVerificare
    }

    // Gli archivi salvati prima del collegamento a Gmail non hanno gli ultimi due campi.
    init(from decoder: Decoder) throws {
        let valori = try decoder.container(keyedBy: CodingKeys.self)
        id = try valori.decode(UUID.self, forKey: .id)
        descrizione = try valori.decode(String.self, forKey: .descrizione)
        importoCentesimi = try valori.decodeIfPresent(Int.self, forKey: .importoCentesimi)
        scadenza = try valori.decode(Date.self, forKey: .scadenza)
        pagatoIl = try valori.decodeIfPresent(Date.self, forKey: .pagatoIl)
        gmailMessageId = try valori.decodeIfPresent(String.self, forKey: .gmailMessageId)
        daVerificare = try valori.decodeIfPresent(Bool.self, forKey: .daVerificare) ?? false
    }

    var isPagato: Bool { pagatoIl != nil }
}
