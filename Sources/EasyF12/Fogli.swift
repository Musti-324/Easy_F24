import SwiftUI

/// Aggiunta o modifica di un F12.
struct FoglioModifica: View {
    let originale: F12?
    let onSalva: (F12) -> Void
    let onAnnulla: () -> Void

    @State private var descrizione: String
    @State private var importo: String
    @State private var scadenza: Date
    @State private var pagatoIl: Date

    init(originale: F12?, onSalva: @escaping (F12) -> Void, onAnnulla: @escaping () -> Void) {
        self.originale = originale
        self.onSalva = onSalva
        self.onAnnulla = onAnnulla
        var testoImporto = ""
        if let centesimi = originale?.importoCentesimi {
            testoImporto = Formato.importo(centesimi)
        }
        _descrizione = State(initialValue: originale?.descrizione ?? "")
        _importo = State(initialValue: testoImporto)
        _scadenza = State(initialValue: originale?.scadenza ?? Date())
        _pagatoIl = State(initialValue: originale?.pagatoIl ?? Date())
    }

    private var giaPagato: Bool { originale?.isPagato == true }

    private var importoValido: Bool {
        let testo = importo.trimmingCharacters(in: .whitespaces)
        return testo.isEmpty || Formato.centesimi(da: testo) != nil
    }

    private var puoSalvare: Bool {
        !descrizione.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && importoValido
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(originale == nil ? "Nuovo F12" : "Modifica F12")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 4) {
                Etichetta("Descrizione")
                TextField("es. Saldo IMU 2026", text: $descrizione)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            VStack(alignment: .leading, spacing: 4) {
                Etichetta("Importo in euro (facoltativo)")
                TextField("es. 1.250,00", text: $importo)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                if !importoValido {
                    Text("Importo non valido")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Etichetta("Scadenza")
                    DatePicker("Scadenza", selection: $scadenza, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(GraphicalDatePickerStyle())
                }
                if giaPagato {
                    VStack(alignment: .leading, spacing: 4) {
                        Etichetta("Pagato il")
                        DatePicker("Pagato il", selection: $pagatoIl, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(GraphicalDatePickerStyle())
                    }
                }
            }

            HStack {
                Spacer()
                Button("Annulla", action: onAnnulla)
                    .keyboardShortcut(.cancelAction)
                Button(originale == nil ? "Aggiungi" : "Salva", action: salva)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!puoSalvare)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func salva() {
        guard puoSalvare else { return }
        let calendario = Calendar.current
        let testoImporto = importo.trimmingCharacters(in: .whitespaces)
        var f12 = originale ?? F12(descrizione: "", scadenza: scadenza)
        f12.descrizione = descrizione.trimmingCharacters(in: .whitespacesAndNewlines)
        f12.importoCentesimi = testoImporto.isEmpty ? nil : Formato.centesimi(da: testoImporto)
        f12.scadenza = calendario.startOfDay(for: scadenza)
        if f12.isPagato {
            f12.pagatoIl = calendario.startOfDay(for: pagatoIl)
        }
        onSalva(f12)
    }
}

/// Conferma del pagamento, con la data in cui è stato pagato (di default oggi).
struct FoglioPagamento: View {
    let f12: F12
    let onConferma: (Date) -> Void
    let onAnnulla: () -> Void

    @State private var data = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Segna come pagato")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 2) {
                Text(f12.descrizione)
                    .font(.headline)
                Text(riepilogo)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Etichetta("Data del pagamento")
                DatePicker("Data del pagamento", selection: $data, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(GraphicalDatePickerStyle())
            }

            HStack {
                Spacer()
                Button("Annulla", action: onAnnulla)
                    .keyboardShortcut(.cancelAction)
                Button("Conferma pagamento") { onConferma(data) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var riepilogo: String {
        var parti: [String] = []
        if let importo = f12.importoCentesimi {
            parti.append(Formato.euro(importo))
        }
        parti.append("scadenza \(Formato.data(f12.scadenza))")
        return parti.joined(separator: " · ")
    }
}

/// Etichetta piccola sopra ai campi.
struct Etichetta: View {
    let testo: String

    init(_ testo: String) {
        self.testo = testo
    }

    var body: some View {
        Text(testo)
            .font(.subheadline)
            .foregroundColor(.secondary)
    }
}
