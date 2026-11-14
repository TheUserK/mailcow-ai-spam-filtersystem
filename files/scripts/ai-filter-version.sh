#!/bin/bash
# =====================================================================
#  Meldet, wenn es eine neuere Fassung des Filters gibt.
#
#  Eingespielt wird nichts. Ein automatisches Update haette bedeutet: Wer
#  auf den Hauptzweig des Repositorys schreiben kann, fuehrt nachts Code
#  als root auf jedem Mailserver aus, auf allen gleichzeitig. Dieses
#  Skript fragt deshalb nur nach ("git fetch" - der Arbeitsstand im
#  Repository bleibt unberuehrt), vergleicht mit dem, was hier
#  INSTALLIERT ist, und schickt einmal pro Woche eine Mail an die
#  Report-Adresse, solange der Server zurueckliegt. Das Update bleibt ein
#  bewusster Handgriff.
#
#  Verglichen wird mit dem installierten Stand, nicht mit dem des
#  Repository-Ordners: Wer "git pull" gemacht, install.sh aber vergessen
#  hat, liegt ebenfalls zurueck - und merkt es sonst nicht.
#
#  Aufruf:
#    ai-filter-version.sh             Stand zeigen und nach Neuem sehen
#    ai-filter-version.sh --mail      Mail schicken, falls es Neues gibt (Cron)
#    ai-filter-version.sh --disable   die Wochenmail abstellen
#    ai-filter-version.sh --enable    wieder einschalten
#
#  Per Cron montags frueh. Empfaenger und Absender sind die des Reports
#  (ai-filter-report.sh --set-to / --from).
# =====================================================================
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

ACTION=print
case "${1:-}" in
    --mail)    ACTION=mail ;;
    --disable) ACTION=disable ;;
    --enable)  ACTION=enable ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

CONF="data/ai-checker/update.conf"
REPORT_CONF="data/ai-checker/report.conf"

conf_get() {   # $1 = Datei, $2 = Schluessel
    [[ -f "$1" ]] || return 0
    sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | head -1
}
conf_set() {   # $1 = Schluessel, $2 = Wert (nur update.conf)
    mkdir -p "$(dirname "$CONF")"
    ( umask 077; touch "$CONF" )
    if grep -q "^[[:space:]]*$1[[:space:]]*=" "$CONF"; then
        sed -i "s|^[[:space:]]*$1[[:space:]]*=.*|$1 = $2|" "$CONF"
    else
        printf '%s = %s\n' "$1" "$2" >> "$CONF"
    fi
}

case "$ACTION" in
disable) conf_set enabled false; echo -e "${GREEN}[OK]${NC} Wochenmail zu neuen Fassungen ist aus"; exit 0 ;;
enable)  conf_set enabled true;  echo -e "${GREEN}[OK]${NC} Wochenmail zu neuen Fassungen ist an"; exit 0 ;;
esac

ENABLED=$(conf_get "$CONF" enabled); [[ -z "$ENABLED" ]] && ENABLED=true
REPO=$(conf_get "$CONF" repo)
BRANCH=$(conf_get "$CONF" branch); [[ -z "$BRANCH" ]] && BRANCH=main
INSTALLED=$(conf_get "$CONF" installed)

# Im Cron-Lauf bei allem, was keine Auskunft ist, still enden: Ein
# Netzfehler am Montagmorgen ist keine Mail wert.
quiet_exit() {
    [[ "$ACTION" == "print" ]] && echo -e "${YELLOW}$1${NC}"
    exit 0
}

[[ "$ACTION" == "mail" && "$ENABLED" != "true" ]] && exit 0
[[ -n "$REPO" && -d "$REPO/.git" ]] \
    || quiet_exit "Kein Repository hinterlegt - install.sh aus einem git-Checkout ausfuehren."

# safe.directory: Das Repository kann einem anderen Benutzer gehoeren als
# dem, der hier laeuft (root per Cron).
g() { git -c safe.directory="$REPO" -C "$REPO" "$@"; }

GIT_TERMINAL_PROMPT=0 timeout 60 git -c safe.directory="$REPO" -C "$REPO" fetch --quiet origin "$BRANCH" 2>/dev/null \
    || quiet_exit "Repository nicht erreichbar - spaeter erneut versuchen."

# Unbekannter oder fehlender Vermerk (aeltere Installation): dann zaehlt
# der Stand des Repository-Ordners.
if [[ -z "$INSTALLED" ]] || ! g cat-file -e "$INSTALLED^{commit}" 2>/dev/null; then
    INSTALLED=$(g rev-parse HEAD 2>/dev/null) || quiet_exit "Repository nicht lesbar."
fi
LATEST=$(g rev-parse "origin/$BRANCH" 2>/dev/null) || quiet_exit "Zweig origin/$BRANCH nicht gefunden."

describe() { g log -1 --format='%h vom %ad' --date=format:'%d.%m.%Y' "$1" 2>/dev/null; }

if [[ "$INSTALLED" == "$LATEST" ]] || g merge-base --is-ancestor "$LATEST" "$INSTALLED" 2>/dev/null; then
    [[ "$ACTION" == "print" ]] && echo -e "${GREEN}Aktuell${NC}: installiert ist $(describe "$INSTALLED")."
    exit 0
fi

COUNT=$(g rev-list --count "$INSTALLED..$LATEST" 2>/dev/null || echo "?")
CHANGES=$(g log --reverse --format='  %ad  %s' --date=format:'%d.%m.' "$INSTALLED..$LATEST" 2>/dev/null | head -40)
HOST=$(sed -n 's/^MAILCOW_HOSTNAME=//p' mailcow.conf 2>/dev/null | tr -d '"' | head -1)
[[ -z "$HOST" ]] && HOST=$(hostname -f 2>/dev/null || hostname)

HEADLINE="AI-Filter: neuere Fassung verfuegbar auf $HOST ($COUNT Aenderungen)"
TEXT="$HEADLINE
$(printf '%.0s=' $(seq 1 ${#HEADLINE}))

Installiert:  $(describe "$INSTALLED")
Verfuegbar:   $(describe "$LATEST")

Was dazugekommen ist:
$CHANGES

Einspielen:
  cd $REPO && git pull origin $BRANCH && sudo ./install.sh --upgrade

Es wird nichts automatisch installiert. Diese Mail kommt montags, solange
der Server zurueckliegt.
  ai-filter-version.sh             Stand ansehen
  ai-filter-version.sh --disable   diese Mail abstellen
"

if [[ "$ACTION" == "print" ]]; then
    echo "$TEXT"
    exit 0
fi

TO=$(conf_get "$REPORT_CONF" report_to)
[[ -n "$TO" ]] || exit 0
FROM=$(conf_get "$REPORT_CONF" report_from)
[[ -z "$FROM" ]] && FROM="ai-filter@$HOST"

if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"
else exit 1; fi

# Direkt in den Postfix-Container - kein SMTP-Login, kein Postfach noetig.
printf 'From: %s\nTo: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
    "$FROM" "$TO" "$HEADLINE" "$TEXT" \
    | $COMPOSE_CMD exec -T postfix-mailcow sendmail -t
