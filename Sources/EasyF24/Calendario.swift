import SwiftUI

/// Campo data "a tendina": mostra la data scelta e, al clic, apre un calendario grande.
struct CampoData: View {
    @Binding var data: Date
    /// Giorno da segnare con un pallino nel calendario (es. la scadenza mentre si sceglie il pagamento).
    let segnata: Date?
    let nomeSegnata: String

    @State private var aperto = false

    init(data: Binding<Date>, segnata: Date? = nil, nomeSegnata: String = "Scadenza") {
        _data = data
        self.segnata = segnata
        self.nomeSegnata = nomeSegnata
    }

    var body: some View {
        Button(action: { aperto.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundColor(.accentColor)
                Text(CampoData.formato.string(from: data))
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(aperto ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: aperto ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help("Scegli la data dal calendario")
        .popover(isPresented: $aperto, arrowEdge: .bottom) {
            CalendarioMese(selezione: data, segnata: segnata, nomeSegnata: nomeSegnata) { scelta in
                data = scelta
                aperto = false
            }
        }
    }

    /// "martedì 16 dicembre 2026"
    private static let formato: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Formato.locale
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter
    }()
}

/// Calendario di un mese, grande e moderno: lunedì primo giorno, oggi cerchiato,
/// giorno scelto pieno, frecce per cambiare mese e pulsante "Oggi".
struct CalendarioMese: View {
    let selezione: Date
    let segnata: Date?
    let nomeSegnata: String
    let onScelta: (Date) -> Void

    @State private var mese: Date
    @State private var sotto: Date?

    private static let lato: CGFloat = 40
    private static let spazio: CGFloat = 4

    init(selezione: Date, segnata: Date? = nil, nomeSegnata: String = "Scadenza", onScelta: @escaping (Date) -> Void) {
        self.selezione = selezione
        self.segnata = segnata
        self.nomeSegnata = nomeSegnata
        self.onScelta = onScelta
        _mese = State(initialValue: CalendarioMese.inizioMese(selezione))
    }

    var body: some View {
        VStack(spacing: 10) {
            intestazione
            HStack(spacing: CalendarioMese.spazio) {
                ForEach(0..<7, id: \.self) { indice in
                    Text(CalendarioMese.nomiGiorni[indice])
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: CalendarioMese.lato)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(CalendarioMese.lato), spacing: CalendarioMese.spazio), count: 7),
                      spacing: CalendarioMese.spazio) {
                ForEach(CalendarioMese.giorni(del: mese), id: \.self) { giorno in
                    cella(giorno)
                }
            }
            if let segnata = segnata {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("\(nomeSegnata): \(Formato.data(segnata))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(16)
        .frame(width: 7 * CalendarioMese.lato + 6 * CalendarioMese.spazio + 32)
    }

    private var intestazione: some View {
        HStack(spacing: 6) {
            Text(CalendarioMese.titolo(mese))
                .font(.title3)
                .bold()
            Spacer()
            BottoneTondo(simbolo: "chevron.left", aiuto: "Mese precedente") { cambiaMese(-1) }
            Button("Oggi") { onScelta(CalendarioMese.calendario.startOfDay(for: Date())) }
                .buttonStyle(BorderlessButtonStyle())
                .foregroundColor(.accentColor)
                .help("Scegli la data di oggi")
            BottoneTondo(simbolo: "chevron.right", aiuto: "Mese successivo") { cambiaMese(1) }
        }
    }

    private func cella(_ giorno: Date) -> some View {
        let calendario = CalendarioMese.calendario
        let delMese = calendario.isDate(giorno, equalTo: mese, toGranularity: .month)
        let scelto = calendario.isDate(giorno, inSameDayAs: selezione)
        let oggi = calendario.isDateInToday(giorno)
        let segnato = segnata.map { calendario.isDate(giorno, inSameDayAs: $0) } ?? false
        let coloreTesto: Color = scelto ? .white : (!delMese ? Color.secondary.opacity(0.45) : (oggi ? .accentColor : .primary))
        return Button(action: { onScelta(calendario.startOfDay(for: giorno)) }) {
            ZStack {
                Circle()
                    .fill(scelto ? Color.accentColor : (sotto == giorno ? Color.primary.opacity(0.08) : Color.clear))
                if oggi && !scelto {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 1.5)
                }
                Text(String(calendario.component(.day, from: giorno)))
                    .font(Font.system(size: 15, weight: scelto || oggi ? .semibold : .regular).monospacedDigit())
                    .foregroundColor(coloreTesto)
                if segnato {
                    Circle()
                        .fill(scelto ? Color.white : Color.orange)
                        .frame(width: 5, height: 5)
                        .offset(y: 12)
                }
            }
            .frame(width: CalendarioMese.lato, height: CalendarioMese.lato)
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { dentro in
            if dentro {
                sotto = giorno
            } else if sotto == giorno {
                sotto = nil
            }
        }
    }

    private func cambiaMese(_ quanti: Int) {
        if let nuovo = CalendarioMese.calendario.date(byAdding: .month, value: quanti, to: mese) {
            mese = nuovo
        }
    }

    // MARK: - Date

    static var calendario: Calendar {
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = .current
        calendario.locale = Formato.locale
        calendario.firstWeekday = 2
        return calendario
    }

    /// "LUN" … "DOM"
    static let nomiGiorni: [String] = {
        let nomi = calendario.shortStandaloneWeekdaySymbols
        return (0..<7).map { nomi[($0 + 1) % 7].uppercased() }
    }()

    static func inizioMese(_ data: Date) -> Date {
        calendario.date(from: calendario.dateComponents([.year, .month], from: data)) ?? data
    }

    /// Le 42 caselle (6 settimane, da lunedì) che mostrano il mese: altezza sempre uguale.
    static func giorni(del mese: Date) -> [Date] {
        let primo = inizioMese(mese)
        let spostamento = (calendario.component(.weekday, from: primo) - calendario.firstWeekday + 7) % 7
        guard let inizio = calendario.date(byAdding: .day, value: -spostamento, to: primo) else { return [] }
        return (0..<42).compactMap { calendario.date(byAdding: .day, value: $0, to: inizio) }
    }

    /// "Dicembre 2026"
    static func titolo(_ mese: Date) -> String {
        let testo = formatoTitolo.string(from: mese)
        return testo.prefix(1).uppercased() + testo.dropFirst()
    }

    private static let formatoTitolo: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Formato.locale
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()
}

/// Piccolo pulsante rotondo con un'icona, che si evidenzia al passaggio del mouse.
private struct BottoneTondo: View {
    let simbolo: String
    let aiuto: String
    let azione: () -> Void

    @State private var sopra = false

    var body: some View {
        Button(action: azione) {
            Image(systemName: simbolo)
                .font(Font.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(sopra ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(aiuto)
        .onHover { sopra = $0 }
    }
}
