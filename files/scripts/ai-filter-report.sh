#!/bin/bash
# Reports the cases where the filter contradicts itself.
#
# Every mistake this filter has had was found the same way: somebody read a
# log line, thought it looked odd, and it turned out to be a bug. That is
# luck as a method. The filter knows its own doubtful cases though - a
# phishing verdict on a DMARC-clean sender, a rejection of a German business
# domain, a high Rspamd score the AI called legitimate. Those were exactly
# the hotel, the school, the survey firm and the Google account mail.
#
# Quiet when there is nothing to report, so "running well" means silence.

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'

usage() {
    cat <<'USAGE'
Usage: ai-filter-report.sh [OPTIONS]

  (no option)        print the report for the last 24 hours
  -d DAYS            look back DAYS days (default 1)
  --mail             send it by mail instead of printing (used by cron)
  --to ADDRESS       send to this address once, without storing it
  --set-to ADDRESS   store the recipient address
  --from ADDRESS     store the sender address (default ai-filter@<hostname>)
  --enable           allow mail delivery
  --disable          stop mail delivery; the report still prints
  --status           show the stored settings
  -h, --help         this text

Nothing to report means no mail. Silence is the normal state.
USAGE
}

DAYS=1
ACTION=print
ARG=""
ONCE_TO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)         DAYS="${2:-1}"; shift 2 ;;
        --mail)     ACTION=mail; shift ;;
        --to)       ONCE_TO="${2:-}"; ACTION=mail; shift 2 ;;
        --set-to)   ACTION=setto; ARG="${2:-}"; shift 2 ;;
        --from)     ACTION=setfrom; ARG="${2:-}"; shift 2 ;;
        --enable)   ACTION=enable; shift ;;
        --disable)  ACTION=disable; shift ;;
        --status)   ACTION=status; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Unknown option: $1"; echo; usage; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo -e "${RED}jq is required${NC} - apt install jq"; exit 1; }

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }
cd "$MAILCOW_DIR" || exit 1

CONF="data/ai-checker/report.conf"
LOG="data/logs/ai-checker/stats.log"

conf_get() {
    [[ -f "$CONF" ]] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | head -1
}

conf_set() {
    mkdir -p "$(dirname "$CONF")"
    umask 077
    touch "$CONF"
    if grep -q "^[[:space:]]*$1[[:space:]]*=" "$CONF"; then
        sed -i "s|^[[:space:]]*$1[[:space:]]*=.*|$1 = $2|" "$CONF"
    else
        printf '%s = %s\n' "$1" "$2" >> "$CONF"
    fi
    chmod 600 "$CONF"
    chown root:root "$CONF" 2>/dev/null || true
}

REPORT_TO=$(conf_get report_to)
REPORT_FROM=$(conf_get report_from)
ENABLED=$(conf_get enabled)
[[ -z "$ENABLED" ]] && ENABLED=true
# Vorgabe fuer den Absender. `hostname` liefert auf mailcow-Servern gern
# nur "mailcow" - keine Domain, also scheitern SPF, DKIM und DMARC beim
# Empfaenger und ausgerechnet die Ueberwachungsmail landet im Spam.
# MAILCOW_HOSTNAME aus mailcow.conf ist dagegen ein echter FQDN.
if [[ -z "$REPORT_FROM" ]]; then
    MC_HOST=$(sed -n 's/^MAILCOW_HOSTNAME=//p' mailcow.conf 2>/dev/null | tr -d '"' | head -1)
    [[ -z "$MC_HOST" ]] && MC_HOST=$(hostname -f 2>/dev/null || hostname)
    REPORT_FROM="ai-filter@$MC_HOST"
fi

# Ohne Punkt in der Domain ist die Adresse nicht zustellbar.
from_domain_ok() {
    local d="${1##*@}"
    [[ "$d" == *.* ]]
}

case "$ACTION" in
setto)
    [[ "$ARG" == *@* ]] || { echo -e "${RED}--set-to braucht eine Mailadresse${NC}"; exit 1; }
    conf_set report_to "$ARG"
    echo -e "${GREEN}[OK]${NC} Report geht an $ARG"
    exit 0 ;;
