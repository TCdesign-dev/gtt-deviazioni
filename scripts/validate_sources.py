#!/usr/bin/env python3
"""
validate_sources.py — Step 0 del progetto "Rilevatore Deviazioni GTT".

Da eseguire PRIMA di scrivere qualsiasi altra riga del sistema.
Risponde alle domande da cui dipende l'intera architettura:

  1. Gli endpoint GTT/OTP sono raggiungibili?
  2. vehicle_position popola trip_id / route_id? Quanti mezzi? Quali linee?
  3. alerts.aspx popola informed_entity in modo utilizzabile?
  4. >>> Le geometrie dei pattern OTP cambiano quando c'e' una deviazione? <<<
     (questa e' LA domanda: e' l'ipotesi su cui poggia il Segnale A)
  5. L'HTML di /cms/variazioni si parsa in modo stabile?

USO
    pip install requests gtfs-realtime-bindings beautifulsoup4 lxml polyline

    # primo giro (crea il baseline)
    python validate_sources.py --lines 4,11,19,46,58,92 --out ./validation

    # nei giorni successivi, almeno 3 volte a 24h di distanza
    python validate_sources.py --lines 4,11,19,46,58,92 --out ./validation --compare

SCELTA DELLE LINEE
    Usa linee ATTUALMENTE DEVIATE (le trovi su https://gtt.to.it/cms/variazioni).
    Su una linea non deviata il test del Segnale A non dice nulla.

Licenza: fai quello che vuoi. Dati GTT: CC-BY, cita la fonte.
"""

from __future__ import annotations

import argparse
import json
import hashlib
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests

# ---------------------------------------------------------------- costanti

OTP_BASE = "https://otpgtt.gtt.to.it/otp/routers/default/index"
RT_VEHICLES = "https://percorsieorari.gtt.to.it/das_gtfsrt/vehicle_position.aspx"
RT_TRIPS = "https://percorsieorari.gtt.to.it/das_gtfsrt/trip_update.aspx"
RT_ALERTS = "https://percorsieorari.gtt.to.it/das_gtfsrt/alerts.aspx"
GTFS_ZIP = "https://www.gtt.to.it/open_data/gtt_gtfs.zip"
WEB_VARIAZIONI = "https://gtt.to.it/cms/variazioni"
WEB_ATTIVE = "https://gtt.to.it/cms/percorari/urbano"

# Identificati. Se GTT vuole contattarti, deve poterlo fare.
UA = ("gtt-deviazioni-validator/1.0 (progetto personale; "
      "contatto: tommasocostanza7@gmail.com)")
HEADERS = {"User-Agent": UA}
TIMEOUT = 30
SLEEP_BETWEEN = 0.4  # rate limiting cortese verso OTP

C_OK, C_WARN, C_ERR, C_DIM, C_HEAD, C_RESET = (
    "\033[92m", "\033[93m", "\033[91m", "\033[90m", "\033[1;96m", "\033[0m"
)


def log(msg: str = "", color: str = "") -> None:
    print(f"{color}{msg}{C_RESET}" if color else msg, flush=True)


def section(title: str) -> None:
    log()
    log("=" * 72, C_HEAD)
    log(f"  {title}", C_HEAD)
    log("=" * 72, C_HEAD)


def pct(n: int, tot: int) -> str:
    return "n/d" if tot == 0 else f"{100.0 * n / tot:.1f}%"


def verdict(ok: bool, msg_ok: str, msg_ko: str) -> None:
    log(f"  {'OK  ' if ok else 'KO  '} {msg_ok if ok else msg_ko}",
        C_OK if ok else C_ERR)


def get(url: str, **kw) -> requests.Response:
    return requests.get(url, headers=HEADERS, timeout=TIMEOUT, **kw)


# ------------------------------------------------------- 1. raggiungibilita'

