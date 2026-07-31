#!/usr/bin/env python3
"""
test_geocoding.py — il test che de-rischia l'intero progetto.

La specifica dice che il tentativo precedente e' morto qui (§5.2.2): i
toponimi geocodificati senza vincoli restituivano vie a caso in Italia.
La correzione proposta e' il geocoding VINCOLATO: cercare solo attorno al
percorso reale della linea.

Questo script lo misura sui toponimi delle 34 fixture annotate a mano:
per ogni via, interroga Photon (geocoder OSM pubblico, nessuna chiave)
usando come vincolo il baricentro e il riquadro della linea a cui l'avviso
si riferisce, presi dal GTFS. Poi verifica che il risultato cada davvero
entro N km dal percorso teorico.

E' la prova che serve prima di scrivere la Fase 3: se la resa e' alta si
costruisce, se e' bassa si ripensa l'approccio prima di spendere settimane.

USO
    python test_geocoding.py [--buffer-km 2.0] [--sleep 1.0]
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
import time
import zipfile
from collections import defaultdict
from pathlib import Path

import requests

PHOTON = "https://photon.komoot.io/api"
UA = {"User-Agent": ("gtt-deviazioni-validator/1.0 (progetto personale; "
                     "contatto: tommasocostanza7@gmail.com)")}
LAT0 = 45.07
M_LAT = 111_132.0
M_LON = 111_320.0 * math.cos(math.radians(LAT0))


def to_m(lat, lon):
    return (lat * M_LAT, lon * M_LON)


def seg_dist(p, a, b):
    px, py = p
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def dist_to_line(pt, shape):
    return min(seg_dist(pt, shape[i], shape[i + 1])
               for i in range(len(shape) - 1))


def load_shapes_by_line(zip_path: Path):
    def rd(zf, name):
        with zf.open(name) as fh:
            yield from csv.DictReader((l.decode("utf-8-sig") for l in fh))

    with zipfile.ZipFile(zip_path) as zf:
        short = {r["route_id"]: (r.get("route_short_name") or "")
                 for r in rd(zf, "routes.txt")}
        shape2route = {}
        for t in rd(zf, "trips.txt"):
            sid = t.get("shape_id")
            if sid:
                shape2route[sid] = t["route_id"]
        pts = defaultdict(list)
        for s in rd(zf, "shapes.txt"):
            pts[s["shape_id"]].append((int(s["shape_pt_sequence"]),
                                       float(s["shape_pt_lat"]),
                                       float(s["shape_pt_lon"])))

    by_line = defaultdict(list)
    for sid, raw in pts.items():
        rid = shape2route.get(sid)
        if not rid:
            continue
        key = short.get(rid, "").upper().replace(" ", "")
        by_line[key].extend([(la, lo) for _, la, lo in sorted(raw)])
    return by_line


def toponyms(dev: dict):
    """Ogni toponimo dell'annotazione, con il campo di provenienza."""
    for i, v in enumerate(dev.get("via_sequence") or []):
        if v.get("street"):
            yield ("via_sequence", v["street"])
    for field in ("detach_point", "rejoin_point", "temporary_terminus"):
        pt = dev.get(field)
        if isinstance(pt, dict):
            for k in ("street", "cross_street"):
                if pt.get(k):
                    yield (f"{field}.{k}", pt[k])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--buffer-km", type=float, default=2.0,
                    help="quanto lontano dal percorso e' ancora accettabile")
    ap.add_argument("--sleep", type=float, default=1.0,
                    help="pausa fra le query: Photon e' un servizio pubblico")
    ap.add_argument("--gtfs", type=Path, default=None)
    args = ap.parse_args()

    gtfs = args.gtfs or sorted(Path("data").glob("gtt_gtfs-*.zip"))[-1]
    print(f"GTFS: {gtfs}")
    by_line = load_shapes_by_line(gtfs)
    print(f"  geometrie per {len(by_line)} linee\n")

    ann = json.loads(Path("tests/fixtures/annotations.json")
                     .read_text(encoding="utf-8"))["annotations"]

    ok = far = miss = skipped = 0
    failures, far_cases = [], []
    seen: dict[str, tuple] = {}

    for nid, entry in ann.items():
        for dev in entry["deviations"]:
            lines = [l.upper().replace(" ", "").removesuffix("U")
                     for l in (dev.get("lines") or [])]
            shape = None
            for l in lines:
                if l in by_line and len(by_line[l]) > 1:
                    shape = [to_m(a, b) for a, b in by_line[l]]
                    break
            if shape is None:
                for _ in toponyms(dev):
                    skipped += 1
                continue

            lat_c = sum(p[0] for p in by_line[lines[0]]) / len(by_line[lines[0]]) \
                if lines[0] in by_line else LAT0
            lon_c = sum(p[1] for p in by_line[lines[0]]) / len(by_line[lines[0]]) \
                if lines[0] in by_line else 7.68

            for field, name in toponyms(dev):
                key = (name, lines[0] if lines else "")
                if key in seen:
                    res = seen[key]
                else:
                    time.sleep(args.sleep)
                    try:
                        # NIENTE lang=it: Photon supporta solo default/de/en/fr
                        # e risponde 400 a tutto il resto, silenziosamente.
                        r = requests.get(PHOTON, params={
                            "q": f"{name}, {dev.get('municipality') or 'Torino'}",
                            "lat": lat_c, "lon": lon_c, "limit": 1},
                            headers=UA, timeout=25)
                        if r.status_code != 200:
                            raise RuntimeError(f"HTTP {r.status_code}: "
                                               f"{r.text[:120]}")
                        feats = r.json().get("features", [])
                    except Exception as e:  # noqa: BLE001
                        feats = []
                        print(f"  errore su {name}: {e}", file=sys.stderr)
                    res = feats[0] if feats else None
                    seen[key] = res

                if not res:
                    miss += 1
                    failures.append((nid, lines[0] if lines else "?", field, name))
                    continue
                lon, lat = res["geometry"]["coordinates"]
                d = dist_to_line(to_m(lat, lon), shape) / 1000.0
                osm_name = res["properties"].get("name", "?")
                if d <= args.buffer_km:
                    ok += 1
                else:
                    far += 1
                    far_cases.append((nid, lines[0] if lines else "?", name,
                                      osm_name, d))

    tot = ok + far + miss
    print("=" * 70)
    print("RISULTATO — geocoding vincolato sui toponimi delle fixture")
    print("=" * 70)
    print(f"  toponimi testati            : {tot}   "
          f"(saltati per linea non risolta: {skipped})")
    print(f"  risolti entro {args.buffer_km:g} km dal percorso: {ok}   "
          f"({100*ok/max(tot,1):.1f}%)")
    print(f"  risolti ma TROPPO LONTANI   : {far}   ({100*far/max(tot,1):.1f}%)")
    print(f"  non trovati                 : {miss}   ({100*miss/max(tot,1):.1f}%)")

    if far_cases:
        print(f"\n  Fuori buffer (il vincolo li avrebbe scartati — e' il "
              f"comportamento giusto):")
        for nid, line, name, osm, d in far_cases[:12]:
            print(f"    {nid:<10} linea {line:<6} '{name}' -> '{osm}'  {d:.1f} km")
    if failures:
        print(f"\n  Non trovati:")
        for nid, line, field, name in failures[:15]:
            print(f"    {nid:<10} linea {line:<6} {field:<24} '{name}'")

    print(f"\n  >>> VERDETTO")
    rate = 100 * ok / max(tot, 1)
    if rate >= 80:
        print(f"  Il geocoding vincolato regge ({rate:.0f}%). La Fase 3 e'")
        print("  praticabile: si costruisce.")
    elif rate >= 60:
        print(f"  Resa media ({rate:.0f}%). Praticabile ma serve lavoro sulla")
        print("  normalizzazione dei toponimi (spec §5.2.2) prima di procedere.")
    else:
        print(f"  Resa bassa ({rate:.0f}%). Ripensare l'approccio prima di")
        print("  scrivere la Fase 3.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
