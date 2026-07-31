# Rilevatore Deviazioni GTT — Specifica tecnica per l'implementazione

**Versione:** 1.0 — 31 luglio 2026
**Destinatario:** chi implementerà il sistema (tu + agente di coding tipo Claude Code)
**Obiettivo del documento:** dare tutte le indicazioni necessarie a costruire il sistema. Non contiene il sistema, contiene il progetto del sistema.

---

## 0. Il problema, riformulato con precisione

Il problema *non* è "GTT non comunica le deviazioni". GTT le comunica, e anche parecchio. Il problema è che **comunica in un formato che non risponde alle tre domande che l'utente si sta effettivamente ponendo alla fermata**:

| Domanda reale dell'utente | Cosa GTT fornisce oggi |
|---|---|
| **Dove passa adesso il mezzo?** | Una stringa di nomi di vie, che devi ricostruire mentalmente su una mappa che non hai |
| **La mia fermata è ancora servita?** | Quasi mai detto esplicitamente. Va dedotto dal fatto che la via non è più nel percorso |
| **Se non è servita, dove vado?** | Praticamente mai |

Da qui discende il requisito centrale del sistema:

> **Il sistema deve trasformare un avviso testuale in una geometria georiferita, e da quella geometria derivare l'impatto sulle fermate.**

Tutto il resto è contorno. Un sistema che riesce a fare solo questo, e lo fa bene su 30 linee, ha già risolto il problema meglio di qualunque cosa esista oggi a Torino, Google Maps incluso.

### 0.1 Perché il tentativo precedente non ha funzionato

Hai provato due strade e nessuna delle due ha retto:

1. **Monitorare le posizioni GPS e dedurre la deviazione.** Fragile per ragioni strutturali (vedi §5.3): il GPS urbano di Torino ha errori di 10-40 m tra i palazzi, la frequenza di aggiornamento è bassa, e soprattutto **serve un mezzo che stia effettivamente percorrendo la deviazione in quel momento** — di notte, o su una linea a bassa frequenza, non hai segnale. In più il feed ti sembrava offline.
2. **Far leggere le notifiche a un LLM e fargli generare il percorso.** Fallisce perché un LLM da solo non sa dove sta via Cigna. Genera testo plausibile, non geometria corretta. **Manca lo stadio di geocoding + routing.**

Entrambi gli approcci fallivano perché puntavano su **un solo segnale**. La soluzione proposta qui usa **tre segnali indipendenti** e li fonde. È la differenza tra un sistema che funziona il 60% delle volte e uno che funziona il 95%.

### 0.2 Nota importante sul feed che sembrava offline

**Il feed non è offline.** Verificato il 31/07/2026: `https://percorsieorari.gtt.to.it/das_gtfsrt/vehicle_position.aspx` risponde 200 con `Content-Type: application/octet-stream` (payload Protocol Buffer). Se lo aprivi nel browser vedevi una pagina vuota o un download — è normale, è binario, non è HTML. Serve decodificarlo con `gtfs-realtime-bindings`.

Questo cambia molto: la strada del GPS è percorribile. Semplicemente non deve essere l'unica.

---

## 1. Ricognizione delle fonti — cosa esiste davvero

Tutte le fonti qui sotto sono state **verificate il 31 luglio 2026**. Lo stato indica cosa è stato realmente testato e cosa va invece riverificato in fase di implementazione (§9).

### 1.1 ⭐ OpenTripPlanner di GTT — la scoperta più importante

**`https://otpgtt.gtt.to.it/otp/routers/default/index/...`**

GTT espone pubblicamente, **senza autenticazione e senza token**, un'istanza OpenTripPlanner con l'intera REST Index API aperta. Questa è di gran lunga la fonte migliore disponibile e va messa al centro dell'architettura.

Endpoint verificati funzionanti:

| Endpoint | Restituisce | Verificato |
|---|---|---|
| `/index/routes` | Tutte le linee (urbane, extraurbane, turistiche) con `id`, `shortName`, `longName`, `mode`, `color`, `agencyName` | ✅ ~200 linee |
| `/index/routes/{routeId}` | Dettaglio linea, incluso URL della pagina GTT ufficiale | ✅ |
| `/index/routes/{routeId}/patterns` | **Tutti i pattern (varianti di percorso) della linea**, con descrizione in chiaro | ✅ |
| `/index/patterns/{patternId}/geometry` | **Polilinea encoded (Google polyline, precisione 5) del percorso** | ✅ |
| `/index/patterns/{patternId}/stops` | **Elenco ordinato delle fermate** con `code`, `name`, `lat`, `lon` | ✅ |
| `/index/stops/{stopId}/stoptimes` | Passaggi alla fermata, **con `tripId` e `pattern` associato** | ✅ (vedi nota sotto) |

**Nota su `stoptimes` — due informazioni importanti emerse dal test:**

1. **L'OTP di GTT gira senza updater realtime.** Tutte le corse tornano `"realtime": false, "realtimeState": "SCHEDULED"`. Quindi **non usare l'OTP per i tempi reali** — per quelli servono i feed GTFS-RT di §1.3. L'OTP serve per la *geometria*, ed è insuperabile in quello.

2. **`stoptimes` espone il `tripId` insieme al `pattern`.** Questo è il ponte che mancava per il Segnale C:

   ```
   vehicle_position (GTFS-RT) → trip_id → [ponte] → pattern_id → geometry
   ```

   Se `vehicle_position` popola `trip_id` nello stesso formato (`1:28259838U`), **non devi inferire nulla**: dal veicolo arrivi direttamente alla geometria teorica corretta, e tutto §5.3.1 diventa superfluo. Costruisci la mappa `trip_id → pattern_id` una volta al giorno (da `stop_times.txt` del GTFS o iterando gli stoptimes) e tienila in cache. **È la prima cosa che lo script di validazione deve confermare.**

Esempio reale (linea 55):

```
GET /otp/routers/default/index/routes/1:55U/patterns
[
  {"id":"1:55U:0:02","desc":"55 LIMITATO, PIAZZA SANTA RITA","routeId":"1:55U"},
  {"id":"1:55U:0:01","desc":"55 GERBIDO, VIA MONCALIERI","routeId":"1:55U"},
  {"id":"1:55U:1:01","desc":"55 VANCHIGLIA, CORSO FARINI","routeId":"1:55U"},
  {"id":"1:55U:1:02","desc":"55 FARINI","routeId":"1:55U"}
]

GET /otp/routers/default/index/patterns/1:55U:0:01/geometry
{"points":"y|arGkq_n@gA`ALr@|@pA^h@|@|@tGbJnJxM~HzKnAfBNz@...","length":111}

