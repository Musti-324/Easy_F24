import AppKit
import SwiftUI

/// Impostazioni dell'integrazione con Google Calendar: interruttore, calendario, forma dell'evento e notifiche.
struct FoglioCalendario: View {
    @ObservedObject var calendario: CalendarioSync
    @ObservedObject var gmail: GmailSync
    let onChiudi: () -> Void

    @State private var bozza: ImpostazioniCalendario

    init(calendario: CalendarioSync, gmail: GmailSync, onChiudi: @escaping () -> Void) {
        self.calendario = calendario
        self.gmail = gmail
        self.onChiudi = onChiudi
        _bozza = State(initialValue: calendario.impostazioni)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Google Calendar")
                .font(.title2)
                .bold()
            Toggle("Aggiungi gli F24 da pagare a Google Calendar", isOn: $bozza.attivo)
            Text("Ogni F24 da pagare diventa un evento nel giorno della scadenza. Quando lo segni come pagato il titolo diventa «PAGATO ✅» e le notifiche si spengono; se lo elimini dalla lista, l'evento viene tolto. Spento: l'app funziona come sempre, senza calendario.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if bozza.attivo {
                Divider()
                if gmail.stato != .collegato {
                    Text("Prima collega Gmail con «Collega a Gmail»: il calendario usa lo stesso account Google.")
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !calendario.autorizzato {
                    autorizzazione
                } else {
                    impostazioniEvento
                }
            }

            stato

            HStack {
                Spacer()
                Button("Annulla", action: onChiudi)
                    .keyboardShortcut(.cancelAction)
                Button("Fine") {
                    var nuove = bozza
                    if let scelto = calendario.calendari.first(where: { ($0.primary == true ? "primary" : $0.id) == bozza.calendarioId }) {
                        nuove.calendarioNome = scelto.nome
                    }
                    calendario.applica(nuove)
                    onChiudi()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { calendario.caricaCalendari() }
    }

    // MARK: Sezioni

    private var autorizzazione: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Easy F24 deve poter creare ed eliminare eventi nel tuo calendario.")
            Text("Prima, nel progetto di Google Cloud usato per Gmail, abilita «Google Calendar API».")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                if calendario.inAutorizzazione {
                    ProgressView()
                        .controlSize(.small)
                    Text("Completa l'accesso nel browser…")
                    Button("Annulla", action: calendario.annullaAutorizzazione)
                } else {
                    Button("Autorizza Google Calendar…", action: calendario.autorizza)
                    Button("Apri Google Cloud Console") {
                        if let url = URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    private var impostazioniEvento: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Calendario")
                    .frame(width: 90, alignment: .leading)
                if calendario.calendari.isEmpty {
                    Text(bozza.calendarioNome)
                        .foregroundColor(.secondary)
                } else {
                    Picker("", selection: $bozza.calendarioId) {
                        ForEach(calendario.calendari) { voce in
                            Text(voce.nome).tag(voce.primary == true ? "primary" : voce.id)
                        }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Text("Evento")
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: $bozza.tuttoIlGiorno) {
                    Text("Tutto il giorno").tag(true)
                    Text("A un orario").tag(false)
                }
                .pickerStyle(SegmentedPickerStyle())
                .labelsHidden()
                .frame(width: 240)
                if !bozza.tuttoIlGiorno {
                    Text("alle")
                    DatePicker("", selection: $bozza.oraEventoComeData, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("(mezz'ora)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text("Notifiche").font(.headline)
            Toggle("Usa le notifiche predefinite del calendario", isOn: $bozza.notifichePredefinite)
            if !bozza.notifichePredefinite {
                ForEach(bozza.notifiche) { notifica in
                    rigaNotifica(notifica.id)
                }
                Button(action: {
                    bozza.notifiche.append(Notifica(unita: bozza.tuttoIlGiorno ? .giorni : .ore))
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Aggiungi notifica")
                    }
                    .foregroundColor(bozza.notifiche.count >= ImpostazioniCalendario.massimoNotifiche ? .secondary : .accentColor)
                }
                .buttonStyle(BorderlessButtonStyle())
                .disabled(bozza.notifiche.count >= ImpostazioniCalendario.massimoNotifiche)
            }
            Text("Le modifiche valgono per gli eventi creati da ora in poi: quelli già nel calendario restano come sono.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rigaNotifica(_ id: UUID) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $bozza[notifica: id].metodo) {
                ForEach(Notifica.Metodo.allCases, id: \.self) { Text($0.nome).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            Stepper(value: $bozza[notifica: id].quantita, in: 1...40) {
                Text("\(notifica(id)?.quantita ?? 1)")
                    .frame(minWidth: 22, alignment: .trailing)
            }
            Picker("", selection: $bozza[notifica: id].unita) {
                ForEach(bozza.tuttoIlGiorno ? [Notifica.Unita.giorni, .settimane] : Notifica.Unita.allCases, id: \.self) {
                    Text($0.nome).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Text("prima")
            if bozza.tuttoIlGiorno {
                Text("alle")
                DatePicker("", selection: $bozza[notifica: id].oraComeData, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            Spacer()
            Button(action: { bozza.notifiche.removeAll { $0.id == id } }) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(BorderlessButtonStyle())
            .help("Togli questa notifica")
        }
    }

    private var stato: some View {
        HStack(spacing: 8) {
            if calendario.inCorso {
                ProgressView()
                    .controlSize(.small)
                Text("Aggiorno il calendario…")
                    .foregroundColor(.secondary)
            } else if let errore = calendario.errore, calendario.autorizzato || !bozza.attivo {
                // (Senza autorizzazione lo dice già la sezione qui sopra.)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(errore)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let quando = calendario.ultimaSincronizzazione, let esito = calendario.esito {
                Text("Ultimo aggiornamento alle \(Formato.ora(quando)): \(esito)")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .font(.caption)
    }

    private func notifica(_ id: UUID) -> Notifica? {
        bozza.notifiche.first { $0.id == id }
    }
}


// I campi del foglio si collegano con percorsi come `$bozza[notifica: id].metodo` invece che con
// `Binding(get:set:)`: quest'ultimo fa usare all'app Swift Concurrency, che su macOS 11 Big Sur non c'è.
extension ImpostazioniCalendario {
    /// La notifica con questo id (una nuova se nel frattempo è stata tolta).
    subscript(notifica id: UUID) -> Notifica {
        get { notifiche.first { $0.id == id } ?? Notifica() }
        set {
            if let indice = notifiche.firstIndex(where: { $0.id == id }) {
                notifiche[indice] = newValue
            }
        }
    }

    /// L'ora dell'evento come data di oggi, per il selettore dell'ora.
    var oraEventoComeData: Date {
        get { Notifica.data(minuti: oraEvento) }
        set { oraEvento = Notifica.minuti(di: newValue) }
    }
}

extension Notifica {
    /// L'ora della notifica come data di oggi, per il selettore dell'ora.
    var oraComeData: Date {
        get { Notifica.data(minuti: ora) }
        set { ora = Notifica.minuti(di: newValue) }
    }

    static func data(minuti: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minuti * 60))
    }

    static func minuti(di data: Date) -> Int {
        let componenti = Calendar.current.dateComponents([.hour, .minute], from: data)
        return (componenti.hour ?? 0) * 60 + (componenti.minute ?? 0)
    }
}
