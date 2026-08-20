#!/bin/bash
# Shows and changes which AI model and provider the filter talks to.
#
# The deployed ai-mail-checker.php ships with IONOS as its default. A profile
# in data/ai-checker/provider.conf overrides that without touching the script,
# so an install.sh --reinstall cannot silently reset the choice.

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'

usage() {
    cat <<'USAGE'
Usage: ai-filter-model.sh [OPTION]

  (no option)        show the active provider, model and token state
  --models           list the models the active provider offers
  --model ID         switch to another model of the same provider
  --use PROVIDER     switch provider: ionos | hetzner
  --cost EUR         cost per API call, feeds the monthly budget guard
  --reasoning LEVEL  low | medium | high - trades answer time for thinking
  --timeout SEC      how long the API may take - also adjusts rspamd's
                     http_timeout and task_timeout so the chain stays sane
  --test             send one request with the current settings, change nothing
  --reset            drop the profile, back to the shipped defaults
  -h, --help         this text

Every change is verified against the live API first. If the test request
fails, nothing is written - the filter keeps running on what it had.

MAILCOW_DIR can be set to point at a mailcow installation elsewhere.
USAGE
}

# --- Anbieter-Vorgaben -------------------------------------------------
# cost_per_call speist die Budgetbremse im Checker und haengt am Modell.
preset_endpoint() {
    case "$1" in
        ionos)   echo "https://openai.inference.de-txl.ionos.com/v1/chat/completions" ;;
        hetzner) echo "https://inference.hetzner.com/api/v1/chat/completions" ;;
        *) return 1 ;;
    esac
}
preset_model() {
    case "$1" in
        ionos)   echo "openai/gpt-oss-120b" ;;
        hetzner) echo "Qwen/Qwen3.6-35B-A3B-FP8" ;;
        *) return 1 ;;
    esac
}
preset_cost() {
    case "$1" in
        ionos)   echo "0.00034" ;;
        hetzner) echo "0" ;;
        *) return 1 ;;
    esac
}

ACTION=status
ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --models)  ACTION=models; shift ;;
        --model)   ACTION=setmodel; ARG="${2:-}"; shift 2 ;;
        --use)     ACTION=useprovider; ARG="${2:-}"; shift 2 ;;
        --cost)    ACTION=setcost; ARG="${2:-}"; shift 2 ;;
        --reasoning) ACTION=setreasoning; ARG="${2:-}"; shift 2 ;;
        --timeout) ACTION=settimeout; ARG="${2:-}"; shift 2 ;;
        --test)    ACTION=test; shift ;;
        --reset)   ACTION=reset; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; echo; usage; exit 1 ;;
    esac
done

command -v curl >/dev/null || { echo -e "${RED}curl is required${NC}"; exit 1; }
command -v jq   >/dev/null || { echo -e "${RED}jq is required${NC} - apt install jq"; exit 1; }

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }
cd "$MAILCOW_DIR" || exit 1

CHECKER="data/ai-checker/ai-mail-checker.php"
CONF="data/ai-checker/provider.conf"
PROFILE_DIR="data/ai-checker/profiles"
LUA_SETTINGS="data/conf/rspamd/lua/ai-filter-settings.lua"
RSPAMD_OPTIONS="data/conf/rspamd/local.d/options.inc"

[[ -f "$CHECKER" ]] || { echo -e "${RED}Checker not installed:${NC} $MAILCOW_DIR/$CHECKER"; exit 1; }

if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"
else echo -e "${RED}Docker Compose not found${NC}"; exit 1; fi

# --- Auslesen ----------------------------------------------------------
# Reihenfolge wie im Checker: Profil schlaegt Auslieferungszustand.
conf_value() {
    [[ -f "$CONF" ]] || return 1
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | head -1
}
php_default() {
    grep -oP "define\('$1',\s*'\K[^']*" "$CHECKER" 2>/dev/null | head -1
}
monthly_budget() {
    grep -oP "define\('MONTHLY_BUDGET_EUR',\s*\K[0-9.]+" "$CHECKER" 2>/dev/null | head -1
}

