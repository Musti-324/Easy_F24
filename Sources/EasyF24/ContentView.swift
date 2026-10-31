import SwiftUI

/// Finestra principale: a sinistra gli F24 da pagare, a destra quelli già pagati.
struct ContentView: View {
    @EnvironmentObject private var store: F24Store
    @EnvironmentObject private var gmail: GmailSync
    @State private var foglio: Foglio?
    @State private var avviso: Avviso?
    @State private var oggi = Date()

    /// Aggiorna "oggi" se l'app resta aperta a cavallo della mezzanotte.
    private let orologio = Timer.publish(every: 600, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            colonne
            Divider()
            BarraGmail(gmail: gmail, onImpostazioni: { foglio = .gmail })
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
        .onAppear {
            gmail.avvia()
        }
    }

    private var colonne: some View {
        HStack(spacing: 0) {
            Colonna(titolo: "Da pagare",
                    colore: .orange,
                    etichettaTotale: "Totale da pagare",
                    totaleInEvidenza: true,
                    elementi: store.daPagare,
                    messaggioVuoto: "Nessun F24 da pagare.\nPremi «Nuovo F24» per aggiungerne uno.",
                    accessorio: {
                        Button(action: { foglio = .nuovo }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Nuovo F24")
                            }
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        .help("Aggiungi un F24 da pagare (⌘N)")
                    },
                    riga: { f24 in
                        RigaDaPagare(f24: f24,
                                     oggi: oggi,
                                     onPaga: { foglio = .paga(f24) },
                                     onModifica: { foglio = .modifica(f24) },
                                     onElimina: { avviso = .elimina(f24) },
                                     onApriEmail: apriEmail(di: f24))
                    })

            Divider()

            Colonna(titolo: "Pagati",
                    colore: .green,
                    etichettaTotale: "Totale pagato",
                    totaleInEvidenza: false,
                    elementi: store.pagati,
                    messaggioVuoto: "Ancora nessun F24 pagato.",
                    accessorio: { EmptyView() },
                    riga: { f24 in
                        RigaPagata(f24: f24,
                                   onModifica: { foglio = .modifica(f24) },
                                   onRiporta: { store.riportaDaPagare(f24) },
                                   onElimina: { avviso = .elimina(f24) },
                                   onApriEmail: apriEmail(di: f24))
                    })
        }
    }

    /// Azione "Apri l'email in Gmail" per gli F24 importati da Gmail.
    private func apriEmail(di f24: F24) -> (() -> Void)? {
        guard let id = f24.gmailMessageId else { return nil }
        return { gmail.apriEmail(id) }
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
        case .modifica(let f24):
            FoglioModifica(originale: f24,
                           onSalva: { modificato in
                               store.aggiorna(modificato)
                               chiudiFoglio()
                           },
                           onAnnulla: chiudiFoglio)
        case .paga(let f24):
            FoglioPagamento(f24: f24,
                            onConferma: { data in
                                store.segnaPagato(f24, il: data)
                                chiudiFoglio()
                            },
                            onAnnulla: chiudiFoglio)
        case .gmail:
            FoglioGmail(gmail: gmail, onChiudi: chiudiFoglio)
        }
    }

    private func chiudiFoglio() {
        foglio = nil
    }

    private func alert(per avviso: Avviso) -> Alert {
        switch avviso {
        case .elimina(let f24):
            return Alert(title: Text("Eliminare questo F24?"),
                         message: Text("«\(f24.descrizione)» verrà eliminato definitivamente."),
                         primaryButton: .destructive(Text("Elimina")) { store.elimina(f24) },
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
    case modifica(F24)
    case paga(F24)
    case gmail

    var id: String {
        switch self {
        case .nuovo: return "nuovo"
        case .gmail: return "gmail"
        case .modifica(let f24): return "modifica-" + f24.id.uuidString
        case .paga(let f24): return "paga-" + f24.id.uuidString
        }
    }
}

/// Le finestre di conferma o di errore.
enum Avviso: Identifiable {
    case elimina(F24)
    case errore(String)

    var id: String {
        switch self {
        case .elimina(let f24): return "elimina-" + f24.id.uuidString
        case .errore(let messaggio): return "errore-" + messaggio
        }
    }
}

/// Una delle due colonne: intestazione con numero e totale, poi l'elenco.
struct Colonna<Accessorio: View, Riga: View>: View {
    let titolo: String
    let colore: Color
    /// Es. "Totale da pagare": la somma degli importi, sempre visibile sotto il titolo.
    let etichettaTotale: String
    /// Totale scritto in grande e in nero (colonna "Da pagare").
    let totaleInEvidenza: Bool
    let elementi: [F24]
    let messaggioVuoto: String
    let accessorio: () -> Accessorio
    let riga: (F24) -> Riga

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
                        ForEach(elementi) { f24 in
                            riga(f24)
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
            rigaTotale
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
    }

    /// "Totale da pagare: 1.732,30 €", sempre presente (anche a 0,00 €). Gli F24 senza importo
    /// non entrano nella somma: lo si dice, così il totale non sembra più basso del vero.
    private var rigaTotale: some View {
        let importi = elementi.compactMap { $0.importoCentesimi }
        let senzaImporto = elementi.count - importi.count
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(etichettaTotale + ":")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(Formato.euro(importi.reduce(0, +)))
                .font(totaleInEvidenza ? Font.title3.bold().monospacedDigit() : Font.subheadline.monospacedDigit())
                .foregroundColor(totaleInEvidenza ? .primary : .secondary)
            if senzaImporto > 0 {
                Text(senzaImporto == 1 ? "· 1 F24 senza importo" : "· \(senzaImporto) F24 senza importo")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .help("Questi F24 non hanno un importo e non sono compresi nel totale: aprili con un doppio clic per inserirlo.")
            }
        }
    }
}
