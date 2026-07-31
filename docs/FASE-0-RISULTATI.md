# Fase 0 — Risultati della validazione delle fonti

**Eseguita:** 31 luglio 2026, ore 15:00–15:20
**Comandi:** `scripts/validate_sources.py` + verifiche aggiuntive + `scripts/snapshot_gtfs.py`
**Report grezzi:** `validation/report-20260731-150523.json`, `validation/snapshots/`, `validation/gtfs_snapshots/`

Questo documento risponde alle domande della checklist di §8 (Fase 0) della specifica.
Tre risposte **contraddicono la specifica** e cambiano l'ordine di implementazione.

---

## Sintesi in cinque righe

1. Tutte le fonti sono vive: 7 endpoint su 7 rispondono 200.
2. **L'OTP non è la fonte da mettere al centro: è un build GTFS diverso e più vecchio.** Il GTFS statico sì — è rigenerato ogni giorno e allineato al realtime.
3. **Il ponte `trip_id` esiste ed è perfetto (100%), ma verso il GTFS statico, non verso l'OTP.**
4. `alerts.aspx` è molto meglio del previsto per attribuire un avviso a una linea, ma **non** dichiara le fermate impattate: quella speranza va abbandonata.
5. Il Segnale A resta **non verificato**: serve il confronto su più giorni. Il baseline è stato creato oggi, sulla fonte giusta.

---

## 1. Raggiungibilità — tutto vivo

| Endpoint | Esito | Latenza | Dimensione |
|---|---|---|---|
| OTP `/index/routes` | 200 `application/json` | 89 ms | 34 KB |
| GTFS-RT `vehicle_position` | 200 `octet-stream` | 818 ms | 27 KB |
| GTFS-RT `trip_update` | 200 `octet-stream` | 1114 ms | 61 KB |
| GTFS-RT `alerts` | 200 `octet-stream` | 187 ms | 210 KB |
| Web `/cms/variazioni` | 200 `text/html` | 480 ms | 226 KB |
| Web `/cms/percorari/urbano` | 200 `text/html` | 624 ms | 170 KB |
| GTFS statico (zip) | 200 `application/zip` | 121 ms | 24,7 MB |

Confermato §0.2: il feed realtime **non è offline**.

---

## 2. 🔴 L'OTP è un build diverso e più vecchio del GTFS statico

Questa è la scoperta che cambia l'architettura. La specifica (§1.1) mette l'OTP al centro
definendolo "di gran lunga la fonte migliore disponibile". Le misure dicono altro.

**Prova 1 — il livello corse/calendario non coincide.**
L'endpoint `/index/trips/{id}` funziona (200 su un id preso dall'OTP stesso), ma restituisce
**404 su 6 `trip_id` del feed realtime su 6**. Il `service_id` di una corsa OTP (`699421U`)
**non esiste** in `calendar.txt` di oggi.

**Prova 2 — l'elenco linee non coincide.**
GTFS statico: 223 linee. OTP: 217. Sette linee presenti nel GTFS mancano dall'OTP
(`E68BU`, `N04BU`, `S05BU`, `S18BU`, `S45BU`, `S45U`, `W15BU`); una presente sull'OTP
non esiste più nel GTFS (`5BU`).

**Prova 3 — le geometrie coincidono solo in parte.**
Confronto di tutti i pattern OTP delle 10 linee della watchlist contro le shape del GTFS
odierno (criterio: stessi estremi entro 50 m e stessa lunghezza entro 100 m):

> **53 pattern su 68 hanno una shape GTFS equivalente — il 78%.**
> I restanti 15 differiscono, in alcuni casi di chilometri (linea 11: 5 pattern su 8 non
> corrispondono; linea 10: 4 su 12).

Quando coincidono, coincidono **al metro** (es. `1:55U:0:01` = 13.091 m contro
`55UDi55RA4` = 13.092 m, estremi a 1 m). Non è quindi imprecisione: sono proprio
percorsi diversi, o pattern che esistono in una fonte e non nell'altra.

### Conseguenza operativa

**Il Segnale A va costruito sul GTFS statico, non sull'OTP.** Motivi:

- è **rigenerato ogni giorno** (`feed_version` = 20260731, file datati 04:00 di stamattina);
- è **provatamente allineato al realtime** (§3 qui sotto);
- è **CC-BY esplicito**, mentre l'OTP resta zona grigia (§Appendice B della specifica);
- contiene `shapes.txt` + `stop_times.txt`, cioè esattamente geometria e sequenza fermate.