setfrom)
    [[ "$ARG" == *@* ]] || { echo -e "${RED}--from braucht eine Mailadresse${NC}"; exit 1; }
    conf_set report_from "$ARG"
    echo -e "${GREEN}[OK]${NC} Absender: $ARG"
    exit 0 ;;
enable)
    conf_set enabled true;  echo -e "${GREEN}[OK]${NC} Mailversand an"; exit 0 ;;
disable)
    conf_set enabled false; echo -e "${GREEN}[OK]${NC} Mailversand aus - der Report laesst sich weiter manuell aufrufen"; exit 0 ;;
status)
    echo
    echo "Empfaenger: ${REPORT_TO:-(nicht gesetzt - nur Ausgabe auf dem Terminal)}"
    if from_domain_ok "$REPORT_FROM"; then
        echo "Absender:   $REPORT_FROM"
    else
        echo -e "Absender:   ${RED}$REPORT_FROM${NC} - keine gueltige Domain!"
        echo -e "            ${YELLOW}Der Report wird beim Empfaenger als Spam landen.${NC}"
        echo    "            Setzen mit: ai-filter-report.sh --from ai-filter@deine-domain.de"
    fi
    echo "Versand:    $ENABLED"
    echo
    exit 0 ;;
esac

[[ -f "$LOG" ]] || { echo -e "${YELLOW}Kein Log:${NC} $LOG"; exit 0; }

SINCE=$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || SINCE=""
[[ -n "$SINCE" ]] || { echo -e "${RED}date -d wird nicht unterstuetzt${NC}"; exit 1; }

# Rotierte Logs mitlesen - bei -d 7 reicht die aktive Datei nicht.
read_logs() {
    local f n
    for f in "$LOG".[0-9]*; do
        [[ -e "$f" ]] || continue
        n=${f#"$LOG".}; n=${n%%.*}
        [[ $n =~ ^[0-9]+$ ]] && printf '%s\t%s\n' "$n" "$f"
    done | sort -k1,1rn | cut -f2- | while IFS= read -r f; do
        case "$f" in *.gz) zcat -- "$f" 2>/dev/null ;; *) cat -- "$f" 2>/dev/null ;; esac
    done
    cat -- "$LOG" 2>/dev/null
}

