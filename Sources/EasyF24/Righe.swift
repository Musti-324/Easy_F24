import SwiftUI

/// Un F24 ancora da pagare, con la scadenza evidenziata se vicina o passata.
struct RigaDaPagare: View {
    let f24: F24
    let oggi: Date
    let onPaga: () -> Void
    let onModifica: () -> Void
    let onElimina: () -> Void
    var onApriEmail: (() -> Void)?

    var body: some View {
        let stato = StatoScadenza(scadenza: f24.scadenza, oggi: oggi)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(f24.descrizione)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let importo = f24.importoCentesimi {
                    Text(Formato.euro(importo))
                        .font(Font.headline.monospacedDigit())
                }
            }
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: stato.simbolo)
                    Text(stato.testo)
                }
                .font(.subheadline)
                .foregroundColor(stato.colore)
                Spacer(minLength: 8)
                Button("Segna pagato", action: onPaga)
                    .help("Segna questo F24 come pagato")
            }
            if f24.gmailMessageId != nil {
                HStack(spacing: 4) {
                    Image(systemName: "envelope")
                    Text(f24.avvisoGmail.map { "Arrivato via Gmail · " + $0 } ?? "Arrivato via Gmail")
                }
                .font(.caption)
                .foregroundColor(f24.avvisoGmail == nil ? .secondary : .orange)
            }
        }
        .modifier(StileScheda(bordo: stato.urgente ? stato.colore : nil))
        .onTapGesture(count: 2, perform: onModifica)
        .contextMenu {
            Button("Segna come pagato…", action: onPaga)
            Button("Modifica…", action: onModifica)
            if let apri = onApriEmail {
                Button("Apri l'email in Gmail", action: apri)
            }
            Divider()
            Button("Elimina…", action: onElimina)
        }
    }
}

/// Un F24 già pagato, con la data del pagamento.
struct RigaPagata: View {
    let f24: F24
    let onModifica: () -> Void
    let onRiporta: () -> Void
    let onElimina: () -> Void
    var onApriEmail: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(f24.descrizione)
                    .font(.headline)
                    .lineLimit(2)
                Text("Pagato il \(Formato.data(f24.pagatoIl ?? f24.scadenza))")
                    .font(.subheadline)
                Text(dettaglioScadenza)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if let importo = f24.importoCentesimi {
                Text(Formato.euro(importo))
                    .font(Font.headline.monospacedDigit())
            }
        }
        .modifier(StileScheda(bordo: nil))
        .onTapGesture(count: 2, perform: onModifica)
        .contextMenu {
            Button("Modifica…", action: onModifica)
            if let apri = onApriEmail {
                Button("Apri l'email in Gmail", action: apri)
            }
            Button("Riporta tra i da pagare", action: onRiporta)
            Divider()
            Button("Elimina…", action: onElimina)
        }
    }

    private var dettaglioScadenza: String {
        var testo = "Scadenza \(Formato.data(f24.scadenza))"
        if let pagatoIl = f24.pagatoIl {
            let ritardo = Formato.giorni(da: f24.scadenza, a: pagatoIl)
            if ritardo > 0 {
                testo += " · pagato con \(Formato.giorniTesto(ritardo)) di ritardo"
            }
        }
        return testo
    }
}

/// Testo, colore e icona della scadenza rispetto ad oggi.
struct StatoScadenza {
    let testo: String
    let colore: Color
    let simbolo: String
    /// Scaduto o in scadenza entro una settimana.
    let urgente: Bool

    init(scadenza: Date, oggi: Date) {
        let data = Formato.data(scadenza)
        let giorni = Formato.giorni(da: oggi, a: scadenza)
        switch giorni {
        case ..<0:
            testo = "Scaduto il \(data), \(Formato.giorniTesto(-giorni)) fa"
            colore = .red
            simbolo = "exclamationmark.triangle.fill"
            urgente = true
        case 0:
            testo = "Scade oggi, \(data)"
            colore = .orange
            simbolo = "exclamationmark.circle.fill"
            urgente = true
        case 1:
            testo = "Scade domani, \(data)"
            colore = .orange
            simbolo = "clock.fill"
            urgente = true
        case 2...7:
            testo = "Scade il \(data), tra \(giorni) giorni"
            colore = .orange
            simbolo = "clock"
            urgente = true
        default:
            testo = "Scade il \(data)"
            colore = .secondary
            simbolo = "calendar"
            urgente = false
        }
    }
}

/// Aspetto a "scheda" comune alle righe.
struct StileScheda: ViewModifier {
    let bordo: Color?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(bordo ?? Color(NSColor.separatorColor), lineWidth: bordo == nil ? 1 : 1.5)
            )
            .contentShape(Rectangle())
    }
}