L'OTP resta utile come comodità (polilinee già encoded, raggruppamento in pattern, REST
piacevole) ma **non può essere la verità di riferimento** e non va usato per il diff.

---

## 3. ✅ Il ponte `trip_id` esiste — verso il GTFS statico

La specifica (§1.1, §5.3.1) sperava in `vehicle_position → trip_id → pattern → geometria`.
Il ponte c'è, ma passa dal GTFS statico:

> **251 `trip_id` del feed realtime su 251 sono presenti in `trips.txt`. Il 100%.**

E `trips.txt` dà direttamente tutto il necessario:

```
trip_id 28370667U -> route_id 19U, direction_id 0, shape_id 19UDi19RD2,
                     trip_headsign CADORE, service_id 703433U
```

Da `shape_id` si va in `shapes.txt` e si ha la geometria teorica. **Nessuna inferenza.**

**Ma §5.3.1 serve comunque**, perché il `trip_id` è popolato solo sul **76,6%** dei veicoli
(256 su 336). Gli 80 senza `trip_id` si concentrano su alcune linee: `15U` (9), `62U` (8),
`13U` (6), `11U` (6), `ST1U` (4), `ST2U` (4), `52U` (4), `5U` (4). Per quel quarto di flotta
l'inferenza per prossimità resta necessaria.

---

## 4. `vehicle_position` — cosa c'è e cosa manca

338 entità nel feed, 95 linee distinte. Timestamp freschi: **mediana 21 s**, max 285 s.
Il polling a 30 s previsto in §5.3 è quindi corretto.

| Campo | Copertura | Nota |
|---|---|---|
| `route_id` | **100%** | filtro per linea gratuito |
| `vehicle_id` | **100%** | necessario per il clustering di §5.3.2 |
| `position` | **100%** | |
| `bearing` | **100%** | utile per disambiguare la direzione |
| `timestamp` | **100%** | |
| `trip_id` | **76,6%** | vedi sopra |
| `direction_id` | **0%** | ⚠️ va dedotta da `trip_id` o dal bearing |
| `speed` | **0%** | irrilevante |
| `stop_id` | **0%** | ⚠️ niente scorciatoie sulla fermata corrente |
| `current_stop_sequence` | **0%** | ⚠️ idem |

`stop_id` e `current_stop_sequence` a zero significa che **non si può sapere a che punto
del percorso sia un mezzo** se non per via geometrica. Il map matching di §5.3 non è
opzionale: è l'unica strada.

---

## 5. `alerts.aspx` — ottimo per la linea, inutile per le fermate

181 alert attivi. Copertura di `informed_entity`:

| Campo | Copertura |
|---|---|
| `informed_entity` non vuoto | **100%** (181/181) |
| `route_id` | **96,7%** (175/181) |
| `stop_id` | **89,5%** (162/181) |
| `trip_id` | 0% |