def check_reachability() -> dict[str, Any]:
    section("1. RAGGIUNGIBILITA' DEGLI ENDPOINT")
    targets = {
        "OTP /index/routes": f"{OTP_BASE}/routes",
        "GTFS-RT vehicle_position": RT_VEHICLES,
        "GTFS-RT trip_update": RT_TRIPS,
        "GTFS-RT alerts": RT_ALERTS,
        "Web /cms/variazioni": WEB_VARIAZIONI,
        "Web /cms/percorari/urbano": WEB_ATTIVE,
        "GTFS statico (HEAD)": GTFS_ZIP,
    }
    out: dict[str, Any] = {}
    for name, url in targets.items():
        try:
            t0 = time.time()
            if "HEAD" in name:
                r = requests.head(url, headers=HEADERS, timeout=TIMEOUT,
                                  allow_redirects=True)
            else:
                r = get(url, stream=True)
            ms = int((time.time() - t0) * 1000)
            size = len(r.content) if not "HEAD" in name else int(
                r.headers.get("Content-Length", 0))
            ctype = r.headers.get("Content-Type", "?").split(";")[0]
            ok = r.status_code == 200
            log(f"  {'OK  ' if ok else 'KO  '} {name:<30} "
                f"{r.status_code}  {ms:>5} ms  {size:>9,} B  {ctype}",
                C_OK if ok else C_ERR)
            out[name] = {"status": r.status_code, "ms": ms,
                         "bytes": size, "content_type": ctype}
        except Exception as e:  # noqa: BLE001
            log(f"  KO   {name:<30} ERRORE: {e}", C_ERR)
            out[name] = {"error": str(e)}
    return out


# ---------------------------------------------------------- 2. GTFS-Realtime

def _load_pb():
    try:
        from google.transit import gtfs_realtime_pb2
        return gtfs_realtime_pb2
    except ImportError:
        log("  !! gtfs-realtime-bindings non installato — salto l'analisi RT",
            C_ERR)
        log("     pip install gtfs-realtime-bindings", C_DIM)
        return None


def check_vehicle_positions() -> dict[str, Any]:
    section("2. GTFS-RT — VEHICLE POSITIONS  (base del Segnale C)")
    pb = _load_pb()
    if pb is None:
        return {"skipped": True}

    try:
        raw = get(RT_VEHICLES).content
        feed = pb.FeedMessage()
        feed.ParseFromString(raw)
    except Exception as e:  # noqa: BLE001
        log(f"  KO   impossibile decodificare: {e}", C_ERR)
        log("       (se fallisce qui, il Segnale C non e' praticabile)", C_DIM)
        return {"error": str(e)}

    ents = list(feed.entity)
    n = len(ents)
    log(f"  Entita' nel feed: {n}")
    if n == 0:
        log("  !! Feed VUOTO. Riprova in orario di servizio (07:00-20:00 feriale).",
            C_WARN)
        return {"entities": 0}

    fields = Counter()
    routes: Counter = Counter()
    ts_list: list[int] = []
    sample: dict[str, Any] = {}
    trip_ids: list[str] = []

    for e in ents:
        if not e.HasField("vehicle"):
            continue
        v = e.vehicle
        if v.HasField("trip"):
            if v.trip.trip_id:
                fields["trip_id"] += 1
                if len(trip_ids) < 10:
                    trip_ids.append(v.trip.trip_id)
            if v.trip.route_id:
                fields["route_id"] += 1
                routes[v.trip.route_id] += 1
            if v.trip.direction_id is not None and v.trip.HasField("direction_id"):
                fields["direction_id"] += 1
        if v.HasField("position"):
            fields["position"] += 1
            if v.position.HasField("bearing"):
                fields["bearing"] += 1
            if v.position.HasField("speed"):
                fields["speed"] += 1
        if v.HasField("vehicle") and v.vehicle.id:
            fields["vehicle_id"] += 1
        if v.HasField("current_stop_sequence"):
            fields["current_stop_sequence"] += 1
        if v.stop_id:
            fields["stop_id"] += 1
        if v.HasField("timestamp"):
            fields["timestamp"] += 1
            ts_list.append(v.timestamp)
        if not sample:
            sample = {
                "entity_id": e.id,
                "trip_id": v.trip.trip_id if v.HasField("trip") else None,
                "route_id": v.trip.route_id if v.HasField("trip") else None,
                "vehicle_id": v.vehicle.id if v.HasField("vehicle") else None,
                "lat": v.position.latitude if v.HasField("position") else None,
                "lon": v.position.longitude if v.HasField("position") else None,
                "bearing": v.position.bearing if v.HasField("position") else None,
                "stop_id": v.stop_id or None,
                "current_stop_sequence": v.current_stop_sequence,
                "timestamp": v.timestamp,
            }

    log()
    log("  Popolamento dei campi:")
    for f in ("trip_id", "route_id", "direction_id", "vehicle_id", "position",
              "bearing", "speed", "stop_id", "current_stop_sequence", "timestamp"):
        c = fields.get(f, 0)
        mark = "OK " if c > n * 0.8 else ("~  " if c > 0 else "KO ")
        col = C_OK if c > n * 0.8 else (C_WARN if c else C_ERR)
        log(f"    {mark} {f:<24} {c:>5}/{n}  ({pct(c, n)})", col)

    log()
    log(f"  Linee distinte con route_id: {len(routes)}")
    if routes:
        top = ", ".join(f"{r}({c})" for r, c in routes.most_common(12))
        log(f"    piu' frequenti: {top}", C_DIM)

    if ts_list:
        now = int(time.time())
        ages = [now - t for t in ts_list if 0 < now - t < 86400]
        if ages:
            ages.sort()
            log()
            log(f"  Eta' dei timestamp: min {min(ages)}s  "
                f"mediana {ages[len(ages)//2]}s  max {max(ages)}s")

    log()
    log("  Esempio di entita':", C_DIM)
    for k, v in sample.items():
        log(f"    {k}: {v}", C_DIM)

    log()
    log("  >>> VERDETTO SEGNALE C", C_HEAD)
    has_trip = fields.get("trip_id", 0) > n * 0.8
    verdict(has_trip,
            "trip_id popolato: matching diretto con il GTFS statico, ottimo.",
            "trip_id ASSENTE o parziale: serve inferenza del pattern (spec §5.3.1).")
    has_route = fields.get("route_id", 0) > n * 0.8
    verdict(has_route,
            "route_id popolato: puoi filtrare per linea senza inferenza.",
            "route_id ASSENTE: il Segnale C diventa molto piu' oneroso.")

    return {"entities": n, "fields": dict(fields),
            "routes": dict(routes.most_common(50)), "sample": sample,
            "trip_ids": trip_ids}


