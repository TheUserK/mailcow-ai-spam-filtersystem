#!/bin/bash
# AI Spam Filter Health Check
# Can be run via cron: */30 * * * * /usr/local/bin/ai-filter-healthcheck.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        if [[ -f "$dir/mailcow.conf" ]]; then
            MAILCOW_DIR="$dir"
            break
        fi
    done
fi

if [[ -z "${MAILCOW_DIR:-}" ]]; then
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

# 1. Filter in plugins.d - rspamd loads *.lua from there on its own, and
# mailcow's update never touches untracked files in it.
if [[ -f "data/conf/rspamd/plugins.d/ai-content-filter.lua" ]]; then
    echo -e "${GREEN}[OK]${NC} ai-content-filter.lua in plugins.d"
else
    echo -e "${RED}[FAIL]${NC} ai-content-filter.lua MISSING from plugins.d"
    echo "       Run: install.sh --reinstall"
    ERRORS=$((ERRORS + 1))
fi

# 2. The module has to be enabled explicitly - rspamd disables any module in
# plugins.d that has no configuration section, quietly.
if grep -q 'ai-content-filter' data/conf/rspamd/rspamd.conf.local 2>/dev/null; then
    echo -e "${GREEN}[OK]${NC} Module enabled in rspamd.conf.local"
else
    echo -e "${RED}[FAIL]${NC} Module NOT enabled in rspamd.conf.local"
    echo "       rspamd loads the file and then disables it. Run: install.sh --reinstall"
    ERRORS=$((ERRORS + 1))
fi

# 3. No leftovers from the previous arrangement, which would load the filter
# a second time.
STALE=""
[[ -f "data/conf/rspamd/lua/ai-content-filter.lua" ]] && STALE="lua/ai-content-filter.lua"
if [[ -f "data/conf/rspamd/lua/rspamd.local.lua" ]] \
   && grep -q "ai-content-filter.lua" data/conf/rspamd/lua/rspamd.local.lua; then
    STALE="$STALE dofile-line-in-rspamd.local.lua"
fi
if [[ -n "$STALE" ]]; then
    echo -e "${RED}[FAIL]${NC} Leftovers from the old layout: $STALE"
    echo "       The filter would run twice. Run: install.sh --reinstall"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}[OK]${NC} No leftovers from the old layout"
fi

# 3. Check settings lua file
if [[ -f "data/conf/rspamd/lua/ai-filter-settings.lua" ]]; then
    echo -e "${GREEN}[OK]${NC} ai-filter-settings.lua exists"
else
    echo -e "${YELLOW}[WARN]${NC} ai-filter-settings.lua missing (using defaults)"
fi

# 4. Check API key is embedded in ai-mail-checker.php
if [[ -f "data/ai-checker/ai-mail-checker.php" ]]; then
    if grep -qP "define\('AI_API_TOKEN',\s*''\)" data/ai-checker/ai-mail-checker.php; then
        echo -e "${RED}[FAIL]${NC} API key not configured in ai-mail-checker.php"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}[OK]${NC} ai-mail-checker.php present with API key"
    fi
else
    echo -e "${RED}[FAIL]${NC} ai-mail-checker.php not found"
    ERRORS=$((ERRORS + 1))
fi

# 5. Check ai-checker container
if $COMPOSE_CMD ps 2>/dev/null | grep -q "ai-checker.*Up\|ai-checker.*running"; then
    echo -e "${GREEN}[OK]${NC} ai-checker container running"

    # Check health endpoint
    HEALTH=$($COMPOSE_CMD exec -T ai-checker curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health 2>/dev/null)
    if [[ "$HEALTH" == "200" ]]; then
        echo -e "${GREEN}[OK]${NC} Health endpoint responding"
    else
        echo -e "${YELLOW}[WARN]${NC} Health endpoint returned: $HEALTH"
    fi
else
    echo -e "${RED}[FAIL]${NC} ai-checker container not running"
    ERRORS=$((ERRORS + 1))
fi

# 6. Check rspamd filter loaded
# Ask rspamd what it actually has registered instead of searching the log for
# an init line. A log line only proves the filter loaded at some point - it
# survives a later restart in which the filter did not come up, and that false
# reassurance has already hidden a dead filter once.
if $COMPOSE_CMD exec -T rspamd-mailcow rspamc counters 2>/dev/null \
     | grep -q 'AI_CONTENT_FILTER'; then
    echo -e "${GREEN}[OK]${NC} AI filter registered in Rspamd"
else
    echo -e "${RED}[FAIL]${NC} AI filter NOT registered in Rspamd"
    echo "       It is loaded but disabled, or not loaded at all. Check:"
    echo "         $COMPOSE_CMD logs rspamd-mailcow | grep -i ai-content"
    ERRORS=$((ERRORS + 1))
fi

# 7. Is a second AI filter registered alongside this one?
# Read what rspamd actually loaded, not what sits on disk: a filter dropped
# into plugins.d is auto-loaded without appearing in any config file, which is
# exactly how a second one can score every mail unnoticed. Any AI-looking
# symbol that is not ours means something else is also judging mail.
FOREIGN_AI=$($COMPOSE_CMD exec -T rspamd-mailcow rspamc counters 2>/dev/null \
    | grep -oE '\b[A-Z0-9_]*AI_[A-Z0-9_]*\b' | sort -u \
    | grep -vE '^AI_CONTENT_(SCORE|FILTER)$' | tr '\n' ' ')
if [[ -n "${FOREIGN_AI// /}" ]]; then
    echo -e "${RED}[FAIL]${NC} A second AI filter is registered: $FOREIGN_AI"
    echo "       Every mail is analysed and scored twice. Find it with:"
    echo "         grep -rl 'rspamd_http' data/conf/rspamd/plugins.d/ data/conf/rspamd/lua/"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}[OK]${NC} No second AI filter registered"
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
STATS_LOG="data/logs/ai-checker/stats.log"
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
            echo "         logrotate -d /etc/logrotate.d/ai-checker"
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
