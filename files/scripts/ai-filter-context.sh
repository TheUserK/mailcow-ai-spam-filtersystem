#!/bin/bash
# =====================================================================
#  Unternehmenskontext der eigenen Domains ermitteln
#
#  Der Filter beurteilte jede Mail bisher im luftleeren Raum: Er wusste
#  nicht, WAS der Empfaenger eigentlich macht. Damit blieb eine ganze
#  Betrugsart unsichtbar - Mails, die den Empfaenger als Anbieter einer
#  Leistung ansprechen, die er gar nicht erbringt.
#
#  Am 04.09. kamen binnen 20 Minuten vier fast gleichlautende deutsche
#  Zimmeranfragen ("Standardzimmer fuer eine Person", "Buchung eines
#  Einzelzimmers") - von einer britischen Steuerkanzlei, einer
#  portugiesischen IT-Firma, einem rumaenischen Hotel und einer
#  brasilianischen Oelmuehle. Alle vier Absenderdomains sind echt, alle
#  vier technisch einwandfrei authentifiziert (gekaperte Konten), alle
#  vier verlinkten einen Google-Share-Link. Rspamd sah nichts, das
#  Modell stufte sie als "personal" mit -2.16 ein.
#
#  Was daran auffaellt, sieht man erst mit einer Information, die nirgends
#  im Kopf der Mail steht: Der Empfaenger vermietet gar keine Zimmer.
#
#  Dieses Skript holt die Website jeder eigenen Domain, laesst das Modell
#  daraus in einem Satz beschreiben, was die Firma tut, und legt das
#  Ergebnis fuer den Checker ab. Ist keine Seite erreichbar, gilt die
#  Domain als privat - auch das ist eine brauchbare Aussage.
#
#  Aufruf:
#    ai-filter-context.sh              neue Domains ergaenzen
#    ai-filter-context.sh --refresh    alles neu bestimmen
#    ai-filter-context.sh --domain D   nur diese eine Domain
#    ai-filter-context.sh --status     was aktuell hinterlegt ist
#    ai-filter-context.sh --show D     Eintrag einer Domain ansehen
#
#  Ergebnis: data/ai-checker/business_context.json
#  Eintraege mit "manuell": true werden nie ueberschrieben - so korrigiert
#  man eine Fehleinschaetzung dauerhaft.
# =====================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'

ACTION=new
ONE_DOMAIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --refresh) ACTION=refresh; shift ;;
        --domain)  ACTION=one; ONE_DOMAIN="${2:-}"; shift 2 ;;
        --status)  ACTION=status; shift ;;
        --show)    ACTION=show; ONE_DOMAIN="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

command -v jq   >/dev/null || { echo -e "${RED}jq is required${NC} - apt install jq"; exit 1; }
command -v perl >/dev/null || { echo -e "${RED}perl is required${NC}"; exit 1; }

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }
cd "$MAILCOW_DIR" || exit 1

OUT="data/ai-checker/business_context.json"
CHECKER="data/ai-checker/ai-mail-checker.php"
CONF="data/ai-checker/provider.conf"

# --- Anzeigen ---------------------------------------------------------
if [[ "$ACTION" == "status" ]]; then
    if [[ ! -f "$OUT" ]]; then
        echo -e "${YELLOW}Noch nichts hinterlegt${NC} - ai-filter-context.sh aufrufen"
        exit 0
    fi
    echo -e "${GREEN}Vorhanden${NC}: $OUT"
    jq -r '.domains | to_entries[] |
           "  \(.key)\n      \(.value.art)\(if .value.manuell then " (manuell)" else "" end): \(.value.beschreibung)"' "$OUT"
    exit 0
fi

if [[ "$ACTION" == "show" ]]; then
    [[ -f "$OUT" ]] || { echo -e "${RED}Datei fehlt${NC}"; exit 1; }
    jq -e --arg d "$ONE_DOMAIN" '.domains[$d]' "$OUT" 2>/dev/null \
        || { echo -e "${YELLOW}Kein Eintrag fuer '$ONE_DOMAIN'${NC}"; exit 1; }
    exit 0
fi

# --- Zugangsdaten wie im Checker: Profil schlaegt Auslieferungszustand --
[[ -f "$CHECKER" ]] || { echo -e "${RED}Checker not installed:${NC} $MAILCOW_DIR/$CHECKER"; exit 1; }

conf_value() {
    [[ -f "$CONF" ]] || return 1
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | head -1
}
php_default() {
    grep -oP "define\('$1',\s*'\K[^']*" "$CHECKER" 2>/dev/null | head -1
}
setting() {
    local from_conf; from_conf=$(conf_value "$1" || true)
    if [[ -n "$from_conf" ]]; then echo "$from_conf"; else php_default "$2"; fi
}

