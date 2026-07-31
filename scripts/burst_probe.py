#!/usr/bin/env python3
"""
burst_probe.py — quanto si impara osservando i mezzi per pochi minuti?

Domanda: invece di tenere il polling GPS acceso in continuo (spec §5.3),
si puo' accendere una finestra breve on-demand e vedere se i mezzi di UNA
linea sono davvero fuori percorso?

Questo script misura i numeri che servono a rispondere:
  - quanti mezzi distinti per linea in una finestra di N minuti
  - quanto si spostano (quindi quanta rete coprono)
  - >>> la distribuzione della distanza dal percorso teorico <<<
    che e' il dato con cui si tara SOGLIA_FUORI_ROTTA, oggi a 80 m "da
    tarare empiricamente" (spec §5.3.2)

USO
    python burst_probe.py --minutes 3 --every 30
"""

from __future__ import annotations

import argparse
import csv
import math
import statistics
import sys
import time
import zipfile
from collections import defaultdict
from pathlib import Path

import requests
from google.transit import gtfs_realtime_pb2

RT = "https://percorsieorari.gtt.to.it/das_gtfsrt/vehicle_position.aspx"
UA = {"User-Agent": ("gtt-deviazioni-validator/1.0 (progetto personale; "
                     "contatto: tommasocostanza7@gmail.com)")}

# Torino ~45.07 N. Scala locale per passare da gradi a metri: a queste
# distanze (decine di metri) l'approssimazione piana e' piu' che adeguata.
LAT0 = 45.07
M_PER_DEG_LAT = 111_132.0
M_PER_DEG_LON = 111_320.0 * math.cos(math.radians(LAT0))


def to_m(lat: float, lon: float) -> tuple[float, float]:
    return (lat * M_PER_DEG_LAT, lon * M_PER_DEG_LON)


# Riquadro generoso attorno al bacino GTT. Serve a scartare le posizioni
# spazzatura: misurato il 31/07/2026, ~3% dei mezzi pubblica lat=0 lon=0
# (Null Island). Senza questo filtro sono 5.000 km di "fuori rotta" e
# qualunque soglia di deviazione produce un falso positivo garantito.
BBOX = (44.5, 45.6, 7.0, 8.3)  # lat_min, lat_max, lon_min, lon_max


def plausible(lat: float, lon: float) -> bool:
    return (BBOX[0] < lat < BBOX[1]) and (BBOX[2] < lon < BBOX[3])


def seg_dist(p, a, b) -> float:
    """Distanza punto-segmento in metri."""
    px, py = p
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def dist_to_shape(pt, shape) -> float:
    return min(seg_dist(pt, shape[i], shape[i + 1])
               for i in range(len(shape) - 1))


