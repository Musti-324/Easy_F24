import SwiftUI
import UniformTypeIdentifiers

/// Impostazioni del collegamento a Gmail: email del commercialista, credenziali
/// dell'app Google e accesso all'account.
struct FoglioGmail: View {
    @ObservedObject var gmail: GmailSync
    let onChiudi: () -> Void

    @State private var emailCommercialista: String
    @State private var paroleChiave: [RigaParola]
    @State private var tuttoIlDominio: Bool
    @State private var clientId: String
    @State private var clientSecret: String
    @State private var modificaCredenziali: Bool
    @State private var erroreFile: String?

    init(gmail: GmailSync, onChiudi: @escaping () -> Void) {
        self.gmail = gmail
        self.onChiudi = onChiudi
        _emailCommercialista = State(initialValue: gmail.impostazioni.emailCommercialista)
        let salvate = gmail.impostazioni.paroleChiave.map { RigaParola(testo: $0) }
        _paroleChiave = State(initialValue: salvate.isEmpty ? [RigaParola(testo: "")] : salvate)
        _tuttoIlDominio = State(initialValue: gmail.impostazioni.tuttoIlDominio)
        _clientId = State(initialValue: gmail.auth.credenziali?.clientId ?? "")
        _clientSecret = State(initialValue: gmail.auth.credenziali?.clientSecret ?? "")
        _modificaCredenziali = State(initialValue: gmail.auth.credenziali == nil)
    }

