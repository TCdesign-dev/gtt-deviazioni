#!/usr/bin/env python3
"""
snapshot_gtfs.py — test del SEGNALE A sulla fonte giusta.

PERCHE' ESISTE QUESTO SCRIPT
    validate_sources.py fa lo snapshot dei pattern dall'OTP di GTT.
    Verificato il 31/07/2026: l'OTP gira su un build GTFS VECCHIO.
    I suoi trip_id (28.259.xxx) non esistono piu' in trips.txt di oggi
    (28.370-28.402.xxx) e i suoi service_id non sono in calendar.txt.
    Diffare le geometrie OTP significa quindi diffare un dato fermo:
    il test del Segnale A su quella fonte non dimostra nulla.

    Il GTFS statico invece e' rigenerato OGNI GIORNO alle 04:00
    (feed_version = data odierna) ed e' allineato al feed realtime
    (100% dei trip_id RT risolti in trips.txt).
    E' quella la base geometrica su cui va fatto il pattern diffing.

COSA FA
    Scarica il GTFS statico, calcola per ogni shape:
      - hash della polilinea + numero di punti + lunghezza in metri
      - hash della sequenza di fermate (da una corsa rappresentativa)
      - route_id, direction_id, headsign, numero di corse che la usano
    Salva uno snapshot JSON. Con --compare diffa contro il precedente:
    shape nuove / rimosse / geometria cambiata / fermate cambiate.

USO
    python snapshot_gtfs.py --out ./validation                  # baseline
    python snapshot_gtfs.py --out ./validation --compare        # ogni giorno
    python snapshot_gtfs.py --out ./validation --compare \
           --lines 4,10,11,13,19,30,46,55,56,92                 # solo watchlist

Dati GTT: CC-BY, cita la fonte.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import sys
import zipfile
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

import requests

GTFS_ZIP = "https://www.gtt.to.it/open_data/gtt_gtfs.zip"
UA = ("gtt-deviazioni-validator/1.0 (progetto personale; "
      "contatto: tommasocostanza7@gmail.com)")

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


def _sha(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:16]


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Distanza in metri. Sufficiente per una misura di lunghezza indicativa:
    per i calcoli veri del sistema si usa EPSG:32632 (spec §10.3)."""
    r = 6371000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp = p2 - p1
    dl = math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


# ------------------------------------------------------------------ download

def fetch_gtfs(dest: Path, refresh: bool) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and not refresh:
        log(f"  Riuso lo zip gia' presente: {dest} "
            f"({dest.stat().st_size:,} B)", C_DIM)
        return dest
    log(f"  Scarico {GTFS_ZIP} ...")
    with requests.get(GTFS_ZIP, headers={"User-Agent": UA},
                      timeout=300, stream=True) as r:
        r.raise_for_status()
        with dest.open("wb") as f:
            for chunk in r.iter_content(1 << 20):
                f.write(chunk)
    log(f"  OK   {dest.stat().st_size:,} B", C_OK)
    return dest


def read_csv(zf: zipfile.ZipFile, name: str) -> Iterator[dict[str, str]]:
    with zf.open(name) as fh:
        yield from csv.DictReader(
            (line.decode("utf-8-sig") for line in fh))


# ------------------------------------------------------------------ snapshot

