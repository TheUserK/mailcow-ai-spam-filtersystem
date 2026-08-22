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

# Liest den API-Key aus einem bereits ausgerollten ai-mail-checker.php,
# damit ein Upgrade nicht erneut danach fragt.
extract_php_api_key() {
    local php_file="$1"
    [[ -f "$php_file" ]] || return 1
    local key
    # Erst der aktuelle Name, dann der alte. Bis einschliesslich v3.1 hiess
    # die Konstante AI_API_TOKEN; ohne diesen Rueckfall fragt ein Upgrade
    # von dort erneut nach dem Schluessel, obwohl er laengst da ist.
    key=$(grep -oP "define\('AI_API_TOKEN_DEFAULT',\s*'\K[^']*" "$php_file" 2>/dev/null | head -1)
    if [[ -z "$key" ]]; then
        key=$(grep -oP "define\('AI_API_TOKEN',\s*'\K[^']*" "$php_file" 2>/dev/null | head -1)
    fi
    if [[ -n "$key" && "$key" != "YOUR_AI_API_KEY_HERE" ]]; then
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

# Ist der Checker-Block in der Override-Datei noch auf dem alten Stand?
# Merkmale des aktuellen Stands: Build-Context zeigt auf data/ai-checker
# (bringt pdo_mysql mit) und PHP_CLI_SERVER_WORKERS ist gesetzt.
override_is_current() {
    local f="$1"
    grep -q 'context:[[:space:]]*\./data/ai-checker' "$f" \
        && grep -q 'PHP_CLI_SERVER_WORKERS' "$f"
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

# === API KEY ===
AI_API_KEY=""

if [[ "${UPGRADE_MODE:-}" == "true" && -f "data/ai-checker/config.ini" ]]; then
    # Pre-v3 installs kept the key in config.ini
    AI_API_KEY=$(grep -oP '^token\s*=\s*\K.*' data/ai-checker/config.ini 2>/dev/null | tr -d ' ')
    [[ -n "$AI_API_KEY" ]] && echo -e "${GREEN}[OK]${NC} Using existing API key from config.ini (v2 install)"
fi

if [[ -z "$AI_API_KEY" && "${UPGRADE_MODE:-}" == "true" && -f "data/ai-checker/ai-mail-checker.php" ]]; then
    # v3 keeps the key as a PHP constant in the deployed checker script
    AI_API_KEY=$(extract_php_api_key "data/ai-checker/ai-mail-checker.php" || true)
    [[ -n "$AI_API_KEY" ]] && echo -e "${GREEN}[OK]${NC} Using existing API key from ai-mail-checker.php"
fi

if [[ -z "$AI_API_KEY" || "$AI_API_KEY" == "YOUR_API_KEY_HERE" ]]; then
    echo ""
    echo "Get your API key from: https://dcd.ionos.com/"
    echo "Navigate to: Access Management -> Tokens"
    echo ""
    read -p "Enter API key: " AI_API_KEY

    if [[ -z "$AI_API_KEY" ]]; then
        echo -e "${RED}Error: API key is required${NC}"
        exit 1
    fi

    # IONOS AI Model Hub gibt JSON Web Tokens aus - die beginnen mit "eyJ".
    # Was wie eine UUID aussieht, ist die Token-ID aus dem Token Manager,
    # nicht der Token selbst. Andere Anbieter mit OpenAI-kompatibler API
    # nutzen eigene Formate - deshalb nur ein Hinweis, kein harter Abbruch.
    if [[ $AI_API_KEY =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}- ]]; then
        echo -e "${RED}Error: That is a token ID, not the token itself.${NC}"
        echo "Copy the token value from the Token Manager - it starts with 'eyJ'."
        exit 1
    fi

    if [[ ! $AI_API_KEY =~ ^eyJ ]]; then
        echo -e "${YELLOW}Note: Key does not look like an IONOS token (JWTs start with 'eyJ')${NC}"
        read -p "Continue anyway? (y/N): " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && exit 1
    fi
fi

echo ""
echo "Installing..."
echo ""

# === DIRECTORIES ===
mkdir -p data/ai-checker
mkdir -p data/logs/ai-checker
chmod 755 data/ai-checker
# Logs enthalten pseudonymisierte Absender/Empfaenger - nicht world-readable
chmod 700 data/logs/ai-checker
# Bereits vorhandene Logdateien mitnehmen. Der Checker setzt 0600 nur beim
# Anlegen, sonst muesste er bei jedem Schreibvorgang die Rechte pruefen -
# Dateien aus einer aelteren Installation blieben dadurch world-readable.
find data/logs/ai-checker -maxdepth 1 -type f \( -name '*.log' -o -name '*.json' \) \
    -exec chmod 600 {} + 2>/dev/null || true

# === PHP SCRIPTS ===
# Der deployte Checker ist die Datei, in der am ehesten von Hand nachgebessert
# wurde - und sie traegt den API-Key. Vor dem Ueberschreiben sichern, sonst
# sind lokale Anpassungen ersatzlos weg.
if [[ -f "data/ai-checker/ai-mail-checker.php" ]]; then
    CHECKER_BACKUP="data/ai-checker/ai-mail-checker.php.backup.$(date +%s)"
    cp data/ai-checker/ai-mail-checker.php "$CHECKER_BACKUP"
    chmod 600 "$CHECKER_BACKUP"
    echo -e "${GREEN}[OK]${NC} Previous checker backed up: $CHECKER_BACKUP"
fi
cp "$SCRIPT_DIR/files/ai-checker/ai-mail-checker.php" data/ai-checker/
cp "$SCRIPT_DIR/files/ai-checker/router.php" data/ai-checker/
cp "$SCRIPT_DIR/files/ai-checker/trusted_sender_profiles.json.example" data/ai-checker/
# Build-Context fuer den ai-checker-Container (bringt pdo_mysql mit,
# das im offiziellen php:8.2-cli-Image fehlt)
cp "$SCRIPT_DIR/files/ai-checker/Dockerfile" data/ai-checker/

# API key lives directly in the deployed checker script as of v3 (no more
# config.ini). Only the copy under data/ai-checker/ is touched - the
# template in this repo keeps an empty token.
AI_API_KEY_ESCAPED=$(printf '%s' "$AI_API_KEY" | sed -e 's/[\&|]/\\&/g')
sed -i "s|define('AI_API_TOKEN_DEFAULT', '')|define('AI_API_TOKEN_DEFAULT', '$AI_API_KEY_ESCAPED')|" \
    data/ai-checker/ai-mail-checker.php

chmod 644 data/ai-checker/router.php data/ai-checker/trusted_sender_profiles.json.example data/ai-checker/Dockerfile
chmod 600 data/ai-checker/ai-mail-checker.php
echo -e "${GREEN}[OK]${NC} PHP scripts installed (API key embedded in ai-mail-checker.php)"

# Leftover from a pre-v3 install - no longer read, but leave it for the
# admin to remove manually since it still contains their API key.
if [[ -f "data/ai-checker/config.ini" ]]; then
    echo -e "${YELLOW}[INFO]${NC} Found old config.ini from a previous version - it is no longer used."
    echo "       Settings now live directly in data/ai-checker/ai-mail-checker.php."
    echo "       Remove it manually once you've confirmed the new install works: rm data/ai-checker/config.ini"
fi

# === RSPAMD LUA FILTER ===
# Der Filter gehoert nach plugins.d, nicht in lua/ mit einer dofile()-Zeile in
# rspamd.local.lua. Grund steht in mailcows update.sh: dort werden vor dem
# Update nur GETRACKTE Dateien committet und anschliessend mit
# "git merge -X theirs" zusammengefuehrt - bei einem Konflikt gewinnt also
# mailcow, und eine angehaengte Loader-Zeile in der getrackten
# rspamd.local.lua ist weg. Untracked Dateien fasst update.sh dagegen nie an,
# es gibt kein "git clean". plugins.d ist ausserdem genau dafuer gedacht;
# mailcows eigenes README dort sagt: "This is where you should copy any
# rspamd custom module".
mkdir -p data/conf/rspamd/plugins.d
cp "$SCRIPT_DIR/files/rspamd/ai-content-filter.lua" data/conf/rspamd/plugins.d/
chmod 644 data/conf/rspamd/plugins.d/ai-content-filter.lua
echo -e "${GREEN}[OK]${NC} AI filter installed to plugins.d"

# Die Datei allein genuegt nicht. Rspamd findet sie dort zwar - plugins.d ist
# als try_path in der modules-Sektion eingetragen -, behandelt sie aber als
# Modul und schaltet jedes Modul ohne eigenen Konfigurationsabschnitt wieder
# ab:
#   "lua module ai-content-filter is enabled but has not been configured"
#   "ai-content-filter disabling unconfigured lua module"
# Der Abschnitt muss auf oberster Ebene stehen; local.d/<name>.conf wird fuer
# eigene Module nicht eingebunden. rspamd.conf.local ist der von mailcow
# dafuer vorgesehene Platz und enthaelt ab Werk nur einen Kommentar.
RSPAMD_CONF_LOCAL="data/conf/rspamd/rspamd.conf.local"
touch "$RSPAMD_CONF_LOCAL"
if ! grep -q 'ai-content-filter' "$RSPAMD_CONF_LOCAL"; then
    printf '\n"ai-content-filter" {\n  enabled = true;\n}\n' >> "$RSPAMD_CONF_LOCAL"
    echo -e "${GREEN}[OK]${NC} Module enabled in rspamd.conf.local"
else
    echo -e "${GREEN}[OK]${NC} Module already enabled in rspamd.conf.local"
fi

# Reste der frueheren Ablage entfernen. Liegen Datei und dofile-Zeile noch
# daneben, wird der Filter zweimal registriert - und rspamd registriert ihn
# daraufhin gar nicht. Der Healthcheck erkennt den Zustand und verweist
# hierher, also muss er hier auch behoben werden.
if [[ -f "data/conf/rspamd/lua/ai-content-filter.lua" ]]; then
    rm -f data/conf/rspamd/lua/ai-content-filter.lua
    echo -e "${GREEN}[OK]${NC} Removed the stale copy from lua/"
fi
if [[ -f "data/conf/rspamd/lua/rspamd.local.lua" ]] \
   && grep -q "ai-content-filter.lua" data/conf/rspamd/lua/rspamd.local.lua; then
    cp data/conf/rspamd/lua/rspamd.local.lua \
       "data/conf/rspamd/lua/rspamd.local.lua.backup.$(date +%s)"
    sed -i '/-- AI Content Filter loader/d; /ai-content-filter\.lua/d' \
        data/conf/rspamd/lua/rspamd.local.lua
    echo -e "${GREEN}[OK]${NC} Removed the stale dofile() line from rspamd.local.lua (backup kept)"
fi

# Die Einstellungsdatei bleibt in lua/: sie wird vom Filter explizit per
# loadfile() geladen, nicht automatisch. In plugins.d wuerde rspamd sie
# ebenfalls laden, aber in unbestimmter Reihenfolge.
if [[ ! -f "data/conf/rspamd/lua/ai-filter-settings.lua" ]]; then
    cp "$SCRIPT_DIR/files/rspamd/ai-filter-settings.lua.template" data/conf/rspamd/lua/ai-filter-settings.lua
    chmod 644 data/conf/rspamd/lua/ai-filter-settings.lua
    echo -e "${GREEN}[OK]${NC} AI filter settings created"
else
    # Diese Datei gehoert dem Betreiber, nicht der Installation: hier stehen
    # whitelist_domains, das Score-Band, log_only_mode - und http_timeout,
    # das ai-filter-model.sh --timeout mitpflegt. --reinstall hat sie frueher
    # durch die Vorlage ersetzt und damit die Timeout-Kette zerrissen.
    # Fehlende Schluessel ergaenzt das Lua-Skript zur Laufzeit selbst.
    echo -e "${GREEN}[OK]${NC} Existing ai-filter-settings.lua preserved"
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
    if grep -q "ai-checker" docker-compose.override.yml; then
        if override_is_current docker-compose.override.yml; then
            echo -e "${GREEN}[OK]${NC} docker-compose.override.yml is up to date"
        else
            # Der Installer hat diese Datei frueher nie aktualisiert. Dadurch
            # blieben Installationen auf einem Override haengen, der pdo_mysql
            # nicht mitbringt - die Interne-Mail-Erkennung war dann dauerhaft
            # kaputt, ohne dass es irgendwo aufgefallen waere.
            echo -e "${YELLOW}[INFO]${NC} docker-compose.override.yml is outdated:"
            grep -q 'context:[[:space:]]*\./data/ai-checker' docker-compose.override.yml \
                || echo "         - build context does not point at data/ai-checker (pdo_mysql missing)"
            grep -q 'PHP_CLI_SERVER_WORKERS' docker-compose.override.yml \
                || echo "         - PHP_CLI_SERVER_WORKERS not set (requests are serialised)"

            OVERRIDE_SERVICES=$(count_compose_services docker-compose.override.yml)

            if [[ "$OVERRIDE_SERVICES" -le 1 ]]; then
                OVERRIDE_BACKUP="docker-compose.override.yml.backup.$(date +%s)"
                cp docker-compose.override.yml "$OVERRIDE_BACKUP"
                echo "       ai-checker is the only service in the file, so it can be"
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
                echo "       automatically. Merge the ai-checker block by hand from:"
                echo "         $SCRIPT_DIR/files/docker-compose.override.yml"
            fi
        fi
    else
        echo -e "${YELLOW}[INFO]${NC} docker-compose.override.yml exists but has no ai-checker service"
        cp docker-compose.override.yml "docker-compose.override.yml.backup.$(date +%s)"
        echo ""
        echo "Your existing override file has been backed up."
        echo "You need to manually add the ai-checker service."
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
cp "$SCRIPT_DIR"/files/scripts/ai-filter-*.sh /usr/local/bin/
chmod +x /usr/local/bin/ai-filter-*.sh

cp "$SCRIPT_DIR/files/scripts/logrotate-ai-filter" /etc/logrotate.d/ai-filter
echo -e "${GREEN}[OK]${NC} Management scripts installed"

# === ZWEIFELSFALL-REPORT ===
# Ein taeglicher Cron, der nur dann eine Mail schickt, wenn sich der Filter
# selbst widerspricht. Gibt es nichts zu melden, bleibt es still - deshalb
# ist der Eintrag auch dann harmlos, wenn keine Adresse gesetzt ist.
cat > /etc/cron.d/ai-filter-report <<'CRON'
# Zweifelsfaelle des AI-Spamfilters, werktags um 8 Uhr.
# Adresse setzen mit: ai-filter-report.sh --set-to du@example.com
# Abstellen mit:      ai-filter-report.sh --disable
0 8 * * 1-5 root /usr/local/bin/ai-filter-report.sh --mail >/dev/null 2>&1
CRON
chmod 644 /etc/cron.d/ai-filter-report
echo -e "${GREEN}[OK]${NC} Daily report scheduled (weekdays 08:00)"

if [[ -z "$(sed -n 's/^[[:space:]]*report_to[[:space:]]*=[[:space:]]*//p' data/ai-checker/report.conf 2>/dev/null | head -1)" ]]; then
    echo ""
    echo "The report mails you the cases where the filter contradicts itself."
    echo "Leave empty to skip - you can set it later with --set-to."
    read -p "Report recipient address: " REPORT_ADDR
    if [[ -n "$REPORT_ADDR" && "$REPORT_ADDR" == *@* ]]; then
        /usr/local/bin/ai-filter-report.sh --set-to "$REPORT_ADDR" >/dev/null \
            && echo -e "${GREEN}[OK]${NC} Report goes to $REPORT_ADDR"
    else
        echo -e "${YELLOW}[INFO]${NC} No address set - the report only prints on the terminal"
    fi
fi

# === START CONTAINERS ===
echo ""
echo "The ai-checker container needs to be built/started, and Rspamd needs a"
echo "restart to actually load the filter - 'up -d' alone leaves a running"
echo "Rspamd untouched, so the filter would stay inactive."
read -p "Start ai-checker and restart Rspamd now? (y/N): " start_containers

if [[ $start_containers =~ ^[Yy]$ ]]; then
    $COMPOSE_CMD up -d --build ai-checker
    sleep 5

    if $COMPOSE_CMD ps 2>/dev/null | grep -q "ai-checker.*Up\|ai-checker.*running"; then
        echo -e "${GREEN}[OK]${NC} ai-checker container running"
    else
        echo -e "${RED}[FAIL]${NC} ai-checker container failed to start"
        echo "       Check: $COMPOSE_CMD logs ai-checker"
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
    echo "         $COMPOSE_CMD up -d --build ai-checker"
    echo "         $COMPOSE_CMD restart rspamd-mailcow"
fi

echo ""
echo "================================================"
echo -e "  ${GREEN}Installation Complete!${NC}"
echo "================================================"
echo ""
echo "Configuration: $MAILCOW_DIR/data/ai-checker/ai-mail-checker.php"
echo "  (edit the constants near the top of the file - budget, model, score caps, etc.)"
echo "Custom trusted senders: $MAILCOW_DIR/data/ai-checker/trusted_sender_profiles.json"
echo "  (copy from trusted_sender_profiles.json.example in the same directory)"
echo ""
echo "Commands:"
echo "  ai-filter-log.sh       Recent verdicts (-h for filters)"
echo "  ai-filter-stats.sh     Summary"
echo "  ai-filter-test.sh      End-to-end check"
echo "  ai-filter-healthcheck.sh  Health check (also: install.sh --check)"
echo "  ai-filter-model.sh     Show or change the model / AI provider"
echo "  ai-filter-report.sh    Cases where the filter contradicts itself"
echo ""
echo "Logs: $COMPOSE_CMD logs -f ai-checker"
echo ""
echo "Tip: Set log_only_mode = true in ai-filter-settings.lua to test"
echo "     without affecting mail delivery!"
echo ""
