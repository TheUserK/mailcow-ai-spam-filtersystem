#!/bin/bash
set -e

echo "================================================"
echo "  Mailcow AI Spam Filter - Installer v2.0"
echo "================================================"
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === HELPER FUNCTIONS ===

detect_mailcow_dir() {
    # 1. Check current directory
    [[ -f "./mailcow.conf" ]] && echo "$(pwd)" && return 0
    # 2. Check common paths
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && echo "$dir" && return 0
    done
    return 1
}

detect_compose_cmd() {
    if docker compose version &> /dev/null; then
        echo "docker compose"
    elif docker-compose version &> /dev/null; then
        echo "docker-compose"
    else
        return 1
    fi
}

preflight_checks() {
    local errors=0

    # Root check
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[FAIL]${NC} Must run as root"
        errors=$((errors + 1))
    fi

    # Docker running
    if ! docker info &> /dev/null; then
        echo -e "${RED}[FAIL]${NC} Docker is not running"
        errors=$((errors + 1))
    fi

    # Docker Compose
    if ! detect_compose_cmd > /dev/null 2>&1; then
        echo -e "${RED}[FAIL]${NC} Docker Compose not found (v2 recommended)"
        errors=$((errors + 1))
    fi

    # Mailcow directory
    if ! detect_mailcow_dir > /dev/null 2>&1; then
        echo -e "${RED}[FAIL]${NC} Mailcow not found (checked: ./, /opt/mailcow-dockerized, /opt/mailcow)"
        errors=$((errors + 1))
    fi

    # curl available
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}[WARN]${NC} curl not found (needed for testing)"
    fi

    return $errors
}

migrate_v1() {
    local mailcow_dir="$1"
    echo -e "${YELLOW}Migrating from v1...${NC}"

    # Remove old Lua block from rspamd.local.lua
    if grep -q "IONOS AI FILTER" "$mailcow_dir/data/conf/rspamd/lua/rspamd.local.lua" 2>/dev/null; then
        sed -i '/-- === IONOS AI FILTER/,/-- === END IONOS AI FILTER ===/d' \
            "$mailcow_dir/data/conf/rspamd/lua/rspamd.local.lua"
        echo -e "${GREEN}[OK]${NC} Removed old v1 Lua block"
    fi

    # Remove old groups.conf entry
    if grep -q 'group "ionos"' "$mailcow_dir/data/conf/rspamd/local.d/groups.conf" 2>/dev/null; then
        sed -i '/group "ionos"/,/^}/d' "$mailcow_dir/data/conf/rspamd/local.d/groups.conf"
        echo -e "${GREEN}[OK]${NC} Removed old v1 groups config"
    fi

    # Extract API key from old PHP if config.ini doesn't exist
    if [[ ! -f "$mailcow_dir/data/ionos-checker/config.ini" ]] && \
       [[ -f "$mailcow_dir/data/ionos-checker/ionos-mail-checker.php" ]]; then
        local old_key
        old_key=$(extract_php_api_key "$mailcow_dir/data/ionos-checker/ionos-mail-checker.php" || true)
        if [[ -n "$old_key" ]]; then
            echo -e "${GREEN}[OK]${NC} Found existing API key from v1"
            echo "$old_key"
            return 0
        fi
    fi
    return 1
}

# Extracts the IONOS_API_TOKEN constant value from a deployed
# ionos-mail-checker.php (v2 config.ini installs never had it embedded here,
# but v1 and v3+ both store it as a PHP constant directly).
extract_php_api_key() {
    local php_file="$1"
    [[ -f "$php_file" ]] || return 1
    local key
    key=$(grep -oP "define\('IONOS_API_TOKEN',\s*'\K[^']*" "$php_file" 2>/dev/null | head -1)
    if [[ -n "$key" && "$key" != "YOUR_IONOS_API_KEY_HERE" ]]; then
        echo "$key"
        return 0
    fi
    return 1
}

# Zaehlt die Top-Level-Services in einer Compose-Datei. Wird gebraucht, um zu
# entscheiden, ob wir eine bestehende Override-Datei gefahrlos ersetzen duerfen
# oder ob dort noch fremde Dienste stehen, die wir nicht anfassen wollen.
count_compose_services() {
    awk '/^services:[[:space:]]*$/{f=1;next} /^[^[:space:]#]/{f=0} f && /^  [a-zA-Z0-9_.-]+:[[:space:]]*$/{c++} END{print c+0}' "$1"
}

