#!/usr/bin/env python3
"""
notify_diff.py — trasforma l'esito del diff in qualcosa che si fa notare.

Separato da daily_snapshot.sh apposta: cosi' il ramo "ha trovato qualcosa"
si puo' testare senza aspettare che il GTFS cambi davvero.

    python notify_diff.py validation/last_diff.json          # normale
    python notify_diff.py <file> --stamp 20260801 --dry-run  # test

Se ci sono cambiamenti: scrive validation/ALERT-<stamp>.md e manda una
notifica macOS. Se non ce ne sono, non fa nulla e non disturba.
Exit code: 0 = nessun cambiamento, 10 = cambiamenti segnalati.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def build_report(d: dict, stamp: str) -> str:
    out = [
        f"# Segnale A — {d['n_changes']} cambiamenti nel GTFS  ({stamp})",
        "",
        f"Confronto `{d['prev_captured_at']}` → `{d['curr_captured_at']}`",
        f"feed_version `{d['prev_feed_version']}` → `{d['curr_feed_version']}`",
        "",
        f"**Linee toccate:** {', '.join(d['lines_touched']) or '—'}",
        "",
        "L'ipotesi del Segnale A regge: GTT codifica le variazioni nel GTFS.",
        "Il passo successivo è verificare se questi cambiamenti corrispondono a",
        "deviazioni annunciate su <https://gtt.to.it/cms/variazioni> — se sì, il",
        "pattern diffing va al centro dell'architettura (spec §5.1).",
        "",
        "## Cambiamenti",
        "",
    ]
    for e in d["events"]:
        out.append(f"- **{e['kind']}** — {e['desc']}")
        # length_m ha forma diversa a seconda del tipo: intero per una shape
        # nuova, coppia [prima, dopo] per una geometria cambiata.
        if e["kind"] == "shape_nuova":
            out.append(f"  - {e['length_m']} m, {e['n_stops']} fermate, "
                       f"{e['n_trips']} corse")
        elif e["kind"] == "geometria_cambiata":
            a, b = e["length_m"]
            out.append(f"  - lunghezza {a} → {b} m ({e['delta_m']:+d} m)")
        if e.get("rimosse"):
            out.append(f"  - fermate non più servite: {', '.join(e['rimosse'])}")
        if e.get("aggiunte"):
            out.append(f"  - fermate aggiunte: {', '.join(e['aggiunte'])}")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("diff", type=Path)
    ap.add_argument("--stamp", default=datetime.now().strftime("%Y%m%d"))
    ap.add_argument("--outdir", type=Path, default=Path("validation"))
    ap.add_argument("--dry-run", action="store_true",
                    help="stampa e basta: non scrive file, non notifica")
    args = ap.parse_args()

    if not args.diff.exists():
        print(f"nessun diff da leggere: {args.diff}", file=sys.stderr)
        return 0

    d = json.loads(args.diff.read_text(encoding="utf-8"))
    n = d.get("n_changes", 0)
    if not n:
        print("nessun cambiamento, nessuna notifica")
        return 0

    report = build_report(d, args.stamp)
    lines = ", ".join(d["lines_touched"][:8]) or "—"
    title = f"GTT — Segnale A: {n} cambiamenti"

    if args.dry_run:
        print(f"[dry-run] notifica: {title!r} / linee {lines}")
        print(f"[dry-run] scriverei {args.outdir / f'ALERT-{args.stamp}.md'}:\n")
        print(report)
        return 10

    path = args.outdir / f"ALERT-{args.stamp}.md"
    path.write_text(report, encoding="utf-8")
    subprocess.run(
        ["osascript", "-e",
         f'display notification "Linee: {lines}" with title "{title}" '
         f'subtitle "Il GTFS è cambiato" sound name "Glass"'],
        check=False, capture_output=True)
    print(f"NOTIFICATO: {n} cambiamenti, linee {lines} -> {path}")
    return 10


if __name__ == "__main__":
    sys.exit(main())