ENDPOINT=$(setting endpoint AI_API_ENDPOINT_DEFAULT)
MODEL=$(setting model AI_MODEL_DEFAULT)
TOKEN=$(setting token AI_API_TOKEN_DEFAULT)

[[ -n "$TOKEN" ]] || { echo -e "${RED}Kein API-Token gefunden${NC} - ai-filter-model.sh pruefen"; exit 1; }

if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"
else echo -e "${RED}Docker Compose not found${NC}"; exit 1; fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- Domainliste ------------------------------------------------------
# Aus derselben Quelle wie isInternalMail() im Checker, damit beide
# dasselbe unter "eigene Domain" verstehen.
local_domains() {
    # shellcheck disable=SC1091
    source mailcow.conf
    $COMPOSE_CMD exec -T -e MYSQL_PWD="$DBPASS" mysql-mailcow \
        mysql -u"$DBUSER" "$DBNAME" -N -B \
        -e "SELECT domain FROM domain WHERE active = 1" 2>/dev/null \
        | tr -d '\r' | grep -E '^[a-zA-Z0-9._-]+$' || true
}

# --- Website holen ----------------------------------------------------
# Kein Browser-Rendering, keine geratenen Unterseiten: nur was die Seite
# selbst verlinkt, und nur auf derselben Domain.
UA="Mozilla/5.0 (compatible; ai-filter-context/1.0; +local mail filter)"

# Setzt HTTP_CODE und EFFECTIVE_URL, legt den Body in $2 ab.
fetch() {
    local url="$1" dest="$2" meta
    meta=$(curl -sL --max-time 15 --max-redirs 5 -A "$UA" \
                --compressed -o "$dest" -w '%{http_code} %{url_effective}' \
                "$url" 2>/dev/null) || { HTTP_CODE=000; EFFECTIVE_URL=""; return 1; }
    HTTP_CODE="${meta%% *}"
    EFFECTIVE_URL="${meta#* }"
    [[ "$HTTP_CODE" == "200" ]]
}

host_of() {
    perl -ne 'print lc($1) if m{^[a-z]+://([^/:]+)}i' <<<"$1"
}

# Landet die Weiterleitung noch auf derselben Domain? Sonst ist es eine
# geparkte Domain, die irgendwohin zeigt - dann sagt die Seite nichts
# ueber den Empfaenger aus.
same_site() {
    local host="$1" domain="$2"
    host="${host#www.}"
    [[ "$host" == "$domain" || "$host" == *".$domain" ]]
}

