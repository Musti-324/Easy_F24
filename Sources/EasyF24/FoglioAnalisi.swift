import AppKit
import SwiftUI

/// Mostra cosa legge l'app nei PDF dell'email da cui è arrivato un F24 (scaricati solo in memoria).
struct FoglioAnalisi: View {
    @ObservedObject var gmail: GmailSync
    let f24: F24
    let onChiudi: () -> Void

    private enum Stato {
        case inCorso
        case fatto([AnalisiPDF])
        case errore(String)
    }

    @State private var stato = Stato.inCorso
    @State private var copiato = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analisi del PDF")
                .font(.title2)
                .bold()
            Text(f24.descrizione)
                .font(.headline)
                .lineLimit(2)
            Text("Il PDF viene letto da Gmail solo in memoria: non viene salvato sul computer. Dal risultato è esclusa la parte alta del modulo, con nome e codice fiscale.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            contenuto
                .frame(height: 380)

            HStack {
                if copiato {
                    Text("Copiato")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Copia il risultato", action: copia)
                    .disabled(testo.isEmpty)
                Button("Chiudi", action: onChiudi)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear(perform: avvia)
    }

    @ViewBuilder
    private var contenuto: some View {
        switch stato {
        case .inCorso:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Scarico il PDF da Gmail e lo analizzo…")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .errore(let messaggio):
            Text(messaggio)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .fatto:
            ScrollView {
                Text(testo)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
    }

    private var testo: String {
        guard case .fatto(let analisi) = stato else { return "" }
        if analisi.isEmpty {
            return "L'email non contiene allegati PDF."
        }
        return analisi.map { $0.resoconto }.joined(separator: "\n\n" + String(repeating: "─", count: 60) + "\n\n")
    }

    private func avvia() {
        gmail.analizzaPDF(di: f24) { risultato in
            switch risultato {
            case .success(let analisi):
                stato = .fatto(analisi)
            case .failure(let errore):
                stato = .errore(errore.localizedDescription)
            }
        }
    }

    private func copia() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(testo, forType: .string)
        copiato = true
    }
}
