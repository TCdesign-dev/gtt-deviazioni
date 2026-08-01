# Rilevatore Deviazioni GTT — quello che serve sapere

Trasforma gli avvisi di deviazione di GTT (Torino) in geometria georiferita
e risponde a una domanda sola: **la mia fermata è ancora servita?**

Questo file raccoglie ciò che *non* sta nel codice: le misure, le decisioni
e il perché, i punti in cui la specifica sbaglia, e le trappole che hanno
già fatto perdere tempo. Leggilo prima di modificare qualcosa.

---

## 1. Dove sta cosa

```
docs/SPECIFICA-…md      il progetto originale. NON è la verità: vedi §4
docs/FASE-0-RISULTATI   le misure sulle fonti, 31/07/2026
scripts/*.py            Python. Misure e validazione, non fanno parte dell'app
app/                    l'app Flutter (iOS + Android)
app/ARCHITETTURA.md     struttura dei moduli e stato
validation/             snapshot GTFS giornalieri (test del Segnale A)
```

**Due mondi separati e va bene così.** Gli script Python servono a *misurare*
(quanto è preciso il GPS, quanti toponimi si risolvono, quale modello sbaglia
meno). L'app non li usa e non li userà: sono strumenti da banco.

## 2. Come funziona, in breve

Tutto avviene **per singola linea, su richiesta**. Non si monitora la rete.
È questa scelta a rendere affidabile il resto: il vincolo geografico del
geocoding è il percorso di *quella* linea.

```
avviso GTT ──► LLM: testo → JSON ──► geocoding VINCOLATO al percorso
                                          │
                                          ▼
                              routing bus (Valhalla) ──► 5 validazioni
                                          │
                                          ▼
                        quali fermate saltano + alternative + mappa
```

Con una **scorciatoia**: se l'avviso nomina solo delle fermate sospese
("Fermata 3445 Sabotino sospesa") non c'è nessun percorso da ricostruire.
Il codice si legge dal testo e si cerca nel GTFS — nessun LLM, nessuna
rete oltre a quella già fatta. È il ramo di massima confidenza, e l'unico
che funziona anche a quota esaurita.

In parallelo, su richiesta: **osservazione dei mezzi** per qualche minuto,
che dice se la deviazione è in corso o — cosa che nessun'altra fonte sa —
se è **già finita**.

**Nessun server.** GTFS e calcoli sul telefono; geocoding con Photon,
routing con Valhalla FOSSGIS, LLM via OpenRouter. Tutti servizi pubblici.

## 3. I fatti misurati (31/07/2026)

Non sono stime. Se li rimetti in discussione, rimisurali.

| Cosa | Valore | Dove |
|---|---|---|
| GPS: distanza dal percorso teorico | mediana **3,6 m**, 99° pct 28 m | `burst_probe.py` |
| Posizioni spazzatura (`lat=0,lon=0`) | **~3%** dei mezzi | idem |
| `trip_id` popolato nel feed veicoli | 76,6% | `validate_sources.py` |
| `route_id` negli alert | **96,7%** | idem |
| `trip_id` RT risolti in `trips.txt` | **100%** (251/251) | idem |
| Geocoding vincolato, toponimi reali | **150/150** entro 2 km | `test_geocoding.py` |
| Toponimi corretti: distanza dal percorso | max **800 m** | idem |
| Vie estranee alla linea | **1342 m** o più | idem (controllo) |
| Copertura alias nomi linea | **98,4%** (63/64) | test Dart |
| Estrazione LLM (nemotron-3-super:free) | 34/34, **0 toponimi inventati** | `eval_extractor.dart` |
| Quota gratuita OpenRouter | **50 richieste/giorno** in totale | misurato sul campo |
| Avvisi di **sola fermata sospesa** | **14 su 198** | conteggio sul feed |
| Rientro non nominato negli avvisi | **24 su 28** | fixture annotate |
| Ultima via nominata: distanza dal percorso | mediana **1 m**, 21/22 ≤ 100 m | misura dedicata |