def check_alerts() -> dict[str, Any]:
    section("3. GTFS-RT — SERVICE ALERTS  (scorciatoia potenziale del Segnale B)")
    pb = _load_pb()
    if pb is None:
        return {"skipped": True}

    try:
        raw = get(RT_ALERTS).content
        feed = pb.FeedMessage()
        feed.ParseFromString(raw)
    except Exception as e:  # noqa: BLE001
        log(f"  KO   impossibile decodificare: {e}", C_ERR)
        return {"error": str(e)}

    ents = [e for e in feed.entity if e.HasField("alert")]
    n = len(ents)
    log(f"  Alert presenti: {n}")
    if n == 0:
        log("  Nessun alert al momento. Riprova quando c'e' una deviazione attiva.",
            C_WARN)
        return {"alerts": 0}

    with_route = with_stop = with_trip = with_any = 0
    samples = []
    for e in ents[:200]:
        a = e.alert
        r = s = t = False
        for ie in a.informed_entity:
            r |= bool(ie.route_id)
            s |= bool(ie.stop_id)
            t |= bool(ie.trip.trip_id)
        with_route += r
        with_stop += s
        with_trip += t
        with_any += bool(a.informed_entity)
        if len(samples) < 3:
            def _txt(ts):
                return ts.translation[0].text if ts.translation else None
            samples.append({
                "header": _txt(a.header_text),
                "description": (_txt(a.description_text) or "")[:400],
                "cause": a.cause,
                "effect": a.effect,
                "informed_entity": [
                    {"agency_id": ie.agency_id or None,
                     "route_id": ie.route_id or None,
                     "stop_id": ie.stop_id or None,
                     "trip_id": ie.trip.trip_id or None}
                    for ie in a.informed_entity
                ][:8],
            })

    log()
    log(f"  con informed_entity non vuoto : {with_any}/{n}  ({pct(with_any, n)})")
    log(f"  con route_id                  : {with_route}/{n}  ({pct(with_route, n)})")
    log(f"  con stop_id                   : {with_stop}/{n}  ({pct(with_stop, n)})")
    log(f"  con trip_id                   : {with_trip}/{n}  ({pct(with_trip, n)})")

    log()
    for i, s in enumerate(samples, 1):
        log(f"  --- Esempio {i} ---", C_DIM)
        log(f"  header: {s['header']}", C_DIM)
        log(f"  descr : {s['description'][:250]}...", C_DIM)
        log(f"  entity: {json.dumps(s['informed_entity'], ensure_ascii=False)}", C_DIM)
        log("", C_DIM)

    log("  >>> VERDETTO ALERTS", C_HEAD)
    verdict(with_route > n * 0.5,
            "route_id popolato: collegamento avviso->linea gratuito. Ottimo.",
            "route_id assente: dovrai estrarre la linea dal testo (spec §4.1).")
    verdict(with_stop > 0,
            f"stop_id presente su {with_stop} alert: fermate impattate dichiarate!",
            "nessun stop_id: le fermate impattate vanno dedotte dalla geometria.")
    return {"alerts": n, "with_route": with_route,
            "with_stop": with_stop, "with_trip": with_trip, "samples": samples}