GET /otp/routers/default/index/patterns/1:55U:0:01/stops
[{"id":"1:607","code":"1540","name":"Fermata 1540 - FARINI CAP","lat":45.07103,"lon":7.70347}, ...]
```

**Convenzioni degli ID** (dedotte, da confermare):
- `1:` = prefisso feed
- `55U` = linea 55, bacino Urbano (`E` = Extraurbano)
- `:0:` / `:1:` = direzione (0 = andata, 1 = ritorno)
- `:01`, `:02` = variante di percorso all'interno della direzione

**Perché è decisivo:** ti dà la geometria ufficiale del percorso in modo strutturato e aggiornabile. Non devi scaricare e parsare il GTFS zip, non devi fare shape matching a mano. E soprattutto abilita il **Segnale A** (§5.1), che è l'idea centrale di questo progetto.

**Attenzione — rischio da verificare subito:** questa API è un'API interna non documentata. Potrebbe cambiare o essere chiusa. Il sistema deve avere un fallback sul GTFS statico (§1.2) e deve **cachare aggressivamente in locale** ogni risposta.

### 1.2 GTFS statico

**`https://www.gtt.to.it/open_data/gtt_gtfs.zip`**
Licenza CC-BY. Catalogato su [aperTO](http://aperto.comune.torino.it/dataset/feed-gtfs-trasporti-gtt).

Contiene `routes.txt`, `trips.txt`, `stops.txt`, `stop_times.txt`, `shapes.txt`, `calendar.txt`. È la stessa base che alimenta l'OTP di §1.1.

**Uso previsto:** fallback e verità di riferimento offline. Scaricalo comunque: ti serve `shapes.txt` per il baseline storico e `stop_times.txt` per gli orari teorici.

⚠️ La frequenza di aggiornamento dichiarata è "irregolare". Vanno misurati i cambiamenti reali (§9).

### 1.3 GTFS-Realtime

Tre endpoint, licenza CC-BY, formato Protocol Buffer:

| Endpoint | Contenuto |
|---|---|
| `https://percorsieorari.gtt.to.it/das_gtfsrt/vehicle_position.aspx` | Posizione dei mezzi ✅ risponde |
| `https://percorsieorari.gtt.to.it/das_gtfsrt/trip_update.aspx` | Ritardi e passaggi previsti |
| `https://percorsieorari.gtt.to.it/das_gtfsrt/alerts.aspx` | Avvisi di servizio strutturati |

**`alerts.aspx` è potenzialmente molto prezioso e va esaminato per primo.** Un `ServiceAlert` GTFS-RT ha un campo `informed_entity` che può contenere `route_id`, `stop_id`, `trip_id`. Se GTT lo popola correttamente, ottieni gratis il collegamento **avviso → linea → fermate impattate**, che è metà del problema. Se lo popola male (solo testo, `informed_entity` vuoto o generico), vale poco. **Non lo so ancora: va verificato con lo script di §9.**

**Incognite critiche su `vehicle_position` da verificare:**
- `trip.trip_id` è popolato e corrisponde ai `trip_id` del GTFS statico? (Senza questo, non sai *quale corsa* stai guardando e il map matching diventa molto più difficile)
- `trip.route_id` è popolato?
- `current_stop_sequence` / `stop_id` sono popolati?
- Frequenza reale di aggiornamento (attesa: 15-60 s)
- Copertura: tutte le linee o solo alcune? Bus e tram entrambi?

### 1.4 Pagina "Variazioni temporanee di percorso" — la miniera testuale

**`https://gtt.to.it/cms/variazioni`** (programmate) e **`https://gtt.to.it/cms/percorari/urbano`** (attive ora)

Questa è la fonte più sottovalutata. È una **tabella HTML strutturata** con colonne:

`Linea | Inizio | Fine presunta | Direzione | Descrizione variazione | Motivo variazione`

Al 31/07/2026 conteneva 48 variazioni attive. E soprattutto: **le descrizioni seguono una grammatica sorprendentemente regolare.** Esempi reali:

> **56** — `Da via Pininfarina deviata in via Ferrero, via Di Vittorio, percorso normale.`

> **63** — `Da strada Del Drosso deviata in via Faccioli, via Plava, corso Unione Sovietica, strada Castello di Mirafiori, percorso attuale.`

> **7** — `Dal capolinea di piazza Castello prosegue per via Pietro Micca, via San Tommaso, via dell'Arsenale, corso Vittorio Emanuele II, percorso normale.`

> **19** — `Direzione corso Bolzano: dalla rotatoria di lungo Dora Colletta / via Carcano / via Poliziano deviata in via Poliziano e, dopo via Ravina segue il percorso normale.`

Il pattern ricorrente è:

```
[Direzione X:] Da <PUNTO_STACCO> deviata in <VIA_1>, <VIA_2>, ..., <VIA_N>, percorso normale.
```

**Questa è parsabile.** Non con una regex da sola (le varianti sono troppe: "prosegue per", "si instrada", "effettua inversione di marcia", "limitata in", "capolinea provvisorio", "angolo", "rotatoria di"), ma **con un LLM che estrae in JSON strutturato**, seguito da geocoding e routing. Vedi §5.2.

Nota anche il vocabolario tecnico ricorrente, che va gestito come categoria semantica e non come testo libero:

- `deviata in` → deviazione classica
- `limitata in` / `capolinea provvisorio` → **troncamento della linea** (caso diverso! metà linea non esiste più)
- `effettua inversione di marcia` → cambio di verso
- `gestione per autobus` / `bus autosnodati` → **sostituzione modale**, percorso invariato ma mezzo diverso
- `le fermate n. X e Y sono temporaneamente sospese` → **impatto fermate dichiarato esplicitamente** (raro ma prezioso: quando c'è, prendilo così com'è)
- `Nel Comune di X` → la deviazione è fuori Torino, attenzione al geocoding ambiguo

### 1.5 Canale Telegram `@gttavvisi`

**`https://t.me/gttavvisi`**, leggibile via web preview su `https://t.me/s/gttavvisi`.

Contiene gli avvisi urgenti e non programmati (incidenti, manifestazioni, guasti) che **non finiscono nella tabella di §1.4**. È la fonte per il "qui e ora imprevisto".

Opzioni di ingestione, in ordine di preferenza:
1. **Telethon / Pyrogram** come client utente iscritto al canale — realtime, pulito, affidabile
2. Scraping di `https://t.me/s/gttavvisi` — nessuna autenticazione, ma polling e HTML fragile
3. Bot API — non funziona per leggere canali pubblici altrui

### 1.6 Fonti sconsigliate

| Fonte | Perché evitarla |
|---|---|
| `5t.torino.it/proxyws` (API nascosta, [gtt-api-keygen](https://github.com/Gabboxl/gtt-api-keygen)) | Richiede reverse engineering di un token proprietario. Zona grigia legale, si rompe a ogni aggiornamento app. Non serve: OTP dà di più, legalmente. |
| [GTT Pirate API](https://gpa.madbob.org/) | Utile come riferimento storico, ma l'autore stesso la definisce "probabilmente illegale" e non monitorata. Dà solo passaggi in fermata. |
| Scraping di Moovit / Google Maps | Vietato dai ToS, e comunque non hanno il dato che ti serve — è proprio il motivo per cui stai costruendo questo. |

---

## 2. L'idea centrale: tre segnali, non uno

Questa è la parte concettualmente più importante del documento. Se implementi solo questa sezione correttamente, il resto viene da sé.

Il sistema rileva le deviazioni attraverso **tre segnali indipendenti**, ciascuno con costo, latenza e affidabilità diversi.

### Segnale A — Diff della geometria ufficiale (`PATTERN_DIFF`)

**Ipotesi:** quando GTT programma una deviazione, prima o poi la codifica nel proprio GTFS. Se la codifica, l'OTP di §1.1 la espone. Quindi: **fai uno snapshot giornaliero delle geometrie dei pattern e confrontale con il baseline.** Se una geometria cambia, hai la deviazione con precisione metrica, senza inferenza, senza GPS, senza LLM.

- **Affidabilità:** massima (è il dato ufficiale)
- **Costo:** quasi zero (poche centinaia di richieste HTTP al giorno)
- **Latenza:** ore o giorni — solo per deviazioni programmate
- **Copre:** cantieri, lavori, modifiche di lungo periodo — cioè la maggior parte delle deviazioni per durata cumulata
- **Non copre:** l'imprevisto di stamattina

> ⚠️ **Questa è un'ipotesi da verificare per prima cosa.** È possibile che GTT non aggiorni il GTFS per le deviazioni brevi, o che lo aggiorni con settimane di ritardo. Lo script di §9 misura esattamente questo. Se l'ipotesi regge, hai vinto. Se non regge, il Segnale A vale poco e il peso si sposta su B e C — il sistema resta valido, ma cambia la priorità implementativa. **Non scrivere una riga di sistema prima di aver misurato questo.**

### Segnale B — Testo dell'avviso → geometria (`TEXT_DERIVED`)

**Pipeline:** testo dell'avviso → estrazione LLM in JSON strutturato → geocoding dei toponimi su OSM → routing sulla rete stradale reale → polilinea.

- **Affidabilità:** media-alta, se e solo se implementi il geocoding **vincolato** (§5.2.2). Senza vincoli è il fallimento che hai già sperimentato.
- **Costo:** basso (poche chiamate LLM al giorno)
- **Latenza:** minuti dalla pubblicazione dell'avviso
- **Copre:** tutto ciò che GTT annuncia, programmato e non
- **Non copre:** ciò che GTT non annuncia o annuncia in modo inutilizzabile

### Segnale C — Evidenza dai mezzi (`GPS_OBSERVED`)

**Pipeline:** posizioni GTFS-RT → associazione al pattern teorico → misura della distanza dal percorso → clustering delle deviazioni ripetute → ricostruzione del percorso reale via map matching.

- **Affidabilità:** bassa sul singolo mezzo, **alta sull'aggregato** (è tutta qui la differenza)
- **Costo:** medio-alto (polling continuo, storage, calcolo geometrico)
- **Latenza:** 10-30 minuti per accumulare evidenza sufficiente
- **Copre:** **le deviazioni non annunciate** — l'unico segnale che le vede
- **Non copre:** linee a bassa frequenza, orari notturni, deviazioni appena iniziate

### La fusione

Nessun segnale è sufficiente da solo. Insieme si validano a vicenda:

| A | B | C | Interpretazione | Confidenza |
|:-:|:-:|:-:|---|---|
| ✅ | ✅ | ✅ | Deviazione confermata da tutte le fonti | **Certa** |
| ✅ | ✅ | — | Programmata, non ancora osservata (o linea a bassa frequenza) | **Alta** |
| — | ✅ | ✅ | Annunciata e in corso, GTFS non ancora aggiornato ← **caso più comune** | **Alta** |
| — | ✅ | — | Annunciata ma non osservata: futura, finita, o testo mal interpretato | **Media** |
| — | — | ✅ | **Deviazione non annunciata** ← il caso di maggior valore per l'utente | **Media** |
| ✅ | — | — | GTFS cambiato senza avviso: probabile modifica permanente di percorso | **Media** |

L'ultima riga e la penultima sono i casi in cui il tuo sistema fa qualcosa che **nessun altro strumento a Torino fa**. Vale la pena progettare per non perderli.

---

## 3. Architettura

```
┌──────────────── INGESTIONE (worker schedulati) ────────────────┐
│                                                                 │
│  OTP patterns      GTFS-RT          /cms/variazioni   Telegram  │
│  (1×/giorno)       (ogni 30s)       (ogni 15 min)     (realtime)│
│       │                │                   │              │     │
└───────┼────────────────┼───────────────────┼──────────────┼─────┘
        ▼                ▼                   ▼              ▼
   ┌─────────────────────────────────────────────────────────────┐
   │                    NORMALIZZAZIONE                          │
   │  Tutto → identificatore canonico di linea (§4.1)            │
   │  Deduplica: stesso avviso su web + Telegram = un record     │
   └─────────────────────────────────────────────────────────────┘
        ▼                ▼                   ▼
   ┌──────────┐   ┌──────────────┐   ┌──────────────────┐
   │ SEGNALE A│   │  SEGNALE B   │   │    SEGNALE C     │
   │ pattern  │   │ LLM → geocode│   │ map matching     │
   │  diff    │   │  → routing   │   │ + clustering     │
   └────┬─────┘   └──────┬───────┘   └────────┬─────────┘
        └────────────────┼─────────────────────┘
                         ▼
              ┌─────────────────────┐
              │   MOTORE DI FUSIONE │
              │  → DeviationEvent   │
              │    con confidenza   │
              └──────────┬──────────┘
                         ▼
              ┌─────────────────────┐
              │  MOTORE DI SINTESI  │
              │  testo + geometria  │
              │  + impatto fermate  │
              └──────────┬──────────┘
                         ▼
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   API REST          Mappa web       Notifiche push
   (JSON)            (Leaflet)       (Telegram/ntfy)
```

**Principio architetturale da rispettare:** ogni segnale è un modulo **indipendente e disattivabile**. Se il feed GPS cade o l'OTP chiude, il sistema degrada ma continua a funzionare. Non costruire dipendenze incrociate tra i segnali.

**Principio operativo, dato il tuo scope:** il sistema **non monitora tutta la rete in continuo**. Mantiene una *watchlist* di linee (le tue + quelle con avvisi attivi) e analizza on-demand per singola linea. Questo tiene i costi vicini a zero e il sistema eseguibile su un Raspberry Pi o un VPS da 5 €/mese.

---

## 4. Modello dati

### 4.1 Identificatore canonico di linea — risolvere prima di tutto

**Questo è il punto in cui il progetto rischia di impantanarsi.** La stessa linea si chiama in modi diversi in ogni fonte:

| Fonte | Come appare la linea 58 barrata |
|---|---|
| OTP `routes` | `id: "1:58BU"`, `shortName: "58 /"` |
| Tabella variazioni | `58/` |
| Testo Telegram | `58 barrata`, `58/`, `58 /` |
| GTFS `routes.txt` | (da verificare) |
| Colloquiale | `il 58 barrato` |

Casi altrettanto sporchi: `STAR 1` ↔ `ST1U`, `16 CS` ↔ `16CSU`, `S4 AZZURRA` ↔ `S04U`, `N10 GIALLA` ↔ `N10U`, `68+` ↔ `68BU`, `Venaria Express` ↔ `VEXU`/`3990U`.

**Costruisci una tabella di alias esplicita, generata una volta e versionata nel repo.** Non affidarti al fuzzy matching a runtime: fallisce silenziosamente e ti ritrovi avvisi assegnati alla linea sbagliata, che è peggio di nessun avviso.

```python
# line_aliases.py — generato da OTP + tabella variazioni, corretto a mano, versionato
CANONICAL = {
    "58B": {
        "otp_route_id": "1:58BU",
        "short_name": "58 /",
        "aliases": ["58/", "58 /", "58 barrata", "58barrata", "58B"],
        "display": "58 barrata",
    },
    "ST1": {
        "otp_route_id": "1:ST1U",
        "short_name": "STAR 1",
        "aliases": ["STAR 1", "STAR1", "ST1", "star 1"],
        "display": "STAR 1",
    },
    # ...
}
```

Regola di normalizzazione: `upper()` → rimuovi spazi → `/` → `B` → cerca in alias → se nessun match, **logga come non risolto invece di indovinare**.

### 4.2 Entità principali

```python
@dataclass
class RoutePattern:
    """Snapshot di un pattern in un momento dato — base del Segnale A."""
    pattern_id: str          # "1:55U:0:01"
    route_id: str            # "1:55U"
    direction: int           # 0 | 1
    description: str         # "55 GERBIDO, VIA MONCALIERI"
    geometry_encoded: str    # polyline encoded, precisione 5
    geometry_hash: str       # sha256 della polilinea → per il diff veloce
    stop_ids: list[str]      # ordinati
    stops_hash: str          # sha256 della sequenza → cattura fermate saltate
    captured_at: datetime

@dataclass
class RawNotice:
    """Avviso grezzo da qualsiasi fonte testuale."""
    source: Literal["web_variazioni", "web_percorari", "telegram", "gtfs_rt_alert"]
    source_id: str           # per deduplica
    raw_text: str
    line_hints: list[str]    # linee estratte grezze, prima della normalizzazione
    published_at: datetime
    valid_from: datetime | None
    valid_until: datetime | None
    reason: str | None       # "Lavori Italgas", "Manifestazione", ...

@dataclass
class ParsedDeviation:
    """Output dell'estrazione LLM (Segnale B) — vedi §5.2.1 per lo schema completo."""
    canonical_line: str
    direction_desc: str | None
    deviation_type: Literal["deviazione","limitazione","inversione",
                            "sostituzione_modale","sospensione_fermate","altro"]
    detach_point: str | None     # "via Pininfarina", "corso Giulio Cesare angolo via Porpora"
    via_sequence: list[str]      # ["via Ferrero", "via Di Vittorio"]
    rejoin_point: str | None
    suspended_stops: list[str]   # codici fermata se dichiarati esplicitamente
    municipality: str            # "Torino", "Grugliasco", ... → vincola il geocoding
    confidence_self: float       # quanto l'LLM si fida della propria estrazione

@dataclass
class DeviationEvent:
    """L'oggetto centrale del sistema."""
    id: str
    canonical_line: str
    direction: int | None
    signals: list[Literal["PATTERN_DIFF","TEXT_DERIVED","GPS_OBSERVED"]]
    confidence: float            # 0.0 - 1.0, vedi §6.4
    status: Literal["attiva","programmata","conclusa","sospetta"]

    official_geometry: list[tuple[float,float]] | None  # percorso normale
    deviated_geometry: list[tuple[float,float]] | None  # percorso reale/stimato
    divergence_point: tuple[float,float] | None
    rejoin_point: tuple[float,float] | None

    skipped_stops: list[Stop]
    added_stops: list[Stop]
    nearest_alternatives: dict[str, list[Stop]]  # fermata saltata → alternative

    valid_from: datetime
    valid_until: datetime | None
    reason: str | None
    human_summary: str           # §6.3
    sources: list[str]           # URL / message id, per verificabilità
```

### 4.3 Persistenza

**SQLite + SpatiaLite** è più che sufficiente per lo scope descritto. Non serve PostGIS a meno di non voler servire pubblicamente tutta la rete.

Tabelle: `pattern_snapshots` (append-only, per il diff storico), `raw_notices`, `parsed_deviations`, `deviation_events`, `vehicle_observations` (con TTL: cancella oltre 7 giorni, cresce in fretta), `line_aliases`.

**Indice critico:** `pattern_snapshots(pattern_id, captured_at DESC)` — è la query più frequente del Segnale A.

---

## 5. Le tre pipeline in dettaglio

### 5.1 Segnale A — Pattern diffing

**Frequenza:** 1×/giorno, di notte (03:00). Più spesso non serve: il GTFS non cambia ogni ora.

```
Per ogni linea nella watchlist:
  1. GET /index/routes/{route_id}/patterns
  2. Per ogni pattern:
       GET /index/patterns/{pattern_id}/geometry
       GET /index/patterns/{pattern_id}/stops
       geometry_hash = sha256(points)
       stops_hash    = sha256("|".join(stop_ids))
  3. Confronta con l'ultimo snapshot in DB:
       - pattern NUOVO           → probabile variante di deviazione creata da GTT
       - pattern SCOMPARSO       → variante ritirata (fine deviazione?)
       - geometry_hash CAMBIATO  → ⚡ percorso modificato
       - stops_hash CAMBIATO     → ⚡ fermate modificate
  4. Se cambiato, calcola il diff geometrico (§5.1.1)
  5. Emetti DeviationEvent con signal=PATTERN_DIFF
  6. Salva il nuovo snapshot (append, non update — serve lo storico)
```

#### 5.1.1 Diff geometrico — come si isola il tratto deviato

Non ti basta sapere *che* la geometria è cambiata: devi dire *da dove a dove*. Algoritmo consigliato:

1. Decodifica entrambe le polilinee (`polyline.decode(points, 5)`)
2. Riproietta in metri (EPSG:32632 — UTM 32N, corretto per Torino). **Non lavorare in gradi**: le distanze in gradi non sono metriche e i risultati saranno sbagliati.
3. Percorri la polilinea nuova dall'inizio, cercando per ogni vertice il punto più vicino sulla polilinea vecchia (`shapely.ops.nearest_points` su un `STRtree`)
4. Il **punto di divergenza** è il primo vertice in cui la distanza supera una soglia `SOGLIA_DIVERGENZA` (parti da **50 m**, poi taratura empirica)
5. Il **punto di ricongiungimento** è il primo vertice successivo in cui la distanza torna sotto soglia **e resta sotto per almeno 3 vertici consecutivi** (evita falsi ricongiungimenti agli incroci)
6. Il tratto tra i due è la deviazione. Estrai le due sotto-polilinee (vecchia e nuova) per la visualizzazione a confronto.
7. Se emergono più tratti divergenti separati, emettili come **segmenti multipli dello stesso evento**, non come eventi distinti.

⚠️ Trappola: se la deviazione è all'inizio o alla fine del percorso (capolinea provvisorio, caso frequentissimo a Torino), non esiste punto di ricongiungimento. Gestisci esplicitamente i casi `divergenza_da_inizio` e `nessun_ricongiungimento` — sono **limitazioni di linea**, non deviazioni, e vanno comunicate diversamente all'utente (§6.3).

### 5.2 Segnale B — Testo → geometria

Questa è la pipeline che ti aveva dato risultati inutilizzabili. Ecco perché, e come si aggiusta.

#### 5.2.1 Estrazione strutturata con LLM

**L'errore da non ripetere:** chiedere all'LLM di produrre il percorso. Non può: non conosce la geometria di Torino con precisione metrica e allucinerà coordinate plausibili ma sbagliate.

**Quello che l'LLM deve fare** è solo una cosa, e la fa benissimo: **trasformare prosa burocratica italiana in JSON strutturato.** Zero geografia, zero coordinate, zero inferenza spaziale.

```
Sei un estrattore di dati. Ricevi il testo di un avviso GTT (Torino) su una
variazione di percorso. Restituisci SOLO JSON valido, nessun commento.

REGOLE ASSOLUTE
- Non inventare vie non presenti nel testo.
- Non produrre coordinate.
- Trascrivi i toponimi ESATTAMENTE come scritti, compresi "corso"/"via"/"piazza"
  /"strada"/"lungo Dora"/"largo".
- Se il testo descrive più direzioni, produci un oggetto per direzione.
- Se un campo non è ricavabile dal testo, usa null. Mai un valore plausibile.

SCHEMA
{
  "deviations": [{
    "lines": ["55"],
    "direction_desc": "direzione corso Farini" | null,
    "deviation_type": "deviazione" | "limitazione" | "inversione"
                    | "sostituzione_modale" | "sospensione_fermate" | "altro",
    "municipality": "Torino",
    "detach_point": {"street": "via Pininfarina", "cross_street": null,
                     "kind": "angolo" | "rotatoria" | "capolinea" | "tratto"},
    "via_sequence": [{"street": "via Ferrero"}, {"street": "via Di Vittorio"}],
    "rejoin_point": {"street": null, "phrase": "percorso normale"},
    "suspended_stop_codes": ["9009", "9010"],
    "temporary_terminus": {"street": "...", "stop_code": "1182"} | null,
    "confidence_self": 0.0-1.0,
    "ambiguities": ["testo che non sono riuscito a interpretare"]
  }]
}

TESTO:
{{raw_text}}
```

Modello: uno piccolo e veloce basta (è estrazione, non ragionamento). Temperatura **0**. Valida sempre l'output contro lo schema JSON prima di usarlo; se non valida, riprova una volta, poi marca `parse_failed` e conserva il testo grezzo — meglio mostrare all'utente il testo originale che una geometria inventata.

#### 5.2.2 Geocoding vincolato — il passaggio che mancava

**Qui è dove il tuo tentativo precedente è morto.** "via Ferrero" geocodificato liberamente restituisce una via a caso in Italia. La correzione è vincolare la ricerca in tre modi simultanei:

1. **Vincolo spaziale:** cerca solo entro un buffer di **2 km attorno al percorso ufficiale della linea** (che hai già dall'OTP). Una deviazione non porta mai un bus a 30 km di distanza.
2. **Vincolo amministrativo:** usa il campo `municipality` estratto dall'LLM. `"Nel Comune di Grugliasco"` è un'informazione che GTT ti regala e va sfruttata.
3. **Vincolo di sorgente:** usa **OSM in locale**, non un servizio online.

**Implementazione consigliata:** scarica l'estratto OSM `nord-ovest-latest.osm.pbf` da [Geofabrik](https://download.geofabrik.de/europe/italy/nord-ovest.html), estrai tutte le `highway` con un `name` nell'area metropolitana torinese, e costruisci un **indice locale nome-via → geometria**. Ottieni:

- risoluzione istantanea, nessun rate limit, nessuna dipendenza di rete
- possibilità di fare matching fuzzy controllato (`rapidfuzz`) con soglia alta
- gestione corretta delle vie multi-segmento (una via lunga = decine di way OSM da unire)

**Normalizzazione dei toponimi — indispensabile.** Costruisci una funzione `normalize_toponym()` che gestisca:
- `c.so` / `C.so` / `corso` → `corso`
- `v.` / `via` → `via`, `p.zza` / `piazza` → `piazza`, `str.` → `strada`
- `SP. 180` / `S.P. 180` → strada provinciale 180
- accenti, apostrofi tipografici vs dritti (`d'Azeglio` vs `d'Azeglio` — ti morderà)
- numeri romani: `XX Settembre`, `XVIII Dicembre`, `1° Maggio`, `IV Marzo`
- nomi con qualificatore: `corso Vittorio Emanuele II`, `lungo Dora Colletta`, `lungo Po Cadorna`

⚠️ Se una via non si risolve, **non tirare a indovinare**: marca la deviazione come `geometry_unavailable` e mostra all'utente il testo originale con l'etichetta "percorso non ricostruito". Un'informazione mancante è recuperabile; una sbagliata gli fa perdere il bus.

#### 5.2.3 Routing sulla sequenza di vie

Hai una lista ordinata di vie geolocalizzate. Devi produrre **un percorso continuo e percorribile**, non spezzoni scollegati.

**Approccio consigliato — routing vincolato con waypoint:**

1. Per ogni via della sequenza, prendi il punto rappresentativo (centroide del segmento più vicino al percorso teorico, non il centroide della via intera)
2. Interroga un motore di routing con **tutti i punti come waypoint in ordine**, partendo dal `detach_point` e arrivando al `rejoin_point`
3. Il motore ti restituisce la polilinea reale che segue le strade

**Motore consigliato: [Valhalla](https://valhalla.github.io/valhalla/) self-hosted in Docker.** Motivi concreti:
- profilo `bus` nativo, che rispetta sensi unici e divieti per mezzi pesanti (OSRM `car` te li fa sbagliare)
- API `trace_route` / `trace_attributes` per il map matching del Segnale C — **lo stesso servizio ti serve due volte**, non installi due stack
- gira bene su hardware modesto con l'estratto Nord-Ovest

Alternativa più leggera: [OSRM](http://project-osrm.org/) con profilo `car`. Più semplice da avviare, meno accurato sui sensi unici.

**Validazione dell'output — non saltarla.** Il percorso generato è plausibile solo se:
- parte entro 200 m dal punto di stacco dichiarato ✓
- arriva entro 200 m dal punto di ricongiungimento ✓
- passa entro 100 m da **ogni** via della sequenza dichiarata ✓
- non è più lungo di 3× la distanza in linea d'aria ✓
- non ripercorre il percorso originale per più del 20% della sua lunghezza ✓

Se una di queste fallisce → `confidence` bassa, mostra comunque il testo originale accanto alla mappa.

### 5.3 Segnale C — Osservazione dei mezzi

**Frequenza di polling:** 30 s. Più frequente non aiuta (il feed a monte probabilmente non aggiorna più spesso) e ti fa solo bannare l'IP.

```
Ogni 30 s:
  1. GET vehicle_position.aspx → decodifica protobuf
  2. Filtra sui route_id della watchlist
  3. Per ogni veicolo:
       a. Determina il pattern atteso
          - se trip_id è popolato → lookup diretto (facile)
          - se non lo è → inferenza per prossimità + direzione di marcia (§5.3.1)
       b. Calcola la distanza dalla polilinea del pattern
       c. Se distanza > SOGLIA_FUORI_ROTTA (parti da 80 m) → marca il punto "off-route"
  4. Accumula in vehicle_observations
```

#### 5.3.1 Se `trip_id` non è utilizzabile

**Prima di implementare questo, verifica se ti serve.** Se `vehicle_position` popola `trip_id` nel formato `1:28259838U`, usa il ponte `trip_id → pattern_id` descritto in §1.1 e salta interamente questa sezione. Questa è solo la via di riserva.

Fallback:
1. Prendi tutti i pattern della linea
2. Per ciascuno, calcola la distanza media degli ultimi 5 punti del veicolo dalla polilinea
3. Il pattern con distanza minima è il candidato — **ma solo se la distanza media è < 150 m**, altrimenti il veicolo è troppo fuori rotta per essere assegnato con fiducia
4. Disambigua la direzione confrontando il verso di marcia (bearing tra punti consecutivi) con il verso della polilinea nel punto più vicino

#### 5.3.2 Da punti sparsi a deviazione confermata — la parte che conta

**Un singolo veicolo fuori rotta non è una deviazione.** È un GPS impazzito, un mezzo che rientra in deposito, un autista che ha sbagliato strada, un fuori servizio. Filtra così:

```
Una deviazione è CONFERMATA solo se, in una finestra di 60 minuti:
  ≥ 3 veicoli DIVERSI della stessa linea e stessa direzione
  hanno lasciato il percorso teorico entro 150 m l'uno dall'altro
  (stesso punto di stacco)
  e hanno percorso traiettorie simili (Fréchet discreta < 200 m)
```

Il **punto di stacco** è il centroide dei punti in cui i veicoli hanno superato la soglia. Il **punto di rientro** è il centroide dei punti di rientro.

**Ricostruzione del percorso deviato reale:**
1. Prendi tutte le tracce off-route del cluster
2. Passale a **Valhalla `trace_route`** (map matching) — snappa la nuvola di punti GPS rumorosi sulle strade reali
3. Se hai più tracce, prendi la **mediana geometrica** dei risultati, non la media (robusta agli outlier)
4. Il risultato è la polilinea del percorso realmente percorso

Parametri di partenza da tarare sul campo:

| Parametro | Valore iniziale | Note |
|---|---|---|
| `SOGLIA_FUORI_ROTTA` | 80 m | Alzalo in centro (canyon urbano, multipath). Considera una soglia variabile per densità edificata. |
| `MIN_VEICOLI_CLUSTER` | 3 | Su linee a bassa frequenza scendi a 2 ma abbassa la confidenza |
| `FINESTRA_TEMPORALE` | 60 min | |
| `MIN_PUNTI_TRACCIA` | 5 | Sotto questo, la traccia è troppo corta per il map matching |
| `MAX_FRECHET_CLUSTER` | 200 m | Distanza di Fréchet discreta tra tracce dello stesso cluster |

**Ottimizzazione importante:** non ricalcolare la distanza punto-polilinea da zero a ogni ciclo. Precarica ogni polilinea in uno `STRtree` (Shapely) al primo uso e tienilo in memoria. Con 30 linee × 4 pattern è tutto in RAM e il ciclo dura millisecondi.

---

## 6. Motore di sintesi — dall'evento ai tre output

L'utente ha chiesto **tutti e tre** gli output. Vanno generati dallo stesso `DeviationEvent`.

### 6.1 Output 1 — Fermate saltate e alternative

L'output più utile in assoluto, e quello che GTT non dà quasi mai.

```
Input: percorso_ufficiale, percorso_deviato, fermate_del_pattern

1. Per ogni fermata del pattern nel tratto tra divergenza e ricongiungimento:
     distanza = distanza(fermata, percorso_deviato)
     se distanza > 40 m  → SALTATA
     se distanza <= 40 m → ancora servita (il bus le passa accanto)

   ⚠️ Passare accanto non significa fermarsi. Se GTT dichiara esplicitamente
      le fermate sospese (campo suspended_stop_codes), quel dato VINCE
      sempre sulla geometria.

2. Per ogni fermata SALTATA, trova le alternative:
     a. fermate ancora servite dalla STESSA linea, ordinate per distanza a piedi
     b. fermate di ALTRE linee entro 400 m che portano in direzione compatibile
     c. calcola la distanza a piedi REALE (routing pedonale Valhalla), non
        in linea d'aria — a Torino un fiume o una ferrovia cambiano tutto

3. Restituisci max 3 alternative per fermata, con distanza in metri e minuti a piedi
```

### 6.2 Output 2 — Mappa percorso reale vs teorico

Rendering consigliato: **Leaflet + MapLibre GL**, tile OSM standard o CartoDB Positron (sfondo neutro, i percorsi si leggono meglio).

Convenzioni grafiche:

| Elemento | Stile |
|---|---|
| Percorso normale (tratto non toccato) | Linea continua, colore della linea GTT (dall'OTP: campo `color`) |
| Tratto **soppresso** | Linea **tratteggiata grigia**, opacità 50% |
| Tratto **deviato** | Linea continua **rossa/arancio**, spessore maggiore |
| Punto di divergenza | Marker con etichetta "esce qui" |
| Punto di ricongiungimento | Marker con etichetta "rientra qui" |
| Fermate servite | Cerchio pieno |
| Fermate **saltate** | Cerchio **barrato**, rosso |
| Fermate alternative | Cerchio verde + linea tratteggiata verso la fermata saltata |

Aggiungi sempre un badge di **confidenza** visibile: `confermato` / `probabile` / `stimato dal testo`. L'utente deve poter capire quanto fidarsi. E metti sempre in fondo il **testo originale GTT** con il link alla fonte: se il sistema sbaglia, l'utente ha comunque il dato grezzo.

### 6.3 Output 3 — Testo in linguaggio naturale

Generato **dai dati geometrici**, non dal testo GTT. Se lo rigeneri dal testo originale non hai aggiunto nulla.

Template per tipo di deviazione:

```
DEVIAZIONE
"Il {linea} verso {capolinea} non passa da {vie_soppresse}.
 Esce dal percorso in {punto_stacco} e rientra in {punto_rientro},
 passando da {vie_deviazione}.
 Non ferma a: {fermate_saltate}.
 Per {fermata_saltata_principale} usa {alternativa} ({distanza} m a piedi).
 Motivo: {motivo}. Fino al {fine} (o «senza data di fine prevista»)."

LIMITAZIONE
"Il {linea} verso {capolinea} è limitato a {capolinea_provvisorio}.
 Il tratto {da} → {a} NON è servito.
 Fermate non servite: {elenco}.
 In alternativa: {linee_alternative} per il tratto mancante."

SOSTITUZIONE MODALE
"Il {linea} percorre il tragitto normale ma con {tipo_mezzo} al posto del tram.
 Le fermate sono le stesse."

NON ANNUNCIATA (solo Segnale C)
"⚠️ Rilevato: {n} mezzi del {linea} stanno passando da {vie_osservate}
 invece che da {vie_normali}. GTT non ha pubblicato avvisi.
 Rilevato alle {ora}, {n} mezzi osservati."
```

Regole di scrittura (contano più di quanto sembri):
- **Nomi di fermata, non nomi di via**, quando parli di dove salire. L'utente sta a una fermata, non su una via.
- **Metri e minuti a piedi**, sempre. "Poco distante" non serve a nessuno.
- **Mai il gergo GTT** (`percorso normale`, `si instrada`, `effettua capolinea provvisorio`). Traducilo.
- Se `confidence < 0.5`, apri con "Probabilmente" e mostra il testo originale in evidenza.

### 6.4 Calcolo della confidenza

```python
confidence = 0.0
if "PATTERN_DIFF"  in signals: confidence += 0.50   # dato ufficiale
if "GPS_OBSERVED"  in signals: confidence += 0.30   # evidenza empirica
if "TEXT_DERIVED"  in signals: confidence += 0.20   # dichiarato

# Penalità
if geometry_validation_failed:      confidence -= 0.30   # §5.2.3
if unresolved_toponyms:             confidence -= 0.15
if llm_confidence_self < 0.7:       confidence -= 0.10
if gps_cluster_size < 3:            confidence -= 0.10

# Bonus di coerenza: due segnali indipendenti che concordano geometricamente
if "TEXT_DERIVED" in signals and "GPS_OBSERVED" in signals:
    if frechet(text_geometry, gps_geometry) < 150:  # metri
        confidence += 0.15

confidence = clamp(confidence, 0.0, 1.0)
```

Soglie di presentazione: `≥ 0.75` **confermato** · `0.45–0.75` **probabile** · `< 0.45` **stimato** (mostra sempre il testo originale in primo piano).

---

## 7. Stack tecnologico consigliato

| Componente | Scelta | Perché |
|---|---|---|
| Linguaggio | **Python 3.11+** | Ecosistema geospaziale imbattibile |
| Geometria | `shapely` 2.x, `pyproj`, `geopandas` | Standard. Shapely 2 è molto più veloce |
| Polilinee | `polyline` | Decodifica il formato OTP |
| GTFS-RT | `gtfs-realtime-bindings` | Ufficiale Google |
| GTFS statico | `gtfs-kit` o `partridge` | |
| Routing + map matching | **Valhalla** in Docker | Un solo servizio per entrambi gli usi, profilo bus |
| Dati stradali | Geofabrik `nord-ovest-latest.osm.pbf` | ~350 MB, copre tutto il bacino GTT |
| Parsing OSM | `pyrosm` o `osmium-tool` | |
| Fuzzy matching toponimi | `rapidfuzz` | Veloce, buone metriche |
| DB | **SQLite + SpatiaLite** | Sufficiente. Zero ops. |
| Scheduler | APScheduler (o cron) | |
| API | **FastAPI** | Type hints + OpenAPI gratis |
| Frontend mappa | Leaflet o MapLibre GL JS | |
| Notifiche | Bot Telegram tuo, o [ntfy.sh](https://ntfy.sh) | |
| Ingestione Telegram | `telethon` | |
| LLM | API con output JSON strutturato, temp 0 | Modello piccolo: è estrazione, non ragionamento |
| Hosting | VPS 2 vCPU / 4 GB, o Raspberry Pi 4+ | Valhalla è la parte esigente (~2 GB RAM) |

**Costo stimato:** 5-10 €/mese di VPS + qualche centesimo/giorno di LLM. Tutto il resto è open source e i dati sono CC-BY.

### Struttura del repository

```
gtt-deviazioni/
├── ingest/
│   ├── otp_client.py           # client OTP + cache su disco
│   ├── gtfs_rt_client.py       # decodifica protobuf
│   ├── web_scraper.py          # /cms/variazioni + /cms/percorari
│   ├── telegram_listener.py    # telethon
│   └── gtfs_static.py          # download + parsing zip
├── signals/
│   ├── pattern_diff.py         # SEGNALE A
│   ├── text_parser.py          # SEGNALE B: LLM
│   ├── geocoder.py             # SEGNALE B: OSM locale, geocoding vincolato
│   ├── router.py               # SEGNALE B: Valhalla
│   └── gps_matcher.py          # SEGNALE C: matching + clustering
├── core/
│   ├── line_aliases.py         # ⚠️ generato + corretto a mano + versionato
│   ├── models.py
│   ├── fusion.py               # motore di fusione + confidenza
│   ├── stop_impact.py          # fermate saltate + alternative
│   └── narrator.py             # generazione testo naturale
├── api/main.py                 # FastAPI
├── web/                        # mappa Leaflet
├── data/
│   ├── osm/                    # estratto Geofabrik
│   ├── cache/                  # risposte OTP
│   └── gtt.db                  # SQLite
├── scripts/
│   ├── validate_sources.py     # ⚠️ §9 — ESEGUI QUESTO PER PRIMO
│   ├── bootstrap_aliases.py
│   └── build_baseline.py
└── tests/
    └── fixtures/               # ⚠️ 30+ avvisi reali annotati a mano
```

---

## 8. Roadmap

Ordinata in modo che **ogni fase produca qualcosa di usabile**, non un pezzo di infrastruttura inerte.

### Fase 0 — Validazione (2-3 giorni) — 🚨 obbligatoria

Esegui `scripts/validate_sources.py` (§9) e **lascialo girare per almeno 48 ore**. Serve a rispondere alle domande da cui dipende tutta l'architettura:

- [ ] `vehicle_position` popola `trip_id` e `route_id`?
- [ ] Quanti veicoli, quali linee, ogni quanti secondi?
- [ ] `alerts.aspx` contiene `informed_entity` con `route_id` utilizzabile?
- [ ] **Le geometrie dei pattern OTP cambiano quando c'è una deviazione?** ← la domanda più importante
- [ ] L'HTML di `/cms/variazioni` si parsa in modo stabile?

**Non scrivere il sistema prima di avere queste risposte.** Se il Segnale A non regge, l'architettura resta ma le priorità cambiano radicalmente.

### Fase 1 — Baseline geometrico (1 settimana)
Client OTP con cache. Tabella alias linee, corretta a mano. Snapshot di tutti i pattern delle tue linee. Diff giornaliero + notifica Telegram grezza a ogni cambiamento. **Già utile:** ti avvisa quando GTT modifica un percorso.

### Fase 2 — Scraper + LLM (1-2 settimane)
Scraper `/cms/variazioni` e `/cms/percorari`. Estrazione LLM con lo schema di §5.2.1. **Costruisci il set di test: 30+ avvisi reali annotati a mano.** Senza questo non saprai mai se stai migliorando. Output: avvisi normalizzati e strutturati per linea.

### Fase 3 — Geometria dal testo (2 settimane) — il cuore
Indice OSM locale + geocoding vincolato. Valhalla in Docker. Routing con waypoint + validazione (§5.2.3). **Prima uscita visibile:** mappa con percorso normale e percorso deviato a confronto.

### Fase 4 — Impatto fermate + narratore (1 settimana)
Calcolo fermate saltate. Alternative con distanza pedonale reale. Generazione testo. **A questo punto il sistema risolve il problema originale.** Fermati qui se vuoi.

### Fase 5 — Segnale GPS (2-3 settimane)
Polling GTFS-RT, matching, clustering, map matching. Rilevamento **deviazioni non annunciate**. È la fase con il rapporto sforzo/beneficio peggiore ma il valore più alto sui casi rari.

### Fase 6 — App personale (1-2 settimane)
Watchlist linee + fermate preferite. Notifiche push. PWA installabile su telefono. Scheduling (es. controlla le tue linee alle 7:30 e alle 18:00).

---

## 9. Step 0 — Script di validazione

**Il file `validate_sources.py` è fornito insieme a questo documento.** Va eseguito prima di scrivere qualsiasi altra cosa.

Cosa fa:
1. Verifica raggiungibilità di tutti gli endpoint
2. Decodifica i tre feed GTFS-RT e **riporta esattamente quali campi sono popolati** (con percentuali)
3. Verifica il **ponte `trip_id` RT ↔ OTP** (§1.1): se regge, il Segnale C si semplifica drasticamente
4. Scarica i pattern OTP di un gruppo di linee e ne salva l'hash
5. Rieseguito nei giorni successivi, **rileva se le geometrie sono cambiate** → è il test dell'ipotesi del Segnale A
6. Verifica la struttura HTML della pagina variazioni e ne estrae esempi utilizzabili come fixture di test
7. Produce un report JSON e un output leggibile con tre verdetti espliciti

**Come si usa:**
```bash
pip install requests gtfs-realtime-bindings beautifulsoup4 lxml polyline
python validate_sources.py --lines 55,4,13,19,68 --out ./validation
# e poi, ogni giorno per almeno 3 giorni:
python validate_sources.py --lines 55,4,13,19,68 --out ./validation --compare
```

Prima di eseguirlo, scegli **linee attualmente deviate** (dalla tabella `/cms/variazioni`): sono quelle su cui il test del Segnale A è significativo. Al 31/07/2026 candidate valide: **4, 11, 19, 46, 58, 92, STAR 1, STAR 2, 13, 10**.

---

## 10. Trappole note — leggi prima di iniziare

Ordinate per quanto tempo ti faranno perdere se le ignori.

1. **Assumere che il Segnale A funzioni senza verificarlo.** Metà dell'architettura ci poggia sopra. Misura, non sperare.

2. **Il matching dei nomi di linea.** `58/`, `58 barrata`, `1:58BU`, `58 /`. Sembra un dettaglio, è la causa più frequente di bug silenziosi. Tabella di alias esplicita, e **logga i mancati match invece di indovinare**.

3. **Lavorare in gradi invece che in metri.** Riproietta sempre in EPSG:32632 prima di qualunque calcolo di distanza. Le soglie in gradi non hanno senso e i risultati saranno sottilmente sbagliati ovunque.

4. **Confondere deviazione e limitazione.** Sono problemi diversi per l'utente: nella deviazione il bus passa altrove, nella limitazione metà linea *non esiste*. Il testo GTT usa `limitata`, `capolinea provvisorio`, `effettua inversione`. Trattale come tipi distinti fin dal modello dati.

5. **Fidarsi di un singolo veicolo fuori rotta.** Rientri in deposito, fuori servizio, GPS impazzito, autista che sbaglia. Sempre clustering (§5.3.2).

6. **Geocodificare senza vincoli spaziali.** È esattamente ciò che ha fatto fallire il tentativo precedente. Buffer 2 km + comune + OSM locale.

7. **Ignorare il comune.** `via Roma` esiste a Torino, Chieri, Nichelino, Settimo, Moncalieri e Grugliasco. GTT scrive `Nel Comune di X`: usalo.

8. **Deviazioni ai capolinea.** Frequentissime a Torino, e rompono l'algoritmo di divergenza/ricongiungimento perché non c'è ricongiungimento. Gestisci esplicitamente i casi limite.

9. **Deviazioni asimmetriche per direzione.** Quasi tutte lo sono. Non modellare mai una deviazione a livello di linea: sempre a livello di **pattern (linea + direzione + variante)**.

10. **Sostituzioni modali scambiate per deviazioni.** `Gestione per autobus` significa percorso identico, mezzo diverso. Se lo tratti come deviazione mostri un allarme falso.

11. **Rate limiting.** OTP è un servizio non documentato di GTT: cachea tutto, non superare qualche richiesta al secondo, metti uno `User-Agent` identificabile con un contatto. Non farti bloccare per fretta.

12. **Apostrofi tipografici.** `d'Azeglio` (U+2019) vs `d'Azeglio` (U+0027). Normalizza in ingresso o passerai un pomeriggio a capire perché una via non si risolve.

13. **Fine deviazione non annunciata.** GTT annuncia l'inizio quasi sempre, la fine quasi mai. Molte righe hanno `Fine presunta: -`. Serve una logica di scadenza: se il Segnale C non osserva più la deviazione per 24-48 h, marcala `probabilmente conclusa` invece di lasciarla attiva per sempre.

14. **Deviazioni multiple sovrapposte sulla stessa linea.** Guarda la linea 19 nella tabella: tre variazioni contemporanee, per motivi diversi. Il modello dati deve supportare N eventi attivi per pattern, e il narratore deve saperli comporre in un testo unico e leggibile.

---

## 11. Criteri di accettazione

Il sistema è considerato riuscito se, su un campione di **20 deviazioni reali** raccolte nell'arco di un mese:

| # | Criterio | Soglia |
|---|---|---|
| 1 | Deviazioni annunciate rilevate entro 30 min dalla pubblicazione | ≥ 90% |
| 2 | Geometria deviata ricostruita e visivamente corretta (verifica manuale) | ≥ 80% |
| 3 | Fermate saltate identificate correttamente (precision e recall) | ≥ 85% |
| 4 | Falsi positivi (deviazione segnalata che non esiste) | ≤ 5% |
| 5 | Testo generato comprensibile a chi non conosce il gergo GTT | verifica su 3 persone |
| 6 | Almeno una deviazione **non annunciata** rilevata dal Segnale C | ≥ 1 |
| 7 | Latenza risposta API per singola linea | < 2 s |

Il criterio 4 è il più importante: **un falso positivo è peggio di un mancato rilevamento.** Se il sistema dice che il 55 devia e non è vero, l'utente cammina 800 metri per niente e non si fida mai più. In caso di dubbio, il sistema deve dichiarare incertezza, non inventare.

---

## 12. Istruzioni per l'agente di coding

Da consegnare insieme a questo documento a Claude Code o equivalente.

```
CONTESTO
Costruisci il sistema descritto in SPECIFICA-Rilevatore-Deviazioni-GTT.md.
Leggi il documento per intero prima di scrivere codice.

VINCOLI NON NEGOZIABILI
1. NON iniziare dalla Fase 1. Esegui prima scripts/validate_sources.py e
   riporta i risultati. L'architettura dipende da quelle risposte.
2. Ogni segnale (A, B, C) è un modulo indipendente e disattivabile via config.
   Nessuna dipendenza incrociata.
3. Ogni calcolo geometrico avviene in EPSG:32632, mai in gradi.
4. La tabella line_aliases.py è generata una volta e poi corretta a mano.
   Non fare fuzzy matching di nomi di linea a runtime.
5. Se un toponimo non si risolve o una validazione geometrica fallisce,
   il sistema DEVE dichiarare incertezza. Non deve mai produrre una
   geometria inventata. Meglio nessuna mappa che una mappa sbagliata.
6. Ogni chiamata a OTP passa da una cache su disco con TTL.
   Rispetta il servizio: max 2 req/s, User-Agent identificabile.
7. Scrivi i test con avvisi GTT REALI (in tests/fixtures/), non inventati.
   Il parser va valutato su almeno 30 casi annotati a mano.

ORDINE DI LAVORO
Fase 0 → Fase 1 → Fase 2 → Fase 3 → Fase 4. Fermati dopo ogni fase e
mostrami un output concreto e verificabile prima di procedere.

DEFINIZIONE DI FATTO PER OGNI FASE
- Test che passano sui fixture reali
- Un comando CLI eseguibile che dimostra la funzionalità
- Log leggibili che mostrano cosa il sistema ha deciso e perché
```

---

## Appendice A — Endpoint di riferimento

```
# OpenTripPlanner GTT (nessuna autenticazione) — VERIFICATO 31/07/2026
https://otpgtt.gtt.to.it/otp/routers/default/index/routes
https://otpgtt.gtt.to.it/otp/routers/default/index/routes/{routeId}
https://otpgtt.gtt.to.it/otp/routers/default/index/routes/{routeId}/patterns
https://otpgtt.gtt.to.it/otp/routers/default/index/patterns/{patternId}
https://otpgtt.gtt.to.it/otp/routers/default/index/patterns/{patternId}/geometry
https://otpgtt.gtt.to.it/otp/routers/default/index/patterns/{patternId}/stops
https://otpgtt.gtt.to.it/otp/routers/default/index/stops/{stopId}/stoptimes

# GTFS statico (CC-BY)
https://www.gtt.to.it/open_data/gtt_gtfs.zip

# GTFS-Realtime (CC-BY, Protocol Buffer)
https://percorsieorari.gtt.to.it/das_gtfsrt/vehicle_position.aspx
https://percorsieorari.gtt.to.it/das_gtfsrt/trip_update.aspx
https://percorsieorari.gtt.to.it/das_gtfsrt/alerts.aspx

# Pagine web
https://gtt.to.it/cms/variazioni            # variazioni programmate (tabella)
https://gtt.to.it/cms/percorari/urbano      # variazioni attive adesso
https://gtt.to.it/cms/percorari/urbano?view=percorsi&bacino=U&linea=55&Regol=GE

# Telegram
https://t.me/gttavvisi
https://t.me/s/gttavvisi                    # preview web, scrapabile

# Dati stradali
https://download.geofabrik.de/europe/italy/nord-ovest-latest.osm.pbf

# Cataloghi open data
http://aperto.comune.torino.it/dataset/feed-gtfs-trasporti-gtt
https://aperto.comune.torino.it/dataset/feed-gtfs-real-time-trasporti-gtt
```

## Appendice B — Nota su licenze e correttezza

I dati GTFS e GTFS-RT sono pubblicati con licenza **Creative Commons Attribution (CC-BY)**: puoi usarli, anche in un'app pubblica, **citando GTT come fonte**. Mettilo nel footer.

L'API OTP di `otpgtt.gtt.to.it` è pubblica ma **non documentata come open data**. Zona grigia: è servita in chiaro senza autenticazione, ma non c'è una licenza esplicita. Comportamento corretto:
- cachea aggressivamente, non martellare il servizio
- `User-Agent` identificabile con un contatto
- se il progetto diventa pubblico, **scrivi a GTT** e chiedi. Potrebbero anche essere contenti: stai costruendo qualcosa che migliora il loro servizio senza costi per loro.

Evita del tutto il reverse engineering di token proprietari (§1.6): non serve, e sposta il progetto dalla zona grigia a quella nera.
