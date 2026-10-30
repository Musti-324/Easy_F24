# Easy F12

Un gestionale semplicissimo per Mac per tenere traccia degli **F12**:

- a **sinistra** gli F12 **da pagare**, ordinati per scadenza (in rosso quelli scaduti, in arancione quelli che scadono entro una settimana);
- a **destra** gli F12 **già pagati**, con la data in cui sono stati pagati.

![Easy F12](docs/screenshot.png)

## Requisiti

- macOS 11 **Big Sur** o successivo
- Mac Intel oppure Apple Silicon (l'app è universale)

## Installazione

1. Scarica `Easy-F12.dmg` dalla pagina **Releases** del repository e aprilo con un doppio clic.
2. Nella finestra che si apre, trascina **Easy F12** sulla cartella **Applicazioni**, poi espelli il disco "Easy F12".
3. La prima volta: **tasto destro sull'app → Apri → Apri**.
   (L'app non è firmata con un certificato Apple a pagamento, quindi macOS chiede una conferma solo al primo avvio.)

## Come si usa

| Cosa vuoi fare | Come |
| --- | --- |
| Aggiungere un F12 | Pulsante **Nuovo F12** (oppure ⌘N): descrizione, importo (facoltativo) e scadenza |
| Segnare un F12 come pagato | Pulsante **Segna pagato**, poi scegli la data del pagamento (di default oggi) |
| Modificare un F12 | Doppio clic sulla scheda, oppure tasto destro → **Modifica…** |
| Annullare un pagamento | Tasto destro su un F12 pagato → **Riporta tra i da pagare** |
| Eliminare un F12 | Tasto destro → **Elimina…** |

## Dove sono salvati i dati

Tutto resta sul Mac, in un file leggibile:

```
~/Library/Application Support/Easy F12/f12.json
```

A ogni apertura dell'app viene fatta una copia di sicurezza in `f12-backup.json`, nella stessa cartella.
Per fare un backup basta copiare questa cartella.

## Compilare dal codice sorgente

Serve solo il pacchetto *Strumenti da riga di comando* di Apple (Xcode non è necessario):

```bash
xcode-select --install
```

Poi, dalla cartella del progetto:

```bash
./scripts/build.sh
```

Il risultato è in `build/`: `Easy F12.app`, il disco di installazione `Easy-F12.dmg` e `Easy-F12.zip`.
Su un Mac Intel si può compilare solo la versione Intel con `ARCHS=x86_64 ./scripts/build.sh`.

Per modificare il codice con Xcode basta aprire `Package.swift`.
L'icona si rigenera con `swift scripts/make-icon.swift`.

## Struttura

```
Sources/EasyF12/
  EasyF12App.swift   avvio dell'app
  ContentView.swift  finestra principale con le due colonne
  Righe.swift        schede "da pagare" e "pagato"
  Fogli.swift        finestre per aggiungere/modificare e per segnare come pagato
  F12.swift          il dato F12
  F12Store.swift     elenco degli F12 e salvataggio su file
  Formato.swift      date e importi all'italiana
```