setting() {
    local from_conf; from_conf=$(conf_value "$1" || true)
    if [[ -n "$from_conf" ]]; then echo "$from_conf"; else php_default "$2"; fi
}

ENDPOINT=$(setting endpoint AI_API_ENDPOINT_DEFAULT)
MODEL=$(setting model AI_MODEL_DEFAULT)
TOKEN=$(setting token AI_API_TOKEN_DEFAULT)
COST=$(conf_value cost_per_call || echo "0.00034")
REASONING=$(conf_value reasoning_effort || echo "")
TIMEOUT=$(conf_value api_timeout || echo "20")

provider_name() {
    case "$1" in
        *ionos.com*)   echo "ionos" ;;
        *hetzner.com*) echo "hetzner" ;;
        *) echo "custom" ;;
    esac
}
ACTIVE=$(provider_name "$ENDPOINT")
BASE="${ENDPOINT%/chat/completions}"

mask_token() {
    local t="$1"
    if [[ -z "$t" ]]; then echo -e "${RED}nicht gesetzt${NC}"
    else echo "gesetzt (${t:0:3}…, ${#t} Zeichen)"; fi
}

# --- API-Aufrufe -------------------------------------------------------
list_models() {
    curl -s --max-time 20 "$BASE/models" -H "Authorization: Bearer $1" \
        | jq -r '.data[]?.id' 2>/dev/null
}

# Testanfrage. Prueft in einem Rutsch Endpoint, Token, Modell UND ob der
# Anbieter Structured Outputs beherrscht - genau die Frage, die sich sonst
# erst im Betrieb an fehlgeschlagenen Analysen zeigt.
test_call() {
    local endpoint="$1" token="$2" model="$3"
    curl -s --max-time 120 "$endpoint" \
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        -d "$(jq -n --arg m "$model" --arg r "${REASONING:-}" '{
              model: $m,
              reasoning_effort: (if $r == "" then null else $r end),
              messages: [{role:"user", content:"Antworte im vorgegebenen Schema mit ok=true."}],
              max_completion_tokens: 200,
              response_format: {type:"json_schema", json_schema:{name:"probe", strict:true,
                schema:{type:"object", properties:{ok:{type:"boolean"}},
                        required:["ok"], additionalProperties:false}}}
            } | with_entries(select(.value != null))')"
}

run_test() {
    local endpoint="$1" token="$2" model="$3"
    local resp schema_ok=true

    echo -e "${DIM}Testanfrage an $model …${NC}"
    resp=$(test_call "$endpoint" "$token" "$model")

    if [[ -z "$resp" ]]; then
        echo -e "${RED}[FAIL]${NC} Keine Antwort - Endpoint nicht erreichbar?"
        return 1
    fi

    local err; err=$(echo "$resp" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "$err" ]]; then
        # Schema abgelehnt? Dann ohne Schema nachfassen - der Checker faellt
        # zur Laufzeit genauso zurueck, das ist kein Ausschlusskriterium.
        schema_ok=false
        resp=$(curl -s --max-time 30 "$endpoint" \
            -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
            -d "$(jq -n --arg m "$model" '{model:$m,
                  messages:[{role:"user",content:"Sag ok."}],
                  max_completion_tokens:50}')")
        err=$(echo "$resp" | jq -r '.error.message // empty' 2>/dev/null)
        if [[ -n "$err" ]]; then
            echo -e "${RED}[FAIL]${NC} $err"
            return 1
        fi
    fi

    echo "$resp" | jq -e '.choices[0].message' >/dev/null 2>&1 || {
        echo -e "${RED}[FAIL]${NC} Unerwartete Antwort:"
        echo "$resp" | head -c 400; echo
        return 1
    }

    echo -e "${GREEN}[OK]${NC}   Endpoint, Token und Modell arbeiten"
    if $schema_ok; then
        echo -e "${GREEN}[OK]${NC}   Structured Outputs (response_format) unterstuetzt"
    else
        echo -e "${YELLOW}[WARN]${NC} Kein response_format - der Checker faellt auf freies JSON zurueck"
    fi
    return 0
}

