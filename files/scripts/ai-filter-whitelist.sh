#!/bin/bash
# =====================================================================
#  Whitelist des AI-Filters verwalten
#
#  Ein Eintrag ist ein Zustellversprechen: Mail von diesem Absender landet
#  im Posteingang - auch wenn Rspamd oder die KI sie fuer Spam halten.
#  Gebrochen wird es nur bei starken Hinweisen, dass das Konto selbst
#  missbraucht wird (Virus, ausfuehrbarer Anhang, Link auf einer
#  Phishing-Liste, oder die KI erkennt sicher Phishing/Betrug UND ein
#  Strukturbeleg wie eine umgeleitete Antwortadresse stuetzt das).
#
#  Anders als die Whitelist in mailcow:
#    - Der Absender muss sich ausweisen (DMARC, oder DKIM/SPF passend zur
#      Domain). Ein gefaelschtes "From: lieferant.de" bekommt nichts.
#    - Ein gekapertes Konto wird trotzdem erkannt.
#    - Die KI prueft weiterhin mit.
#
#  Gilt fuer alle Postfaecher dieses Servers. Aenderungen wirken nach
#  spaetestens einer Minute, ohne Neustart.
#
#  Aufruf:
#    ai-filter-whitelist.sh add lieferant.de "Hauptlieferant"
#    ai-filter-whitelist.sh add max@beispiel.de
#    ai-filter-whitelist.sh remove lieferant.de
#    ai-filter-whitelist.sh list
#    ai-filter-whitelist.sh check rechnung@lieferant.de
#    ai-filter-whitelist.sh mailcow             (Whitelist in mailcow zeigen)
#    ai-filter-whitelist.sh mailcow --import    (... und hierher uebernehmen)
# =====================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'

usage() {
    cat <<'USAGE'
Usage: ai-filter-whitelist.sh BEFEHL [ARGUMENTE]

  add EINTRAG [NOTIZ]   Domain (lieferant.de) oder Adresse (max@beispiel.de)
                        eintragen. Eine Domain gilt auch fuer ihre Subdomains.
  remove EINTRAG        Eintrag entfernen
  list                  alle Eintraege zeigen
  check ADRESSE         greift ein Eintrag fuer diesen Absender? Dazu die
                        letzten Urteile aus dem Log.
  mailcow [--import]    Whitelist-Eintraege in mailcow zeigen (nur lesen).
                        Mit --import werden sie hierher uebernommen - in
                        mailcow bleibt alles stehen.
  -h, --help            dieser Text

Abgelehnt werden: ganze Freemail-Domains (gmail.com, web.de, ... - dort
geht nur eine einzelne Adresse), eigene mailcow-Domains und alles ohne
Punkt in der Domain.

MAILCOW_DIR kann auf eine mailcow-Installation an anderer Stelle zeigen.
USAGE
}

[[ $# -ge 1 ]] || { usage; exit 1; }
CMD="$1"; shift
case "$CMD" in -h|--help|help) usage; exit 0 ;; esac

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }
cd "$MAILCOW_DIR" || exit 1

# Liegt neben ai-filter-settings.lua: Dieses Verzeichnis ist sicher im
# Rspamd-Container eingehaengt, das Lua-Modul liest es als
# /etc/rspamd/lua/ai-filter-whitelist.map.
FILE="data/conf/rspamd/lua/ai-filter-whitelist.map"
LOG="data/logs/ai-checker/stats.log"

# Dieselbe Liste wie im Lua-Modul, ergaenzt um Anbieter, bei denen eine
# ganze Domain ebenso sinnlos waere. Wer "gmx.de" freigibt, gibt jedem
# GMX-Konto ein Zustellversprechen.
FREEMAIL="gmail.com googlemail.com gmx.de gmx.net gmx.at gmx.ch web.de
t-online.de outlook.com outlook.de hotmail.com hotmail.de live.com live.de
msn.com yahoo.com yahoo.de icloud.com me.com mac.com aol.com aol.de mail.com
protonmail.com proton.me freenet.de arcor.de posteo.de mailbox.org
email.de online.de vodafone.de kabelmail.de mail.ru yandex.com yandex.ru
gmx.com zoho.com tutanota.com tuta.io"