def build_snapshot(zip_path: Path, wanted: set[str] | None) -> dict[str, Any]:
    section("SNAPSHOT GTFS STATICO")
    snap: dict[str, Any] = {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "source": "gtfs_static",
    }

    with zipfile.ZipFile(zip_path) as zf:
        info = next(iter(read_csv(zf, "feed_info.txt")), {})
        snap["feed_version"] = info.get("feed_version")
        snap["feed_start_date"] = info.get("feed_start_date")
        snap["feed_end_date"] = info.get("feed_end_date")
        log(f"  feed_version : {snap['feed_version']}   "
            f"validita' {snap['feed_start_date']} -> {snap['feed_end_date']}")

        routes = {r["route_id"]: r for r in read_csv(zf, "routes.txt")}
        log(f"  routes.txt   : {len(routes):,} linee")

        if wanted:
            keep_routes = {
                rid for rid, r in routes.items()
                if (r.get("route_short_name") or "").upper().replace(" ", "")
                in wanted
            }
            if not keep_routes:
                log(f"  !! nessuna linea corrisponde a {sorted(wanted)}", C_ERR)
                sys.exit(2)
            log(f"  filtro watchlist: {len(keep_routes)} linee  "
                + ", ".join(sorted(routes[r].get("route_short_name", "?")
                                   for r in keep_routes)), C_DIM)
        else:
            keep_routes = None

        # ---- trips: shape -> metadati, e corsa rappresentativa per shape
        shapes_meta: dict[str, dict[str, Any]] = {}
        rep_trip: dict[str, str] = {}
        trip_to_shape: dict[str, str] = {}
        n_trips = 0
        for t in read_csv(zf, "trips.txt"):
            n_trips += 1
            rid, sid = t["route_id"], t.get("shape_id") or ""
            if not sid or (keep_routes is not None and rid not in keep_routes):
                continue
            m = shapes_meta.setdefault(sid, {
                "route_id": rid,
                "route_short_name": routes.get(rid, {}).get("route_short_name"),
                "direction_id": t.get("direction_id"),
                "headsigns": set(),
                "n_trips": 0,
            })
            m["headsigns"].add(t.get("trip_headsign") or "")
            m["n_trips"] += 1
            # corsa rappresentativa: la prima in ordine di trip_id
            if sid not in rep_trip or t["trip_id"] < rep_trip[sid]:
                rep_trip[sid] = t["trip_id"]
        for sid, tid in rep_trip.items():
            trip_to_shape[tid] = sid
        log(f"  trips.txt    : {n_trips:,} corse   "
            f"{len(shapes_meta):,} shape considerate")

        # ---- shapes: geometria
        pts: dict[str, list[tuple[int, float, float]]] = defaultdict(list)
        for s in read_csv(zf, "shapes.txt"):
            sid = s["shape_id"]
            if sid not in shapes_meta:
                continue
            pts[sid].append((int(s["shape_pt_sequence"]),
                             float(s["shape_pt_lat"]),
                             float(s["shape_pt_lon"])))
        log(f"  shapes.txt   : {sum(len(v) for v in pts.values()):,} punti")

        # ---- stop_times: sequenza fermate delle sole corse rappresentative
        log("  stop_times.txt: lettura in streaming (file grosso, ~1 min)...",
            C_DIM)
        seq: dict[str, list[tuple[int, str]]] = defaultdict(list)
        for st in read_csv(zf, "stop_times.txt"):
            sid = trip_to_shape.get(st["trip_id"])
            if sid is None:
                continue
            seq[sid].append((int(st["stop_sequence"]), st["stop_id"]))
        log(f"  OK   sequenze fermate per {len(seq):,} shape", C_OK)

    out: dict[str, Any] = {}
    for sid, meta in shapes_meta.items():
        p = sorted(pts.get(sid, []))
        coords = [(lat, lon) for _, lat, lon in p]
        length = sum(haversine_m(coords[i], coords[i + 1])
                     for i in range(len(coords) - 1)) if len(coords) > 1 else 0.0
        stops = [sc for _, sc in sorted(seq.get(sid, []))]
        out[sid] = {
            "route_id": meta["route_id"],
            "route_short_name": meta["route_short_name"],
            "direction_id": meta["direction_id"],
            "headsign": sorted(meta["headsigns"])[0] if meta["headsigns"] else None,
            "n_trips": meta["n_trips"],
            "n_points": len(coords),
            "length_m": round(length),
            "geometry_hash": _sha(";".join(f"{a:.5f},{b:.5f}" for a, b in coords)),
            "stops_hash": _sha("|".join(stops)),
            "n_stops": len(stops),
            "stop_ids": stops,
        }

    snap["shapes"] = out
    log(f"\n  Snapshot costruito: {len(out):,} shape", C_OK)
    return snap


# ------------------------------------------------------------------- compare