def load_gtfs(zip_path: Path):
    def rd(zf, name):
        with zf.open(name) as fh:
            yield from csv.DictReader((l.decode("utf-8-sig") for l in fh))

    with zipfile.ZipFile(zip_path) as zf:
        trip2shape, trip2route = {}, {}
        for t in rd(zf, "trips.txt"):
            trip2shape[t["trip_id"]] = t.get("shape_id") or ""
            trip2route[t["trip_id"]] = t["route_id"]
        raw = defaultdict(list)
        for s in rd(zf, "shapes.txt"):
            raw[s["shape_id"]].append((int(s["shape_pt_sequence"]),
                                       float(s["shape_pt_lat"]),
                                       float(s["shape_pt_lon"])))
    shapes = {k: [to_m(la, lo) for _, la, lo in sorted(v)]
              for k, v in raw.items() if len(v) > 1}
    return trip2shape, trip2route, shapes


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=3.0)
    ap.add_argument("--every", type=int, default=30)
    ap.add_argument("--gtfs", type=Path,
                    default=Path("data") / "gtt_gtfs-20260731.zip")
    args = ap.parse_args()

    if not args.gtfs.exists():
        cands = sorted(Path("data").glob("gtt_gtfs-*.zip"))
        if not cands:
            print("nessuno zip GTFS in data/", file=sys.stderr)
            return 1
        args.gtfs = cands[-1]

    print(f"Carico il GTFS da {args.gtfs} ...")
    trip2shape, trip2route, shapes = load_gtfs(args.gtfs)
    print(f"  {len(trip2shape):,} corse, {len(shapes):,} shape\n")

    n_samples = max(1, int(args.minutes * 60 / args.every))
    print(f"Burst: {n_samples} campioni ogni {args.every}s "
          f"(~{args.minutes:g} minuti)\n")

    # veicolo -> lista di (ts, lat, lon, trip_id, route_id)
    tracks: dict[str, list] = defaultdict(list)
    bytes_total = 0
    n_junk = [0]

    for i in range(n_samples):
        try:
            r = requests.get(RT, headers=UA, timeout=30)
            bytes_total += len(r.content)
            feed = gtfs_realtime_pb2.FeedMessage()
            feed.ParseFromString(r.content)
        except Exception as e:  # noqa: BLE001
            print(f"  campione {i+1}: errore {e}")
            continue
        n = junk = 0
        for e in feed.entity:
            if not e.HasField("vehicle"):
                continue
            v = e.vehicle
            if not v.HasField("position"):
                continue
            la, lo = v.position.latitude, v.position.longitude
            if not plausible(la, lo):
                junk += 1
                continue
            vid = v.vehicle.id or e.id
            tracks[vid].append((v.timestamp, la, lo,
                                v.trip.trip_id, v.trip.route_id))
            n += 1
        n_junk[0] += junk
        print(f"  campione {i+1}/{n_samples}: {n} mezzi"
              + (f"  ({junk} scartati: posizione implausibile)" if junk else ""))
        if i < n_samples - 1:
            time.sleep(args.every)

    print(f"\nTraffico totale: {bytes_total/1024:.0f} KB "
          f"({bytes_total/1024/n_samples:.0f} KB a campione)")
    print(f"Posizioni spazzatura scartate: {n_junk[0]} "
          f"(lat/lon fuori dal bacino GTT, tipicamente 0,0)")

    # ---------------------------------------------------- mezzi per linea
    per_route: dict[str, set] = defaultdict(set)
    for vid, pts in tracks.items():
        for _, _, _, _, rid in pts:
            if rid:
                per_route[rid].add(vid)

    print(f"\nMezzi distinti osservati: {len(tracks)}  su {len(per_route)} linee")
    top = sorted(per_route.items(), key=lambda kv: -len(kv[1]))[:10]
    print("  linee piu' coperte: " +
          ", ".join(f"{r}({len(v)})" for r, v in top))
    sizes = [len(v) for v in per_route.values()]
    print(f"  mezzi per linea: mediana {statistics.median(sizes):.0f}, "
          f"max {max(sizes)}, linee con 1 solo mezzo: "
          f"{sum(1 for s in sizes if s == 1)}")

    # ---------------------------------------------- spostamento in finestra
    moved = []
    for pts in tracks.values():
        if len(pts) < 2:
            continue
        a, b = to_m(pts[0][1], pts[0][2]), to_m(pts[-1][1], pts[-1][2])
        moved.append(math.hypot(a[0] - b[0], a[1] - b[1]))
    if moved:
        moved.sort()
        print(f"\nSpostamento nella finestra ({args.minutes:g} min): "
              f"mediana {statistics.median(moved):.0f} m, "
              f"90° pct {moved[int(len(moved)*0.9)]:.0f} m, "
              f"max {max(moved):.0f} m")
        print(f"  -> in 10 minuti, circa "
              f"{statistics.median(moved) * 10 / args.minutes / 1000:.1f} km "
              f"a mezzo (mediana)")

    # ------------------------------- distanza dal percorso teorico (il dato)
    dists, no_trip, no_shape = [], 0, 0
    for pts in tracks.values():
        for ts, la, lo, tid, rid in pts:
            if not tid:
                no_trip += 1
                continue
            sid = trip2shape.get(tid)
            if not sid or sid not in shapes:
                no_shape += 1
                continue
            dists.append(dist_to_shape(to_m(la, lo), shapes[sid]))

    if dists:
        dists.sort()
        def pc(p): return dists[min(len(dists) - 1, int(len(dists) * p))]
        print(f"\nDISTANZA DAL PERCORSO TEORICO  ({len(dists):,} posizioni "
              f"con trip_id risolto)")
        print(f"  mediana  {statistics.median(dists):7.1f} m")
        for p in (0.50, 0.75, 0.90, 0.95, 0.99):
            print(f"  {int(p*100):>3}° pct {pc(p):7.1f} m")
        print(f"  max      {max(dists):7.1f} m")
        for thr in (50, 80, 150, 300):
            n = sum(1 for d in dists if d > thr)
            print(f"  oltre {thr:>3} m: {n:>5}/{len(dists)}  "
                  f"({100*n/len(dists):.2f}%)")
        print(f"\n  posizioni senza trip_id: {no_trip}  "
              f"(shape mancante: {no_shape})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