## 4. Dove la specifica sbaglia

Il documento in `docs/` è il progetto originale. **Sette punti sono stati
smentiti dalle misure.** Non "adattati": smentiti.

1. **L'OTP di GTT non va messo al centro.** È un build più vecchio: i suoi
   `trip_id` non esistono nel feed odierno, mancano 7 linee, e solo il 78%
   dei pattern ha una shape equivalente. La fonte primaria è il **GTFS
   statico**, rigenerato ogni giorno alle 04:00 e CC-BY.
2. **Il ponte `trip_id` passa dal GTFS statico**, non dall'OTP: 100% contro 0%.
3. **`alerts.aspx` non dichiara le fermate impattate.** Gli `stop_id` sono
   *tutte* le fermate della linea (verificato sulla 82: 31 dichiarate = 31
   totali). I codici veri stanno nel **testo**.
4. **Buffer del geocoding: 1 km, non 2.** A 2 km entra spazzatura, a 500 m
   si scartano vie legittime (una deviazione si allontana per definizione).
5. **Soglia fuori-rotta: 50 m, non 80.** Il GPS è molto più pulito del
   previsto.
6. **"Max 20% di sovrapposizione col percorso normale" non regge.** Gli
   avvisi dicono spesso "prosegue per la stessa via": le tre deviazioni
   reali provate condividevano 36%, 38% e 66% ed erano tutte corrette.
   Sostituita con: deve esistere un tratto **continuo** fuori percorso di
   almeno 150 m.
7. **"Non più lungo di 3× la linea d'aria" non regge sugli anelli.** La 2C
   fa 4,3 km per 0,8 km in linea d'aria. Si confronta col **tratto di
   percorso che sostituisce**.

## 5. Trappole già pagate

Ognuna di queste è costata tempo. Sono tutte silenziose: non danno errore.

- **Valhalla usa polilinee a precisione 6**, non 5. Con 5 il primo punto
  finisce a latitudine 450 e la mappa resta vuota senza eccezioni.
- **Photon risponde 400 a `lang=it`** (accetta solo default/de/en/fr). Se
  non controlli lo status sembra "nessun risultato": mi ha fatto misurare
  uno 0% di copertura inesistente.
- **`\b` dopo un punto letterale non trova mai un confine di parola.**
  `\bstr\.\b` non sostituiva niente: dopo il punto viene uno spazio, e
  nessuno dei due è alfanumerico.
- **I file GTFS di GTT hanno il BOM e usano le virgolette.** Uno split su
  virgola sfasa tutte le colonne in silenzio.
- **Il confronto per sottostringhe è pericoloso**: "lavori **strada**li"
  faceva scattare il capolinea "**STRADA** del Drosso" e mandava l'avviso
  sulla direzione sbagliata. Parole intere, e scarta i qualificatori
  generici.
- **La Fréchet discreta misura anche il campionamento.** Densifica prima di
  confrontare, o misuri i vertici invece della forma.
- **Il `Marker` di flutter_map usa le sue dimensioni come area toccabile.**
  Con 11 px non si prende mai su un telefono.
- **Il feed delle posizioni si spegne di notte, il servizio no.** Dopo le
  23:30 `vehicle_position` torna 15 byte vuoti mentre la linea 15 ha corse
  fino alle 01:52. "Feed spento" ≠ "nessun mezzo".
- **`direction: 0` fisso** faceva calcolare le fermate saltate sempre
  sull'andata, anche per gli avvisi che riguardano il ritorno. GTT scrive
  avvisi *per direzione*.
- **Non tutto deve passare dalla geometria.** Il caso più *certo* di tutti
  — "Fermata 3445 Sabotino sospesa", il numero scritto da GTT — si perdeva
  perché il flusso passava dal ricostruire un percorso che lì non esiste.
  Un codice fermata lo prende una regex: niente LLM, niente geocoding,
  niente routing. Vale anche a LLM spento, ed è proprio quando serve.