html_to_text() {
    perl -0777 -pe '
        s{<(script|style|noscript|svg)\b.*?</\1>}{ }gis;
        s{<!--.*?-->}{ }gs;
        s{<[^>]+>}{ }gs;
        s{&nbsp;|&#160;}{ }gi;
        s{&amp;}{&}gi; s{&lt;}{<}gi; s{&gt;}{>}gi; s{&quot;}{"}gi; s{&#39;}{'"'"'}g;
        # Deutsche Umlaute als Entity sind auf aelteren Seiten normal. Ohne
        # diese Zeile wird aus "&Uuml;ber uns" ein " ber uns" - schlechter
        # Text fuer die Einstufung, und zwar genau bei deutschen Betrieben.
        s{&Auml;}{Ae}g;  s{&auml;}{ae}g;  s{&Ouml;}{Oe}g;  s{&ouml;}{oe}g;
        s{&Uuml;}{Ue}g;  s{&uuml;}{ue}g;  s{&szlig;}{ss}g; s{&euro;}{ EUR }gi;
        s{&[a-z]+;|&#\d+;}{ }gi;
        s{\s+}{ }g;
    '
}

# Echte Links der Seite, nur dieselbe Domain. Bevorzugt werden die, die
# ueblicherweise beschreiben was eine Firma tut - aber nur, wenn sie auch
# wirklich verlinkt sind. Nichts wird geraten.
pick_links() {
    local file="$1" base="$2" domain="$3"
    perl -0777 -ne '
        while (m{<a\b[^>]*href\s*=\s*["\x27]([^"\x27#]+)["\x27]}gis) { print "$1\n" }
    ' "$file" \
    | while IFS= read -r href; do
        case "$href" in
            http://*|https://*) echo "$href" ;;
            /*)                 echo "${base}${href}" ;;
            mailto:*|tel:*|javascript:*) ;;
            *)                  echo "${base}/${href}" ;;
        esac
      done \
    | awk '!seen[$0]++' \
    | while IFS= read -r url; do
        same_site "$(host_of "$url")" "$domain" && echo "$url"
      done \
    | awk '
        {
            p = 9
            u = tolower($0)
            if (u ~ /impressum|ueber-uns|über-uns|about|unternehmen|company/) p = 1
            else if (u ~ /leistung|service|produkt|angebot|portfolio|zimmer|rooms/) p = 2
            else if (u ~ /kontakt|contact/) p = 3
            else next
            print p "\t" $0
        }' \
    | sort -k1,1n | cut -f2- | head -3
}

# --- Klassifizieren ---------------------------------------------------
SYS_PROMPT='Du beschreibst anhand von Website-Text, was ein Unternehmen tatsaechlich tut.

Antworte AUSSCHLIESSLICH mit diesem JSON, ohne weiteren Text:
{"beschreibung": "...", "branche": "..."}

"beschreibung": EIN Satz auf Deutsch, hoechstens 200 Zeichen. Nenne die
Taetigkeit und die angebotenen Leistungen konkret. Haenge an, was dieser
Betrieb erkennbar NICHT ist, wenn es sich klar sagen laesst - zum Beispiel
"; kein Beherbergungs- oder Gastgewerbe" bei einer Softwarefirma. Diese
Abgrenzung hilft spaeter, unsinnige Anfragen zu erkennen.

"branche": ein bis drei Woerter.

Wenn der Text zu duenn, generisch oder offensichtlich eine Platzhalterseite
ist, antworte mit leerer "beschreibung". Rate nichts zusammen.'

classify() {
    local text="$1" payload resp content json
    payload=$(jq -n --arg m "$MODEL" --arg s "$SYS_PROMPT" --arg u "$text" '{
        model: $m,
        messages: [ {role:"system",content:$s}, {role:"user",content:$u} ],
        temperature: 0,
        max_completion_tokens: 500
    }')
    resp=$(curl -sS --max-time 90 "$ENDPOINT" \
             -H "Authorization: Bearer $TOKEN" \
             -H 'Content-Type: application/json' \
             -d "$payload" 2>/dev/null) || return 1
    content=$(jq -r '.choices[0].message.content // empty' <<<"$resp" 2>/dev/null) || return 1
    [[ -n "$content" ]] || return 1
    # Modelle verpacken JSON gern in ```-Bloecke oder stellen Text voran.
    json=$(perl -0777 -ne 'print $1 if /(\{.*\})/s' <<<"$content")
    [[ -n "$json" ]] || return 1
    jq -e . >/dev/null 2>&1 <<<"$json" || return 1
    echo "$json"
}

# Holt Startseite + bis zu 3 verlinkte Unterseiten, gibt Text aus.
# Rueckgabe ueber PAGE_TEXT / PAGE_SOURCE / PAGE_STATUS.
collect_text() {
    local domain="$1" url base
    PAGE_TEXT=""; PAGE_SOURCE=""; PAGE_STATUS=""

    for url in "https://${domain}/" "https://www.${domain}/" "http://${domain}/"; do
        if fetch "$url" "$TMP/page.html"; then
            local host; host=$(host_of "$EFFECTIVE_URL")
            if ! same_site "$host" "$domain"; then
                PAGE_STATUS="weiterleitung auf $host"
                continue
            fi
            PAGE_SOURCE="$EFFECTIVE_URL"
            PAGE_STATUS="$HTTP_CODE"
            break
        fi
        [[ -z "$PAGE_STATUS" || "$PAGE_STATUS" =~ ^[0-9]+$ ]] && PAGE_STATUS="HTTP $HTTP_CODE"
    done

    [[ -n "$PAGE_SOURCE" ]] || return 1

    base="${PAGE_SOURCE%/}"
    base=$(perl -ne 'print $1 if m{^([a-z]+://[^/]+)}i' <<<"$base")

    { html_to_text < "$TMP/page.html"; } > "$TMP/text.txt"

    local sub
    while IFS= read -r sub; do
        [[ -n "$sub" ]] || continue
        if fetch "$sub" "$TMP/sub.html"; then
            printf ' \n' >> "$TMP/text.txt"
            html_to_text < "$TMP/sub.html" >> "$TMP/text.txt"
        fi
    done < <(pick_links "$TMP/page.html" "$base" "$domain")

    PAGE_TEXT=$(cut -c1-4000 "$TMP/text.txt" | head -c 4000)
    return 0
}

# --- Hauptlauf --------------------------------------------------------
mkdir -p data/ai-checker
if [[ ! -f "$OUT" ]]; then
    jq -n '{
        _hinweis: "Erzeugt von ai-filter-context.sh. Eintraege mit \"manuell\": true bleiben unangetastet - so korrigiert man eine Fehleinschaetzung dauerhaft.",
        domains: {}
    }' > "$OUT"
    chmod 644 "$OUT"
fi

if [[ "$ACTION" == "one" ]]; then
    DOMAINS="$ONE_DOMAIN"
else
    DOMAINS=$(local_domains)
    if [[ -z "$DOMAINS" ]]; then
        echo -e "${RED}Keine Domains aus der Mailcow-Datenbank gelesen${NC}"
        echo "  Laeuft der mysql-mailcow-Container? Sind DBUSER/DBPASS in mailcow.conf gesetzt?"
        exit 1
    fi
fi

CHANGED=0
SKIPPED=0

for domain in $DOMAINS; do
    domain=$(tr '[:upper:]' '[:lower:]' <<<"$domain")

    if jq -e --arg d "$domain" '.domains[$d].manuell == true' "$OUT" >/dev/null 2>&1; then
        echo -e "  ${DIM}$domain: manuell gepflegt, bleibt${NC}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if [[ "$ACTION" == "new" ]] && jq -e --arg d "$domain" '.domains[$d]' "$OUT" >/dev/null 2>&1; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    printf '  %s ... ' "$domain"

    ART="privat"; BESCHREIBUNG=""; QUELLE=""; NOTIZ=""

    if collect_text "$domain"; then
        QUELLE="$PAGE_SOURCE"
        # Zu wenig echter Text heisst: JS-Seite, Baustelle, Platzhalter.
        # Dann lieber nichts sagen als etwas erfinden.
        if [[ ${#PAGE_TEXT} -lt 200 ]]; then
            ART="unbekannt"
            NOTIZ="Seite erreichbar, aber kaum auswertbarer Text (${#PAGE_TEXT} Zeichen)"
            echo -e "${YELLOW}zu wenig Text${NC}"
        elif RESULT=$(classify "$PAGE_TEXT"); then
            BESCHREIBUNG=$(jq -r '.beschreibung // ""' <<<"$RESULT")
            if [[ -n "$BESCHREIBUNG" ]]; then
                ART="firma"
                echo -e "${GREEN}Firma${NC}"
            else
                ART="unbekannt"
                NOTIZ="Modell konnte aus dem Seitentext nichts ableiten"
                echo -e "${YELLOW}nicht einzuordnen${NC}"
            fi
        else
            ART="unbekannt"
            NOTIZ="Klassifizierung fehlgeschlagen (API)"
            echo -e "${RED}API-Fehler${NC}"
        fi
    else
        # Keine erreichbare Seite. Das ist die Aussage, die der Betreiber
        # sieht und bei Bedarf korrigiert - deshalb steht der Grund dabei.
        ART="privat"
        BESCHREIBUNG="Private Domain ohne oeffentlich erreichbare Website - kein Betrieb, der Leistungen fuer Dritte anbietet."
        NOTIZ="${PAGE_STATUS:-nicht erreichbar}"
        echo -e "${YELLOW}privat${NC} ${DIM}($NOTIZ)${NC}"
    fi

    jq --arg d "$domain" --arg art "$ART" --arg b "$BESCHREIBUNG" \
       --arg q "$QUELLE" --arg n "$NOTIZ" --arg t "$(date '+%Y-%m-%d')" \
       '.domains[$d] = {art: $art, beschreibung: $b, quelle: $q, notiz: $n, geprueft: $t, manuell: false}' \
       "$OUT" > "$TMP/out.json" && mv "$TMP/out.json" "$OUT"
    chmod 644 "$OUT"
    CHANGED=$((CHANGED + 1))
done

echo ""
if [[ "$CHANGED" -eq 0 ]]; then
    echo -e "${GREEN}[OK]${NC} Nichts zu tun - $SKIPPED Domain(s) bereits hinterlegt."
else
    echo -e "${GREEN}[OK]${NC} $CHANGED Domain(s) bestimmt, $SKIPPED unveraendert -> $OUT"
    echo ""
    echo "Bitte einmal durchsehen - das Modell liest nur die Website, es kann daneben liegen:"
    echo "  ai-filter-context.sh --status"
    echo ""
    echo "Korrigieren: Beschreibung in $OUT anpassen und \"manuell\": true setzen,"
    echo "dann bleibt der Eintrag bei jedem weiteren Lauf unangetastet."
fi
