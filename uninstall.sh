#!/bin/bash
set -e

echo "================================================"
echo "  Mailcow AI Spam Filter - Uninstaller"
echo "================================================"
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: Run as root${NC}"
   exit 1
fi

# Find mailcow directory
MAILCOW_DIR=""
if [[ -f "./mailcow.conf" ]]; then
    MAILCOW_DIR="$(pwd)"
else
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi

if [[ -z "$MAILCOW_DIR" ]]; then
    echo -e "${RED}Error: Mailcow not found${NC}"
    exit 1
fi

cd "$MAILCOW_DIR" || exit 1

read -p "Remove AI Spam Filter? (y/N): " confirm
[[ ! $confirm =~ ^[Yy]$ ]] && exit 0

if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# Stop container
$COMPOSE_CMD stop ai-checker 2>/dev/null || true

# Remove dofile() loader from rspamd.local.lua (v2)
if [[ -f "data/conf/rspamd/lua/rspamd.local.lua" ]]; then
    sed -i '/-- AI Content Filter loader/d' data/conf/rspamd/lua/rspamd.local.lua
    sed -i '/ai-content-filter.lua/d' data/conf/rspamd/lua/rspamd.local.lua
    echo -e "${GREEN}[OK]${NC} Old rspamd loader line removed"
fi

# Remove filter lua files
rm -f data/conf/rspamd/plugins.d/ai-content-filter.lua
if [[ -f "data/conf/rspamd/rspamd.conf.local" ]]; then
    sed -i '/"ai-content-filter" {/,/^}/d' data/conf/rspamd/rspamd.conf.local
fi
rm -f data/conf/rspamd/lua/ai-content-filter.lua
rm -f data/conf/rspamd/lua/ai-filter-settings.lua
echo -e "${GREEN}[OK]${NC} Lua filter files removed"

# Clean groups.conf (v2 and v1)
if [[ -f "data/conf/rspamd/local.d/groups.conf" ]]; then
    sed -i '/group "ai_filter"/,/^}/d' data/conf/rspamd/local.d/groups.conf
    echo -e "${GREEN}[OK]${NC} Groups config cleaned"
fi

# Remove PHP scripts + config leftovers. Any of these can hold your API key:
# ai-mail-checker.php as of v3, provider.conf and profiles/ once a provider
# was switched, config.ini on pre-v3 installs.
read -p "Delete ai-mail-checker.php, router.php, provider.conf and profiles (contain your API key)? (y/N): " delete_php
if [[ $delete_php =~ ^[Yy]$ ]]; then
    rm -f data/ai-checker/*.php
    rm -f data/ai-checker/config.ini
    rm -f data/ai-checker/provider.conf
    rm -rf data/ai-checker/profiles
    rm -f data/ai-checker/Dockerfile
    echo -e "${GREEN}[OK]${NC} PHP scripts and config deleted"
else
    echo -e "${YELLOW}[INFO]${NC} PHP scripts, provider.conf and profiles preserved (contain your API key)"
fi

rm -f data/ai-checker/trusted_sender_profiles.json.example
rm -f data/ai-checker/trusted_sender_profiles.json

rmdir data/ai-checker 2>/dev/null || true

read -p "Delete logs? (y/N): " delete_logs
if [[ $delete_logs =~ ^[Yy]$ ]]; then
    rm -rf data/logs/ai-checker
    echo -e "${GREEN}[OK]${NC} Logs deleted"
fi

# Remove system scripts
rm -f /usr/local/bin/ai-filter-*.sh
rm -f /etc/logrotate.d/ai-filter
echo -e "${GREEN}[OK]${NC} Scripts removed"

read -p "Restart Rspamd? (y/N): " restart
[[ $restart =~ ^[Yy]$ ]] && $COMPOSE_CMD restart rspamd-mailcow

echo ""
echo -e "${GREEN}Uninstallation complete${NC}"
echo ""
echo "Note: docker-compose.override.yml was NOT removed."
echo "Remove manually if no other services use it:"
echo "  rm $MAILCOW_DIR/docker-compose.override.yml"
echo ""