def check_trip_id_bridge(rt: dict[str, Any]) -> dict[str, Any]:
    """Il trip_id del feed RT e' compatibile con quello dell'OTP?

    Se si', dal veicolo si arriva direttamente al pattern e alla sua geometria
    senza alcuna inferenza: e' la semplificazione piu' importante possibile
    per il Segnale C (spec §1.1 e §5.3.1).
    """
    section("3-bis. PONTE trip_id  RT <-> OTP  +  FRESCHEZZA DELL'OTP")

    rt_trips = (rt or {}).get("trip_ids") or []
    if not rt_trips:
        log("  ~~   Nessun trip_id nel feed RT: ponte non verificabile.", C_WARN)
        log("       Dovrai usare l'inferenza per prossimita' (spec §5.3.1).", C_DIM)
        return {"bridge": "unknown"}

    # Il confronto di FORMA non basta: '28370684U' e '1:28259877U' differiscono
    # solo per il prefisso di feed, ma possono comunque appartenere a due build
    # GTFS diversi. L'unica prova che conta e' risolvere davvero l'id sull'OTP.
    resolved, missing = [], []
    for t in rt_trips[:6]:
        try:
            time.sleep(SLEEP_BETWEEN)
            r = get(f"{OTP_BASE}/trips/1:{t}")
            (resolved if r.status_code == 200 else missing).append(t)
        except Exception:  # noqa: BLE001
            missing.append(t)

    log(f"  trip_id RT testati sull'OTP : {len(resolved)}/{len(resolved)+len(missing)}"
        f" risolti come '1:<id>'")
    if missing:
        log(f"    non risolti: {missing}", C_DIM)

    # Controllo: un id preso DALL'OTP stesso si risolve? Se si', l'endpoint
    # funziona e il problema non e' la sintassi ma il contenuto del dataset.
    otp_trip, control_ok = None, None
    try:
        routes = otp_get("/routes")
        rid = next((r["id"] for r in routes
                    if (r.get("shortName") or "") == "55"), routes[0]["id"])
        pats = otp_get(f"/routes/{rid}/patterns")
        stops = otp_get(f"/patterns/{pats[0]['id']}/stops")
        for grp in otp_get(f"/stops/{stops[0]['id']}/stoptimes"):
            for t in grp.get("times", []):
                if t.get("tripId"):
                    otp_trip = t["tripId"]
                    break
            if otp_trip:
                break
        if otp_trip:
            time.sleep(SLEEP_BETWEEN)
            control_ok = get(f"{OTP_BASE}/trips/{otp_trip}").status_code == 200
    except Exception as e:  # noqa: BLE001
        log(f"  ~~   controllo OTP non riuscito: {e}", C_WARN)

    log(f"  trip_id preso dall'OTP      : {otp_trip}  "
        f"-> /trips/ risponde {'200' if control_ok else 'NO'}")

    log()
    log("  >>> VERDETTO PONTE trip_id", C_HEAD)
    if resolved and not missing:
        log("  OK   Gli id RT si risolvono sull'OTP: aggiungi il prefisso '1:'", C_OK)
        log("       e salti interamente l'inferenza di §5.3.1.", C_OK)
        state = "ok"
    elif control_ok and not resolved:
        log("  KO   L'endpoint /trips funziona (200 su un id dell'OTP) ma", C_ERR)
        log("       NESSUN id del feed realtime esiste sull'OTP.", C_ERR)
        log("       => l'OTP gira su un build GTFS VECCHIO, disallineato dal RT.", C_ERR)
        log("       Conseguenze (importanti):", C_ERR)
        log("         - il ponte trip_id -> pattern via OTP non e' percorribile:", C_DIM)
        log("           serve l'inferenza di §5.3.1, oppure il GTFS statico,", C_DIM)
        log("           che e' allineato al RT ed e' rigenerato ogni giorno.", C_DIM)
        log("         - il Segnale A NON va testato sulle geometrie OTP:", C_DIM)
        log("           usa scripts/snapshot_gtfs.py, che diffa il GTFS statico.", C_DIM)
        state = "otp_stale"
    else:
        log("  ~~   Esito non conclusivo: riprova in orario di servizio.", C_WARN)
        state = "unknown"

    return {"bridge": state, "rt_trip_ids_resolved": resolved,
            "rt_trip_ids_missing": missing, "otp_trip_id": otp_trip,
            "otp_control_200": control_ok}


