#!/bin/bash
# Summary of what the filter did, from stats.log.
# For individual mails use ai-filter-log.sh.

set -uo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'

command -v jq >/dev/null || { echo -e "${RED}jq is required${NC} - apt install jq"; exit 1; }

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }

LOG_DIR="$MAILCOW_DIR/data/logs/ionos-checker"
STATS_LOG="$LOG_DIR/stats.log"
ERROR_LOG="$LOG_DIR/errors.log"
BUDGET_FILE="$LOG_DIR/monthly_budget.json"

echo "================================================"
echo "  AI Spam Filter - Statistics"
echo "================================================"
echo ""

if [[ ! -s "$STATS_LOG" ]]; then
    echo "No statistics yet (log empty or freshly rotated)."
    exit 0
fi

TOTAL=$(wc -l < "$STATS_LOG")
echo "Analysed (in the current log): $TOTAL"

# Zeitraum aus den Eintraegen selbst, nicht aus der Dateizeit - die aendert
# sich bei jedem Schreibvorgang und sagt nichts ueber die Abdeckung.
FIRST=$(head -1 "$STATS_LOG" | jq -r '.timestamp[0:10]' 2>/dev/null)
LAST=$(tail -1 "$STATS_LOG" | jq -r '.timestamp[0:10]' 2>/dev/null)
[[ -n "$FIRST" ]] && echo "Period: $FIRST .. $LAST"

echo ""
echo "Where the verdict came from:"
jq -r '.analysis_source // "unknown"' "$STATS_LOG" | sort | uniq -c | sort -rn | sed 's/^/  /'

echo ""
echo "Categories:"
jq -r '.category // "unknown"' "$STATS_LOG" | sort | uniq -c | sort -rn | sed 's/^/  /'

echo ""
echo "AI score distribution:"
jq -r '.ai_score // 0 |
  if . <= -1 then "ham (score <= -1)"
  elif . < 1 then "neutral (-1 .. 1)"
  elif . < 5 then "suspicious (1 .. 5)"
  elif . < 10 then "spam (5 .. 10)"
  else "decisive (>= 10)" end' "$STATS_LOG" | sort | uniq -c | sort -rn | sed 's/^/  /'

REJECTS=$(jq -r 'select(.reject_eligible == true) | .id' "$STATS_LOG" 2>/dev/null | wc -l)
if [[ "$REJECTS" -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Reject candidates: $REJECTS${NC}   (ai-filter-log.sh -R for the list)"
fi

if [[ -s "$ERROR_LOG" ]]; then
    echo ""
    echo "Errors:"
    jq -r '.message // "unknown"' "$ERROR_LOG" | sort | uniq -c | sort -rn | head -8 | sed 's/^/  /'
fi

if [[ -f "$BUDGET_FILE" ]]; then
    echo ""
    echo "Budget:"
    jq -r '"  \(.month): \(.calls) calls, approx. EUR \(.estimated_cost_eur | . * 100 | round / 100)"' \
        "$BUDGET_FILE" 2>/dev/null | sed 's/^/  /'
fi

echo ""
echo -e "${DIM}Individual mails: ai-filter-log.sh${NC}"