write_profile() {
    local endpoint="$1" model="$2" token="$3" cost="$4"
    local reasoning="${5-$REASONING}" timeout="${6-$TIMEOUT}"
    mkdir -p "$PROFILE_DIR"
    umask 077
    cat > "$CONF" <<EOF
; Aktives Anbieterprofil des AI-Spamfilters.
; Angelegt von ai-filter-model.sh - enthaelt einen API-Token, daher 0600.
; Loeschen oder "ai-filter-model.sh --reset" stellt den Auslieferungszustand her.
endpoint = $endpoint
model = $model
token = $token
cost_per_call = $cost
reasoning_effort = $reasoning
api_timeout = $timeout
EOF
    chmod 600 "$CONF"
    chown root:root "$CONF" 2>/dev/null || true
    # Token je Anbieter merken, damit ein Rueckwechsel nicht erneut fragt.
    local name; name=$(provider_name "$endpoint")
    printf '%s\n' "$token" > "$PROFILE_DIR/$name.token"
    chmod 600 "$PROFILE_DIR/$name.token"
    chown root:root "$PROFILE_DIR/$name.token" 2>/dev/null || true
}


# --- Die Timeout-Kette ------------------------------------------------
# Drei Uhren laufen gleichzeitig, und ihre Reihenfolge entscheidet, WIE
# der Filter kaputtgeht:
#
#   api_timeout  <  http_timeout  <  task_timeout
#
# Laeuft http_timeout zuerst ab, faellt das Lua-Modul offen aus und die
# Mail wird ohne KI-Bewertung zugestellt - unschoen, aber harmlos.
# Laeuft task_timeout zuerst ab, weist Rspamd die Mail per SOFT REJECT
# ab. Deshalb darf die Reihenfolge nie kippen, und deshalb setzt dieses
# Skript alle drei Werte gemeinsam statt einen einzeln.
HTTP_MARGIN=3      # was der Checker neben dem API-Aufruf noch braucht
TASK_MARGIN=8      # was Rspamd neben dem KI-Aufruf noch braucht

http_timeout_for() { echo $(( $1 + HTTP_MARGIN )); }
task_timeout_for() { echo $(( $1 + HTTP_MARGIN + TASK_MARGIN )); }