# -------------------------------------------- 4. OTP patterns (Segnale A) ---

def otp_get(path: str) -> Any:
    time.sleep(SLEEP_BETWEEN)
    r = get(f"{OTP_BASE}{path}")
    r.raise_for_status()
    return r.json()


def _sha(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:16]


def snapshot_patterns(line_names: list[str]) -> dict[str, Any]:
    section("4. OTP PATTERNS — SNAPSHOT  (test dell'ipotesi del Segnale A)")

    log("  Scarico l'elenco delle linee...")
    try:
        routes = otp_get("/routes")
    except Exception as e:  # noqa: BLE001
        log(f"  KO   OTP non raggiungibile: {e}", C_ERR)
        log("       Senza OTP il Segnale A non e' praticabile: usa il GTFS zip.", C_DIM)
        return {"error": str(e)}

    log(f"  OK   {len(routes)} linee trovate")

    wanted = {n.strip().upper().replace(" ", "") for n in line_names}
    matched = []
    for r in routes:
        sn = (r.get("shortName") or "").upper().replace(" ", "")
        if sn in wanted:
            matched.append(r)

    if not matched:
        log(f"  !! Nessuna linea corrisponde a {sorted(wanted)}", C_ERR)
        log("     shortName disponibili (primi 40): "
            + ", ".join(sorted({(r.get('shortName') or '') for r in routes})[:40]),
            C_DIM)
        return {"error": "no lines matched"}

    log(f"  OK   {len(matched)} linee da campionare: "
        + ", ".join(f"{r['shortName']}({r['id']})" for r in matched))
    unresolved = wanted - {(r.get("shortName") or "").upper().replace(" ", "")
                           for r in matched}
    if unresolved:
        log(f"  ~~   non risolte: {sorted(unresolved)}  "
            f"(controlla il naming, es. '58 /' vs '58/')", C_WARN)

    snap: dict[str, Any] = {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "routes": {},
    }

    log()
    for r in matched:
        rid = r["id"]
        try:
            patterns = otp_get(f"/routes/{rid}/patterns")
        except Exception as e:  # noqa: BLE001
            log(f"  KO   {r['shortName']}: {e}", C_ERR)
            continue

        log(f"  {r['shortName']:<10} ({rid})  {len(patterns)} pattern")
        entry: dict[str, Any] = {"shortName": r["shortName"], "patterns": {}}

        for p in patterns:
            pid = p["id"]
            try:
                geom = otp_get(f"/patterns/{pid}/geometry")
                stops = otp_get(f"/patterns/{pid}/stops")
            except Exception as e:  # noqa: BLE001
                log(f"     KO {pid}: {e}", C_ERR)
                continue

            points = geom.get("points", "")
            stop_codes = [s.get("code") for s in stops]
            entry["patterns"][pid] = {
                "desc": p.get("desc"),
                "geometry_hash": _sha(points),
                "geometry_len": geom.get("length"),
                "geometry_chars": len(points),
                "stops_hash": _sha("|".join(map(str, stop_codes))),
                "n_stops": len(stop_codes),
                "first_stop": stops[0]["name"] if stops else None,
                "last_stop": stops[-1]["name"] if stops else None,
                # utile per il diff manuale nelle prime fasi
                "stop_codes": stop_codes,
            }
            log(f"     - {pid:<18} {str(p.get('desc'))[:38]:<40} "
                f"geo:{_sha(points)}  {len(stop_codes):>3} fermate", C_DIM)

        snap["routes"][rid] = entry

    return snap


