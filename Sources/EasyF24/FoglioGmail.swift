import SwiftUI
import UniformTypeIdentifiers

/// Impostazioni del collegamento a Gmail: email del commercialista, credenziali
/// dell'app Google e accesso all'account.
struct FoglioGmail: View {
    @ObservedObject var gmail: GmailSync
    let onChiudi: () -> Void

    @State private var emailCommercialista: String
    @State private var tuttoIlDominio: Bool
    @State private var clientId: String
    @State private var clientSecret: String
    @State private var modificaCredenziali: Bool
    @State private var erroreFile: String?

    init(gmail: GmailSync, onChiudi: @escaping () -> Void) {
        self.gmail = gmail
        self.onChiudi = onChiudi
        _emailCommercialista = State(initialValue: gmail.impostazioni.emailCommercialista)
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
            Text("Easy F24 cerca nella tua casella le email del commercialista con «\(GmailSync.oggettoRichiesto)» nell'oggetto e aggiunge i nuovi moduli tra quelli da pagare. L'accesso a Gmail è in sola lettura.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("1. Email del commercialista").font(.headline)
            sezioneCommercialista

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
                .disabled(gmail.inControllo || !emailValida)
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
    let onImpostazioni: () -> Void

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
            } else if gmail.stato == .collegato && gmail.emailCommercialistaValida {
                Button("Controlla ora", action: gmail.controlla)
            }
            Button(gmail.stato == .collegato ? "Gmail…" : "Collega Gmail…", action: onImpostazioni)
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
            if gmail.inControllo {
                return "Controllo delle email di \(gmail.mittenteCercato)…"
            }
            var parti = ["Gmail: email da \(gmail.mittenteCercato)"]
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