ensure_file() {
    [[ -f "$FILE" ]] && return 0
    mkdir -p "$(dirname "$FILE")"
    cat > "$FILE" <<'HEAD'
# Whitelist des AI-Filters - verwaltet mit ai-filter-whitelist.sh
#
# Ein Eintrag pro Zeile: eine Domain (gilt auch fuer Subdomains) oder eine
# einzelne Adresse. Alles ab # ist Kommentar.
#
# Zugestellt wird nur, wenn der Absender sich fuer diese Domain ausweist
# (DMARC, oder DKIM/SPF passend zur From-Domain), und nur, solange es
# keine starken Hinweise auf ein missbrauchtes Konto gibt.
HEAD
    chmod 644 "$FILE"
}

# Normalisiert einen Eintrag oder bricht mit Begruendung ab.
# Mailcow-Schreibweisen (*@domain, @domain, *.domain) werden verstanden.
normalize_entry() {
    local raw="$1" e domain
    e=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]<>')
    e="${e#\*@}"; e="${e#@}"; e="${e#\*.}"

    if [[ "$e" == *[!a-z0-9@._+-]* ]]; then
        if [[ "$e" == *"*"* ]]; then
            echo "Platzhalter mitten im Eintrag gehen nicht - eine Domain gilt ohnehin fuer alle Subdomains" >&2
        else
            echo "Ungueltige Zeichen. Umlaut-Domains bitte in Punycode (xn--...) angeben" >&2
        fi
        return 1
    fi

    if [[ "$e" == *@* ]]; then
        [[ "$e" =~ ^[a-z0-9._+-]+@[a-z0-9.-]+$ ]] || { echo "Keine gueltige Adresse" >&2; return 1; }
        domain="${e#*@}"
    else
        domain="$e"
    fi

    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]{2,}$ ]] \
        || { echo "Keine gueltige Domain: $domain" >&2; return 1; }

    if [[ "$e" != *@* ]]; then
        local f
        for f in $FREEMAIL; do
            if [[ "$domain" == "$f" ]]; then
                echo "$domain ist ein Freemail-Anbieter - damit waere JEDES Konto dort freigegeben." >&2
                echo "Bitte die einzelne Adresse eintragen, z.B. name@$domain" >&2
                return 1
            fi
        done
    fi

    printf '%s\n' "$e"
}

# Aktive mailcow-Domains. Gleiche Quelle wie ai-filter-context.sh.
compose_cmd() {
    if docker compose version >/dev/null 2>&1; then echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"
    fi
}

mysql_query() {
    local cc; cc=$(compose_cmd)
    [[ -n "$cc" ]] || return 1
    # shellcheck disable=SC1091
    ( source mailcow.conf
      [[ -n "${DBPASS:-}" && -n "${DBUSER:-}" && -n "${DBNAME:-}" ]] || exit 1
      $cc exec -T -e MYSQL_PWD="$DBPASS" mysql-mailcow \
          mysql -u"$DBUSER" "$DBNAME" -N -B -e "$1" </dev/null 2>/dev/null ) | tr -d '\r'
    [[ ${PIPESTATUS[0]} -eq 0 ]]
}

is_own_domain() {
    local domain="$1" own
    own=$(mysql_query "SELECT domain FROM domain WHERE active = 1") || return 1
    while IFS= read -r d; do
        d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
        [[ -n "$d" ]] || continue
        [[ "$domain" == "$d" || "$domain" == *".$d" ]] && return 0
    done <<<"$own"
    return 1
}

entries() {
    [[ -f "$FILE" ]] || return 0
    sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//' "$FILE" \
        | tr '[:upper:]' '[:lower:]' | grep -v '^$' || true
}

has_entry() {
    entries | grep -qxF -- "$1"
}

# Schreibt ueber eine Kopie im selben Verzeichnis, damit Rspamd nie eine
# halb geschriebene Datei liest.
write_atomic() {
    local tmp
    tmp=$(mktemp "$FILE.XXXXXX") || return 1
    cat > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$FILE"
}

