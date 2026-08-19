#!/bin/bash
# Mailcow IONOS AI Spam Filter - Statistics Script

STATS_LOG="/opt/mailcow-dockerized/data/logs/ionos-checker/stats.log"
BUDGET_FILE="/opt/mailcow-dockerized/data/logs/ionos-checker/monthly_budget.json"

echo "================================================"
echo "  IONOS AI Spam Filter - Statistics"
echo "================================================"
echo ""

if [[ ! -f "$STATS_LOG" ]]; then
    echo "No statistics available yet."
    exit 0
fi

TODAY=$(date +%Y-%m-%d)
TOTAL_TODAY=$(grep "$TODAY" "$STATS_LOG" | wc -l)
echo "Emails analyzed today: $TOTAL_TODAY"

MONTH=$(date +%Y-%m)
TOTAL_MONTH=$(grep "$MONTH" "$STATS_LOG" | wc -l)
echo "Emails analyzed this month: $TOTAL_MONTH"

echo ""
echo "Category Distribution (today):"
grep "$TODAY" "$STATS_LOG" | jq -r '.category' | sort | uniq -c | sort -rn

echo ""
echo "Action Distribution (today):"
grep "$TODAY" "$STATS_LOG" | jq -r '.ai_action' | sort | uniq -c | sort -rn

if [[ -f "$BUDGET_FILE" ]]; then
    echo ""
    echo "Budget Status:"
    jq '.' "$BUDGET_FILE"
fi

echo ""
echo "Recent High-Risk Mails (phishing/fraud category or score >= 4, last 5):"
grep "$TODAY" "$STATS_LOG" | jq -r 'select(.category=="phishing" or .category=="fraud" or .ai_score >= 4) | "\(.timestamp) | score=\(.ai_score) | \(.category) | \(.from) | \(.subject)"' | tail -5

echo ""