def compare_snapshots(prev: dict, curr: dict) -> None:
    section("5. CONFRONTO SNAPSHOT  <<< IL TEST DECISIVO >>>")
    log(f"  precedente : {prev.get('captured_at')}")
    log(f"  attuale    : {curr.get('captured_at')}")
    log()

    changes = 0
    for rid, cr in curr.get("routes", {}).items():
        pr = prev.get("routes", {}).get(rid)
        if not pr:
            log(f"  + LINEA NUOVA nello snapshot: {cr['shortName']}", C_WARN)
            changes += 1
            continue

        pp, cp = pr.get("patterns", {}), cr.get("patterns", {})

        for pid in cp.keys() - pp.keys():
            log(f"  + PATTERN NUOVO  {cr['shortName']:<8} {pid}  "
                f"'{cp[pid]['desc']}'", C_WARN)
            log("      -> possibile variante creata da GTT per una deviazione", C_DIM)
            changes += 1

        for pid in pp.keys() - cp.keys():
            log(f"  - PATTERN RIMOSSO {cr['shortName']:<8} {pid}  "
                f"'{pp[pid]['desc']}'", C_WARN)
            log("      -> possibile fine di una deviazione", C_DIM)
            changes += 1

        for pid in pp.keys() & cp.keys():
            a, b = pp[pid], cp[pid]
            if a["geometry_hash"] != b["geometry_hash"]:
                log(f"  ! GEOMETRIA CAMBIATA  {cr['shortName']:<8} {pid}", C_ERR)
                log(f"      '{b['desc']}'", C_DIM)
                log(f"      vertici: {a['geometry_len']} -> {b['geometry_len']}", C_DIM)
                changes += 1
            if a["stops_hash"] != b["stops_hash"]:
                sa, sb = set(map(str, a.get("stop_codes", []))), \
                         set(map(str, b.get("stop_codes", [])))
                log(f"  ! FERMATE CAMBIATE    {cr['shortName']:<8} {pid}  "
                    f"({a['n_stops']} -> {b['n_stops']})", C_ERR)
                if sa - sb:
                    log(f"      rimosse: {sorted(sa - sb)}", C_DIM)
                if sb - sa:
                    log(f"      aggiunte: {sorted(sb - sa)}", C_DIM)
                changes += 1

    log()
    log("  >>> VERDETTO SEGNALE A", C_HEAD)
    if changes:
        log(f"  OK   {changes} cambiamenti rilevati.", C_OK)
        log("       L'ipotesi del Segnale A REGGE: GTT codifica le deviazioni", C_OK)
        log("       nel GTFS e l'OTP le espone. Il pattern diffing e' la", C_OK)
        log("       fonte piu' affidabile: mettilo al centro del sistema.", C_OK)
    else:
        log("  ~~   Nessun cambiamento in questo intervallo.", C_WARN)
        log("       NON conclusivo. Controlla che:", C_DIM)
        log("         a) le linee campionate siano DAVVERO deviate ora", C_DIM)
        log("            (verifica su https://gtt.to.it/cms/variazioni)", C_DIM)
        log("         b) siano passate almeno 48-72 ore dal baseline", C_DIM)
        log("       Se dopo una settimana su linee deviate non cambia nulla,", C_DIM)
        log("       il Segnale A vale poco: sposta il peso su B (testo) e C (GPS).", C_DIM)


# ------------------------------------------------ 6. struttura pagina web ---

