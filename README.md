# Easy F24

Un gestionale semplicissimo per Mac per tenere traccia degli **F24**:

- a **sinistra** gli F24 **da pagare**, ordinati per scadenza (in rosso quelli scaduti, in arancione quelli che scadono entro una settimana);
- a **destra** gli F24 **già pagati**, con la data in cui sono stati pagati.

![Easy F24](docs/screenshot.png)

## Requisiti

- macOS 11 **Big Sur** o successivo
- Mac Intel oppure Apple Silicon (l'app è universale)

## Installazione

1. Scarica `Easy_F24.dmg` dalla pagina **Releases** del repository e aprilo con un doppio clic.
2. Nella finestra che si apre, trascina **Easy F24** sulla cartella **Applicazioni**, poi espelli il disco "Easy F24".
3. La prima volta: **tasto destro sull'app → Apri → Apri**.
   (L'app non è firmata con un certificato Apple a pagamento, quindi macOS chiede una conferma solo al primo avvio.)

## Come si usa

| Cosa vuoi fare | Come |
| --- | --- |
| Aggiungere un F24 | Pulsante **Nuovo F24** (oppure ⌘N): descrizione, importo (facoltativo) e scadenza |
| Segnare un F24 come pagato | Pulsante **Segna pagato**, poi scegli la data del pagamento (di default oggi) |
| Modificare un F24 | Doppio clic sulla scheda, oppure tasto destro → **Modifica…** |
| Annullare un pagamento | Tasto destro su un F24 pagato → **Riporta tra i da pagare** |
| Eliminare un F24 | Tasto destro → **Elimina…** |

## Dove sono salvati i dati

Tutto resta sul Mac, in un file leggibile:

```
~/Library/Application Support/Easy F24/f24.json
```

A ogni apertura dell'app viene fatta una copia di sicurezza in `f24-backup.json`, nella stessa cartella.
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

Il risultato è in `build/`: `Easy F24.app`, il disco di installazione `Easy_F24.dmg` e `Easy_F24.zip`.
Su un Mac Intel si può compilare solo la versione Intel con `ARCHS=x86_64 ./scripts/build.sh`.

Per modificare il codice con Xcode basta aprire `Package.swift`.
L'icona si rigenera con `swift scripts/make-icon.swift`.

## Struttura

```
Sources/EasyF24/
  EasyF24App.swift   avvio dell'app
  ContentView.swift  finestra principale con le due colonne
  Righe.swift        schede "da pagare" e "pagato"
  Fogli.swift        finestre per aggiungere/modificare e per segnare come pagato
  F24.swift          il dato F24
  F24Store.swift     elenco degli F24 e salvataggio su file
  Formato.swift      date e importi all'italiana
```
