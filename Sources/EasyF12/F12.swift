import Foundation

/// Un modello F12. Finché `pagatoIl` è nil è considerato "da pagare".
struct F12: Identifiable, Codable, Equatable {
    var id: UUID
    var descrizione: String
    /// Importo in centesimi di euro; nil se non indicato.
    var importoCentesimi: Int?
    var scadenza: Date
    var pagatoIl: Date?

    init(id: UUID = UUID(), descrizione: String, importoCentesimi: Int? = nil, scadenza: Date, pagatoIl: Date? = nil) {
        self.id = id
        self.descrizione = descrizione
        self.importoCentesimi = importoCentesimi
        self.scadenza = scadenza
        self.pagatoIl = pagatoIl
    }

    var isPagato: Bool { pagatoIl != nil }
}
