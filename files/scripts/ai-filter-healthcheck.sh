#!/bin/bash
# AI Spam Filter Health Check
# Can be run via cron: */30 * * * * /usr/local/bin/ai-filter-healthcheck.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
MAILCOW_DIR=""

# Find mailcow directory
for dir in /opt/mailcow-dockerized /opt/mailcow; do
    if [[ -f "$dir/mailcow.conf" ]]; then
        MAILCOW_DIR="$dir"
        break
    fi
done

if [[ -z "$MAILCOW_DIR" ]]; then
    echo -e "${RED}[FAIL]${NC} Mailcow directory not found"
    exit 1
fi

# Detect docker compose command
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${RED}[FAIL]${NC} Docker Compose not found"
    exit 1
fi

cd "$MAILCOW_DIR" || exit 1

echo "AI Spam Filter Health Check"
echo "==========================="
echo ""

# 1. Check dofile line in rspamd.local.lua
if [[ -f "data/conf/rspamd/lua/rspamd.local.lua" ]]; then
    if grep -q "ai-content-filter.lua" data/conf/rspamd/lua/rspamd.local.lua; then
        echo -e "${GREEN}[OK]${NC} dofile() loader present in rspamd.local.lua"
    else
        echo -e "${RED}[FAIL]${NC} dofile() loader MISSING in rspamd.local.lua"
        echo "       Run: /usr/local/bin/ai-filter-repair.sh"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo -e "${RED}[FAIL]${NC} rspamd.local.lua not found"
    ERRORS=$((ERRORS + 1))
fi

# 2. Check filter lua file
if [[ -f "data/conf/rspamd/lua/ai-content-filter.lua" ]]; then
    echo -e "${GREEN}[OK]${NC} ai-content-filter.lua exists"
else
    echo -e "${RED}[FAIL]${NC} ai-content-filter.lua MISSING"
    ERRORS=$((ERRORS + 1))
fi

# 3. Check settings lua file
if [[ -f "data/conf/rspamd/lua/ai-filter-settings.lua" ]]; then
    echo -e "${GREEN}[OK]${NC} ai-filter-settings.lua exists"
else
    echo -e "${YELLOW}[WARN]${NC} ai-filter-settings.lua missing (using defaults)"
fi

# 4. Check API key is embedded in ionos-mail-checker.php
if [[ -f "data/ionos-checker/ionos-mail-checker.php" ]]; then
    if grep -qP "define\('IONOS_API_TOKEN',\s*''\)" data/ionos-checker/ionos-mail-checker.php; then
        echo -e "${RED}[FAIL]${NC} API key not configured in ionos-mail-checker.php"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}[OK]${NC} ionos-mail-checker.php present with API key"
    fi
else
    echo -e "${RED}[FAIL]${NC} ionos-mail-checker.php not found"
    ERRORS=$((ERRORS + 1))
fi

# 5. Check ionos-checker container
if $COMPOSE_CMD ps 2>/dev/null | grep -q "ionos-checker.*Up\|ionos-checker.*running"; then
    echo -e "${GREEN}[OK]${NC} ionos-checker container running"

    # Check health endpoint
    HEALTH=$($COMPOSE_CMD exec -T ionos-checker curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health 2>/dev/null)
    if [[ "$HEALTH" == "200" ]]; then
        echo -e "${GREEN}[OK]${NC} Health endpoint responding"
    else
        echo -e "${YELLOW}[WARN]${NC} Health endpoint returned: $HEALTH"
    fi
else
    echo -e "${RED}[FAIL]${NC} ionos-checker container not running"
    ERRORS=$((ERRORS + 1))
fi

# 6. Check rspamd filter loaded
# Grosszuegiges Fenster: Rspamd loggt viel, die Init-Zeile faellt sonst
# hinten raus und der Check meldet faelschlich einen Fehler.
if $COMPOSE_CMD logs --tail=2000 rspamd-mailcow 2>/dev/null | grep -q "AI Content Filter initialized"; then
    echo -e "${GREEN}[OK]${NC} AI filter loaded in Rspamd"
else
    echo -e "${YELLOW}[WARN]${NC} Cannot confirm filter loaded (may need rspamd restart)"
fi

# 7. Warn about a second, older filter still running alongside this one.
# rspamd auto-loads every *.lua in plugins.d, so a leftover filter keeps
# scoring every mail a second time without appearing in any config file.
LEGACY_HITS=$(grep -rl 'IONOS_AI_CHECK\|IONOS_AI_SPAM\|IONOS_AI_HAM' \
    data/conf/rspamd/plugins.d/*.lua data/conf/rspamd/lua/*.lua 2>/dev/null | tr '\n' ' ')
if [[ -n "$LEGACY_HITS" ]]; then
    echo -e "${RED}[FAIL]${NC} An older IONOS filter is still active: $LEGACY_HITS"
    echo "       Every mail is analysed and scored TWICE. Run: install.sh --reinstall"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}[OK]${NC} No leftover legacy filter"
fi

# 8. Check groups.conf
if [[ -f "data/conf/rspamd/local.d/groups.conf" ]]; then
    if grep -q 'group "ai_filter"' data/conf/rspamd/local.d/groups.conf; then
        echo -e "${GREEN}[OK]${NC} Rspamd groups configured"
    else
        echo -e "${YELLOW}[WARN]${NC} ai_filter group missing in groups.conf"
    fi
fi

# 9. Is log rotation actually happening?
# This is worth checking explicitly: nothing else notices when logrotate is
# not running, and the files hold pseudonymised sender data, so a silently
# unrotated log quietly outgrows the retention the setup promises.
STATS_LOG="data/logs/ionos-checker/stats.log"
if [[ ! -f "$STATS_LOG" ]]; then
    echo -e "${YELLOW}[WARN]${NC} stats.log does not exist yet (no mail analysed so far)"
elif [[ ! -s "$STATS_LOG" ]]; then
    # Leere Datei ist ein gueltiger Zustand - aber sag es, statt die Zeile
    # kommentarlos wegzulassen. Eine fehlende Ausgabe liest sich wie ein
    # fehlender Check.
    echo -e "${GREEN}[OK]${NC} stats.log is empty (just rotated, or no mail analysed yet)"
else
    FIRST_DAY=$(head -1 "$STATS_LOG" | grep -oP '"timestamp":"\K[0-9-]{10}')
    if [[ -n "$FIRST_DAY" ]]; then
        SPAN_DAYS=$(( ( $(date +%s) - $(date -d "$FIRST_DAY" +%s 2>/dev/null || echo 0) ) / 86400 ))
        if [[ $SPAN_DAYS -gt 10 ]]; then
            echo -e "${RED}[FAIL]${NC} stats.log covers $SPAN_DAYS days - retention is 7"
            echo "       Log rotation is not running. Check:"
            echo "         logrotate -d /etc/logrotate.d/ionos-checker"
            ERRORS=$((ERRORS + 1))
        else
            echo -e "${GREEN}[OK]${NC} Log rotation working (stats.log covers $SPAN_DAYS days)"
        fi
    fi
fi

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}All checks passed!${NC}"
    exit 0
else
    echo -e "${RED}$ERRORS check(s) failed${NC}"
    exit 1
fi
