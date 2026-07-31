#!/usr/bin/env python3
"""
build_fixtures.py — raccoglie il corpus di avvisi GTT reali per la Fase 2.

La specifica (§12.7) chiede almeno 30 avvisi REALI annotati a mano, da usare
come test set del parser LLM di §5.2.1. Questo script raccoglie il corpus e
prepara lo scheletro dell'annotazione; l'annotazione vera va fatta a mano.

DUE FONTI, COMPLEMENTARI
  - /cms/variazioni  : tabella HTML, 6 colonne, ~50 righe.
    Colonne gia' separate (linea/date/direzione/descrizione/motivo): i campi
    "meccanici" si prendono da li' senza interpretare nulla.
  - alerts.aspx      : ~180 ServiceAlert. Portano route_id CANONICO (96,7%),
    piu' cause/effect codificati. effect=4 (DETOUR) e' un pre-filtro utile.
    Misurato il 31/07/2026: la sovrapposizione col web e' bassa (~1 riga su 12),
    quindi le fonti vanno unite, non sostituite.

COSA COMPILA E COSA NO
  Compila solo cio' che e' MECCANICO (colonne HTML, campi protobuf).
  Lascia a null tutto cio' che richiede interpretazione (detach_point,
  via_sequence, rejoin_point, deviation_type): quelli sono il ground truth,
  e un ground truth generato da un LLM per valutare un LLM non misura nulla.

USO
    python build_fixtures.py --out tests/fixtures
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests
from bs4 import BeautifulSoup
from google.transit import gtfs_realtime_pb2

WEB_VARIAZIONI = "https://gtt.to.it/cms/variazioni"
RT_ALERTS = "https://percorsieorari.gtt.to.it/das_gtfsrt/alerts.aspx"
UA = {"User-Agent": ("gtt-deviazioni-validator/1.0 (progetto personale; "
                     "contatto: tommasocostanza7@gmail.com)")}

# Enum GTFS-Realtime, per leggibilita' delle fixture
CAUSE = {1: "UNKNOWN_CAUSE", 2: "OTHER_CAUSE", 3: "TECHNICAL_PROBLEM",
         4: "STRIKE", 5: "DEMONSTRATION", 6: "ACCIDENT", 7: "HOLIDAY",
         8: "WEATHER", 9: "MAINTENANCE", 10: "CONSTRUCTION",
         11: "POLICE_ACTIVITY", 12: "MEDICAL_EMERGENCY"}
EFFECT = {1: "NO_SERVICE", 2: "REDUCED_SERVICE", 3: "SIGNIFICANT_DELAYS",
          4: "DETOUR", 5: "ADDITIONAL_SERVICE", 6: "MODIFIED_SERVICE",
          7: "OTHER_EFFECT", 8: "UNKNOWN_EFFECT", 9: "STOP_MOVED"}

# Vocabolario di §1.4: serve a stratificare il campione, NON ad annotare.
# Marca solo quali categorie un testo *potrebbe* toccare, per scegliere cosa
# annotare per primo e non ritrovarsi 30 fixture tutte dello stesso tipo.
VOCAB = {
    "deviazione": r"deviat|prosegue per|si instrada|percorso normale",
    "limitazione": r"limitat|capolinea provvisorio|capolinea temporaneo",
    "inversione": r"inversione di marcia",
    "sostituzione_modale": r"gestit[ao] con autobus|gestione per autobus|autosnodat",
    "sospensione_fermate": r"fermat[ae].{0,40}(sospes|soppress)|sospension.{0,20}fermat",
    "fuori_torino": r"nel comune di",
}


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", s.lower())).strip()


def split_lines(raw: str) -> list[str]:
    """Best effort sulle linee citate. Non indovina: cio' che non riconosce
    resta in `line_hints_raw` (spec §4.1: loggare, non tirare a indovinare)."""
    parts = re.split(r"\s*[-–—/]\s*(?=\S)|\s{2,}", raw)
    out = []
    for p in parts:
        p = p.strip()
        if p and re.match(r"^[0-9A-Za-z][0-9A-Za-z+°/ ]{0,18}$", p):
            out.append(p)
    return out or [raw.strip()]


def tags_for(text: str) -> list[str]:
    t = text.lower()
    return [k for k, pat in VOCAB.items() if re.search(pat, t)]


def empty_expected() -> dict[str, Any]:
    """Scheletro dello schema di §5.2.1. Tutto null: da riempire a mano."""
    return {
        "deviation_type": None,
        "direction_desc": None,
        "municipality": None,
        "detach_point": None,
        "via_sequence": None,
        "rejoin_point": None,
        "suspended_stop_codes": None,
        "temporary_terminus": None,
        "ambiguities": [],
    }


def fetch_web() -> list[dict[str, Any]]:
    html = requests.get(WEB_VARIAZIONI, headers=UA, timeout=60).text
    soup = BeautifulSoup(html, "lxml")
    tables = soup.find_all("table")
    if not tables:
        print("  !! nessuna tabella: la pagina e' cambiata", file=sys.stderr)
        return []
    table = max(tables, key=lambda t: len(t.find_all("tr")))

    out = []
    for i, tr in enumerate(table.find_all("tr")[1:]):
        cells = [c.get_text(" ", strip=True) for c in tr.find_all(["td", "th"])]
        cells = [c for c in cells if c]
        if len(cells) < 5:
            continue
        line_raw, start, end, direction, descr = cells[:5]
        reason = cells[5] if len(cells) > 5 else None
        out.append({
            "id": f"web-{i:03d}",
            "sources": ["web_variazioni"],
            "source_urls": [WEB_VARIAZIONI],
            "line_hints_raw": line_raw,
            "line_hints": split_lines(line_raw),
            "route_ids": [],
            "raw_text": descr,
            "valid_from_raw": start,
            "valid_until_raw": None if end.strip() in ("-", "") else end,
            "direction_raw": direction,
            "reason": reason,
            "tags": tags_for(descr),
            "expected": empty_expected(),
            "annotated": False,
        })
    return out


def fetch_alerts() -> list[dict[str, Any]]:
    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(requests.get(RT_ALERTS, headers=UA, timeout=60).content)

    def txt(t):
        return t.translation[0].text if t.translation else ""

    out = []
    for i, e in enumerate(feed.entity):
        if not e.HasField("alert"):
            continue
        a = e.alert
        header, descr = txt(a.header_text), txt(a.description_text)
        full = f"{header} {descr}".strip()
        if not full:
            continue
        routes = sorted({ie.route_id for ie in a.informed_entity if ie.route_id})
        # Gli stop_id NON sono le fermate impattate ma tutte quelle della linea
        # (verificato su linea 82: 31 dichiarati = 31 fermate totali).
        # Li conservo solo come conteggio, per non indurre in errore.
        n_stops = len({ie.stop_id for ie in a.informed_entity if ie.stop_id})
        out.append({
            "id": f"alert-{i:03d}",
            "sources": ["gtfs_rt_alert"],
            "source_urls": [RT_ALERTS],
            "line_hints_raw": header,
            "line_hints": [],
            "route_ids": routes,
            "raw_text": full,
            "header": header,
            "valid_from_raw": None,
            "valid_until_raw": None,
            "direction_raw": None,
            "reason": CAUSE.get(a.cause),
            "effect": EFFECT.get(a.effect),
            "informed_stop_count": n_stops,
            "tags": tags_for(full),
            "expected": empty_expected(),
            "annotated": False,
        })
    return out


def merge(web: list[dict], alerts: list[dict], thr: float) -> list[dict]:
    """Unisce i duplicati fra le due fonti. Misurato: la sovrapposizione e'
    bassa, quindi quasi tutto resta separato — ma quando un avviso compare in
    entrambe, la versione web porta le date e l'alert porta il route_id."""
    merged = list(web)
    used: set[int] = set()
    for a in alerts:
        na = norm(a["raw_text"])
        best_i, best_r = None, 0.0
        for i, w in enumerate(merged):
            if i in used:
                continue
            r = difflib.SequenceMatcher(None, na, norm(w["raw_text"])).ratio()
            if r > best_r:
                best_i, best_r = i, r
        if best_i is not None and best_r >= thr:
            w = merged[best_i]
            w["sources"].append("gtfs_rt_alert")
            w["source_urls"].append(RT_ALERTS)
            w["route_ids"] = sorted(set(w["route_ids"]) | set(a["route_ids"]))
            w["effect"] = a.get("effect")
            w["merged_from"] = a["id"]
            w["merge_similarity"] = round(best_r, 3)
            w["tags"] = sorted(set(w["tags"]) | set(a["tags"]))
            used.add(best_i)
        else:
            merged.append(a)
    return merged


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="tests/fixtures")
    ap.add_argument("--threshold", type=float, default=0.75,
                    help="soglia di similarita' per considerare due avvisi lo stesso")
    args = ap.parse_args()

    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    print("Scarico /cms/variazioni ...")
    web = fetch_web()
    print(f"  {len(web)} righe")
    print("Scarico alerts.aspx ...")
    alerts = fetch_alerts()
    print(f"  {len(alerts)} alert")

    corpus = merge(web, alerts, args.threshold)
    n_merged = sum(1 for c in corpus if len(c["sources"]) > 1)
    print(f"\nCorpus: {len(corpus)} avvisi  ({n_merged} presenti in entrambe le fonti)")

    from collections import Counter
    tc = Counter(t for c in corpus for t in c["tags"])
    print("Copertura per categoria (§1.4):")
    for k in VOCAB:
        print(f"  {k:<22} {tc.get(k, 0):>4}")
    print(f"  {'nessuna categoria':<22} {sum(1 for c in corpus if not c['tags']):>4}")

    doc = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "note": ("Corpus di avvisi GTT reali. I campi in 'expected' sono il "
                 "ground truth del parser di §5.2.1 e vanno compilati A MANO: "
                 "generarli con un LLM per poi valutarci un LLM non misura nulla."),
        "attribution": "Dati: GTT S.p.A. — licenza CC-BY",
        "count": len(corpus),
        "notices": corpus,
    }
    path = outdir / "notices.json"
    path.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nScritto {path}  ({path.stat().st_size:,} B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
