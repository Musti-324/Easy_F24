import SwiftUI

/// Finestra principale: a sinistra gli F24 da pagare, a destra quelli già pagati.
struct ContentView: View {
    @EnvironmentObject private var store: F24Store
    @EnvironmentObject private var gmail: GmailSync
    @EnvironmentObject private var calendario: CalendarioSync
    @State private var foglio: Foglio?
    @State private var avviso: Avviso?
    @State private var oggi = Date()

    /// Aggiorna "oggi" se l'app resta aperta a cavallo della mezzanotte.
    private let orologio = Timer.publish(every: 600, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            colonne
            Divider()
            BarraGmail(gmail: gmail, calendario: calendario, onImpostazioni: { foglio = .gmail }, onCalendario: { foglio = .calendario })
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
            calendario.avvia()
        }
    }

    private var colonne: some View {
        HStack(spacing: 0) {
            Colonna(titolo: "Da pagare",
                    colore: .orange,
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
                                     onRileggi: rileggi(f24),
                                     onEliminaDefinitivamente: f24.gmailMessageId == nil ? nil : { avviso = .eliminaDefinitivamente(f24) })
                    })

            Divider()

            Colonna(titolo: "Pagati",
                    colore: .green,
                    elementi: store.pagati,
                    messaggioVuoto: "Ancora nessun F24 pagato.",
                    accessorio: { EmptyView() },
                    riga: { f24 in
                        RigaPagata(f24: f24,
                                   onModifica: { foglio = .modifica(f24) },
                                   onRiporta: { store.riportaDaPagare(f24) },
                                   onElimina: { avviso = .elimina(f24) },
                                     onRileggi: rileggi(f24),
                                     onEliminaDefinitivamente: f24.gmailMessageId == nil ? nil : { avviso = .eliminaDefinitivamente(f24) })
                    })
        }
    }

    /// Azione "Rileggi importo e scadenza dal PDF" per gli F24 importati da Gmail.
    private func rileggi(_ f24: F24) -> (() -> Void)? {
        guard f24.gmailMessageId != nil else { return nil }
        return { gmail.rileggi(f24) }
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
        case .calendario:
            FoglioCalendario(calendario: calendario, gmail: gmail, onChiudi: chiudiFoglio)
        }
    }

    private func chiudiFoglio() {
        foglio = nil
    }

    private func alert(per avviso: Avviso) -> Alert {
        switch avviso {
        case .elimina(let f24):
            return Alert(title: Text("Eliminare questo F24?"),
                         message: Text(f24.gmailMessageId == nil
                                        ? "«\(f24.descrizione)» verrà eliminato definitivamente."
                                        : "«\(f24.descrizione)» è arrivato da Gmail: se lo elimini verrà riaggiunto al prossimo controllo. Per toglierlo per sempre usa «Elimina definitivamente…»."),
                         primaryButton: .destructive(Text("Elimina")) { store.elimina(f24) },
                         secondaryButton: .cancel(Text("Annulla")))
        case .eliminaDefinitivamente(let f24):
            return Alert(title: Text("Eliminare definitivamente questo F24?"),
                         message: Text("«\(f24.descrizione)» verrà eliminato e non verrà più riaggiunto da Gmail."),
                         primaryButton: .destructive(Text("Elimina definitivamente")) { gmail.eliminaDefinitivamente(f24) },
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
    case calendario

    var id: String {
        switch self {
        case .nuovo: return "nuovo"
        case .gmail: return "gmail"
        case .calendario: return "calendario"
        case .modifica(let f24): return "modifica-" + f24.id.uuidString
        case .paga(let f24): return "paga-" + f24.id.uuidString
        }
    }
}

/// Le finestre di conferma o di errore.
enum Avviso: Identifiable {
    case elimina(F24)
    case eliminaDefinitivamente(F24)
    case errore(String)

    var id: String {
        switch self {
        case .elimina(let f24): return "elimina-" + f24.id.uuidString
        case .eliminaDefinitivamente(let f24): return "elimina-definitivamente-" + f24.id.uuidString
        case .errore(let messaggio): return "errore-" + messaggio
        }
    }
}

/// Una delle due colonne: intestazione con numero e totale, poi l'elenco.
struct Colonna<Accessorio: View, Riga: View>: View {
    let titolo: String
    let colore: Color
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
