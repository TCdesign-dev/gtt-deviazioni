# Struttura dell'app

> Per il quadro completo — misure, decisioni, trappole — vedi
> [`CLAUDE.md`](../CLAUDE.md) nella radice del repository.
> Qui c'è solo la struttura dei moduli.

Una regola sola, ma vale per tutto il resto:

> **`lib/core/` è Dart puro. Nessun `import 'package:flutter/...'`.**

Da lì discende il resto. Il core si testa in millisecondi senza simulatore,
si può eseguire da riga di comando, e l'interfaccia si può riscrivere (o
sostituire con Android nativo, o con uno script) senza toccare la logica.
Se un file dentro `core/` ha bisogno di Flutter, quel file è nel posto
sbagliato.

```
lib/
├── core/                        ← Dart puro, zero Flutter
│   ├── config.dart              ← TUTTE le costanti tarabili, in un posto solo
│   ├── models/                  ← tipi di dominio, senza comportamento di rete
│   ├── geo/
│   │   ├── projection.dart      ← gradi ↔ metri  (l'unico file da cambiare
│   │   │                           se un giorno servisse la UTM vera)
│   │   ├── geometry.dart        ← distanze, proiezioni, Fréchet, densify
│   │   └── polyline.dart        ← codifica Google polyline
│   ├── gtfs/                    ← scarico e indicizzazione del GTFS statico
│   ├── sources/                 ← una classe per fonte GTT, tutte intercambiabili
│   └── pipeline/                ← i passaggi del calcolo, uno per file
│       ├── line_resolver.dart   ← "55" → 55U   (tabella alias, §4.1)
│       ├── notice_merge.dart    ← due fonti → un avviso solo, per linea
│       ├── extractor.dart       ← testo → JSON  (LLM)
│       ├── geocoder.dart        ← toponimo → coordinate, VINCOLATO
│       ├── route_builder.dart   ← vie → polilinea  (Valhalla)
│       ├── stop_impact.dart     ← quali fermate saltano, quali alternative
│       └── narrator.dart        ← evento → frase in italiano
├── data/                        ← persistenza, cache, watchlist
│   └── user_location.dart       ← la posizione: plugin Flutter, quindi NON in core/
└── ui/                          ← schermate
```

## Perché è diviso così

Ogni file di `pipeline/` è **un passaggio del ragionamento** e si può
sostituire da solo. Se Photon smette di funzionare cambi `geocoder.dart` e
basta. Se Valhalla pubblico sparisce, cambi `route_builder.dart`. Se domani
vuoi un LLM diverso, tocchi `extractor.dart`. Nessuno degli altri file se
ne accorge.

`config.dart` esiste perché quasi tutte le soglie di questo sistema vanno
tarate sul campo, e quando lo farai vorrai un file solo da aprire invece di
cercare numeri sparsi nel codice. I valori marcati `MISURATO` vengono da
rilevazioni vere, non dalle stime della specifica — e in tre casi le
smentiscono.

## Stato

| Modulo | Stato |
|---|---|
| `config.dart` | fatto |
| `geo/projection.dart` | fatto, 4 test |
| `geo/geometry.dart` | fatto, 21 test |
| `geo/polyline.dart` | fatto, 3 test |
| `models/transit.dart` | fatto |
| `models/notice.dart` | fatto |
| `gtfs/csv.dart` | fatto, 6 test |
| `gtfs/gtfs_parser.dart` | fatto, 6 test sul GTFS vero |
| `net/gtt_http.dart` | fatto |
| `sources/alerts_source.dart` | fatto, 4 test su feed reale |
| `sources/variazioni_source.dart` | fatto, 5 test su pagina reale |
| `pipeline/line_resolver.dart` | fatto, 5 test — copertura 98,4% |
| `pipeline/notice_merge.dart` | fatto, 25 test — 31 coppie sui dati veri |
| `llm/` | fatto — misurato su 34 avvisi reali |
| `pipeline/extractor.dart` | fatto, 11 test + banco di prova |
| `pipeline/geocoder.dart` | fatto, 13 test + verifica dal vivo |
| `pipeline/route_builder.dart` | fatto, 12 test + catena dal vivo 3/3 |
| `pipeline/stop_impact.dart` | fatto, 18 test + catena dal vivo |
| `pipeline/rejoin_inference.dart` | fatto, 7 test + catena dal vivo |
| `sources/vehicles_source.dart` | fatto |
| `pipeline/vehicle_watch.dart` | fatto, 9 test + prova dal vivo |
| `data/` | fatto — impostazioni, orchestrazione, controllo per linea, posizione |
| `ui/` | fatto — 3 schermate + mappa, 11 test |
| `core/deviation_service.dart` | fatto — la facciata, 19 test |
| `core/gtfs/gtfs_downloader.dart` | fatto — scarico ed estrazione |

```bash
flutter test
```

I test sulle fonti girano **offline su dati veri**: la pagina e il feed di
GTT del 31/07/2026 sono salvati in `test/fixtures/`. Quelli sul GTFS si
saltano da soli se i file non sono estratti in `data/gtfs/`.

## Due cose imparate scrivendo i test

**La Fréchet discreta misura anche il campionamento, non solo la forma.**
Due campionamenti diversi dello stesso identico percorso danno una distanza
pari al passo più rado. Le shape GTFS hanno vertici ogni ~200 m, le tracce
GPS un punto ogni 30 s: confrontarle direttamente produrrebbe centinaia di
metri di differenza fantasma, e la soglia di 200 m della specifica
scarterebbe accoppiamenti giusti. Per questo esiste `densify()`, da
chiamare **prima** di ogni confronto.

**Infittire non è ricampionare.** Un ricampionamento a passo fisso che
sostituisce i vertici taglia gli angoli, e accorcia il percorso proprio nei
punti di svolta — che sono quelli dove una deviazione si distingue da un
percorso normale. `densify()` aggiunge punti senza toglierne, e un test
verifica che la lunghezza resti identica al metro.

## Cosa il sistema NON fa (ancora)

Per non confondersi leggendo `config.dart`, che contiene piu' costanti di
quante ne siano usate:

- **non manda notifiche.** Servirebbe qualcosa fuori dal telefono che
  sorvegli gli avvisi: iOS non regge il polling in background.
- **non calcola le distanze a piedi reali.** Le alternative alle fermate
  saltate sono in linea d'aria, e l'interfaccia lo dichiara.
- **non deduce il punto di rientro** quando l'avviso dice solo "percorso
  normale" senza nominare la via.
- **non distingue le varianti dentro una direzione**: usa la principale
  (quella con piu' corse). Una deviazione che riguarda solo la corsa
  limitata verrebbe calcolata sul percorso intero.

## Un limite di GTT che vale la pena sapere

**Il feed delle posizioni si spegne di notte, ma il servizio no.**
Misurato il 31/07/2026 alle 23:39: `vehicle_position` restituisce un
protobuf vuoto di 15 byte, mentre `trip_update` (26 KB) e `alerts`
(197 KB) continuano a rispondere. Il GTFS pero' dice che la linea 15 ha
corse programmate fino alle **01:52**, con 2.920 passaggi dopo le 23:30.

Quindi i mezzi circolano e GTT semplicemente smette di dire dove sono.
Per questo l'app distingue "feed spento" da "nessun mezzo su questa
linea": confonderli significherebbe dire che il servizio e' finito quando
non lo e'.
