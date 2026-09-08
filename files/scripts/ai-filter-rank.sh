#!/bin/bash
# =====================================================================
#  Domain-Rang-Datenbank aus der Majestic Million erzeugen
#
#  Anders als die Markenliste (ai-filter-brands.sh, nur Top 10000, nur
#  Marken-Namen) haelt diese Datei den Rang JEDER der vollen 1 Million
#  Domains vor. Zweck: dem Modell mitgeben, wie etabliert eine
#  Absenderdomain ist - nicht als hartes Ja/Nein, sondern als Zahl, die
#  es selbst gewichten kann. Tchibo, Zooplus & Co. sind in Deutschland
#  bekannte Firmen, liegen aber weit ausserhalb der globalen Top 10000
#  (Tchibo: Rang 23080), weil Majestic weltweit misst - eine feste
#  Schwelle waere hier immer willkuerlich.
#
#  Warum SQLite statt Textdatei/PHP-Array: eine Million Zeilen im
#  PHP-Array kostet ~120 MB RAM - UND ZWAR PRO WORKER-PROZESS. Der
#  Checker laeuft mit PHP_CLI_SERVER_WORKERS=4, also ~480 MB nur fuer
#  diese eine Liste. SQLite liest nur die Seiten von der Platte, die
#  eine einzelne Abfrage braucht, und der Betriebssystem-Seiten-Cache
#  wird automatisch von allen 4 Workern geteilt - gemessen: praktisch
#  0 MB PHP-Speicher pro Abfrage, 0.2-1.2 ms Antwortzeit.
#
#  Quelle: Majestic Million, https://majestic.com/reports/majestic-million
#  Lizenz: Creative Commons Attribution 3.0 Unported (CC BY 3.0)
#          https://creativecommons.org/licenses/by/3.0/
#          (c) Majestic-12 Ltd
#
#  Die erzeugte Datei bleibt auf DIESEM Server und wird bewusst nicht
#  mit dem Projekt ausgeliefert - wie bei ai-filter-brands.sh.
#
#  Aufruf:
#    ai-filter-rank.sh              erzeugen/aktualisieren (volle Liste)
#    ai-filter-rank.sh --show D     Rang einer Domain nachsehen
#    ai-filter-rank.sh --status     Stand der vorhandenen Datenbank
#
#  Per Cron einmal woechentlich - haeufiger bringt nichts, die Liste
#  bewegt sich kaum.
# =====================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

SOURCE_URL="https://downloads.majestic.com/majestic_million.csv"
ACTION=build
ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --show)   ACTION=show; ARG="${2:-}"; shift 2 ;;
        --status) ACTION=status; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

command -v sqlite3 >/dev/null || { echo -e "${RED}sqlite3 is required${NC} - apt install sqlite3"; exit 1; }

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }
cd "$MAILCOW_DIR" || exit 1

OUT="data/ai-checker/domain_ranks.sqlite"

if [[ "$ACTION" == "status" ]]; then
    if [[ -f "$OUT" ]]; then
        echo -e "${GREEN}Vorhanden${NC}: $OUT"
        echo "  Domains:     $(sqlite3 "$OUT" 'SELECT COUNT(*) FROM ranks' 2>/dev/null || echo '?')"
        echo "  Groesse:     $(du -h "$OUT" | cut -f1)"
        echo "  Erzeugt am:  $(date -r "$OUT" '+%d.%m.%Y %H:%M')"
    else
        echo -e "${YELLOW}Noch nicht erzeugt${NC} - ai-filter-rank.sh aufrufen"
    fi
    exit 0
fi

if [[ "$ACTION" == "show" ]]; then
    [[ -f "$OUT" ]] || { echo -e "${RED}Datenbank fehlt${NC}"; exit 1; }
    row=$(sqlite3 -separator ' / ' "$OUT" "SELECT global_rank, tld_rank FROM ranks WHERE domain = '${ARG//\'/}'")
    if [[ -n "$row" ]]; then
        echo -e "${GREEN}$ARG${NC}: Rang $row (global / TLD)"
    else
        echo -e "${YELLOW}'$ARG' steht nicht in den Top 1 Million${NC}"
    fi
    exit 0
fi

# --- Bauen ------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "Lade Majestic Million (~80 MB) ..."
if ! curl -fsSL --max-time 300 "$SOURCE_URL" -o "$TMP/million.csv"; then
    echo -e "${RED}Download fehlgeschlagen${NC} - vorhandene Datenbank bleibt unveraendert."
    exit 1
fi

# Spalten: GlobalRank,TldRank,Domain,TLD,RefSubNets,RefIPs,...
tail -n +2 "$TMP/million.csv" | awk -F, '
    { gsub(/[\r"]/, "", $1); gsub(/[\r"]/, "", $2); gsub(/[\r"]/, "", $3)
      if ($1 != "" && $3 != "") print $3 "\t" $1 "\t" $2 }
' > "$TMP/domain_rank.tsv"

ROWS=$(wc -l < "$TMP/domain_rank.tsv" | tr -d ' ')
if [[ "$ROWS" -lt 100000 ]]; then
    echo -e "${RED}Nur $ROWS Zeilen erkannt${NC} - das sieht nach einem Formatwechsel aus."
    echo "Erwartet werden die Spalten: GlobalRank,TldRank,Domain,TLD,..."
    echo "Vorhandene Datenbank bleibt unveraendert."
    exit 1
fi

echo "Baue Datenbank aus $ROWS Zeilen ..."
sqlite3 "$TMP/ranks.sqlite" <<SQL
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
CREATE TABLE ranks (domain TEXT, global_rank INTEGER, tld_rank INTEGER);
.mode tabs
.import '$TMP/domain_rank.tsv' ranks
CREATE INDEX idx_domain ON ranks(domain);
SQL

mkdir -p data/ai-checker
mv "$TMP/ranks.sqlite" "$OUT"
chmod 644 "$OUT"

echo -e "${GREEN}[OK]${NC} $ROWS Domains nach $OUT geschrieben"
echo "     Pruefen mit: ai-filter-rank.sh --show tchibo.de"
