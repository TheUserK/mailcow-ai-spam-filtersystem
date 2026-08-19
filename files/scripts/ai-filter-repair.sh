#!/bin/bash
# AI Spam Filter Repair Script
# Re-adds the dofile() loader to rspamd.local.lua if missing after a mailcow update

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: Run as root${NC}"
   exit 1
fi

MAILCOW_DIR=""
for dir in /opt/mailcow-dockerized /opt/mailcow; do
    if [[ -f "$dir/mailcow.conf" ]]; then
        MAILCOW_DIR="$dir"
        break
    fi
done

if [[ -z "$MAILCOW_DIR" ]]; then
    echo -e "${RED}Error: Mailcow directory not found${NC}"
    exit 1
fi

if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${RED}Error: Docker Compose not found${NC}"
    exit 1
fi

cd "$MAILCOW_DIR" || exit 1

REPAIRED=0

# 1. Check and repair dofile() in rspamd.local.lua
RSPAMD_LUA="data/conf/rspamd/lua/rspamd.local.lua"
if [[ -f "$RSPAMD_LUA" ]]; then
    if ! grep -q "ai-content-filter.lua" "$RSPAMD_LUA"; then
        echo -e "${YELLOW}Repairing:${NC} Adding dofile() loader to rspamd.local.lua"
        echo "" >> "$RSPAMD_LUA"
        echo "-- AI Content Filter loader (auto-repaired)" >> "$RSPAMD_LUA"
        echo "dofile('/etc/rspamd/lua/ai-content-filter.lua')" >> "$RSPAMD_LUA"
        echo -e "${GREEN}[OK]${NC} dofile() loader added"
        REPAIRED=$((REPAIRED + 1))
    else
        echo -e "${GREEN}[OK]${NC} dofile() loader already present"
    fi
else
    echo -e "${YELLOW}Creating:${NC} $RSPAMD_LUA"
    echo "-- AI Content Filter loader (auto-repaired)" > "$RSPAMD_LUA"
    echo "dofile('/etc/rspamd/lua/ai-content-filter.lua')" >> "$RSPAMD_LUA"
    echo -e "${GREEN}[OK]${NC} rspamd.local.lua created with loader"
    REPAIRED=$((REPAIRED + 1))
fi

# 2. Check groups.conf
GROUPS_CONF="data/conf/rspamd/local.d/groups.conf"
if [[ -f "$GROUPS_CONF" ]]; then
    if ! grep -q 'group "ai_filter"' "$GROUPS_CONF"; then
        echo -e "${YELLOW}Repairing:${NC} Adding ai_filter group to groups.conf"
        cat >> "$GROUPS_CONF" << 'GROUPEOF'

group "ai_filter" {
  symbols {
    "AI_CONTENT_FILTER" {
      weight = 0.0;
      description = "AI content filter triggered";
    }
    "AI_CONTENT_SCORE" {
      weight = 1.0;
      description = "AI content policy check";
    }
  }
}
GROUPEOF
        echo -e "${GREEN}[OK]${NC} ai_filter group added"
        REPAIRED=$((REPAIRED + 1))
    else
        echo -e "${GREEN}[OK]${NC} groups.conf already has ai_filter"
    fi
fi

# 3. Verify filter lua exists
if [[ ! -f "data/conf/rspamd/lua/ai-content-filter.lua" ]]; then
    echo -e "${RED}[FAIL]${NC} ai-content-filter.lua not found!"
    echo "       You may need to re-run the installer: install.sh --upgrade"
    exit 1
fi

# 4. Restart rspamd if repairs were made
if [[ $REPAIRED -gt 0 ]]; then
    echo ""
    read -p "Restart Rspamd to apply repairs? (y/N): " restart
    if [[ $restart =~ ^[Yy]$ ]]; then
        $COMPOSE_CMD restart rspamd-mailcow
        echo -e "${GREEN}[OK]${NC} Rspamd restarted"
    else
        echo -e "${YELLOW}[INFO]${NC} Remember to restart rspamd: $COMPOSE_CMD restart rspamd-mailcow"
    fi
else
    echo ""
    echo -e "${GREEN}Nothing to repair - everything looks good!${NC}"
fi