current_http_timeout() {
    local v=""
    [[ -f "$LUA_SETTINGS" ]] && v=$(sed -n 's/^[[:space:]]*http_timeout[[:space:]]*=[[:space:]]*\([0-9.]*\).*/\1/p' "$LUA_SETTINGS" | head -1)
    echo "${v:-?}"
}
current_task_timeout() {
    local v=""
    [[ -f "$RSPAMD_OPTIONS" ]] && v=$(sed -n 's/^[[:space:]]*task_timeout[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$RSPAMD_OPTIONS" | head -1)
    # Ohne eigenen Eintrag gilt mailcows Vorgabe.
    echo "${v:-25 (Vorgabe)}"
}

apply_timeout_chain() {
    local api="$1"
    local http; http=$(http_timeout_for "$api")
    local task; task=$(task_timeout_for "$api")

    # 1. Lua-Settings
    if [[ -f "$LUA_SETTINGS" ]]; then
        cp "$LUA_SETTINGS" "$LUA_SETTINGS.backup.$(date +%s)"
        sed -i "s/^\([[:space:]]*http_timeout[[:space:]]*=[[:space:]]*\)[0-9.]*.*/\1${http}.0,   -- muss unter task_timeout (${task}s) bleiben/" \
            "$LUA_SETTINGS"
        echo -e "${GREEN}[OK]${NC}   http_timeout = ${http}s  ($LUA_SETTINGS)"
    else
        echo -e "${YELLOW}[WARN]${NC} $LUA_SETTINGS fehlt - http_timeout nicht gesetzt"
    fi

    # 2. Rspamds globaler task_timeout. local.d ueberlebt mailcow-Updates.
    mkdir -p "$(dirname "$RSPAMD_OPTIONS")"
    touch "$RSPAMD_OPTIONS"
    if grep -q '^[[:space:]]*task_timeout' "$RSPAMD_OPTIONS"; then
        cp "$RSPAMD_OPTIONS" "$RSPAMD_OPTIONS.backup.$(date +%s)"
        sed -i "s/^\([[:space:]]*task_timeout[[:space:]]*=[[:space:]]*\)[0-9]*.*/\1${task}s;/" "$RSPAMD_OPTIONS"
    else
        printf '\n# Gesetzt von ai-filter-model.sh: muss ueber http_timeout des\n# AI-Filters liegen, sonst weist Rspamd langsame Mails per soft\n# reject ab statt sie unbewertet zuzustellen.\ntask_timeout = %ss;\n' \
            "$task" >> "$RSPAMD_OPTIONS"
    fi
    echo -e "${GREEN}[OK]${NC}   task_timeout = ${task}s  ($RSPAMD_OPTIONS)"

    # 3. Durchsatz. Der Engpass sind die PHP-Worker, nicht die Uhren - aber
    #    das Container-Neuerstellen und den Speicherbedarf entscheidet der
    #    Betreiber, nicht dieses Skript.
    local workers burst
    workers=$(grep -oP 'PHP_CLI_SERVER_WORKERS=\K[0-9]+' docker-compose.override.yml 2>/dev/null | head -1)
    workers=${workers:-4}
    burst=$(( workers * task / api ))
    if (( api > 10 )); then
        echo
        echo -e "${DIM}Durchsatz: ${workers} Worker a ${api}s bedienen etwa $(( workers * 60 / api )) Mails/Minute.${NC}"
        echo -e "${DIM}Ein Schwung von mehr als ~${burst} gleichzeitigen Mails laeuft in den${NC}"
        echo -e "${DIM}task_timeout. Falls das vorkommt, PHP_CLI_SERVER_WORKERS erhoehen:${NC}"
        echo -e "${DIM}  \$EDITOR $MAILCOW_DIR/docker-compose.override.yml${NC}"
        echo -e "${DIM}  $COMPOSE_CMD up -d ai-checker${NC}"
    fi
}

restart_rspamd() {
    echo -e "${DIM}Starte rspamd neu ...${NC}"
    $COMPOSE_CMD restart rspamd-mailcow >/dev/null 2>&1 \
        && echo -e "${GREEN}[OK]${NC}   rspamd neu gestartet" \
        || echo -e "${YELLOW}[WARN]${NC} Neustart fehlgeschlagen - bitte manuell: $COMPOSE_CMD restart rspamd-mailcow"
}

restart_checker() {
    echo -e "${DIM}Starte ai-checker neu …${NC}"
    $COMPOSE_CMD restart ai-checker >/dev/null 2>&1 \
        && echo -e "${GREEN}[OK]${NC}   ai-checker neu gestartet" \
        || echo -e "${YELLOW}[WARN]${NC} Neustart fehlgeschlagen - bitte manuell: $COMPOSE_CMD restart ai-checker"
}

# --- Aktionen ----------------------------------------------------------
case "$ACTION" in

status)
    echo
    echo -e "Aktiv:    ${GREEN}$ACTIVE${NC}$([[ -f $CONF ]] || echo -e " ${DIM}(Auslieferungszustand, kein Profil)${NC}")"
    echo    "Endpoint: $ENDPOINT"
    echo    "Modell:   $MODEL"
    echo -e "Token:    $(mask_token "$TOKEN")"
    echo    "Kosten:   $COST EUR pro Anfrage"
    echo    "Reasoning: ${REASONING:-(Vorgabe des Anbieters)}"
    echo    "Timeout:  ${TIMEOUT}s"
    if [[ -d "$PROFILE_DIR" ]]; then
        echo "Profile:  $(ls "$PROFILE_DIR"/*.token 2>/dev/null | xargs -rn1 basename | sed 's/\.token$//' | paste -sd', ' -)"
    fi
    echo
    echo -e "${DIM}ai-filter-model.sh --models   zeigt die verfuegbaren Modelle${NC}"
    echo
    ;;