# Ist der ionos-checker-Block in der Override-Datei noch auf dem alten Stand?
# Merkmale des aktuellen Stands: Build-Context zeigt auf data/ionos-checker
# (bringt pdo_mysql mit) und PHP_CLI_SERVER_WORKERS ist gesetzt.
override_is_current() {
    local f="$1"
    grep -q 'context:[[:space:]]*\./data/ionos-checker' "$f" \
        && grep -q 'PHP_CLI_SERVER_WORKERS' "$f"
}

# Entfernt Ueberbleibsel des alten v1-Filters (IONOS_AI_CHECK / IONOS_AI_SPAM).
# Laeuft in JEDEM Modus: bisher war die Bereinigung an eine Neuinstallation
# gekoppelt und wurde bei --upgrade/--reinstall uebersprungen - also genau
# dann, wenn eine Altinstallation garantiert vorhanden ist. Folge: beide
# Filter liefen parallel, jede Mail kostete zwei API-Calls und bekam den
# KI-Score doppelt aufaddiert, was die Score-Deckelung aushebelt.
cleanup_legacy_filter() {
    local removed=0
    local ts
    ts=$(date +%s)
    local lua_dir="data/conf/rspamd/lua"
    local local_lua="$lua_dir/rspamd.local.lua"

    if [[ -f "$local_lua" ]]; then
        # Einzelne dofile()-Zeile auf die alte Datei: gefahrlos zu entfernen.
        if grep -q 'ionos-ai-filter\.lua' "$local_lua"; then
            cp "$local_lua" "$local_lua.backup.$ts"
            sed -i '/ionos-ai-filter\.lua/d' "$local_lua"
            removed=$((removed + 1))
            echo -e "${GREEN}[OK]${NC} Old v1 loader removed from rspamd.local.lua (backup: $local_lua.backup.$ts)"
        fi

        # Inline-Block: NUR anfassen, wenn Anfangs- UND Endmarker da sind.
        # Fehlt der Endmarker, wuerde ein Bereichs-sed bis zum Dateiende
        # loeschen und andere Anpassungen mitnehmen - das ist es nicht wert.
        if grep -q -- '-- === IONOS AI FILTER' "$local_lua" \
           && grep -q -- '-- === END IONOS AI FILTER ===' "$local_lua"; then
            cp "$local_lua" "$local_lua.backup.$ts"
            sed -i '/-- === IONOS AI FILTER/,/-- === END IONOS AI FILTER ===/d' "$local_lua"
            removed=$((removed + 1))
            echo -e "${GREEN}[OK]${NC} Old v1 filter block removed from rspamd.local.lua (backup: $local_lua.backup.$ts)"
        elif grep -q 'IONOS_AI_CHECK\|IONOS_AI_SPAM\|IONOS_AI_HAM' "$local_lua"; then
            # Vorhanden, aber nicht sauber abgegrenzt -> nichts automatisch
            # entfernen, sondern genau sagen, wo es steht.
            echo -e "${RED}[ACTION REQUIRED]${NC} An old IONOS filter is still active in:"
            echo "       $MAILCOW_DIR/$local_lua"
            echo "       It registers its own symbols, so every mail is analysed TWICE"
            echo "       and the AI score is added twice. Lines involved:"
            grep -n 'IONOS_AI_CHECK\|IONOS_AI_SPAM\|IONOS_AI_HAM\|IONOS AI FILTER' "$local_lua" \
                | sed 's/^/         /'
            echo "       The block has no clear end marker, so it is NOT removed"
            echo "       automatically. Delete it by hand, then restart rspamd:"
            echo "         $COMPOSE_CMD restart rspamd-mailcow"
            LEGACY_MANUAL=true
        fi
    fi

    if [[ -f "$lua_dir/ionos-ai-filter.lua" ]]; then
        mv "$lua_dir/ionos-ai-filter.lua" "$lua_dir/ionos-ai-filter.lua.disabled.$ts"
        removed=$((removed + 1))
        echo -e "${GREEN}[OK]${NC} Old v1 filter file disabled (renamed, not deleted)"
    fi

    # plugins.d ist der unauffaelligste Fundort: Rspamd laedt dort JEDE .lua
    # automatisch, ohne Eintrag in rspamd.local.lua. Ein alter Filter laeuft
    # deshalb unbemerkt weiter und bewertet jede Mail ein zweites Mal.
    # Nur Dateien anfassen, die wirklich die alten Symbole registrieren -
    # in plugins.d koennen auch fremde Plugins liegen.
    local plugins_dir="data/conf/rspamd/plugins.d"
    if [[ -d "$plugins_dir" ]]; then
        local plugin
        for plugin in "$plugins_dir"/*.lua; do
            [[ -e "$plugin" ]] || continue
            if grep -q 'IONOS_AI_CHECK\|IONOS_AI_SPAM\|IONOS_AI_HAM' "$plugin"; then
                mv "$plugin" "$plugin.disabled.$ts"
                removed=$((removed + 1))
                echo -e "${GREEN}[OK]${NC} Old filter disabled: $plugin -> $plugin.disabled.$ts"
                echo "       (renamed, not deleted - rspamd only loads *.lua from plugins.d)"
            fi
        done
    fi

    if [[ -f "data/conf/rspamd/local.d/groups.conf" ]] \
       && grep -q 'group "ionos"' data/conf/rspamd/local.d/groups.conf; then
        cp data/conf/rspamd/local.d/groups.conf "data/conf/rspamd/local.d/groups.conf.backup.$ts"
        sed -i '/group "ionos"/,/^}/d' data/conf/rspamd/local.d/groups.conf
        removed=$((removed + 1))
        echo -e "${GREEN}[OK]${NC} Old v1 symbol group removed from groups.conf"
    fi

    if [[ $removed -gt 0 ]]; then
        echo -e "${YELLOW}[INFO]${NC} The old filter was running alongside the new one -"
        echo "       every mail was analysed twice and scored twice. Fixed now."
    fi
}

# === MAIN LOGIC ===

# Handle command-line arguments
case "${1:-}" in
    --check)
        echo "Running health check..."
        echo ""
        if [[ -f /usr/local/bin/ai-filter-healthcheck.sh ]]; then
            exec /usr/local/bin/ai-filter-healthcheck.sh
        else
            echo -e "${RED}Health check not installed yet. Run install.sh first.${NC}"
            exit 1
        fi
        ;;
    --upgrade)
        UPGRADE_MODE=true
        echo -e "${YELLOW}Upgrade mode${NC} - will carry your existing API key over"
        echo ""
        ;;
    --reinstall)
        UPGRADE_MODE=true
        FORCE_REPLACE=true
        echo -e "${YELLOW}Reinstall mode${NC} - every component is replaced with the shipped version."
        echo "Your API key and trusted_sender_profiles.json are kept; everything else"
        echo "(settings, rspamd group config, compose override) is overwritten."
        echo ""
        ;;
    --help|-h)
        echo "Usage: install.sh [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  (none)      Fresh installation"
        echo "  --upgrade   Upgrade existing installation (preserves your config)"
        echo "  --reinstall Replace every component with the shipped version."
        echo "              Keeps only the API key and trusted_sender_profiles.json."
        echo "  --check     Run health check on existing installation"
        echo "  --help      Show this help"
        exit 0
        ;;
esac

# Preflight
echo "Preflight checks..."
if ! preflight_checks; then
    echo ""
    echo -e "${RED}Preflight checks failed. Fix the issues above and try again.${NC}"
    exit 1
fi

MAILCOW_DIR=$(detect_mailcow_dir)
COMPOSE_CMD=$(detect_compose_cmd)

echo -e "${GREEN}[OK]${NC} Mailcow found at: $MAILCOW_DIR"
echo -e "${GREEN}[OK]${NC} Docker Compose: $COMPOSE_CMD"
echo ""

cd "$MAILCOW_DIR" || exit 1

# Check for v1 installation
V1_API_KEY=""
if [[ "${UPGRADE_MODE:-}" != "true" ]] && grep -q "IONOS AI FILTER" data/conf/rspamd/lua/rspamd.local.lua 2>/dev/null; then
    echo -e "${YELLOW}Detected v1 installation. Migrating...${NC}"
    V1_API_KEY=$(migrate_v1 "$MAILCOW_DIR" 2>/dev/null || true)
    UPGRADE_MODE=true
fi

# === API KEY ===
IONOS_API_KEY=""

if [[ "${UPGRADE_MODE:-}" == "true" && -f "data/ionos-checker/config.ini" ]]; then
    # Pre-v3 installs kept the key in config.ini
    IONOS_API_KEY=$(grep -oP '^token\s*=\s*\K.*' data/ionos-checker/config.ini 2>/dev/null | tr -d ' ')
    [[ -n "$IONOS_API_KEY" ]] && echo -e "${GREEN}[OK]${NC} Using existing API key from config.ini (v2 install)"
fi

if [[ -z "$IONOS_API_KEY" && "${UPGRADE_MODE:-}" == "true" && -f "data/ionos-checker/ionos-mail-checker.php" ]]; then
    # v3 keeps the key as a PHP constant in the deployed checker script
    IONOS_API_KEY=$(extract_php_api_key "data/ionos-checker/ionos-mail-checker.php" || true)
    [[ -n "$IONOS_API_KEY" ]] && echo -e "${GREEN}[OK]${NC} Using existing API key from ionos-mail-checker.php"
fi

if [[ -z "$IONOS_API_KEY" && -n "$V1_API_KEY" ]]; then
    IONOS_API_KEY="$V1_API_KEY"
    echo -e "${GREEN}[OK]${NC} Using API key from v1 installation"
fi

if [[ -z "$IONOS_API_KEY" || "$IONOS_API_KEY" == "YOUR_API_KEY_HERE" ]]; then
    echo ""
    echo "Get your API key from: https://dcd.ionos.com/"
    echo "Navigate to: Access Management -> Tokens"
    echo ""
    read -p "Enter API key: " IONOS_API_KEY

    if [[ -z "$IONOS_API_KEY" ]]; then
        echo -e "${RED}Error: API key is required${NC}"
        exit 1
    fi

    if [[ ! $IONOS_API_KEY =~ ^ionos_ ]]; then
        echo -e "${YELLOW}Warning: Key doesn't start with 'ionos_'${NC}"
        read -p "Continue anyway? (y/N): " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && exit 1
    fi
fi

echo ""
echo "Installing..."
echo ""

# === LEGACY CLEANUP ===
cleanup_legacy_filter

# === DIRECTORIES ===
mkdir -p data/ionos-checker
mkdir -p data/logs/ionos-checker
chmod 755 data/ionos-checker
# Logs enthalten pseudonymisierte Absender/Empfaenger - nicht world-readable
chmod 700 data/logs/ionos-checker
# Bereits vorhandene Logdateien mitnehmen. Der Checker setzt 0600 nur beim
# Anlegen, sonst muesste er bei jedem Schreibvorgang die Rechte pruefen -
# Dateien aus einer aelteren Installation blieben dadurch world-readable.
find data/logs/ionos-checker -maxdepth 1 -type f \( -name '*.log' -o -name '*.json' \) \
    -exec chmod 600 {} + 2>/dev/null || true

# === PHP SCRIPTS ===
# Der deployte Checker ist die Datei, in der am ehesten von Hand nachgebessert
# wurde - und sie traegt den API-Key. Vor dem Ueberschreiben sichern, sonst
# sind lokale Anpassungen ersatzlos weg.
if [[ -f "data/ionos-checker/ionos-mail-checker.php" ]]; then
    CHECKER_BACKUP="data/ionos-checker/ionos-mail-checker.php.backup.$(date +%s)"
    cp data/ionos-checker/ionos-mail-checker.php "$CHECKER_BACKUP"
    chmod 600 "$CHECKER_BACKUP"
    echo -e "${GREEN}[OK]${NC} Previous checker backed up: $CHECKER_BACKUP"
fi
cp "$SCRIPT_DIR/files/ionos-checker/ionos-mail-checker.php" data/ionos-checker/
cp "$SCRIPT_DIR/files/ionos-checker/router.php" data/ionos-checker/
cp "$SCRIPT_DIR/files/ionos-checker/trusted_sender_profiles.json.example" data/ionos-checker/
# Build-Context fuer den ionos-checker-Container (bringt pdo_mysql mit,
# das im offiziellen php:8.2-cli-Image fehlt)
cp "$SCRIPT_DIR/files/ionos-checker/Dockerfile" data/ionos-checker/

# API key lives directly in the deployed checker script as of v3 (no more
# config.ini). Only the copy under data/ionos-checker/ is touched - the
# template in this repo keeps an empty token.
IONOS_API_KEY_ESCAPED=$(printf '%s' "$IONOS_API_KEY" | sed -e 's/[\&|]/\\&/g')
sed -i "s|define('IONOS_API_TOKEN', '')|define('IONOS_API_TOKEN', '$IONOS_API_KEY_ESCAPED')|" \
    data/ionos-checker/ionos-mail-checker.php

chmod 644 data/ionos-checker/router.php data/ionos-checker/trusted_sender_profiles.json.example data/ionos-checker/Dockerfile
chmod 600 data/ionos-checker/ionos-mail-checker.php
echo -e "${GREEN}[OK]${NC} PHP scripts installed (API key embedded in ionos-mail-checker.php)"

# Leftover from a pre-v3 install - no longer read, but leave it for the
# admin to remove manually since it still contains their API key.
if [[ -f "data/ionos-checker/config.ini" ]]; then
    echo -e "${YELLOW}[INFO]${NC} Found old config.ini from a previous version - it is no longer used."
    echo "       Settings now live directly in data/ionos-checker/ionos-mail-checker.php."
    echo "       Remove it manually once you've confirmed the new install works: rm data/ionos-checker/config.ini"
fi

# === RSPAMD LUA FILTER ===
# Copy filter and settings files
cp "$SCRIPT_DIR/files/rspamd/ai-content-filter.lua" data/conf/rspamd/lua/
chmod 644 data/conf/rspamd/lua/ai-content-filter.lua
echo -e "${GREEN}[OK]${NC} AI filter Lua script installed"

# Generate settings file (only if not exists or not upgrading)
if [[ ! -f "data/conf/rspamd/lua/ai-filter-settings.lua" ]]; then
    cp "$SCRIPT_DIR/files/rspamd/ai-filter-settings.lua.template" data/conf/rspamd/lua/ai-filter-settings.lua
    chmod 644 data/conf/rspamd/lua/ai-filter-settings.lua
    echo -e "${GREEN}[OK]${NC} AI filter settings created"
elif [[ "${FORCE_REPLACE:-}" == "true" ]]; then
    cp data/conf/rspamd/lua/ai-filter-settings.lua \
       "data/conf/rspamd/lua/ai-filter-settings.lua.backup.$(date +%s)"
    cp "$SCRIPT_DIR/files/rspamd/ai-filter-settings.lua.template" data/conf/rspamd/lua/ai-filter-settings.lua
    chmod 644 data/conf/rspamd/lua/ai-filter-settings.lua
    echo -e "${GREEN}[OK]${NC} AI filter settings replaced (backup kept)"
else
    echo -e "${GREEN}[OK]${NC} Existing ai-filter-settings.lua preserved"
fi

# Add dofile() loader to rspamd.local.lua
touch data/conf/rspamd/lua/rspamd.local.lua
if ! grep -q "ai-content-filter.lua" data/conf/rspamd/lua/rspamd.local.lua; then
    echo "" >> data/conf/rspamd/lua/rspamd.local.lua
    echo "-- AI Content Filter loader" >> data/conf/rspamd/lua/rspamd.local.lua
    echo "dofile('/etc/rspamd/lua/ai-content-filter.lua')" >> data/conf/rspamd/lua/rspamd.local.lua
    echo -e "${GREEN}[OK]${NC} dofile() loader added to rspamd.local.lua"
else
    echo -e "${GREEN}[OK]${NC} dofile() loader already present"
fi

# === RSPAMD GROUPS ===
if [[ -f "data/conf/rspamd/local.d/groups.conf" ]]; then
    if ! grep -q 'group "ai_filter"' data/conf/rspamd/local.d/groups.conf; then
        cat "$SCRIPT_DIR/files/rspamd/groups.conf.append" >> data/conf/rspamd/local.d/groups.conf
        echo -e "${GREEN}[OK]${NC} Groups config updated"
    elif [[ "${FORCE_REPLACE:-}" == "true" ]]; then
        # Nur den ai_filter-Block herausschneiden und frisch anhaengen -
        # andere Gruppen in der Datei bleiben unberuehrt.
        cp data/conf/rspamd/local.d/groups.conf \
           "data/conf/rspamd/local.d/groups.conf.backup.$(date +%s)"
        sed -i '/group "ai_filter"/,/^}/d' data/conf/rspamd/local.d/groups.conf
        cat "$SCRIPT_DIR/files/rspamd/groups.conf.append" >> data/conf/rspamd/local.d/groups.conf
        echo -e "${GREEN}[OK]${NC} Groups config replaced (backup kept)"
    else
        echo -e "${GREEN}[OK]${NC} Groups config already present"
    fi
else
    cp "$SCRIPT_DIR/files/rspamd/groups.conf.append" data/conf/rspamd/local.d/groups.conf
    echo -e "${GREEN}[OK]${NC} Groups config created"
fi

# === DOCKER COMPOSE OVERRIDE ===
if [[ -f "docker-compose.override.yml" ]]; then
    if grep -q "ionos-checker" docker-compose.override.yml; then
        if override_is_current docker-compose.override.yml; then
            echo -e "${GREEN}[OK]${NC} docker-compose.override.yml is up to date"
        else
            # Der Installer hat diese Datei frueher nie aktualisiert. Dadurch
            # blieben Installationen auf einem Override haengen, der pdo_mysql
            # nicht mitbringt - die Interne-Mail-Erkennung war dann dauerhaft
            # kaputt, ohne dass es irgendwo aufgefallen waere.
            echo -e "${YELLOW}[INFO]${NC} docker-compose.override.yml is outdated:"
            grep -q 'context:[[:space:]]*\./data/ionos-checker' docker-compose.override.yml \
                || echo "         - build context does not point at data/ionos-checker (pdo_mysql missing)"
            grep -q 'PHP_CLI_SERVER_WORKERS' docker-compose.override.yml \
                || echo "         - PHP_CLI_SERVER_WORKERS not set (requests are serialised)"

            OVERRIDE_SERVICES=$(count_compose_services docker-compose.override.yml)

            if [[ "$OVERRIDE_SERVICES" -le 1 ]]; then
                OVERRIDE_BACKUP="docker-compose.override.yml.backup.$(date +%s)"
                cp docker-compose.override.yml "$OVERRIDE_BACKUP"
                echo "       ionos-checker is the only service in the file, so it can be"
                echo "       replaced safely. Backup: $OVERRIDE_BACKUP"
                if [[ "${FORCE_REPLACE:-}" == "true" ]]; then
                    upd="y"
                else
                    read -p "Update docker-compose.override.yml? (Y/n): " upd
                fi
                if [[ ! $upd =~ ^[Nn]$ ]]; then
                    cp "$SCRIPT_DIR/files/docker-compose.override.yml" docker-compose.override.yml
                    echo -e "${GREEN}[OK]${NC} docker-compose.override.yml updated (backup kept)"
                else
                    echo -e "${YELLOW}[WARN]${NC} Keeping the old file - internal-mail detection will stay broken."
                fi
            else
                # Fremde Dienste in der Datei: nichts automatisch anfassen.
                echo "       The file defines $OVERRIDE_SERVICES services, so it is NOT touched"
                echo "       automatically. Merge the ionos-checker block by hand from:"
                echo "         $SCRIPT_DIR/files/docker-compose.override.yml"
            fi
        fi
    else
        echo -e "${YELLOW}[INFO]${NC} docker-compose.override.yml exists but has no ionos-checker service"
        cp docker-compose.override.yml "docker-compose.override.yml.backup.$(date +%s)"
        echo ""
        echo "Your existing override file has been backed up."
        echo "You need to manually add the ionos-checker service."
        echo "Reference: $SCRIPT_DIR/files/docker-compose.override.yml"
        echo ""
        read -p "Replace with our template? (y/N): " replace
        if [[ $replace =~ ^[Yy]$ ]]; then
            cp "$SCRIPT_DIR/files/docker-compose.override.yml" docker-compose.override.yml
            echo -e "${GREEN}[OK]${NC} docker-compose.override.yml replaced (backup saved)"
        fi
    fi
else
    cp "$SCRIPT_DIR/files/docker-compose.override.yml" docker-compose.override.yml
    echo -e "${GREEN}[OK]${NC} docker-compose.override.yml installed"
fi

# === SYSTEM SCRIPTS ===
cp "$SCRIPT_DIR/files/scripts/ionos-stats.sh" /usr/local/bin/
cp "$SCRIPT_DIR/files/scripts/ionos-test.sh" /usr/local/bin/
cp "$SCRIPT_DIR/files/scripts/ai-filter-healthcheck.sh" /usr/local/bin/
cp "$SCRIPT_DIR/files/scripts/ai-filter-repair.sh" /usr/local/bin/
chmod +x /usr/local/bin/ionos-*.sh /usr/local/bin/ai-filter-*.sh
cp "$SCRIPT_DIR/files/scripts/logrotate-ionos" /etc/logrotate.d/ionos-checker
echo -e "${GREEN}[OK]${NC} Management scripts installed"

# === START CONTAINERS ===
echo ""
echo "The ionos-checker container needs to be built/started, and Rspamd needs a"
echo "restart to actually load the filter - 'up -d' alone leaves a running"
echo "Rspamd untouched, so the filter would stay inactive."
read -p "Start ionos-checker and restart Rspamd now? (y/N): " start_containers

if [[ $start_containers =~ ^[Yy]$ ]]; then
    $COMPOSE_CMD up -d --build ionos-checker
    sleep 5

    if $COMPOSE_CMD ps 2>/dev/null | grep -q "ionos-checker.*Up\|ionos-checker.*running"; then
        echo -e "${GREEN}[OK]${NC} ionos-checker container running"
    else
        echo -e "${RED}[FAIL]${NC} ionos-checker container failed to start"
        echo "       Check: $COMPOSE_CMD logs ionos-checker"
    fi

    # Ohne diesen Restart laedt Rspamd ai-content-filter.lua nicht und der
    # Filter bleibt stumm - das ist der haeufigste "es passiert nichts"-Fall.
    echo "Restarting Rspamd to load the filter..."
    $COMPOSE_CMD restart rspamd-mailcow
    # Rspamd braucht ein paar Sekunden, bis die Lua-Dateien geladen sind, und
    # loggt beim Start sehr viel - mit einem kurzen sleep und einem kleinen
    # tail-Fenster ist die Init-Zeile leicht zu verpassen. Also nachfassen.
    FILTER_LOADED=false
    for _ in $(seq 1 10); do
        if $COMPOSE_CMD logs --tail=2000 rspamd-mailcow 2>/dev/null \
             | grep -q "AI Content Filter initialized"; then
            FILTER_LOADED=true
            break
        fi
        sleep 3
    done

    if [[ "$FILTER_LOADED" == "true" ]]; then
        echo -e "${GREEN}[OK]${NC} AI filter loaded in Rspamd"
    else
        echo -e "${YELLOW}[WARN]${NC} Could not confirm the filter loaded after 30s"
        echo "       Check: $COMPOSE_CMD logs rspamd-mailcow | grep 'AI Filter'"
    fi
else
    echo -e "${YELLOW}[INFO]${NC} Nothing started. The filter stays INACTIVE until you run:"
    echo "         $COMPOSE_CMD up -d --build ionos-checker"
    echo "         $COMPOSE_CMD restart rspamd-mailcow"
fi

echo ""
echo "================================================"
echo -e "  ${GREEN}Installation Complete!${NC}"
echo "================================================"
echo ""
echo "Configuration: $MAILCOW_DIR/data/ionos-checker/ionos-mail-checker.php"
echo "  (edit the constants near the top of the file - budget, model, score caps, etc.)"
echo "Custom trusted senders: $MAILCOW_DIR/data/ionos-checker/trusted_sender_profiles.json"
echo "  (copy from trusted_sender_profiles.json.example in the same directory)"
echo ""
echo "Commands:"
echo "  install.sh --check     Health check"
echo "  ionos-test.sh          Quick API test"
echo "  ionos-stats.sh         View statistics"
echo "  ai-filter-repair.sh    Repair after mailcow update"
echo ""
echo "Logs: $COMPOSE_CMD logs -f ionos-checker"
echo ""
echo "Tip: Set log_only_mode = true in ai-filter-settings.lua to test"
echo "     without affecting mail delivery!"
echo ""
