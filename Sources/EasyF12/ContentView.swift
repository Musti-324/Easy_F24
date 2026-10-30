import SwiftUI

/// Finestra principale: a sinistra gli F12 da pagare, a destra quelli già pagati.
struct ContentView: View {
    @EnvironmentObject private var store: F12Store
    @State private var foglio: Foglio?
    @State private var avviso: Avviso?
    @State private var oggi = Date()

    /// Aggiorna "oggi" se l'app resta aperta a cavallo della mezzanotte.
    private let orologio = Timer.publish(every: 600, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            Colonna(titolo: "Da pagare",
                    colore: .orange,
                    elementi: store.daPagare,
                    messaggioVuoto: "Nessun F12 da pagare.\nPremi «Nuovo F12» per aggiungerne uno.",
                    accessorio: {
                        Button(action: { foglio = .nuovo }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Nuovo F12")
                            }
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        .help("Aggiungi un F12 da pagare (⌘N)")
                    },
                    riga: { f12 in
                        RigaDaPagare(f12: f12,
                                     oggi: oggi,
                                     onPaga: { foglio = .paga(f12) },
                                     onModifica: { foglio = .modifica(f12) },
                                     onElimina: { avviso = .elimina(f12) })
                    })

            Divider()

            Colonna(titolo: "Pagati",
                    colore: .green,
                    elementi: store.pagati,
                    messaggioVuoto: "Ancora nessun F12 pagato.",
                    accessorio: { EmptyView() },
                    riga: { f12 in
                        RigaPagata(f12: f12,
                                   onModifica: { foglio = .modifica(f12) },
                                   onRiporta: { store.riportaDaPagare(f12) },
                                   onElimina: { avviso = .elimina(f12) })
                    })
        }
        .frame(minWidth: 820, minHeight: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(item: $foglio) { foglio in
            contenuto(del: foglio)
                .environment(\.locale, Formato.locale)
        }
        .alert(item: $avviso) { avviso in
            alert(per: avviso)
        }
        .onReceive(store.$errore) { messaggio in
            if let messaggio = messaggio {
                avviso = .errore(messaggio)
            }
        }
        .onReceive(orologio) { adesso in
            oggi = adesso
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            oggi = Date()
        }
    }

    @ViewBuilder
    private func contenuto(del foglio: Foglio) -> some View {
        switch foglio {
        case .nuovo:
            FoglioModifica(originale: nil,
                           onSalva: { nuovo in
                               store.aggiungi(nuovo)
                               chiudiFoglio()
                           },
                           onAnnulla: chiudiFoglio)
        case .modifica(let f12):
            FoglioModifica(originale: f12,
                           onSalva: { modificato in
                               store.aggiorna(modificato)
                               chiudiFoglio()
                           },
                           onAnnulla: chiudiFoglio)
        case .paga(let f12):
            FoglioPagamento(f12: f12,
                            onConferma: { data in
                                store.segnaPagato(f12, il: data)
                                chiudiFoglio()
                            },
                            onAnnulla: chiudiFoglio)
        }
    }

    private func chiudiFoglio() {
        foglio = nil
    }

    private func alert(per avviso: Avviso) -> Alert {
        switch avviso {
        case .elimina(let f12):
            return Alert(title: Text("Eliminare questo F12?"),
                         message: Text("«\(f12.descrizione)» verrà eliminato definitivamente."),
                         primaryButton: .destructive(Text("Elimina")) { store.elimina(f12) },
                         secondaryButton: .cancel(Text("Annulla")))
        case .errore(let messaggio):
            return Alert(title: Text("Attenzione"),
                         message: Text(messaggio),
                         dismissButton: .default(Text("OK")) { store.errore = nil })
        }
    }
}

/// Il foglio (finestra modale) aperto sopra la finestra principale.
enum Foglio: Identifiable {
    case nuovo
    case modifica(F12)
    case paga(F12)

    var id: String {
        switch self {
        case .nuovo: return "nuovo"
        case .modifica(let f12): return "modifica-" + f12.id.uuidString
        case .paga(let f12): return "paga-" + f12.id.uuidString
        }
    }
}

/// Le finestre di conferma o di errore.
enum Avviso: Identifiable {
    case elimina(F12)
    case errore(String)

    var id: String {
        switch self {
        case .elimina(let f12): return "elimina-" + f12.id.uuidString
        case .errore(let messaggio): return "errore-" + messaggio
        }
    }
}

/// Una delle due colonne: intestazione con numero e totale, poi l'elenco.
struct Colonna<Accessorio: View, Riga: View>: View {
    let titolo: String
    let colore: Color
    let elementi: [F12]
    let messaggioVuoto: String
    let accessorio: () -> Accessorio
    let riga: (F12) -> Riga

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            intestazione
            Divider()
            if elementi.isEmpty {
                Text(messaggioVuoto)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(elementi) { f12 in
                            riga(f12)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var intestazione: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(titolo)
                    .font(.title2)
                    .bold()
                Text("\(elementi.count)")
                    .font(Font.callout.monospacedDigit())
                    .bold()
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(colore))
                Spacer()
                accessorio()
            }
            Text(totale)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
    }

    private var totale: String {
        let importi = elementi.compactMap { $0.importoCentesimi }
        // Riga sempre presente (anche vuota) per allineare le due intestazioni.
        return importi.isEmpty ? " " : "Totale " + Formato.euro(importi.reduce(0, +))
    }
}