def compare(prev: dict, curr: dict) -> dict[str, Any]:
    """Ritorna un riepilogo strutturato, non solo un conteggio: serve a
    daily_snapshot.sh per decidere se svegliare qualcuno (un log che nessuno
    legge non e' un risultato)."""
    section("CONFRONTO SNAPSHOT  <<< TEST DEL SEGNALE A >>>")
    log(f"  precedente : {prev.get('captured_at')}  "
        f"feed_version {prev.get('feed_version')}")
    log(f"  attuale    : {curr.get('captured_at')}  "
        f"feed_version {curr.get('feed_version')}")
    same_feed = prev.get("feed_version") == curr.get("feed_version")
    if same_feed:
        log("  ~~   stesso feed_version: GTT non ha ripubblicato il GTFS.", C_WARN)
    log()

    ps, cs = prev.get("shapes", {}), curr.get("shapes", {})
    events: list[dict[str, Any]] = []

    def label(d: dict) -> str:
        return (f"{str(d.get('route_short_name')):<8} dir{d.get('direction_id')} "
                f"{str(d.get('headsign'))[:34]:<36}")

    def short(d: dict, sid: str) -> str:
        return (f"{d.get('route_short_name')} dir{d.get('direction_id')} "
                f"\"{d.get('headsign')}\" [{sid}]")

    for sid in sorted(cs.keys() - ps.keys()):
        d = cs[sid]
        log(f"  + SHAPE NUOVA     {label(d)} {sid}", C_WARN)
        log(f"      {d['n_points']} punti, {d['length_m']} m, "
            f"{d['n_stops']} fermate, {d['n_trips']} corse", C_DIM)
        log("      -> possibile variante creata da GTT per una deviazione", C_DIM)
        events.append({"kind": "shape_nuova", "shape_id": sid,
                       "line": d.get("route_short_name"),
                       "desc": short(d, sid), "length_m": d["length_m"],
                       "n_stops": d["n_stops"], "n_trips": d["n_trips"]})

    for sid in sorted(ps.keys() - cs.keys()):
        d = ps[sid]
        log(f"  - SHAPE RIMOSSA   {label(d)} {sid}", C_WARN)
        log("      -> possibile fine di una deviazione", C_DIM)
        events.append({"kind": "shape_rimossa", "shape_id": sid,
                       "line": d.get("route_short_name"), "desc": short(d, sid)})

    for sid in sorted(ps.keys() & cs.keys()):
        a, b = ps[sid], cs[sid]
        if a["geometry_hash"] != b["geometry_hash"]:
            log(f"  ! GEOMETRIA CAMBIATA  {label(b)} {sid}", C_ERR)
            log(f"      punti {a['n_points']} -> {b['n_points']}   "
                f"lunghezza {a['length_m']} -> {b['length_m']} m "
                f"({b['length_m'] - a['length_m']:+d} m)", C_DIM)
            events.append({"kind": "geometria_cambiata", "shape_id": sid,
                           "line": b.get("route_short_name"),
                           "desc": short(b, sid),
                           "delta_m": b["length_m"] - a["length_m"],
                           "length_m": [a["length_m"], b["length_m"]]})
        if a["stops_hash"] != b["stops_hash"]:
            sa, sb = set(a.get("stop_ids", [])), set(b.get("stop_ids", []))
            log(f"  ! FERMATE CAMBIATE    {label(b)} {sid}  "
                f"({a['n_stops']} -> {b['n_stops']})", C_ERR)
            if sa - sb:
                log(f"      non piu' servite: {sorted(sa - sb)}", C_DIM)
            if sb - sa:
                log(f"      aggiunte        : {sorted(sb - sa)}", C_DIM)
            events.append({"kind": "fermate_cambiate", "shape_id": sid,
                           "line": b.get("route_short_name"),
                           "desc": short(b, sid),
                           "rimosse": sorted(sa - sb), "aggiunte": sorted(sb - sa)})

    log()
    log("  >>> VERDETTO SEGNALE A", C_HEAD)
    if events:
        log(f"  OK   {len(events)} cambiamenti rilevati sul GTFS statico.", C_OK)
        log("       GTT codifica le variazioni nel feed. Il pattern diffing", C_OK)
        log("       su GTFS statico e' praticabile: mettilo al centro.", C_OK)
    else:
        log("  ~~   Nessun cambiamento in questo intervallo.", C_WARN)
        log("       Non conclusivo dopo un solo giorno. Servono 3-7 giorni.", C_DIM)

    return {
        "compared_at": datetime.now(timezone.utc).isoformat(),
        "prev_captured_at": prev.get("captured_at"),
        "curr_captured_at": curr.get("captured_at"),
        "prev_feed_version": prev.get("feed_version"),
        "curr_feed_version": curr.get("feed_version"),
        "same_feed_version": same_feed,
        "n_changes": len(events),
        "lines_touched": sorted({e["line"] for e in events if e.get("line")}),
        "events": events,
    }


# ---------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(
        description="Snapshot e diff delle shape del GTFS statico GTT")
    ap.add_argument("--out", default="./validation", help="cartella di output")
    ap.add_argument("--lines", default="",
                    help="route_short_name separati da virgola (vuoto = tutte)")
    ap.add_argument("--compare", action="store_true",
                    help="confronta con lo snapshot precedente")
    ap.add_argument("--refresh", action="store_true",
                    help="riscarica lo zip anche se gia' presente")
    args = ap.parse_args()

    outdir = Path(args.out)
    snap_dir = outdir / "gtfs_snapshots"
    snap_dir.mkdir(parents=True, exist_ok=True)
    wanted = {x.strip().upper().replace(" ", "")
              for x in args.lines.split(",") if x.strip()} or None

    log()
    log("#" * 72, C_HEAD)
    log("#  SNAPSHOT GTFS STATICO — test del Segnale A", C_HEAD)
    log(f"#  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", C_HEAD)
    log("#" * 72, C_HEAD)

    zip_path = Path("data") / f"gtt_gtfs-{datetime.now():%Y%m%d}.zip"
    fetch_gtfs(zip_path, args.refresh)

    snap = build_snapshot(zip_path, wanted)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = snap_dir / f"gtfs-{stamp}.json"
    path.write_text(json.dumps(snap, ensure_ascii=False), encoding="utf-8")
    log(f"  Salvato: {path}  ({path.stat().st_size:,} B)", C_OK)

    if args.compare:
        prev_files = sorted(snap_dir.glob("gtfs-*.json"))[:-1]
        if not prev_files:
            log("\n  ~~   nessuno snapshot precedente. Riesegui tra 24 ore.", C_WARN)
        else:
            prev = json.loads(prev_files[-1].read_text(encoding="utf-8"))
            result = compare(prev, snap)
            # Esito in forma leggibile da uno script: e' cio' che permette al
            # job giornaliero di segnalare i cambiamenti invece di limitarsi
            # a scriverli in un log.
            (outdir / "last_diff.json").write_text(
                json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
            log(f"\n  Esito strutturato: {outdir / 'last_diff.json'}", C_DIM)

    log()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("\nInterrotto.", C_WARN)
        sys.exit(130)
