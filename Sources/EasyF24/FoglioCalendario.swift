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
            Text("Ogni F24 da pagare diventa un evento nel giorno della scadenza. Quando lo segni come pagato (o lo elimini) l'evento viene tolto. Spento: l'app funziona come sempre, senza calendario.")
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
                    calendario.applica(bozza)
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
                    Picker("", selection: sceltaCalendario) {
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
                    DatePicker("", selection: oraBinding(\.oraEvento), displayedComponents: .hourAndMinute)
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
            Picker("", selection: campo(id, \.metodo)) {
                ForEach(Notifica.Metodo.allCases, id: \.self) { Text($0.nome).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            Stepper(value: campo(id, \.quantita), in: 1...40) {
                Text("\(notifica(id)?.quantita ?? 1)")
                    .frame(minWidth: 22, alignment: .trailing)
            }
            Picker("", selection: campo(id, \.unita)) {
                ForEach(bozza.tuttoIlGiorno ? [Notifica.Unita.giorni, .settimane] : Notifica.Unita.allCases, id: \.self) {
                    Text($0.nome).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Text("prima")
            if bozza.tuttoIlGiorno {
                Text("alle")
                DatePicker("", selection: oraNotifica(id), displayedComponents: .hourAndMinute)
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

    // MARK: Collegamenti ai campi

    private var sceltaCalendario: Binding<String> {
        Binding(get: { bozza.calendarioId },
                set: { id in
                    bozza.calendarioId = id
                    bozza.calendarioNome = calendario.calendari.first { ($0.primary == true ? "primary" : $0.id) == id }?.nome ?? id
                })
    }

    private func notifica(_ id: UUID) -> Notifica? {
        bozza.notifiche.first { $0.id == id }
    }

    /// Collegamento a un campo di una notifica cercata per id (sicuro anche se nel frattempo viene tolta).
    private func campo<Valore>(_ id: UUID, _ percorso: WritableKeyPath<Notifica, Valore>) -> Binding<Valore> {
        Binding(get: { notifica(id)?[keyPath: percorso] ?? Notifica()[keyPath: percorso] },
                set: { nuovo in
                    if let indice = bozza.notifiche.firstIndex(where: { $0.id == id }) {
                        bozza.notifiche[indice][keyPath: percorso] = nuovo
                    }
                })
    }

    private func oraBinding(_ percorso: WritableKeyPath<ImpostazioniCalendario, Int>) -> Binding<Date> {
        Binding(get: { FoglioCalendario.data(minuti: bozza[keyPath: percorso]) },
                set: { bozza[keyPath: percorso] = FoglioCalendario.minuti(di: $0) })
    }

    private func oraNotifica(_ id: UUID) -> Binding<Date> {
        let minuti = campo(id, \.ora)
        return Binding(get: { FoglioCalendario.data(minuti: minuti.wrappedValue) },
                       set: { minuti.wrappedValue = FoglioCalendario.minuti(di: $0) })
    }

    private static func data(minuti: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minuti * 60))
    }

    private static func minuti(di data: Date) -> Int {
        let componenti = Calendar.current.dateComponents([.hour, .minute], from: data)
        return (componenti.hour ?? 0) * 60 + (componenti.minute ?? 0)
    }
}
