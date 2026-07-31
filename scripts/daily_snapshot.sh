#!/bin/zsh
# Snapshot + diff giornaliero del GTFS statico GTT — test del Segnale A.
# Lanciato da launchd alle 05:00 (il GTFS di GTT viene rigenerato alle 04:00).
# Vedi docs/FASE-0-RISULTATI.md §7.
#
# Se il diff trova qualcosa lo fa NOTARE (notifica macOS + ALERT-*.md) invece
# di seppellirlo nel log: un risultato che nessuno legge non e' un risultato,
# ed e' proprio il caso in cui il Segnale A si sta dimostrando vero.
# La notifica sta in notify_diff.py, separata, cosi' e' testabile da sola.

set -u
PROJ="/Users/tommasocostanza/Projects/gtt-deviazioni"
cd "$PROJ" || exit 1

mkdir -p validation/logs
STAMP=$(date +%Y%m%d)
LOG="validation/logs/daily-${STAMP}.log"
PY="./.venv/bin/python"

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
  $PY scripts/snapshot_gtfs.py --out ./validation --compare
  echo "snapshot exit=$?"
  $PY scripts/notify_diff.py validation/last_diff.json --stamp "$STAMP"
  echo "notify exit=$?"
} >> "$LOG" 2>&1

# Retention: tengo solo gli ultimi 3 zip GTFS (24 MB l'uno) e 30 giorni di log.
ls -1t data/gtt_gtfs-*.zip 2>/dev/null | tail -n +4 | while read -r f; do rm -f "$f"; done
find validation/logs -name 'daily-*.log' -mtime +30 -delete 2>/dev/null

exit 0
