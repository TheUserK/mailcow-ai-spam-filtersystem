#!/bin/bash
# =====================================================================
#  ai-checker-Image aktuell halten
#
#  Der Container wird lokal gebaut, nicht gepullt. Ohne Zutun bleibt er
#  deshalb fuer immer auf dem Stand des ersten Installs: "up --build" nimmt
#  das Basis-Image aus dem Cache, und mailcows update.sh fasst einen nur
#  gebauten Dienst gar nicht an. PHP-Patches und Debian-Sicherheitsupdates
#  kamen so nie an.
#
#  Dieses Skript baut mit frischem php:8-cli neu und schaltet nur um, wenn
#  der neue Container nachweislich funktioniert:
#    1. Bauen. Schlaegt das fehl, laeuft der alte Container einfach weiter.
#    2. Das neue Image VOR dem Umschalten pruefen: pdo_mysql und pdo_sqlite
#       vorhanden, der Checker laeuft unter der neuen PHP-Version durch.
#    3. Umschalten und auf "healthy" warten. Wird er das nicht, wird auf
#       das vorherige Image zurueckgedreht.
#  Probleme gehen per Mail an die Adresse von ai-filter-report.sh. Ein
#  erfolgreiches Update bleibt still - steht nur im Log.
#
#  Aufruf:
#    ai-filter-update-image.sh            neu bauen und umschalten
#    ai-filter-update-image.sh --status   PHP-Version, Alter des Images
#    ai-filter-update-image.sh --cron     wie ohne Option, Ausgabe nur ins Log
# =====================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

MODE=run
case "${1:-}" in
    "")          ;;
    --cron)      MODE=cron ;;
    --status)    MODE=status ;;
    -h|--help)   sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "Unknown option: $1 (--status, --cron, --help)"; exit 1 ;;
esac

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }
cd "$MAILCOW_DIR" || exit 1

if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"
else echo -e "${RED}Docker Compose not found${NC}"; exit 1; fi

CONTAINER="mailcow-ai-checker"
ROLLBACK_TAG="mailcow-ai-checker:rollback"
LOGFILE="data/logs/ai-checker/image-update.log"
CONF="data/ai-checker/report.conf"
BUILD_LOG=$(mktemp); trap 'rm -f "$BUILD_LOG"' EXIT

say() {
    local line
    line="$(date '+%Y-%m-%d %H:%M') $(printf '%s' "$*" | sed 's/\\033\[[0-9;]*m//g')"
    mkdir -p "$(dirname "$LOGFILE")"
    echo "$line" >> "$LOGFILE"
    [[ "$MODE" == "cron" ]] || echo -e "$*"
}

conf_get() {
    [[ -f "$CONF" ]] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | head -1
}

# Gleicher Weg wie ai-filter-report.sh: direkt in den Postfix-Container.
notify() {
    local subject="$1" body="$2" to from host
    to=$(conf_get report_to)
    [[ -n "$to" && "$(conf_get enabled)" != "false" ]] || return 0
    from=$(conf_get report_from)
    if [[ -z "$from" ]]; then
        host=$(sed -n 's/^MAILCOW_HOSTNAME=//p' mailcow.conf 2>/dev/null | tr -d '"' | head -1)
        from="ai-filter@${host:-$(hostname -f 2>/dev/null || hostname)}"
    fi
    printf 'From: %s\nTo: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "$from" "$to" "AI-Filter: $subject" "$body" \
        | $COMPOSE_CMD exec -T postfix-mailcow sendmail -t >/dev/null 2>&1
}

image_ref()   { docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null; }
running_id()  { docker inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null; }
image_id()    { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null; }
php_in()      { docker run --rm --entrypoint php "$1" -r 'echo PHP_VERSION;' 2>/dev/null; }

wait_healthy() {
    local status
    for _ in $(seq 1 30); do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
                 "$CONTAINER" 2>/dev/null)
        [[ "$status" == "healthy" ]] && return 0
        [[ "$status" == "unhealthy" || "$status" == "exited" ]] && return 1
        sleep 4
    done
    return 1
}

if [[ "$MODE" == "status" ]]; then
    ID=$(running_id)
    [[ -n "$ID" ]] || { echo -e "${RED}$CONTAINER laeuft nicht${NC}"; exit 1; }
    CREATED=$(docker image inspect --format '{{.Created}}' "$ID" 2>/dev/null)
    AGE=$(( ( $(date +%s) - $(date -d "$CREATED" +%s 2>/dev/null || date +%s) ) / 86400 ))
    echo
    echo "PHP im Container: $(docker exec "$CONTAINER" php -r 'echo PHP_VERSION;' 2>/dev/null)"
    echo "Image gebaut:     ${CREATED%%.*} (vor $AGE Tagen)"
    if image_id "$ROLLBACK_TAG" >/dev/null; then
        echo "Rollback-Image:   PHP $(php_in "$ROLLBACK_TAG")"
    fi
    if [[ -f "$LOGFILE" ]]; then
        echo
        echo "Letzte Laeufe:"
        tail -5 "$LOGFILE" | sed 's/^/  /'
    fi
    echo
    exit 0
fi

