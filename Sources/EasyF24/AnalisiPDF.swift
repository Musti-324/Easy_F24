import Foundation
import PDFKit

/// Diagnosi di un PDF: cosa legge l'app e dove, per capire perché un importo non viene trovato.
/// Si guarda solo la prima pagina sotto il 75% dell'altezza: la parte alta del modulo F24,
/// con nome, codice fiscale e indirizzo del contribuente, resta esclusa.
struct AnalisiPDF {
    struct Riga {
        /// Posizione in percentuale: y dal basso della pagina, x da sinistra.
        let y: Int
        let x: Int
        let testo: String
    }

    struct Campo {
        let y: Int
        let x: Int
        let nome: String
        let valore: String
    }

    static let limiteAltezza: CGFloat = 0.75
    static let massimoRighe = 150

    let nome: String
    let byte: Int
    let pagine: Int
    let dimensioni: CGSize
    let rotazione: Int
    let bloccato: Bool
    let haTesto: Bool
    let lettura: LettoreF24.LetturaPDF?
    let righe: [Riga]
    let campi: [Campo]

    init(_ pdf: LettoreF24.PDF) {
        nome = pdf.nome
        byte = pdf.dati.count
        lettura = LettoreF24.leggi(pdf: pdf.dati)
        let documento = pdf.dati.count <= MessaggioGmail.massimaDimensionePDF ? PDFDocument(data: pdf.dati) : nil
        pagine = documento?.pageCount ?? 0
        bloccato = documento?.isLocked ?? false
        guard let documento = documento, !documento.isLocked, let pagina = documento.page(at: 0) else {
            dimensioni = .zero
            rotazione = 0
            haTesto = false
            righe = []
            campi = []
            return
        }
        let bordi = pagina.bounds(for: .cropBox)
        dimensioni = bordi.size
        rotazione = pagina.rotation
        haTesto = !(pagina.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        func percentuali(_ rettangolo: CGRect) -> (y: Int, x: Int) {
            (y: Int(((rettangolo.midY - bordi.minY) / max(bordi.height, 1) * 100).rounded()),
             x: Int(((rettangolo.minX - bordi.minX) / max(bordi.width, 1) * 100).rounded()))
        }
        let zona = CGRect(x: bordi.minX, y: bordi.minY, width: bordi.width, height: bordi.height * AnalisiPDF.limiteAltezza)
        let linee = pagina.selection(for: zona)?.selectionsByLine() ?? []
        righe = linee.compactMap { linea -> Riga? in
            let testo = (linea.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !testo.isEmpty else { return nil }
            let posizione = percentuali(linea.bounds(for: pagina))
            return Riga(y: posizione.y, x: posizione.x, testo: String(testo.prefix(160)))
        }
        .sorted { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }
        .prefix(AnalisiPDF.massimoRighe)
        .map { $0 }
        // Valori scritti nei campi compilabili del modulo: non fanno parte del testo della pagina.
        campi = pagina.annotations.compactMap { annotazione -> Campo? in
            guard annotazione.bounds.midY < bordi.minY + bordi.height * AnalisiPDF.limiteAltezza else { return nil }
            let valore = (annotazione.widgetStringValue ?? annotazione.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let nome = annotazione.fieldName ?? annotazione.type ?? ""
            guard !valore.isEmpty || !nome.isEmpty else { return nil }
            let posizione = percentuali(annotazione.bounds)
            return Campo(y: posizione.y, x: posizione.x, nome: String(nome.prefix(60)), valore: String(valore.prefix(80)))
        }
        .sorted { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }
        .prefix(AnalisiPDF.massimoRighe)
        .map { $0 }
    }

    /// Il risultato in forma di testo, da copiare e inviare.
    var resoconto: String {
        var testo: [String] = ["Easy F24 – analisi del PDF «\(nome)»"]
        if pagine == 0 {
            testo.append("Il file non si apre come PDF.")
            return testo.joined(separator: "\n")
        }
        testo.append("Dimensione: \(byte / 1024) KB · pagine: \(pagine) · pagina \(Int(dimensioni.width)) × \(Int(dimensioni.height)) punti · rotazione \(rotazione)°")
        if bloccato {
            testo.append("Il PDF è protetto da password: non si può leggere.")
            return testo.joined(separator: "\n")
        }
        testo.append(haTesto ? "Testo leggibile nella prima pagina: sì"
                             : "Testo leggibile nella prima pagina: NO (è un'immagine o una scansione)")
        if let saldo = lettura?.saldo {
            testo.append("Lettura dell'app: saldo finale \(Formato.euro(saldo.centesimi))\(saldo.sicuro ? "" : " (da verificare)") · pagine lette \(lettura?.pagineLette ?? 0) · fasce lette \(lettura?.zoneLette ?? 0)")
        } else {
            testo.append("Lettura dell'app: saldo finale NON trovato · pagine lette \(lettura?.pagineLette ?? 0) · fasce lette \(lettura?.zoneLette ?? 0)")
        }
        testo.append("")
        testo.append("Righe di testo nella prima pagina, sotto il 75% dell'altezza (y = % dal basso, x = % da sinistra):")
        testo += righe.isEmpty ? ["  (nessuna)"] : righe.map { "  y \(String(format: "%3d", $0.y)) · x \(String(format: "%3d", $0.x)) · \($0.testo)" }
        testo.append("")
        testo.append("Campi compilabili del modulo nella stessa zona:")
        testo += campi.isEmpty ? ["  (nessuno)"] : campi.map { "  y \(String(format: "%3d", $0.y)) · x \(String(format: "%3d", $0.x)) · «\($0.nome)» = «\($0.valore)»" }
        testo.append("")
        testo.append("(La parte alta della pagina, con nome e codice fiscale, non è inclusa.)")
        return testo.joined(separator: "\n")
    }
}
