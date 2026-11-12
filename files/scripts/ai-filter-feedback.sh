#!/bin/bash
# =====================================================================
#  Lernt aus dem, was die Empfaenger mit ihrer Post tun.
#
#  "Abonniert oder nicht" steht in keiner Mail - im Postfach schon:
#    - Post mit Spam-Kennzeichen, die im POSTEINGANG liegt, hat der
#      Empfaenger aus dem Junk zurueckgeholt  -> Absender erwuenscht
#    - Post OHNE Spam-Kennzeichen im JUNK hat er von Hand hineingeschoben
#                                              -> Absender unerwuenscht
#
#  Gelesen werden per doveadm ausschliesslich Kopfzeilen (From, das
#  Spam-Kennzeichen, Ablagedatum) der letzten Tage aus Posteingang und
#  Junk. Kein Betreff, kein Text, keine Anhaenge. Gespeichert wird je
#  Postfach und Absenderdomain nur "zurueckgeholt" oder "aussortiert" mit
#  Datum, in data/logs/ai-checker/relationship.sqlite (root, 0600). Nichts
#  davon verlaesst den Server.
#
#  Was der Checker damit macht, steht bei RELATIONSHIP_MODE in
#  ai-mail-checker.php. Vorgabe ist der Schattenmodus: Es wird
#  mitgeschrieben und im Log gezeigt, was es bewirkt haette.
#
#  Aufruf:
#    ai-filter-feedback.sh              Postfaecher lesen und uebernehmen
#    ai-filter-feedback.sh --dry-run    nur zeigen, was gefunden wuerde
#    ai-filter-feedback.sh --status     Stand der Datenbank
#    ai-filter-feedback.sh --show M     Eintraege eines Postfachs
#    ai-filter-feedback.sh --forget M [ABSENDER]
#                                       Eintraege eines Postfachs loeschen
#    ai-filter-feedback.sh --days N     Zeitraum (Vorgabe 14 Tage)
#
#  Postfaecher oder ganze Domains ausnehmen: eine Zeile je Angabe in
#  data/ai-checker/feedback_exclude.txt. Sinnvoll fuer Sammel- und
#  Archivpostfaecher, in denen niemand sortiert.
#
#  Per Cron einmal nachts.
# =====================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

ACTION=scan
ARG=""; ARG2=""
DAYS=14
DRY=""
# Ordnername des Junk-Ordners. mailcow legt "Junk" an.
JUNK_FOLDER="${AI_FILTER_JUNK_FOLDER:-Junk}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY="--dry-run"; shift ;;
        --status)  ACTION=status; shift ;;
        --show)    ACTION=show; ARG="${2:-}"; shift 2 ;;
        --forget)  ACTION=forget; ARG="${2:-}"; ARG2="${3:-}"
                   if [[ -n "$ARG2" && "$ARG2" != --* ]]; then shift 3; else ARG2=""; shift 2; fi ;;
        --days)    DAYS="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ "$DAYS" =~ ^[0-9]+$ && "$DAYS" -ge 1 ]] || { echo -e "${RED}--days needs a positive number${NC}"; exit 1; }

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }
cd "$MAILCOW_DIR" || exit 1

if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"
else echo -e "${RED}docker compose not found${NC}"; exit 1; fi

DB="data/logs/ai-checker/relationship.sqlite"

need_sqlite() {
    command -v sqlite3 >/dev/null || { echo -e "${RED}sqlite3 is required${NC} - apt install sqlite3"; exit 1; }
    [[ -f "$DB" ]] || { echo -e "${YELLOW}Noch keine Datenbank${NC} - erst ai-filter-feedback.sh laufen lassen"; exit 0; }
}
# Einfache Anfuehrungszeichen fuer SQL verdoppeln.
sq() { printf '%s' "${1//\'/\'\'}" | tr 'A-Z' 'a-z'; }

case "$ACTION" in
status)
    need_sqlite
    echo "Datenbank:      $DB ($(du -h "$DB" | cut -f1))"
    echo "Zurueckgeholt:  $(sqlite3 "$DB" "SELECT COUNT(*) FROM feedback WHERE verdict='rescued'")"
    echo "Aussortiert:    $(sqlite3 "$DB" "SELECT COUNT(*) FROM feedback WHERE verdict='junked'")"
    echo "Postfaecher:    $(sqlite3 "$DB" "SELECT COUNT(DISTINCT rcpt) FROM feedback")"
    echo "Historie:       $(sqlite3 "$DB" "SELECT COUNT(*) FROM history") Absender/Postfach-Paare"
    echo "Modus:          $($COMPOSE_CMD exec -T ai-checker printenv AI_FILTER_RELATIONSHIP_MODE 2>/dev/null || echo 'shadow (Vorgabe)')"
    exit 0 ;;
show)
    [[ -n "$ARG" ]] || { echo "Usage: ai-filter-feedback.sh --show postfach@domain"; exit 1; }
    need_sqlite
    echo "Entscheidungen von $ARG:"
    sqlite3 -separator '  ' "$DB" "SELECT verdict, sender, date(ts,'unixepoch') FROM feedback WHERE rcpt='$(sq "$ARG")' ORDER BY ts DESC"
    echo ""
    echo "Historie (Posteingang/gesamt, seit):"
    sqlite3 -separator '  ' "$DB" "SELECT inbox || '/' || seen, sender, date(first_seen,'unixepoch') FROM history WHERE rcpt='$(sq "$ARG")' ORDER BY seen DESC LIMIT 40"
    exit 0 ;;
forget)
    [[ -n "$ARG" ]] || { echo "Usage: ai-filter-feedback.sh --forget postfach@domain [absender]"; exit 1; }
    need_sqlite
    where="rcpt='$(sq "$ARG")'"
    [[ -n "$ARG2" ]] && where="$where AND sender='$(sq "$ARG2")'"
    sqlite3 "$DB" "DELETE FROM feedback WHERE $where; DELETE FROM history WHERE $where;"
    echo -e "${GREEN}Geloescht${NC}: $ARG ${ARG2:+/ $ARG2}"
    exit 0 ;;
esac

# --- Postfaecher lesen ------------------------------------------------
[[ -f data/ai-checker/feedback-import.php ]] \
    || { echo -e "${RED}data/ai-checker/feedback-import.php fehlt${NC} - install.sh erneut ausfuehren"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

FIELDS='user date.saved hdr.x-spam-flag hdr.x-spam hdr.from'

# -A geht alle Postfaecher durch. Ein einzelnes kaputtes Postfach laesst
# doveadm mit Fehlercode enden, liefert die uebrigen aber trotzdem -
# deshalb zaehlt hier, ob ueberhaupt etwas kam, nicht der Rueckgabewert.
fetch() {   # $1 = Kennung, $2 = Ordner
    $COMPOSE_CMD exec -T dovecot-mailcow doveadm -f tab fetch -A "$FIELDS" \
        mailbox "$2" savedsince "${DAYS}d" 2>>"$TMP/doveadm.err" \
        | sed "s/^/$1\t/" >> "$TMP/mails.tsv" || true
}
: > "$TMP/mails.tsv"
fetch INBOX INBOX
fetch JUNK "$JUNK_FOLDER"

if [[ ! -s "$TMP/mails.tsv" ]]; then
    echo -e "${YELLOW}doveadm hat nichts geliefert${NC}"
    [[ -s "$TMP/doveadm.err" ]] && head -5 "$TMP/doveadm.err"
    exit 1
fi

$COMPOSE_CMD exec -T ai-checker php /app/feedback-import.php $DRY < "$TMP/mails.tsv"