add_entry() {
    local raw="$1" note="${2:-}" e domain
    e=$(normalize_entry "$raw") || return 1
    domain="${e#*@}"

    if is_own_domain "$domain"; then
        echo -e "${RED}$domain ist eine eigene mailcow-Domain.${NC} Interne Post prueft der Filter ohnehin nicht," >&2
        echo    "und ein Eintrag wuerde nur gefaelschte Absender dieser Domain beguenstigen." >&2
        return 1
    fi

    ensure_file
    if has_entry "$e"; then
        echo -e "${YELLOW}[=]${NC} $e steht schon drin"
        return 0
    fi

    note=$(printf '%s' "$note" | tr -d '\n\r#')
    local line="$e"
    line+="   # $(date +%Y-%m-%d)"
    [[ -n "$note" ]] && line+=": $note"
    { cat "$FILE"; printf '%s\n' "$line"; } | write_atomic || { echo -e "${RED}Schreiben fehlgeschlagen${NC}" >&2; return 1; }
    echo -e "${GREEN}[OK]${NC} $e eingetragen - wirkt in spaetestens einer Minute"
}

remove_entry() {
    local e
    e=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]<>')
    e="${e#\*@}"; e="${e#@}"; e="${e#\*.}"
    if ! has_entry "$e"; then
        echo -e "${YELLOW}[!]${NC} $e steht nicht in der Liste"
        return 1
    fi
    awk -v e="$e" '{
        line = $0; key = line
        sub(/#.*/, "", key); gsub(/^[ \t]+|[ \t].*$/, "", key)
        if (tolower(key) != e) print line
    }' "$FILE" | write_atomic || { echo -e "${RED}Schreiben fehlgeschlagen${NC}"; return 1; }
    echo -e "${GREEN}[OK]${NC} $e entfernt"
}

list_entries() {
    if [[ -z "$(entries)" ]]; then
        echo "Die Whitelist ist leer."
        echo "Eintragen mit: ai-filter-whitelist.sh add lieferant.de \"Notiz\""
        return 0
    fi
    echo
    grep -v '^[[:space:]]*#' "$FILE" | grep -v '^[[:space:]]*$' \
        | awk '{ key = $1; rest = $0; sub(/^[^#]*#?[ ]*/, "", rest); printf "  %-40s %s\n", key, rest }'
    echo
    echo -e "${DIM}$(entries | wc -l) Eintraege in $FILE${NC}"
}

# Gleiche Logik wie whitelist_entry_for() im Lua-Modul.
match_for() {
    local addr="$1" domain="${1#*@}" d
    if has_entry "$addr"; then printf '%s\n' "$addr"; return 0; fi
    d="$domain"
    while [[ -n "$d" ]]; do
        if has_entry "$d"; then printf '%s\n' "$d"; return 0; fi
        [[ "$d" == *.* ]] || break
        d="${d#*.}"
    done
    return 1
}

