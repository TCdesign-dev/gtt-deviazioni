#!/usr/bin/env python3
"""
check_annotations.py — verifica le fixture annotate prima di usarle come test set.

Controlli:
  1. ogni id annotato esiste nel corpus
  2. lo schema e' quello di §5.2.1 (chiavi presenti, deviation_type ammesso)
  3. >>> ogni toponimo annotato compare DAVVERO nel testo originale <<<
     E' il controllo che conta: smaschera le vie inventate, che sono
     esattamente il fallimento che §5.2.1 vieta ("Non inventare vie non
     presenti nel testo"). Vale sia per un LLM sia per un annotatore umano
     distratto.
  4. copertura per categoria, per sapere se il campione e' bilanciato

USO
    python check_annotations.py            # esce 1 se un controllo fallisce
"""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path

FIX = Path("tests/fixtures")
TYPES = {"deviazione", "limitazione", "inversione",
         "sostituzione_modale", "sospensione_fermate", "altro"}
REQUIRED = {"lines", "direction_desc", "deviation_type", "municipality",
            "detach_point", "via_sequence", "rejoin_point",
            "suspended_stop_codes", "temporary_terminus", "ambiguities"}


def norm(s: str) -> str:
    """Normalizza per il confronto: apostrofi tipografici, accenti sciolti,
    maiuscole, spazi. E' la stessa classe di problemi di §10.12."""
    s = unicodedata.normalize("NFC", s)
    s = s.replace("’", "'").replace("‘", "'").replace(" ", " ")
    return re.sub(r"\s+", " ", s.lower()).strip()


def main() -> int:
    corpus = {n["id"]: n for n in
              json.loads((FIX / "notices.json").read_text(encoding="utf-8"))["notices"]}
    ann = json.loads((FIX / "annotations.json").read_text(encoding="utf-8"))
    items = ann["annotations"]

    errors, warnings = [], []
    n_dev = 0
    types: Counter = Counter()
    conf: Counter = Counter()

    for nid, entry in items.items():
        if nid not in corpus:
            errors.append(f"{nid}: id assente dal corpus")
            continue
        raw = norm(corpus[nid]["raw_text"] + " " +
                   (corpus[nid].get("direction_raw") or "") + " " +
                   (corpus[nid].get("reason") or ""))
        conf[entry.get("confidence", "?")] += 1

        for i, d in enumerate(entry["deviations"]):
            n_dev += 1
            tag = f"{nid}[{i}]"

            missing = REQUIRED - d.keys()
            if missing:
                errors.append(f"{tag}: chiavi mancanti {sorted(missing)}")
            if d.get("deviation_type") not in TYPES:
                errors.append(f"{tag}: deviation_type '{d.get('deviation_type')}' non ammesso")
            else:
                types[d["deviation_type"]] += 1

            # --- il controllo che conta: niente toponimi inventati
            streets = [v["street"] for v in (d.get("via_sequence") or [])]
            for p in ("detach_point", "rejoin_point", "temporary_terminus"):
                pt = d.get(p)
                if isinstance(pt, dict):
                    streets += [pt.get("street"), pt.get("cross_street")]
            for s in [x for x in streets if x]:
                if norm(s) not in raw:
                    errors.append(f"{tag}: toponimo '{s}' NON presente nel testo originale")

            # i codici fermata devono comparire nel testo
            for c in (d.get("suspended_stop_codes") or []):
                if c not in raw:
                    errors.append(f"{tag}: codice fermata '{c}' non nel testo")
            tt = d.get("temporary_terminus")
            if isinstance(tt, dict) and tt.get("stop_code") and tt["stop_code"] not in raw:
                errors.append(f"{tag}: stop_code '{tt['stop_code']}' non nel testo")

            # coerenza interna
            if d["deviation_type"] == "sostituzione_modale" and streets:
                warnings.append(f"{tag}: sostituzione_modale con toponimi: "
                                "il percorso dovrebbe essere invariato (§10.10)")
            if d["deviation_type"] == "limitazione" and not d.get("temporary_terminus"):
                warnings.append(f"{tag}: limitazione senza temporary_terminus")

    print(f"Avvisi annotati : {len(items)}  su {len(corpus)} nel corpus")
    print(f"Oggetti deviation: {n_dev}")
    print(f"Per tipo        : {dict(types)}")
    print(f"Per confidenza  : {dict(conf)}")

    if warnings:
        print(f"\nAvvertimenti ({len(warnings)}):")
        for w in warnings:
            print(f"  ~ {w}")
    if errors:
        print(f"\nERRORI ({len(errors)}):")
        for e in errors:
            print(f"  ! {e}")
        return 1

    print("\nOK — nessun toponimo inventato, schema conforme.")
    if len(items) < 30:
        print(f"~~ ma sono solo {len(items)} avvisi: §12.7 ne chiede almeno 30")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