def check_web_table() -> dict[str, Any]:
    section("6. PAGINA /cms/variazioni — STABILITA' DEL PARSING")
    try:
        from bs4 import BeautifulSoup
    except ImportError:
        log("  !! beautifulsoup4 non installato — salto", C_ERR)
        return {"skipped": True}

    try:
        html = get(WEB_VARIAZIONI).text
    except Exception as e:  # noqa: BLE001
        log(f"  KO   {e}", C_ERR)
        return {"error": str(e)}

    soup = BeautifulSoup(html, "lxml")
    tables = soup.find_all("table")
    log(f"  Tabelle trovate nella pagina: {len(tables)}")

    best, best_rows = None, 0
    for t in tables:
        rows = t.find_all("tr")
        if len(rows) > best_rows:
            best, best_rows = t, len(rows)

    if not best:
        log("  KO   nessuna tabella: la pagina e' cambiata, rivedi lo scraper", C_ERR)
        return {"tables": 0}

    rows = best.find_all("tr")
    log(f"  OK   tabella principale: {len(rows)} righe", C_OK)

    parsed, examples = 0, []
    for tr in rows:
        cells = [c.get_text(" ", strip=True) for c in tr.find_all(["td", "th"])]
        cells = [c for c in cells if c]
        if len(cells) >= 5:
            parsed += 1
            if len(examples) < 4:
                examples.append(cells[:6])

    log(f"  OK   righe con >=5 colonne (variazioni utili): {parsed}", C_OK)
    log()
    for ex in examples:
        log(f"    linea    : {ex[0]}", C_DIM)
        log(f"    inizio   : {ex[1]}", C_DIM)
        log(f"    fine     : {ex[2]}", C_DIM)
        log(f"    direzione: {ex[3][:70]}", C_DIM)
        log(f"    descr    : {ex[4][:160]}...", C_DIM)
        log("", C_DIM)

    log("  >>> VERDETTO SEGNALE B", C_HEAD)
    verdict(parsed >= 10,
            f"{parsed} variazioni estratte: lo scraping e' praticabile.",
            "poche righe estratte: verifica la struttura HTML a mano.")
    log()
    log("  SUGGERIMENTO: salva queste righe come fixture di test.", C_DIM)
    log("  Ti servono >=30 avvisi reali annotati a mano per valutare il", C_DIM)
    log("  parser LLM (spec §5.2.1). Questa pagina te li regala.", C_DIM)

    return {"tables": len(tables), "rows": len(rows),
            "parsed_rows": parsed, "examples": examples}


# ----------------------------------------------------------------- main -----

def main() -> int:
    ap = argparse.ArgumentParser(
        description="Validazione delle fonti dati GTT — Step 0")
    ap.add_argument("--lines", default="4,11,19,46,58,92",
                    help="shortName separati da virgola. USA LINEE DEVIATE ORA.")
    ap.add_argument("--out", default="./validation", help="cartella di output")
    ap.add_argument("--compare", action="store_true",
                    help="confronta con lo snapshot precedente")
    ap.add_argument("--skip-rt", action="store_true",
                    help="salta l'analisi GTFS-RT")
    args = ap.parse_args()

    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)
    lines = [x.strip() for x in args.lines.split(",") if x.strip()]

    log()
    log("#" * 72, C_HEAD)
    log("#  VALIDAZIONE FONTI DATI GTT — Step 0", C_HEAD)
    log(f"#  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", C_HEAD)
    log(f"#  linee campionate: {', '.join(lines)}", C_HEAD)
    log("#" * 72, C_HEAD)

    report: dict[str, Any] = {
        "run_at": datetime.now(timezone.utc).isoformat(),
        "lines": lines,
    }

    report["reachability"] = check_reachability()
    if not args.skip_rt:
        report["vehicle_positions"] = check_vehicle_positions()
        report["alerts"] = check_alerts()
        report["trip_id_bridge"] = check_trip_id_bridge(
            report["vehicle_positions"])

    snap = snapshot_patterns(lines)
    report["patterns_ok"] = "error" not in snap

    snap_dir = outdir / "snapshots"
    snap_dir.mkdir(exist_ok=True)

    if "error" not in snap:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        (snap_dir / f"patterns-{stamp}.json").write_text(
            json.dumps(snap, indent=2, ensure_ascii=False), encoding="utf-8")
        log()
        log(f"  Snapshot salvato: snapshots/patterns-{stamp}.json", C_OK)

        if args.compare:
            prev_files = sorted(snap_dir.glob("patterns-*.json"))[:-1]
            if not prev_files:
                log("  ~~   nessuno snapshot precedente da confrontare.", C_WARN)
                log("       Riesegui con --compare tra 24 ore.", C_DIM)
            else:
                prev = json.loads(prev_files[-1].read_text(encoding="utf-8"))
                compare_snapshots(prev, snap)

    report["web_table"] = check_web_table()

    rpt = outdir / f"report-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
    rpt.write_text(json.dumps(report, indent=2, ensure_ascii=False),
                   encoding="utf-8")

    section("FATTO")
    log(f"  Report: {rpt}")
    log()
    log("  PROSSIMI PASSI", C_HEAD)
    log("   1. Rileggi i tre VERDETTI qui sopra (Segnale A, B, C).")
    log("   2. Riesegui con --compare ogni 24h per almeno 3 giorni.")
    log("      Il test del Segnale A ha senso solo su piu' giorni.")
    log("   3. Solo dopo, inizia la Fase 1 della roadmap.")
    log()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("\nInterrotto.", C_WARN)
        sys.exit(130)
