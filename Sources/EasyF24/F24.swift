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
    /// Importato da Gmail senza essere sicuri dell'importo (o senza averlo trovato): va controllato.
    var importoDaVerificare: Bool
    /// Importato da Gmail senza essere sicuri della scadenza: va controllata.
    var scadenzaDaVerificare: Bool

    /// C'è qualcosa da controllare. Impostarlo a false toglie entrambi gli avvisi (es. dopo una modifica).
    var daVerificare: Bool {
        get { importoDaVerificare || scadenzaDaVerificare }
        set {
            importoDaVerificare = newValue
            scadenzaDaVerificare = newValue
        }
    }

    init(id: UUID = UUID(), descrizione: String, importoCentesimi: Int? = nil, scadenza: Date, pagatoIl: Date? = nil,
         gmailMessageId: String? = nil, importoDaVerificare: Bool = false, scadenzaDaVerificare: Bool = false) {
        self.id = id
        self.descrizione = descrizione
        self.importoCentesimi = importoCentesimi
        self.scadenza = scadenza
        self.pagatoIl = pagatoIl
        self.gmailMessageId = gmailMessageId
        self.importoDaVerificare = importoDaVerificare
        self.scadenzaDaVerificare = scadenzaDaVerificare
    }

    private enum CodingKeys: String, CodingKey {
        case id, descrizione, importoCentesimi, scadenza, pagatoIl, gmailMessageId, importoDaVerificare, scadenzaDaVerificare
        /// Fino alla versione 1.8 c'era un solo avviso per importo e scadenza insieme.
        case daVerificare
    }

    func encode(to encoder: Encoder) throws {
        var valori = encoder.container(keyedBy: CodingKeys.self)
        try valori.encode(id, forKey: .id)
        try valori.encode(descrizione, forKey: .descrizione)
        try valori.encodeIfPresent(importoCentesimi, forKey: .importoCentesimi)
        try valori.encode(scadenza, forKey: .scadenza)
        try valori.encodeIfPresent(pagatoIl, forKey: .pagatoIl)
        try valori.encodeIfPresent(gmailMessageId, forKey: .gmailMessageId)
        try valori.encode(importoDaVerificare, forKey: .importoDaVerificare)
        try valori.encode(scadenzaDaVerificare, forKey: .scadenzaDaVerificare)
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
        // Archivi fino alla 1.8: un solo avviso, che vale per entrambi.
        let vecchioAvviso = try valori.decodeIfPresent(Bool.self, forKey: .daVerificare) ?? false
        importoDaVerificare = try valori.decodeIfPresent(Bool.self, forKey: .importoDaVerificare) ?? vecchioAvviso
        scadenzaDaVerificare = try valori.decodeIfPresent(Bool.self, forKey: .scadenzaDaVerificare) ?? vecchioAvviso
    }

    var isPagato: Bool { pagatoIl != nil }

    /// Cosa controllare in un F24 arrivato da Gmail, es. "importo non trovato nel PDF"; nil se è tutto a posto.
    var avvisoGmail: String? {
        var avvisi: [String] = []
        if importoCentesimi == nil {
            avvisi.append("importo non trovato: inseriscilo con un doppio clic")
        } else if importoDaVerificare {
            avvisi.append("controlla l'importo")
        }
        if scadenzaDaVerificare {
            avvisi.append("controlla la scadenza")
        }
        return avvisi.isEmpty ? nil : avvisi.joined(separator: " · ")
    }
}