REF=$(image_ref)
OLD_ID=$(running_id)
OLD_PHP=""
PREV_ROLLBACK=$(image_id "$ROLLBACK_TAG")
if [[ -n "$OLD_ID" ]]; then
    OLD_PHP=$(docker exec "$CONTAINER" php -r 'echo PHP_VERSION;' 2>/dev/null)
    docker tag "$OLD_ID" "$ROLLBACK_TAG"
fi

# --- 1. Bauen ---------------------------------------------------------
[[ "$MODE" == "cron" ]] || echo "Baue ai-checker mit frischem Basis-Image ..."
if ! $COMPOSE_CMD build --pull ai-checker >"$BUILD_LOG" 2>&1; then
    say "${RED}[FAIL]${NC} Build fehlgeschlagen - der bisherige Container laeuft unveraendert weiter"
    notify "Image-Update fehlgeschlagen" "Der Neubau des ai-checker-Images ist fehlgeschlagen.
Der bisherige Container (PHP ${OLD_PHP:-?}) laeuft unveraendert weiter.

Letzte Zeilen des Builds:
$(tail -25 "$BUILD_LOG")

Von Hand nachvollziehen: cd $MAILCOW_DIR && $COMPOSE_CMD build --pull ai-checker"
    exit 1
fi

[[ -n "$REF" ]] || REF=$($COMPOSE_CMD config --images ai-checker 2>/dev/null | head -1)
NEW_ID=$(image_id "$REF")
if [[ -n "$OLD_ID" && "$NEW_ID" == "$OLD_ID" ]]; then
    say "${GREEN}[OK]${NC} Nichts Neues - Image unveraendert (PHP $OLD_PHP)"
    exit 0
fi
NEW_PHP=$(php_in "$REF")

# Zuruecksetzen auf das alte Image, falls etwas schiefgeht. Danach baut
# compose beim naechsten "up" nicht neu, sondern nimmt genau dieses.
restore_old() {
    [[ -n "$OLD_ID" ]] || return 1
    docker tag "$OLD_ID" "$REF" && $COMPOSE_CMD up -d ai-checker >/dev/null 2>&1
}

# --- 2. Neues Image pruefen, bevor es Post sieht ------------------------
PROBLEM=""
MODULES=$(docker run --rm --entrypoint php "$REF" -m 2>/dev/null)
for ext in pdo_mysql pdo_sqlite curl json mbstring; do
    grep -qix "$ext" <<<"$MODULES" || PROBLEM+="PHP-Erweiterung $ext fehlt. "
done
# Der Checker selbst: ohne Eingabe muss er sauber mit "Invalid JSON input"
# antworten. Das laedt die ganze Datei unter der neuen PHP-Version - ein
# Syntax- oder Startfehler faellt hier auf und nicht erst an echter Post.
SMOKE=$(docker run --rm -v "$MAILCOW_DIR/data/ai-checker:/app:ro" -w /app --entrypoint php "$REF" \
        -d display_errors=stderr ai-mail-checker.php </dev/null 2>&1)
grep -q 'Invalid JSON input' <<<"$SMOKE" || PROBLEM+="Checker startet nicht: $(head -c 400 <<<"$SMOKE"). "

if [[ -n "$PROBLEM" ]]; then
    restore_old || docker tag "$OLD_ID" "$REF" 2>/dev/null
    say "${RED}[FAIL]${NC} Neues Image (PHP $NEW_PHP) besteht die Pruefung nicht - nicht umgeschaltet: $PROBLEM"
    notify "Image-Update zurueckgehalten" "Das neue ai-checker-Image (PHP $NEW_PHP) hat die Pruefung vor dem
Umschalten nicht bestanden und wurde NICHT in Betrieb genommen.
Es laeuft weiter: PHP ${OLD_PHP:-?}.

$PROBLEM"
    exit 1
fi

# --- 3. Umschalten ------------------------------------------------------
$COMPOSE_CMD up -d ai-checker >/dev/null 2>&1
if wait_healthy; then
    say "${GREEN}[OK]${NC} ai-checker aktualisiert: PHP ${OLD_PHP:-?} -> $NEW_PHP"
    if [[ -n "$PREV_ROLLBACK" && "$PREV_ROLLBACK" != "$OLD_ID" && "$PREV_ROLLBACK" != "$NEW_ID" ]]; then
        docker image rm "$PREV_ROLLBACK" >/dev/null 2>&1 || true
    fi
    exit 0
fi

if restore_old && wait_healthy; then
    OUTCOME="Zurueckgedreht auf PHP $OLD_PHP, der Filter laeuft wieder."
else
    OUTCOME="ACHTUNG: Auch das Zurueckdrehen hat nicht geklappt - bitte sofort ansehen:
  cd $MAILCOW_DIR && $COMPOSE_CMD logs --tail=50 ai-checker"
fi
say "${RED}[FAIL]${NC} Neuer Container (PHP $NEW_PHP) wurde nicht healthy. $OUTCOME"
notify "Image-Update zurueckgedreht" "Der neue ai-checker-Container (PHP $NEW_PHP) ist nach dem Umschalten
nicht healthy geworden.

$OUTCOME

Bis zur Klaerung baut der woechentliche Lauf es erneut und dreht bei
Bedarf wieder zurueck. Logs: $COMPOSE_CMD logs ai-checker"
exit 1