    private var emailValida: Bool { GmailSync.emailValida(emailCommercialista.trimmingCharacters(in: .whitespaces)) }
    private var dominioInserito: String? { emailValida ? VerificaMittente.dominio(di: emailCommercialista) : nil }
    private var credenzialiCompilate: Bool {
        !clientId.trimmingCharacters(in: .whitespaces).isEmpty && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Collegamento a Gmail")
                .font(.title2)
                .bold()
            Text("Easy F24 cerca nella tua casella le email del commercialista che hanno nell'oggetto una delle parole chiave scelte da te, e aggiunge i nuovi moduli tra quelli da pagare. L'accesso a Gmail è in sola lettura.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("1. Email del commercialista").font(.headline)
            sezioneCommercialista
            sezioneParoleChiave

            Divider()
            Text("2. Credenziali dell'app Google").font(.headline)
            sezioneCredenziali

            Divider()
            Text("3. Account Gmail").font(.headline)
            sezioneAccount

            HStack(alignment: .bottom) {
                if let ultimo = gmail.ultimoModulo {
                    Text("Ultimo modulo trovato: «\(ultimo.oggetto)», arrivato il \(Formato.data(ultimo.ricevutoIl))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Fine", action: chiudi)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    /// Altezza di una riga dell'elenco (campo di testo più spazio).
    private static let altezzaRiga: CGFloat = 30

    /// Parole chiave inserite, pulite (senza vuote né doppioni).
    private var paroleValide: [String] { GmailSync.pulisci(paroleChiave: paroleChiave.map { $0.testo }) }

    private var sezioneParoleChiave: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Etichetta("Parole chiave nell'oggetto dell'email (ne basta una)")
                Spacer()
                Text("\(paroleChiave.count) di \(GmailSync.massimoParoleChiave)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            // Al massimo 4 righe visibili, poi si scorre: il foglio resta dentro lo schermo del Mac.
            ScrollViewReader { scorrimento in
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(paroleChiave) { riga in
                            HStack(spacing: 6) {
                                TextField("es. MOD. F24", text: $paroleChiave[testoDi: riga.id])
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                Button(action: { togli(riga.id) }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .help("Togli questa parola chiave")
                                .disabled(paroleChiave.count == 1)
                            }
                            .id(riga.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: CGFloat(min(paroleChiave.count, 4)) * FoglioGmail.altezzaRiga + 4)
                .onChange(of: paroleChiave.count) { _ in
                    if let ultima = paroleChiave.last {
                        withAnimation { scorrimento.scrollTo(ultima.id, anchor: .bottom) }
                    }
                }
            }
            Button(action: { paroleChiave.append(RigaParola(testo: "")) }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Aggiungi parola chiave")
                }
                .foregroundColor(paroleChiave.count >= GmailSync.massimoParoleChiave ? .secondary : .accentColor)
            }
            .buttonStyle(BorderlessButtonStyle())
            .disabled(paroleChiave.count >= GmailSync.massimoParoleChiave)
            Text(paroleValide.isEmpty
                 ? "Scrivi il testo che il commercialista mette nell'oggetto delle email con gli F24."
                 : "Vengono importate le email che hanno nell'oggetto almeno una di queste parole (maiuscole e minuscole non contano).")
                .font(.caption)
                .foregroundColor(paroleValide.isEmpty ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func togli(_ id: UUID) {
        guard paroleChiave.count > 1 else { return }
        paroleChiave.removeAll { $0.id == id }
    }

    private var sezioneCommercialista: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("es. studio@commercialista.it", text: $emailCommercialista)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            if !emailCommercialista.isEmpty && !emailValida {
                Text("Indirizzo email non valido")
                    .font(.caption)
                    .foregroundColor(.red)
            } else if let dominio = dominioInserito, !VerificaMittente.providerPubblico(dominio) {
                Toggle("Accetta anche gli altri indirizzi @\(dominio) (es. colleghi dello studio)", isOn: $tuttoIlDominio)
                    .font(.callout)
                Text(tuttoIlDominio
                     ? "Vengono cercate le email di qualsiasi indirizzo @\(dominio)."
                     : "Vengono cercate solo le email inviate da questo indirizzo.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let dominio = dominioInserito {
                Text("Vengono cercate solo le email inviate da questo indirizzo: su @\(dominio) chiunque può avere una casella.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Vengono cercate solo le email inviate da questo indirizzo.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sezioneCredenziali: some View {
        if modificaCredenziali {
            VStack(alignment: .leading, spacing: 8) {
                Text("Servono un «ID client» e un «client secret» che si creano gratis su Google Cloud, una volta sola.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Come si ottengono") {
                    guida
                }
                .font(.callout)
                HStack {
                    Button("Importa file JSON…", action: importaFile)
                    Text("oppure incollali qui sotto")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                TextField("Client ID", text: $clientId)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                SecureField("Client secret", text: $clientSecret)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                if let erroreFile = erroreFile {
                    Text(erroreFile)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        } else {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Inserite")
                Text(clientId)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cambia…") { modificaCredenziali = true }
            }
        }
    }

    @ViewBuilder
    private var sezioneAccount: some View {
        switch gmail.stato {
        case .collegato:
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Collegato come \(gmail.impostazioni.account ?? "account Gmail")")
                Spacer()
                Button("Controlla ora") {
                    salvaCommercialista()
                    gmail.controlla()
                }
                .disabled(gmail.inControllo || !emailValida || paroleValide.isEmpty)
                Button("Scollega", action: gmail.scollega)
            }
        case .attesaBrowser:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Completa l'accesso nel browser…")
                Spacer()
                Button("Annulla", action: gmail.annullaCollegamento)
            }
        case .daConfigurare, .nonCollegato:
            VStack(alignment: .leading, spacing: 4) {
                Button("Accedi con Google…") {
                    salvaCommercialista()
                    salvaCredenziali()
                    gmail.collega()
                }
                .disabled(!credenzialiCompilate)
                Text("Si apre il browser: scegli il tuo account e consenti a Easy F24 di leggere le email.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        if let errore = gmail.errore {
            Text(errore)
                .font(.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var guida: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1. Apri Google Cloud Console con il tuo account Google e crea un progetto, per esempio «Easy F24».")
            Text("2. Cerca «Gmail API» e premi «Abilita».")
            Text("3. Configura la schermata di consenso OAuth: tipo «Esterno», nome dell'app e la tua email. Aggiungi il tuo indirizzo Gmail tra gli utenti di test.")
            Text("4. Crea le credenziali: «ID client OAuth» di tipo «App desktop», poi scarica il file JSON.")
            Text("5. Torna qui e premi «Importa file JSON…».")
            Button("Apri Google Cloud Console") {
                if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
    }

    private func importaFile() {
        let pannello = NSOpenPanel()
        pannello.allowedContentTypes = [.json]
        pannello.allowsMultipleSelection = false
        pannello.message = "Scegli il file JSON scaricato da Google Cloud"
        guard pannello.runModal() == .OK, let url = pannello.url else { return }
        guard let dati = try? Data(contentsOf: url), let credenziali = CredenzialiGoogle.daFileGoogle(dati) else {
            erroreFile = "Il file scelto non contiene credenziali Google valide."
            return
        }
        erroreFile = nil
        clientId = credenziali.clientId
        clientSecret = credenziali.clientSecret
        salvaCredenziali()
    }

    private func salvaCommercialista() {
        gmail.impostaParoleChiave(paroleChiave.map { $0.testo })
        if emailValida {
            gmail.impostaEmailCommercialista(emailCommercialista)
            gmail.impostaTuttoIlDominio(tuttoIlDominio)
        }
    }

    private func salvaCredenziali() {
        guard credenzialiCompilate else { return }
        gmail.impostaCredenziali(clientId: clientId, clientSecret: clientSecret)
    }

    private func chiudi() {
        salvaCommercialista()
        salvaCredenziali()
        onChiudi()
    }
}

/// Riga in fondo alla finestra con lo stato del collegamento a Gmail.
struct BarraGmail: View {
    @ObservedObject var gmail: GmailSync
    @ObservedObject var calendario: CalendarioSync
    let onImpostazioni: () -> Void
    let onCalendario: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .foregroundColor(.secondary)
            Text(descrizione)
                .foregroundColor(gmail.errore == nil && gmail.emailIgnorate == 0 ? .secondary : .orange)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if gmail.emailIgnorate > 0 {
                Image(systemName: "exclamationmark.shield")
                    .foregroundColor(.orange)
                    .help("Email che sembrano del commercialista ma che Gmail non ha potuto verificare (SPF/DKIM/DMARC): possono essere false e non sono state importate. Se sono vere, aggiungi l'F24 a mano.")
            }
            if gmail.inControllo {
                ProgressView()
                    .controlSize(.small)
            } else if gmail.stato == .collegato && gmail.configurazioneCompleta {
                Button("Controlla ora", action: gmail.controlla)
            }
            if gmail.stato == .collegato {
                Button(action: onCalendario) {
                    HStack(spacing: 4) {
                        Image(systemName: calendario.errore == nil ? "calendar" : "exclamationmark.triangle.fill")
                            .foregroundColor(calendario.errore == nil ? (calendario.impostazioni.attivo ? .accentColor : .secondary) : .orange)
                        Text("Calendario…")
                    }
                }
                .help(calendario.errore ?? (calendario.impostazioni.attivo ? "Google Calendar attivo" : "Google Calendar spento"))
                Button("Gmail…", action: onImpostazioni)
            } else {
                Button("Collega a Gmail", action: onImpostazioni)
                    .buttonStyle(PulsanteGiallo())
                    .help("Collega Gmail per aggiungere da soli gli F24 del commercialista")
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var descrizione: String {
        if let errore = gmail.errore {
            return errore
        }
        switch gmail.stato {
        case .daConfigurare, .nonCollegato:
            return "Gmail non collegato: gli F24 si aggiungono a mano."
        case .attesaBrowser:
            return "Accesso a Gmail in corso nel browser…"
        case .collegato:
            if gmail.rileggendo {
                return "Rileggo il PDF da Gmail…"
            }
            if gmail.inControllo {
                return "Controllo delle email di \(gmail.mittenteCercato)…"
            }
            var parti = ["Gmail: email da \(gmail.mittenteCercato) con \(BarraGmail.elenco(gmail.paroleChiave))"]
            if let quando = gmail.ultimoControllo {
                let giorno = Calendar.current.isDateInToday(quando) ? "" : "il \(Formato.data(quando)) "
                parti.append("controllate \(giorno)alle \(Formato.ora(quando))")
            }
            if let esito = gmail.esito {
                parti.append(esito)
            }
            return parti.joined(separator: " · ")
        }
    }
}

extension BarraGmail {
    /// «A»; «A» o «B»; «A», «B» o altre 3
    static func elenco(_ parole: [String]) -> String {
        let citate = parole.map { "«\($0)»" }
        switch citate.count {
        case 0: return "nessuna parola chiave"
        case 1: return citate[0]
        case 2: return citate[0] + " o " + citate[1]
        default: return citate[0] + ", " + citate[1] + " o altre \(citate.count - 2)"
        }
    }
}

/// Una riga dell'elenco delle parole chiave nel foglio Gmail.
struct RigaParola: Identifiable {
    let id = UUID()
    var testo: String
}

extension Array where Element == RigaParola {
    /// Il testo della riga con questo id (vuoto se nel frattempo è stata tolta), per collegare i campi di testo
    /// con `$paroleChiave[testoDi: id]`. Un collegamento con `Binding(get:set:)` qui fa usare all'app
    /// Swift Concurrency, che su macOS 11 Big Sur non c'è: l'app si chiuderebbe aprendo il foglio.
    subscript(testoDi id: UUID) -> String {
        get { first { $0.id == id }?.testo ?? "" }
        set {
            if let indice = firstIndex(where: { $0.id == id }) {
                self[indice].testo = newValue
            }
        }
    }
}

/// Pulsante giallo, per far notare che Gmail non è ancora collegato.
struct PulsanteGiallo: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Color.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(NSColor.systemYellow).opacity(configuration.isPressed ? 0.75 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}