- **Il rientro va cercato A VALLE dello stacco.** Una linea puo' passare
  due volte vicino alla stessa via: senza il vincolo si sceglie il
  passaggio già fatto. Con la direzione sbagliata la deduzione finisce a
  2 km — verificato, e la guardia l'ha rifiutata invece di piazzarla lì.

## 6. Le regole di condotta del sistema

Non sono stile: sono il motivo per cui questa cosa può essere usata.

> **Meglio nessuna mappa che una mappa sbagliata.** Un falso positivo fa
> camminare l'utente 800 metri per niente e non si fida mai più (§11.4).

In pratica:

- Se un toponimo non si risolve o una validazione fallisce, si **dichiara
  l'incertezza**. Mai una geometria inventata.
- Il **testo originale di GTT** si mostra sempre, in fondo a tutto: se il
  sistema sbaglia, il dato grezzo resta.
- I nomi di linea non risolti si **segnalano**, non si indovinano.
- I messaggi d'errore distinguono ciò su cui l'utente **può agire** (quota,
  chiave, rete) da ciò su cui non può.
- **"Non lo so" è una risposta valida** e va detta come tale: "nessun mezzo
  osservato" non è "va tutto bene".
- Gli orari si dicono in **ora locale**: "mezzanotte UTC" all'una di notte
  sembra una bugia.

## 7. Cosa NON fa (ancora)

`app/lib/core/config.dart` contiene più costanti di quante ne siano usate.
Per non fraintendere:

- **niente notifiche.** iOS non regge il polling in background (lezione già
  pagata su un altro progetto). Servirebbe un cron esterno — GitHub Actions
  è gratis e basta.
- **distanze a piedi in linea d'aria**, non reali. L'interfaccia lo dichiara.
- **dentro una direzione usa solo la variante principale.** Una deviazione
  che riguardasse la sola corsa limitata verrebbe calcolata sul percorso
  intero — lo stesso errore corretto un livello più in alto.
- **il Segnale A è ancora senza risposta**: servono più giorni di diff. Un
  LaunchAgent gira alle 05:00 (`com.tommaso.gtt-deviazioni.snapshot`), e
  una routine cloud esiste ma non ha mai girato con successo.

## 8. Come si lavora

```bash
cd app && flutter test          # 168 test, devono passare tutti
cd app && flutter analyze       # deve essere pulito
```

Verifiche dal vivo, che usano servizi veri:

```bash
cd app && dart run tool/check_pipeline_live.dart      # catena completa
cd app && dart run tool/check_geocoding_live.dart     # solo geocoding
OPENROUTER_API_KEY=... dart run tool/eval_extractor.dart --provider openrouter
```

Il GTFS per i test sta in `data/gtfs/` e si estrae da `data/gtt_gtfs-*.zip`.
I test che ne hanno bisogno si **saltano da soli** se non c'è.

### Come si verifica sul serio

Le prove più utili di questa sessione sono venute dal **far girare l'app sul
simulatore iOS** e guardare cosa succede, non dai test. Il bersaglio delle
fermate troppo piccolo, il feed spento di notte, la chiave rovinata, la home
bianca all'avvio: nessuno di questi sarebbe emerso da un test scritto a
tavolino.

Quando qualcosa sembra rotto, **guarda i log prima di toccare il codice**:
una volta ho creduto che l'osservazione fosse bloccata, e invece stavo
facendo gli screenshot troppo presto.

## 9. Note pratiche

- I dati GTT sono **CC-BY**: citare la fonte (già nel piè di pagina).
- Photon e Valhalla sono **servizi di cortesia**: pause fra le chiamate,
  User-Agent identificabile, e sempre un ripiego se cadono.
- La chiave OpenRouter sta **sul dispositivo**. Per un'app personale va
  bene; mettere un tetto di spesa e non pubblicarla mai così com'è.
- Le 34 fixture annotate in `tests/fixtures/annotations.json` **le ho
  scritte io, non un umano**: vanno riviste prima di usarle come verità.

---

*Ultimo aggiornamento: 1 agosto 2026. 168 test, 26 commit.*