models)
    [[ -n "$TOKEN" ]] || { echo -e "${RED}Kein Token gesetzt${NC}"; exit 1; }
    echo -e "${DIM}Modelle bei $ACTIVE:${NC}"
    found=$(list_models "$TOKEN")
    if [[ -z "$found" ]]; then
        echo -e "${RED}Keine Liste erhalten${NC} - Endpoint oder Token pruefen"
        exit 1
    fi
    echo "$found" | sed "s/^/  /; s|^  $MODEL\$|  * $MODEL|"
    echo
    echo -e "${DIM}* = aktiv${NC}"
    ;;

test)
    [[ -n "$TOKEN" ]] || { echo -e "${RED}Kein Token gesetzt${NC}"; exit 1; }
    run_test "$ENDPOINT" "$TOKEN" "$MODEL"
    ;;

setmodel)
    [[ -n "$ARG" ]] || { echo -e "${RED}--model braucht eine Modell-ID${NC}"; exit 1; }
    [[ -n "$TOKEN" ]] || { echo -e "${RED}Kein Token gesetzt${NC}"; exit 1; }
    echo
    echo "Wechsel: $MODEL  ->  $ARG"
    echo
    if ! run_test "$ENDPOINT" "$TOKEN" "$ARG"; then
        echo
        echo -e "${YELLOW}Nichts geaendert${NC} - der Filter laeuft weiter auf $MODEL"
        exit 1
    fi
    echo
    echo -e "${YELLOW}Hinweis:${NC} Die Schwellen des Filters (confidence >= 0.80, REJECT_FLOOR)"
    echo    "sind gegen das bisherige Modell kalibriert. Ein anderes Modell meint"
    echo    "mit derselben Zahl nicht dasselbe - beobachte ai-filter-log.sh -R."
    echo
    echo -e "${YELLOW}Hinweis:${NC} cost_per_call bleibt bei $COST EUR. Der Preis haengt am"
    echo    "Modell - passe ihn bei Bedarf an: ai-filter-model.sh --cost <EUR>"
    echo
    write_profile "$ENDPOINT" "$ARG" "$TOKEN" "$COST"
    echo -e "${GREEN}[OK]${NC}   Profil geschrieben: $MAILCOW_DIR/$CONF"
    restart_checker
    ;;