**La buona notizia.** Il `route_id` al 96,7% risolve gratis il problema di §4.1
(l'attribuzione avviso → linea) *per gli alert*, che la specifica indica come "la causa più
frequente di bug silenziosi". Per questa fonte la tabella di alias non serve: l'id è già
canonico. 139 alert su 180 parlano esplicitamente di deviazione/limitazione/sospensione.

**La cattiva notizia — verificata, non supposta.** Gli `stop_id` **non sono le fermate
impattate**: sono tutte le fermate della linea. Controprova sulla linea 82 (alert
"Linea 82 deviata in direzione corso Trieste"):

> l'alert dichiara **31** `stop_id` — e la linea 82 ha esattamente **31** fermate distinte
> in tutto il GTFS.

Quindi la speranza di §1.3 ("ottieni gratis il collegamento avviso → linea → fermate
impattate") **è per metà infondata**: il collegamento alla linea sì, alle fermate no.
Le fermate saltate vanno derivate dalla geometria, come da §6.1. Nessuna scorciatoia.

**Precisazione emersa annotando le fixture (§8 qui sotto).** Le fermate sospese *sono*
dichiarate, ma **nel testo di alert dedicati**, non nel campo strutturato. Nel corpus ci
sono 14 avvisi del tipo `Fermata 3447 "Sabotino" sospesa`, con il codice esplicito.
Vale quindi la regola di §6.1 ("quel dato VINCE sulla geometria"), ma il codice va estratto
con una regex sul testo — attenzione alle varianti `n.`, `n°`, `Fermata 3447`, `Fermata n. 15080`.

Nota: il campo `description_text` degli alert contiene **lo stesso testo** della tabella
`/cms/variazioni`, in forma già strutturata e senza HTML da parsare. Per il Segnale B
conviene ingerire **prima** gli alert e usare lo scraping web come complemento.

---

## 6. Scraping web — una pagina su due

**`/cms/variazioni`: parsing stabile.** Una sola tabella, 53 righe, **51 righe utili**
con ≥5 colonne. Le colonne sono quelle attese (`Linea | Inizio | Fine presunta | Direzione |
Descrizione variazione | Motivo`). 52 variazioni attive al 31/07.

**`/cms/percorari/urbano`: struttura diversa.** 2 tabelle, 143 righe, ma **zero righe**
con ≥5 colonne: l'euristica dello script non si applica. Va scritto un parser dedicato,
non riusato quello di `/cms/variazioni`.

Le 51 righe estratte sono materiale pronto per le fixture richieste da §12.7
(≥30 avvisi reali annotati a mano).

---

## 7. ⏳ Segnale A — ancora senza risposta, ma ora misurabile

**Questa domanda resta aperta**, ed è quella da cui dipende metà dell'architettura.
Non è rispondibile in un giorno: serve un baseline e almeno 3 giorni di confronto.

Quello che è stato fatto oggi:

- creato lo strumento giusto — `scripts/snapshot_gtfs.py`, che diffa il **GTFS statico**
  anziché l'OTP (che, per §2, avrebbe misurato un dato fermo);
- **baseline acquisito**: 1.486 shape, 76.949 corse, 223 linee, 718 KB
  (`validation/gtfs_snapshots/gtfs-20260731-150910.json`);
- logica di diff **verificata con un self-test** sui quattro casi che deve riconoscere
  (shape nuova, shape rimossa, geometria cambiata, fermate cambiate): 4 su 4.

**Indizio incoraggiante, non ancora prova.** Nel GTFS convivono due famiglie di `shape_id`:
quelle stabili e mnemoniche (`55UDi55RA4`, `19UAs19AD1`) e quelle a suffisso numerico
(`55UDi37713` → "LIMITATO, PIAZZA SANTA RITA", `4UAs67693` → "PORTA PALAZZO SUD",
`55UAs48673`). Le seconde sembrano generate per le varianti temporanee. Se l'ipotesi
regge, le deviazioni compaiono nel GTFS come **shape nuove**, che sono il caso più
facile da rilevare. Da confermare col diff dei prossimi giorni.

---

## 8. Checklist di §8 — stato

| Domanda | Risposta |
|---|---|
| `vehicle_position` popola `trip_id` e `route_id`? | `route_id` 100%, `trip_id` 76,6% |
| Quanti veicoli, quali linee, ogni quanti secondi? | 338 veicoli, 95 linee, mediana 21 s |
| `alerts.aspx` ha `informed_entity` con `route_id` usabile? | **Sì, 96,7%.** Ma gli `stop_id` non sono le fermate impattate |
| **Le geometrie cambiano quando c'è una deviazione?** | ⏳ **Baseline creato oggi. Risposta tra 3 giorni.** |
| L'HTML di `/cms/variazioni` si parsa stabilmente? | Sì, 51 righe su 53. `/cms/percorari` no: serve un parser a parte |

---

## 9. Modifiche da fare alla specifica

| § | Dice | Va corretto in |
|---|---|---|
| §1.1 | L'OTP è "la fonte migliore, da mettere al centro" | L'OTP è un build più vecchio e disallineato (78% di geometrie coincidenti, corse e calendario no). **Al centro va il GTFS statico**, rigenerato ogni giorno |
| §1.1 nota 2 | `trip_id → pattern_id` via stoptimes OTP | Il ponte è `trip_id → trips.txt → shape_id → shapes.txt`. Il 100% risolve. Via OTP, lo 0% |
| §1.2 | GTFS statico = "fallback e verità offline", aggiornamento "irregolare" | È la **fonte primaria**. Rigenerato quotidianamente alle 04:00 |
| §1.3 | Se `alerts` popola `informed_entity`, "ottieni gratis avviso → linea → fermate impattate" | Linea sì (96,7%). **Fermate impattate no**: gli `stop_id` sono tutte le fermate della linea |
| §5.1 | Il diff dei pattern interroga l'OTP | Il diff legge il GTFS statico (`scripts/snapshot_gtfs.py`) |
| §5.3.1 | Da saltare se `trip_id` è popolato | Serve comunque, per il 23,4% di veicoli senza `trip_id` |
| §5.3 | `current_stop_sequence` / `stop_id` fra le incognite | Confermati **a zero**. Il map matching è obbligatorio |

---

## 9-bis. Fixture per la Fase 2 — e cosa hanno rivelato

Raccolte in parallelo, perché servono comunque qualunque sia l'esito del Segnale A.

- **Corpus**: `tests/fixtures/notices.json` — **198 avvisi reali** (50 dal web, 180 alert,
  32 riconosciuti come lo stesso avviso in entrambe le fonti). Le due fonti sono
  **complementari**: solo ~1 riga su 12 ha un alert molto simile, quindi vanno unite.
  Rigenerabile con `scripts/build_fixtures.py`.
- **Annotazioni**: `tests/fixtures/annotations.json` — **34 avvisi, 41 oggetti `deviation`**,
  campione stratificato su tutte e cinque le categorie (`deviazione` 23, `limitazione` 8,
  `sostituzione_modale` 4, `sospensione_fermate` 4, `inversione` 2). Supera il minimo di 30
  richiesto da §12.7. File separato dal corpus, così rigenerare il corpus non le distrugge.
- **Verifica**: `scripts/check_annotations.py` controlla schema e, soprattutto, che
  **ogni toponimo annotato compaia davvero nel testo originale**. Passa: nessuna via inventata.

> ⚠️ **Le annotazioni le ho prodotte io, non un umano.** Usarle per valutare un parser LLM
> misura meno di quanto sembri: gli errori sistematici condivisi restano invisibili.
> Vanno riviste a mano — a partire da `web-009`, l'unica con `confidence: bassa`.

### Tre limiti dello schema di §5.2.1, emersi annotando

1. **Un avviso può avere due tipi insieme.** `web-008` (linea 3) è *sostituzione modale*
   **e** *limitazione*; `web-031` (linea 42) è *deviazione* **e** *limitazione*.
   Lo schema ha un solo `deviation_type` per oggetto: servono più oggetti sullo stesso testo,
   e il narratore di §6.3 deve saperli comporre.
2. **Le navette sostitutive non sono deviazioni.** `web-009` (linea 4) descrive un servizio
   bus *nuovo*, con un percorso proprio di oltre venti vie e andata/ritorno nello stesso
   campo. Non è modellabile come variante della linea: è un'altra linea.
3. **Le fermate provvisorie non hanno un campo.** `alert-032` istituisce una fermata
   sostitutiva in "carreggiata laterale Nord di corso Vittorio Emanuele II": informazione
   direttamente utile all'utente, che oggi si perderebbe.

Aggiungerei anche: `ponte` manca dalla lista di qualificatori da normalizzare in §5.2.2
(`ponte Rossini`, `ponte Emanuele I` in `web-011`), e "carreggiata laterale Est/Nord"
(`web-040`, `alert-032`) non è un toponimo geocodificabile per nome — in OSM è una way
distinta con lo stesso `name`, quindi va scelta per prossimità al percorso.

**Il caso da non perdere è `alert-085`**: `informed_entity` vuoto (quindi la linea va dedotta,
e la tabella alias di §4.1 torna necessaria) e il testo cita "via Rossini angolo lungo Dora
Siena" come **causa dei lavori, non come percorso**. Un parser distratto le estrae come
`via_sequence` e inventa una deviazione inesistente: esattamente il falso positivo che §11.4
indica come il fallimento più grave.

---

## 10. Cosa fare adesso

1. **Rieseguire il diff ogni giorno per almeno 3 giorni.** È l'unico modo di chiudere la
   domanda sul Segnale A, e nessuna riga di sistema andrebbe scritta prima (§8, §12.1).

   ```bash
   cd ~/Projects/gtt-deviazioni && .venv/bin/python scripts/snapshot_gtfs.py --out ./validation --compare
   ```

   Il job è già installato: LaunchAgent `com.tommaso.gtt-deviazioni.snapshot`, ogni giorno
   alle 05:00 (il GTFS viene rigenerato alle 04:00). Log in `validation/logs/`.
   Testato end-to-end il 31/07 con `launchctl kickstart`: `exit 0`, e su input identico
   rileva zero cambiamenti — gli hash sono deterministici, niente falsi positivi.

2. ~~Raccogliere le fixture~~ — **fatto** (§9-bis). Restano da **rivedere a mano** le 34
   annotazioni, partendo da `web-009`.

3. Quando il Segnale A avrà una risposta, rivedere le priorità della roadmap di §8 —
   la Fase 1 va riscritta sul GTFS statico anziché sul client OTP.