# --- Die Widersprüche ---------------------------------------------------
# Jeder Eintrag: Bezeichnung + jq-Bedingung. Sie beschreiben Faelle, in
# denen zwei Teile des Systems verschiedener Meinung sind - genau dort
# lagen bisher alle Fehlurteile.
render_group() {
    local titel="$1" beschreibung="$2" bedingung="$3"
    local out
    out=$(read_logs | jq -r --arg since "$SINCE" "
        select(.timestamp >= \$since) |
        select($bedingung) |
        [ (.timestamp|sub(\"\\\\+00:00$\";\"Z\")|fromdateiso8601|strflocaltime(\"%d.%m. %H:%M\")),
          ((.ai_score // 0)|tostring),
          (.category // \"-\"),
          (.from // \"-\"),
          ((if .reject_eligible then \"REJECT \" else \"\" end) + ((.evidence // [])|join(\",\"))),
          (.subject // \"\")
        ] | @tsv" 2>/dev/null \
        | awk -F'\t' '{ printf "    %-14s %7s  %-13s %-32s %-30s %s\n", $1,$2,$3,$4,$5,$6 }')

    [[ -z "$out" ]] && return 1
    echo
    echo "  $titel"
    echo "  $beschreibung"
    echo "$out"
    return 0
}

FOUND=0
BODY=$(
    # 1. Abgewiesen, obwohl der Absender per DMARC beglaubigt ist.
    #    Das war die Google-Kontomail.
    render_group "Abgewiesen trotz bestandener Authentifizierung" \
        "$(printf 'Der Absender ist beglaubigt - eine Ablehnung ist hier fast immer falsch.')" \
        '.reject_eligible == true and ((.red_flags // []) | index("auth:suspicious") | not)' && FOUND=1

    # 2. Erste Ablehnung in einer Kategorie, die sonst nie feuert.
    render_group "Ablehnung in einer seltenen Kategorie" \
        "$(printf 'clickbait, pharma und fraud haben kaum Datenpunkte - der erste Treffer gehoert geprueft.')" \
        '.reject_eligible == true and (.category == "clickbait" or .category == "pharma" or .category == "fraud")' && FOUND=1

    # 3. Die KI widerspricht Rspamd deutlich.
    render_group "KI und Rspamd uneinig" \
        "$(printf 'Rspamd sieht Spam, die KI sieht Ham - oder umgekehrt.')" \
        '((.rspamd_score // 0) > 8 and (.ai_score // 0) < -1) or ((.rspamd_score // 0) < 0 and (.ai_score // 0) > 6)' && FOUND=1

    # 4. Prompt-Injection versucht.
    render_group "Prompt-Injection im Mailtext" \
        "$(printf 'Die Mail hat versucht, dem Modell ein Urteil vorzuschreiben.')" \
        '((.prompt_injection // []) | length) > 0' && FOUND=1

    # 5. Beleg gesetzt, aber die Mail war unauffaellig.
    #    Das waren LATS und Scenic.
    render_group "Beleg auf offensichtlich harmloser Post" \
        "$(printf 'Ein struktureller Beleg auf einer Mail mit negativem Score - vermutlich ein Fehlalarm.')" \
        '((.evidence // []) | length) > 0 and (.ai_score // 0) < 0' && FOUND=1
)

if [[ -z "$BODY" ]]; then
    if [[ "$ACTION" == "print" ]]; then
        echo -e "${GREEN}Keine Zweifelsfaelle${NC} in den letzten $DAYS Tag(en)."
    fi
    exit 0
fi

HOST=$(hostname -s 2>/dev/null || hostname)
HEADLINE="AI-Filter: Zweifelsfaelle auf $HOST (letzte $DAYS Tag(e))"

TEXT="$HEADLINE
$(printf '%.0s=' $(seq 1 ${#HEADLINE}))
$BODY

Diese Zeilen sind keine Fehler, sondern Faelle, in denen sich das System
selbst widerspricht. Genau dort lagen bisher alle Fehlurteile.

  ai-filter-log.sh -n 200 -F <absender>     Umfeld ansehen
  ai-filter-report.sh --disable             diesen Report abstellen
"

if [[ "$ACTION" == "print" ]]; then
    echo "$TEXT"
    exit 0
fi

TO="${ONCE_TO:-$REPORT_TO}"
if [[ -z "$TO" ]]; then
    echo -e "${YELLOW}Keine Empfaengeradresse${NC} - mit --set-to setzen. Ausgabe:"
    echo "$TEXT"
    exit 0
fi
if [[ "$ENABLED" != "true" && -z "$ONCE_TO" ]]; then
    exit 0
fi

# Nur warnen, nicht abbrechen: an ein Postfach auf demselben System kommt
# die Mail auch mit fragwuerdiger Absenderdomain an, weil unterwegs niemand
# DMARC prueft. Erst bei einem echten Fremdempfaenger wird es eng - und ein
# funktionierender Versand darf daran nicht scheitern.
if ! from_domain_ok "$REPORT_FROM"; then
    echo -e "${YELLOW}[WARN]${NC} Absender $REPORT_FROM hat keine gueltige Domain."
    echo    "        Intern kommt das an, extern voraussichtlich nicht. Besser:"
    echo    "        ai-filter-report.sh --from ai-filter@deine-domain.de"
fi

if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"
else echo -e "${RED}Docker Compose not found${NC}"; exit 1; fi

# Direkt in den Postfix-Container - kein SMTP-Login, kein Postfach noetig.
printf 'From: %s\nTo: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
    "$REPORT_FROM" "$TO" "$HEADLINE" "$TEXT" \
    | $COMPOSE_CMD exec -T postfix-mailcow sendmail -t \
    && echo -e "${GREEN}[OK]${NC} Report an $TO" \
    || { echo -e "${RED}[FAIL]${NC} Versand fehlgeschlagen"; exit 1; }
