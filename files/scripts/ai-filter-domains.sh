#!/bin/bash
# =====================================================================
#  Exportiert die eigenen (aktiven) mailcow-Domains fuer den Checker.
#
#  Der Checker muss wissen, welche Domains "wir" sind - fuer interne
#  Post und fuer die Frage, ob eine Mail auf einen unserer Threads
#  verweist. Bis 12.11. fragte er das bei JEDER Mail selbst in der
#  mailcow-Datenbank ab und trug dafuer deren Passwort im Container: ein
#  Container, der Angreifer-Post liest und mit dem Internet spricht, mit
#  Zugriff auf Postfaecher, Passwort-Hashes und Aliase - fuer eine Spalte.
#
#  Jetzt liest dieses Skript die Spalte auf dem Host aus und legt sie als
#  Datei ab; der Container bekommt kein Datenbank-Passwort mehr.
#
#  Aufruf:
#    ai-filter-domains.sh            exportieren
#    ai-filter-domains.sh --status   Stand der Datei
#
#  Per Cron stuendlich. Eine neu angelegte Domain kennt der Checker also
#  spaetestens nach einer Stunde - oder sofort nach einem Aufruf von Hand.
# =====================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ACTION=export
case "${1:-}" in
    --status) ACTION=status ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1"; exit 1 ;;
esac

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }
cd "$MAILCOW_DIR" || exit 1

OUT="data/ai-checker/local_domains.json"

if [[ "$ACTION" == "status" ]]; then
    if [[ -f "$OUT" ]]; then
        echo -e "${GREEN}Vorhanden${NC}: $OUT ($(date -r "$OUT" '+%d.%m.%Y %H:%M'))"
        tr ',' '\n' < "$OUT" | tr -d '[]"' | sed 's/^/  /'
    else
        echo -e "${YELLOW}Noch nicht exportiert${NC} - ai-filter-domains.sh aufrufen"
    fi
    exit 0
fi

if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"
else echo -e "${RED}docker compose not found${NC}"; exit 1; fi

# shellcheck disable=SC1091
source mailcow.conf

DOMAINS=$($COMPOSE_CMD exec -T -e MYSQL_PWD="$DBPASS" mysql-mailcow \
    mysql -u"$DBUSER" "$DBNAME" -N -B \
    -e "SELECT domain FROM domain WHERE active = 1" 2>/dev/null \
    | tr -d '\r' | tr 'A-Z' 'a-z' | grep -E '^[a-z0-9._-]+$' | sort -u || true)

# Eine leere Antwort ist ein Fehler, keine Auskunft: Die vorhandene Datei
# bleibt dann stehen. Ohne Liste haelt der Checker vorsichtshalber jeden
# Thread-Bezug fuer einen eigenen und weist nichts mehr ab.
if [[ -z "$DOMAINS" ]]; then
    echo -e "${RED}Keine Domains gelesen${NC} - laeuft mysql-mailcow? Die bisherige Datei bleibt unveraendert."
    exit 1
fi

TMP=$(mktemp "$OUT.XXXXXX")
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$DOMAINS" | awk 'BEGIN{printf "["} {printf "%s\"%s\"", (NR>1?",":""), $0} END{print "]"}' > "$TMP"
chmod 644 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
echo -e "${GREEN}[OK]${NC} $(printf '%s\n' "$DOMAINS" | wc -l) Domains exportiert nach $OUT"
