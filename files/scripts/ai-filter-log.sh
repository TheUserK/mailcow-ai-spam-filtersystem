#!/bin/bash
# Shows recent AI filter verdicts.
#
# Without options: one line per mail, newest last, timestamps in local time.
# With -r you get the raw JSON, which is what `tail | jq` on the log gives you.

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'

COUNT=20
RAW=false
FOLLOW=false
WHICH=stats
FILTER='true'

usage() {
    cat <<'USAGE'
Usage: ai-filter-log.sh [OPTIONS]

  -n N            number of entries (default 20)
  -r, --raw       full JSON instead of the table
  -f, --follow    keep printing new entries as they arrive
  -e, --errors    read errors.log instead of stats.log
  -s, --spam      only mail the AI scored positive
  -H, --ham       only mail the AI scored negative
  -R, --rejected  only reject candidates
  -c CATEGORY     only this category (spam, clickbait, phishing, ...)
  -F PATTERN      only senders matching PATTERN (case-insensitive regex)
  -h, --help      this text

Examples:
  ai-filter-log.sh -n 40 -r          # what `tail -40 stats.log | jq` gives you
  ai-filter-log.sh -R                # what the filter would reject, or did
  ai-filter-log.sh -c clickbait -n 50
  ai-filter-log.sh -f                # live

MAILCOW_DIR can be set to point at a mailcow installation elsewhere.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) COUNT="${2:-20}"; shift 2 ;;
        -r|--raw) RAW=true; shift ;;
        -f|--follow) FOLLOW=true; shift ;;
        -e|--errors) WHICH=errors; shift ;;
        -s|--spam) FILTER="$FILTER and (.ai_score > 0)"; shift ;;
        -H|--ham) FILTER="$FILTER and (.ai_score < 0)"; shift ;;
        -R|--rejected) FILTER="$FILTER and (.reject_eligible == true)"; shift ;;
        -c) FILTER="$FILTER and (.category == \"${2:-}\")"; shift 2 ;;
        -F) FILTER="$FILTER and ((.from // \"\") | test(\"${2:-}\"; \"i\"))"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
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

LOG="$MAILCOW_DIR/data/logs/ai-checker/$WHICH.log"
[[ -f "$LOG" ]] || { echo -e "${YELLOW}No log yet:${NC} $LOG"; exit 0; }
[[ -s "$LOG" ]] || { echo -e "${YELLOW}Log is empty${NC} (just rotated, or nothing analysed yet)"; exit 0; }

# Der Checker schreibt UTC, Rspamd schreibt Lokalzeit. Damit sich beide Logs
# nebeneinander lesen lassen, hier auf Lokalzeit umrechnen - und robust
# bleiben, falls die Zeitstempel spaeter mit lokalem Versatz kommen.
TIME_FN='def localtime:
  if test("\\+00:00$") or test("Z$")
  then (sub("\\+00:00$";"Z") | fromdateiso8601 | strflocaltime("%d.%m. %H:%M:%S"))
  else (.[8:10] + "." + .[5:7] + ". " + .[11:19])
  end;'

render_stats() {
    jq -r "$TIME_FN"'
      select('"$FILTER"') |
      [ (.timestamp|localtime),
        ((.ai_score // 0) | if . > 0 then "+\(.)" else tostring end),
        (.category // "-"),
        (.from // "-"),
        (.to // "-"),
        ((if .reject_eligible then ["REJECT"] else [] end) + (.evidence // []) | join(","))
      ] | @tsv' \
    | awk -F'\t' '{ printf "%-16s %7s  %-14s %-32s %-26s %s\n", $1,$2,$3,$4,$5,$6 }'
}

render_errors() {
    jq -r "$TIME_FN"'
      [ (.timestamp|localtime),
        (.message // "-"),
        (.context.category // ""),
        ((.context.total_score // "")|tostring),
        (.context.from // "")
      ] | @tsv' \
    | awk -F'\t' '{ printf "%-16s %-34s %-12s %6s  %s\n", $1,$2,$3,$4,$5 }'
}

render() {
    if [[ "$RAW" == "true" ]]; then
        jq -c "select($FILTER)" | jq .
    elif [[ "$WHICH" == "errors" ]]; then
        render_errors
    else
        render_stats
    fi
}

if [[ "$RAW" != "true" ]]; then
    if [[ "$WHICH" == "errors" ]]; then
        echo -e "${DIM}$(printf '%-16s %-34s %-12s %6s  %s' Zeit Meldung Kategorie Score Absender)${NC}"
    else
        echo -e "${DIM}$(printf '%-16s %7s  %-14s %-32s %-26s %s' Zeit Score Kategorie Von An Belege)${NC}"
    fi
fi

if [[ "$FOLLOW" == "true" ]]; then
    tail -n "$COUNT" -f "$LOG" | render
else
    tail -n "$COUNT" "$LOG" | render
fi
