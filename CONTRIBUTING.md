# Modifiche e contributi

Easy F24 è distribuito con licenza **Apache 2.0** (file [`LICENSE`](LICENSE)).
Chiunque, anche esterno al progetto, può usare e modificare il codice, ma **le modifiche vanno sempre segnalate**.

## Se pubblichi o distribuisci una versione modificata

Come richiede la licenza (sezione 4):

1. **In ogni file che hai cambiato** aggiungi in cima una nota ben visibile, per esempio:

   ```swift
   // Modificato da Mario Rossi il 2026-11-15: aggiunta l'esportazione in CSV.
   ```

2. Mantieni il file [`NOTICE`](NOTICE) e le note di copyright esistenti; puoi aggiungere le tue.
3. Includi una copia del file `LICENSE`.
4. Non presentare la tua versione come quella originale di Easy F24.

## Se proponi una modifica a questo repository

1. Apri una *pull request* su GitHub: ogni modifica resta registrata con il nome del suo autore.
2. Nella descrizione spiega **cosa** cambia e **perché**; scrivi messaggi di commit chiari, uno per modifica.
3. Fai girare le prove prima di proporre la modifica:

   ```bash
   ./scripts/test.sh
   ```

4. Inviando una modifica accetti che sia distribuita con la stessa licenza Apache 2.0 (sezione 5 della licenza).

Non inserire mai nel codice dati personali, indirizzi email reali o credenziali.