check_sender() {
    local addr hit domain logdomain
    addr=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]<>')
    [[ "$addr" == *@* ]] || { echo -e "${RED}check braucht eine Absenderadresse${NC}"; return 1; }
    domain="${addr#*@}"

    echo
    if hit=$(match_for "$addr"); then
        echo -e "  ${GREEN}Eintrag greift:${NC} $hit"
        echo    "  Zugestellt wird, wenn der Absender sich fuer $domain ausweist"
        echo    "  (DMARC, sonst DKIM oder SPF passend zur Domain) und es keine"
        echo    "  starken Hinweise auf ein missbrauchtes Konto gibt."
    else
        echo -e "  ${YELLOW}Kein Eintrag${NC} fuer $addr"
    fi
    # Bei einem Domain-Eintrag alle Absender darunter zeigen, auch die
    # Subdomains - sonst fehlt genau die Mail, um die es geht.
    logdomain="${hit:-$domain}"
    logdomain="${logdomain#*@}"

    [[ -f "$LOG" ]] || { echo; return 0; }
    command -v jq >/dev/null || { echo; return 0; }

    # Im Log ist der lokale Teil gekuerzt (buc***@domain), die Domain
    # steht vollstaendig da.
    local lines
    lines=$({ for f in "$LOG".[0-9]*; do
                  [[ -e "$f" ]] || continue
                  case "$f" in *.gz) zcat -- "$f" 2>/dev/null ;; *) cat -- "$f" 2>/dev/null ;; esac
              done; cat -- "$LOG" 2>/dev/null; } \
        | jq -r --arg d "$logdomain" '
            select((.from // "") | ascii_downcase | (endswith("@" + $d) or endswith("." + $d))) |
            [ .timestamp[0:16],
              ((.total_score // 0)|tostring),
              (.category // "-"),
              (if .whitelist_verdict then
                 .whitelist_verdict + (if ((.whitelist_abuse // []) | length) > 0
                                       then " (" + (.whitelist_abuse | join(",")) + ")" else "" end)
               else "keine Whitelist" end),
              (.subject // "")
            ] | @tsv' 2>/dev/null | sort | tail -10)

    if [[ -n "$lines" ]]; then
        echo
        echo "  Letzte Urteile fuer $logdomain (Score = Rspamd + KI):"
        echo "$lines" | awk -F'\t' '{ printf "    %-17s %7s  %-13s %-34s %s\n", $1,$2,$3,$4,$5 }'
        echo
        echo -e "  ${DIM}deliver      zugestellt, egal welcher Score${NC}"
        echo -e "  ${DIM}abuse        Whitelist ausgesetzt - starke Hinweise auf ein missbrauchtes Konto${NC}"
        echo -e "  ${DIM}auth-failed  Absender hat sich nicht fuer die Domain ausgewiesen - normale Bewertung${NC}"
    fi
    echo
}

# mailcows eigene Whitelist (Tabelle filterconf, option whitelist_from).
# Nur lesen: Was dort steht, bekommt von Rspamd einen so grossen
# Abzug, dass unser Filter die Mail gar nicht mehr sieht - auch kein
# gekapertes Konto. Wer umziehen will, traegt hier ein und loescht die
# Zeile danach in der mailcow-Oberflaeche selbst.
mailcow_entries() {
    local import="${1:-}" rows
    rows=$(mysql_query "SELECT object, value FROM filterconf WHERE option = 'whitelist_from'") \
        || { echo -e "${RED}mailcow-Datenbank nicht erreichbar${NC} (laeuft mysql-mailcow?)"; return 1; }
    if [[ -z "$rows" ]]; then
        echo "In mailcow sind keine Whitelist-Eintraege hinterlegt."
        return 0
    fi

    echo
    echo "  Whitelist in mailcow (gilt dort nur fuer das genannte Postfach/die Domain):"
    echo
    local object value e status n_ok=0 n_skip=0
    while IFS=$'\t' read -r object value; do
        [[ -n "$value" ]] || continue
        if e=$(normalize_entry "$value" 2>/dev/null); then
            if has_entry "$e"; then status="schon hier"; else status="uebernehmbar -> $e"; fi
        else
            status="nicht uebernehmbar"
            e=""
        fi
        printf '    %-36s fuer %-30s %s\n' "$value" "$object" "$status"
        if [[ "$import" == "--import" && -n "$e" ]] && ! has_entry "$e"; then
            if add_entry "$e" "aus mailcow (dort fuer $object)" >/dev/null 2>&1; then
                n_ok=$((n_ok + 1))
            else
                n_skip=$((n_skip + 1))
            fi
        fi
    done <<<"$rows"
    echo

    if [[ "$import" == "--import" ]]; then
        echo -e "${GREEN}[OK]${NC} $n_ok uebernommen, $n_skip abgelehnt (Freemail-Domain, eigene Domain, ungueltig)."
        echo    "     Hier gilt ein Eintrag fuer ALLE Postfaecher, nicht nur fuer das oben genannte."
    else
        echo "  Uebernehmen mit: ai-filter-whitelist.sh mailcow --import"
    fi
    echo -e "  ${YELLOW}Solange ein Eintrag auch in mailcow steht, gewinnt mailcow:${NC} Die Mail wird"
    echo    "  ohne jede Pruefung zugestellt. Nach dem Uebernehmen dort loeschen"
    echo    "  (mailcow-Oberflaeche -> Postfach/Domain -> Spamfilter)."
    echo
}

case "$CMD" in
    add)
        [[ $# -ge 1 ]] || { echo "add braucht einen Eintrag"; exit 1; }
        entry="$1"; shift
        add_entry "$entry" "$*" || exit 1 ;;
    remove|rm|del)
        [[ $# -ge 1 ]] || { echo "remove braucht einen Eintrag"; exit 1; }
        remove_entry "$1" || exit 1 ;;
    list|ls)
        list_entries ;;
    check)
        [[ $# -ge 1 ]] || { echo "check braucht eine Absenderadresse"; exit 1; }
        check_sender "$1" || exit 1 ;;
    mailcow)
        mailcow_entries "${1:-}" || exit 1 ;;
    *)
        echo "Unbekannter Befehl: $CMD"; echo; usage; exit 1 ;;
esac