useprovider)
    NEW_ENDPOINT=$(preset_endpoint "$ARG") || {
        echo -e "${RED}Unbekannter Anbieter:${NC} ${ARG:-(leer)}"
        echo "Moeglich: ionos, hetzner"
        exit 1
    }
    NEW_MODEL=$(preset_model "$ARG")
    NEW_COST=$(preset_cost "$ARG")

    if [[ "$ARG" == "$ACTIVE" ]]; then
        echo -e "${YELLOW}$ARG ist bereits aktiv${NC}"
        exit 0
    fi

    # --- Datenschutzhinweis. Kein Enter-Weiterklicken. ---
    if [[ "$ARG" != "ionos" ]]; then
        echo
        echo -e "${RED}=== Datenschutzhinweis ===${NC}"
        echo
        echo "Du wechselst den Auftragsverarbeiter, an den Inhalte fremder"
        echo "E-Mails uebermittelt werden. Das ist eine Verarbeitung"
        echo "personenbezogener Daten Dritter. Vor dem Wechsel noetig:"
        echo
        echo "  - Auftragsverarbeitungsvertrag nach Art. 28 DSGVO mit dem"
        echo "    neuen Anbieter"
        echo "  - Verarbeitungsverzeichnis nach Art. 30 anpassen"
        echo "  - Datenschutzerklaerung anpassen"
        echo
        if [[ "$ARG" == "hetzner" ]]; then
            echo -e "${YELLOW}Zu Hetzner Inference im Besonderen:${NC} Das Angebot laeuft unter"
            echo "\"Experiments\", ohne Abrechnung und ohne SLA. Ohne Vertrag gibt es"
            echo "auch keinen AVV - fuer echte Fremdkorrespondenz ist das nicht"
            echo "geeignet, unabhaengig vom EU-Standort. Ausserdem kann der"
            echo "Dienst jederzeit enden; der Filter faellt dann aus."
            echo
        fi
        echo "Verstanden? Dann tippe den Anbieternamen: ${ARG}"
        read -r -p "> " confirm
        if [[ "$confirm" != "$ARG" ]]; then
            echo -e "${YELLOW}Abgebrochen${NC} - nichts geaendert"
            exit 1
        fi
        echo
    fi

    # Token: gemerkten wiederverwenden, sonst fragen.
    NEW_TOKEN=""
    if [[ -r "$PROFILE_DIR/$ARG.token" ]]; then
        NEW_TOKEN=$(cat "$PROFILE_DIR/$ARG.token")
        echo -e "${GREEN}[OK]${NC}   Gemerkten Token fuer $ARG gefunden"
    fi
    if [[ -z "$NEW_TOKEN" ]]; then
        echo "API-Token fuer $ARG (Eingabe wird nicht angezeigt):"
        read -r -s -p "> " NEW_TOKEN
        echo
        [[ -n "$NEW_TOKEN" ]] || { echo -e "${RED}Kein Token - abgebrochen${NC}"; exit 1; }
    fi

    echo
    if ! run_test "$NEW_ENDPOINT" "$NEW_TOKEN" "$NEW_MODEL"; then
        echo
        echo -e "${YELLOW}Nichts geaendert${NC} - der Filter laeuft weiter auf $ACTIVE / $MODEL"
        exit 1
    fi

    # Alten Token sichern, damit --use ionos ohne Nachfrage zurueckfuehrt.
    if [[ -n "$TOKEN" ]]; then
        mkdir -p "$PROFILE_DIR"; umask 077
        printf '%s\n' "$TOKEN" > "$PROFILE_DIR/$ACTIVE.token"
        chmod 600 "$PROFILE_DIR/$ACTIVE.token"
        chown root:root "$PROFILE_DIR/$ACTIVE.token" 2>/dev/null || true
    fi

    write_profile "$NEW_ENDPOINT" "$NEW_MODEL" "$NEW_TOKEN" "$NEW_COST"
    echo
    echo -e "${GREEN}[OK]${NC}   $ACTIVE  ->  $ARG ($NEW_MODEL)"
    restart_checker
    ;;

