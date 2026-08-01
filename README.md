# Deviazioni GTT

**La mia fermata è ancora servita?**

GTT pubblica gli avvisi di deviazione in prosa: *«Da via Asinari di Bernezzo
angolo corso Monte Grappa, per via Asinari di Bernezzo, piazza Chironi, via
Medici, corso Lecce, via Lessona, segue percorso normale»*. Chi aspetta il
bus non vuole leggere un elenco di vie: vuole sapere se il mezzo passa
ancora dove sta lui.

Questa app trasforma quel testo in geometria georiferita e risponde a quella
domanda sola, per le linee che prendi tu.

App Flutter per **iOS e Android**. Nessun server: il GTFS e tutti i calcoli
stanno sul telefono.

> Progetto personale, non affiliato a GTT.

<p align="center">
  <img src="docs/img/linea-65.png" width="330"
       alt="Schermata della linea 65: mappa con le due direzioni, le fermate,
            e la scritta «Adesso il percorso è regolare»">
</p>

---

## Cosa fa

- **Quali fermate saltano**, e dove andare al loro posto — è la cosa che
  GTT non dice quasi mai.
- **La mappa**: percorso normale di entrambe le direzioni, tratto deviato
  in rosso, fermate saltate cerchiate.
- **Distingue quello che è in corso da quello che comincerà.** Il 19%
  delle variazioni pubblicate non è ancora iniziato.
- **Guarda dove sono i mezzi adesso**, per qualche minuto, e dice se la
  deviazione è in corso o — cosa che nessun'altra fonte sa — se è **già
  finita**. GTT la fine non la annuncia quasi mai.
- **Il testo originale di GTT resta sempre in fondo.** Se il sistema
  sbaglia, il dato grezzo è lì.

## Cosa NON fa

Vale la pena dirlo prima, per non far perdere tempo:

- **Niente notifiche.** iOS non regge il polling in background. Servirebbe
  qualcosa fuori dal telefono.
- **Le distanze alle fermate alternative sono in linea d'aria**, non a
  piedi. L'interfaccia lo dichiara.
- Dentro una direzione **usa solo la variante principale**: una deviazione
  che riguardasse la sola corsa limitata verrebbe calcolata sul percorso
  intero.
- **Non indovina.** Se un toponimo non si risolve o una validazione non
  torna, dichiara l'incertezza e mostra il testo. Meglio nessuna mappa che
  una mappa sbagliata: un falso positivo ti fa camminare 800 metri per
  niente.

## Come funziona

```
avviso GTT ──► le due fonti si uniscono ──► LLM: testo → JSON
                                                    │
                              geocoding VINCOLATO al percorso della linea
                                                    │
                              routing bus (Valhalla) ──► 5 validazioni
                                                    │
                              quali fermate saltano + alternative + mappa
```

Il passaggio che fa la differenza è il **geocoding vincolato**: i toponimi
si cercano solo entro 1 km dal percorso di *quella* linea. Senza questo
vincolo «via Roma» a Torino è un disastro; con il vincolo, sui toponimi
reali degli avvisi, la risoluzione è **150 su 150**.

C'è una scorciatoia per il caso più certo di tutti: se l'avviso nomina solo
delle fermate sospese (*«Fermata 3445 Sabotino sospesa»*) non c'è nessun
percorso da ricostruire — il codice si legge dal testo e si cerca nel GTFS.
Niente LLM, niente rete: funziona anche a quota esaurita.

## Provarla

Serve [Flutter](https://docs.flutter.dev/get-started/install) (Dart ≥ 3.12).

```bash
git clone https://github.com/TCdesign-dev/gtt-deviazioni.git
cd gtt-deviazioni/app && flutter pub get && flutter run
```

Al primo avvio scarica il GTFS di GTT (24 MB), poi non serve più per una
settimana. Aggiungi le linee che prendi e tocca **Controlla**.

Per leggere il testo degli avvisi serve una chiave
[OpenRouter](https://openrouter.ai/keys), che si incolla nelle
impostazioni e **resta sul dispositivo**. Il modello predefinito è
gratuito, con un limite di 50 richieste al giorno: per questo si può
controllare una linea sola invece di tutte.

**Android**: `flutter build apk`. Nessuna licenza da sviluppatore.
**iOS**: con un Apple ID gratuito la firma scade dopo 7 giorni; per
distribuirla ad altri serve il programma a pagamento di Apple.

## Documentazione

| Dove | Cosa |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | **Leggi questo per primo.** Le misure, le decisioni e il perché, i punti in cui il progetto originale sbaglia, e le trappole già pagate. |
| [`app/ARCHITETTURA.md`](app/ARCHITETTURA.md) | Struttura dei moduli e stato. |
| [`docs/FASE-0-RISULTATI.md`](docs/FASE-0-RISULTATI.md) | Le misure sulle fonti GTT. |
| [`docs/SPECIFICA-…md`](docs/) | Il progetto originale. **Non è la verità**: sette punti sono stati smentiti dalle misure, vedi `CLAUDE.md` §4. |

Una regola sola tiene su il resto: **`app/lib/core/` è Dart puro, senza un
solo `import 'package:flutter/…'`**. Si testa in millisecondi senza
simulatore, e l'interfaccia si può riscrivere senza toccare la logica.

```bash
cd app && flutter test      # 203 test
cd app && flutter analyze
```

I test sulle fonti girano **offline su dati veri**: il feed e la pagina di
GTT sono salvati in `app/test/fixtures/`.

## Dati e licenze

- Dati di trasporto: **GTT S.p.A.**, [open data](https://www.gtt.to.it/cms/openday/open-data),
  licenza **CC-BY** — vanno citati.
- Mappe: **OpenStreetMap**, licenza ODbL.
- Routing: **Valhalla** ospitato da [FOSSGIS](https://valhalla1.openstreetmap.de/).
- Geocoding: **[Photon](https://photon.komoot.io/)** di Komoot.

Photon e Valhalla sono servizi di cortesia: l'app fa pause fra le
chiamate, si identifica con uno User-Agent, e ha sempre un ripiego se
cadono. Se ci costruisci qualcosa di grosso sopra, ospitateli.

Il codice è sotto licenza **MIT** — vedi [`LICENSE`](LICENSE).

## Contribuire

Segnalazioni e patch benvenute. Due cose che vale la pena sapere prima:

1. **Le soglie si tarano misurando, non a occhio.** Gli script in
   `scripts/` e `app/tool/` servono a questo, e `CLAUDE.md` §3 elenca cosa
   è già stato misurato. Se rimetti in discussione un numero, rimisuralo.
2. **«Non lo so» è una risposta valida** e va detta come tale. Il sistema
   preferisce dichiarare l'incertezza piuttosto che inventare una
   geometria.