setcost)
    if [[ ! $ARG =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo -e "${RED}--cost braucht eine Zahl${NC}, z.B. 0.0016 (oder 0 fuer kostenlos)"
        exit 1
    fi

    BUDGET=$(monthly_budget)
    BUDGET=${BUDGET:-50}

    echo
    echo "Kosten pro Anfrage: $COST  ->  $ARG EUR"
    if [[ "$ARG" == "0" || "$ARG" == "0.0" ]]; then
        echo "Budgetbremse: aus (kostenloser Anbieter)"
    else
        # Die Bremse zaehlt Anfragen, nicht Euro - also ausrechnen, wie
        # viele das beim neuen Preis sind. Sonst ist die Zahl bedeutungslos.
        echo "Budgetbremse: $BUDGET EUR entsprechen jetzt $(awk -v b="$BUDGET" -v c="$ARG" 'BEGIN{printf "%d", b/c}') Anfragen pro Monat"
    fi
    echo

    write_profile "$ENDPOINT" "$MODEL" "$TOKEN" "$ARG"
    echo -e "${GREEN}[OK]${NC}   Profil aktualisiert"
    restart_checker
    ;;

setreasoning)
    if [[ ! $ARG =~ ^(low|medium|high)$ ]]; then
        echo -e "${RED}--reasoning braucht low, medium oder high${NC}"
        exit 1
    fi
    echo
    echo "Reasoning: ${REASONING:-(Vorgabe)}  ->  $ARG"
    echo -e "${DIM}Antwortzeit messen ...${NC}"
    START=$(date +%s)
    if ! REASONING="$ARG" run_test "$ENDPOINT" "$TOKEN" "$MODEL" >/dev/null 2>&1; then
        echo -e "${RED}[FAIL]${NC} Testanfrage fehlgeschlagen - nichts geaendert"
        exit 1
    fi
    ELAPSED=$(( $(date +%s) - START ))
    echo -e "${GREEN}[OK]${NC}   Testanfrage in ${ELAPSED}s"
    # Eine Messung, die ueber dem Timeout liegt, wuerde im Betrieb jede
    # Mail unbewertet lassen - lieber hier sagen als spaeter im Log finden.
    # Ein Drittel Luft auf die Messung: die Antwortzeit schwankt, und ein
    # knapp bemessenes Budget faellt genau bei Last aus.
    SUGGEST=$(( (ELAPSED * 4 + 2) / 3 ))
    if (( ELAPSED > TIMEOUT )); then
        echo -e "${YELLOW}[WARN]${NC} laenger als das Budget von ${TIMEOUT}s - so bleibt jede Mail unbewertet."
        echo    "        Passend waere:  ai-filter-model.sh --timeout $SUGGEST"
    elif (( ELAPSED * 4 > TIMEOUT * 3 )); then
        echo -e "${YELLOW}[HINWEIS]${NC} nur wenig Luft zum Budget von ${TIMEOUT}s."
        echo    "        Mehr Reserve mit:  ai-filter-model.sh --timeout $SUGGEST"
    fi
    write_profile "$ENDPOINT" "$MODEL" "$TOKEN" "$COST" "$ARG" "$TIMEOUT"
    echo -e "${GREEN}[OK]${NC}   Profil aktualisiert"
    restart_checker
    ;;

settimeout)
    if [[ ! $ARG =~ ^[0-9]+$ ]] || (( ARG < 5 )); then
        echo -e "${RED}--timeout braucht eine ganze Zahl ab 5${NC}"
        exit 1
    fi
    if (( ARG > 120 )); then
        echo -e "${RED}Ueber 120s ist keine sinnvolle Zustellzeit mehr${NC}"
        exit 1
    fi

    NEW_HTTP=$(http_timeout_for "$ARG")
    NEW_TASK=$(task_timeout_for "$ARG")

    echo
    echo "Timeout-Kette:"
    printf '  %-14s %11ss  ->  %4ss   (Profil)\n'       'api_timeout'  "$TIMEOUT" "$ARG"
    printf '  %-14s %12s  ->  %4ss   (Lua-Settings)\n'  'http_timeout' "$(current_http_timeout)" "$NEW_HTTP"
    printf '  %-14s %12s  ->  %4ss   (rspamd)\n'        'task_timeout' "$(current_task_timeout)" "$NEW_TASK"
    echo
    echo -e "${DIM}Reihenfolge bleibt gewahrt: laeuft die Zeit ab, faellt der Filter${NC}"
    echo -e "${DIM}offen aus und die Mail wird zugestellt - kein soft reject.${NC}"
    echo

    write_profile "$ENDPOINT" "$MODEL" "$TOKEN" "$COST" "$REASONING" "$ARG"
    echo -e "${GREEN}[OK]${NC}   api_timeout = ${ARG}s  ($CONF)"
    apply_timeout_chain "$ARG"
    restart_checker
    restart_rspamd
    ;;

reset)
    if [[ ! -f "$CONF" ]]; then
        echo -e "${YELLOW}Kein Profil vorhanden${NC} - laeuft bereits im Auslieferungszustand"
        exit 0
    fi
    rm -f "$CONF"
    echo -e "${GREEN}[OK]${NC}   Profil entfernt, zurueck auf $(php_default AI_MODEL_DEFAULT)"
    echo -e "${DIM}Gemerkte Token bleiben unter $PROFILE_DIR liegen.${NC}"
    restart_checker
    ;;

esac
