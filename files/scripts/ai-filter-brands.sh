#!/bin/bash
# =====================================================================
#  Marken-Domains aus der Majestic Million erzeugen
#
#  Baut aus den meistverlinkten Domains eine Liste "Markenname -> echte
#  Domain". Damit erkennt der Filter eine behauptete Marke auch dann als
#  gefaelscht, wenn die Mail die echte Domain NICHT verlinkt - der Fall,
#  den brandLinkedNotSender() offen laesst.
#
#  Quelle: Majestic Million, https://majestic.com/reports/majestic-million
#  Lizenz: Creative Commons Attribution 3.0 Unported (CC BY 3.0)
#          https://creativecommons.org/licenses/by/3.0/
#          (c) Majestic-12 Ltd
#
#  Die erzeugte Datei bleibt auf DIESEM Server und wird bewusst nicht
#  mit dem Projekt ausgeliefert: Wer nichts weitergibt, muss auch nichts
#  nennen. Die Quellenangabe steht trotzdem im Kopf der Datei.
#
#  Aufruf:
#    ai-filter-brands.sh              erzeugen/aktualisieren
#    ai-filter-brands.sh --count N    andere Anzahl Domains (Standard 10000)
#    ai-filter-brands.sh --show WORT  nachsehen, ob ein Wort als Marke gilt
#    ai-filter-brands.sh --status     Stand der vorhandenen Liste
#
#  Per Cron einmal woechentlich - haeufiger bringt nichts, die Spitze der
#  Liste bewegt sich kaum.
# =====================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

SOURCE_URL="https://downloads.majestic.com/majestic_million.csv"
COUNT=10000
ACTION=build
ARG=""
DEBUG=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count)  COUNT="${2:-10000}"; shift 2 ;;
        --show)   ACTION=show; ARG="${2:-}"; shift 2 ;;
        --status) ACTION=status; shift ;;
        --debug)  DEBUG=1; shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }
cd "$MAILCOW_DIR" || exit 1

OUT="data/ai-checker/brand_domains.txt"

if [[ "$ACTION" == "status" ]]; then
    if [[ -f "$OUT" ]]; then
        echo -e "${GREEN}Vorhanden${NC}: $OUT"
        echo "  Marken:      $(grep -vc '^#' "$OUT" || echo 0)"
        echo "  Erzeugt am:  $(date -r "$OUT" '+%d.%m.%Y %H:%M')"
    else
        echo -e "${YELLOW}Noch nicht erzeugt${NC} - ai-filter-brands.sh aufrufen"
    fi
    exit 0
fi

if [[ "$ACTION" == "show" ]]; then
    [[ -f "$OUT" ]] || { echo -e "${RED}Liste fehlt${NC}"; exit 1; }
    if hit=$(grep -iP "^\Q${ARG}\E\t" "$OUT"); then
        echo -e "${GREEN}Marke${NC}: $hit"
    else
        echo -e "${YELLOW}'$ARG' steht nicht in der Liste${NC} - gilt also nicht als bekannte Marke."
    fi
    exit 0
fi

# --- Bauen ------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "Lade Majestic Million (~80 MB) ..."
if ! curl -fsSL --max-time 300 "$SOURCE_URL" -o "$TMP/million.csv"; then
    echo -e "${RED}Download fehlgeschlagen${NC} - vorhandene Liste bleibt unveraendert."
    exit 1
fi

# Spalten: GlobalRank,TldRank,Domain,TLD,RefSubNets,RefIPs,...
#
# Rausgefiltert wird alles, was zwar oben steht, aber keine MARKE ist:
# Infrastruktur, Kurzlinkdienste, Baukaesten und Allerweltswoerter. Ohne
# das waere jede Mail mit einem bit.ly- oder blogspot-Link plotzlich eine
# "Markenfaelschung" - die Spitze der Liste besteht zu einem guten Teil
# aus solchen Domains.
cat > "$TMP/skip.txt" <<'SKIP'
about access account admin adobe amazonaws apache archive
blog blogger blogspot bootstrapcdn business
cloudflare cloudfront contact cpanel creativecommons
disqus doubleclick download
email europa example
facebook fastly fbcdn feedburner fontawesome forms
github gitlab gmpg google googleapis googletagmanager gravatar
gstatic health help home
index info instagram
jquery jsdelivr
launchpad licenses linkedin live login
macromedia mail mailchimp maps media medium microsoft
mozilla myspace
news nginx
office online opera
pinterest player plesk policies press privacy
purl
reddit research
schema search security service services shop shopify sites
soundcloud sourceforge spotify support
telegram tiktok tinyurl tumblr twimg twitter
unpkg
vimeo
webmail whatsapp wikimedia wikipedia wixsite wordpress
yahoo youtu youtube
SKIP

echo "Werte die ersten $COUNT Domains aus ..."

# Bewusst OHNE "tail | head": head schliesst die Pipe nach COUNT Zeilen,
# tail bekommt SIGPIPE, und pipefail bricht das ganze Skript ab. awk zaehlt
# selbst mit und steigt aus.
awk -F, -v skipfile="$TMP/skip.txt" -v maxn="$COUNT" -v debug="$DEBUG" '
    # Die Skip-Datei hat mehrere Woerter pro Zeile, getline liefert aber
    # ganze Zeilen - also je Zeile aufteilen, sonst steht die komplette
    # Zeile als ein Schluessel im Array und nichts wird gefiltert.
    BEGIN {
        while ((getline line < skipfile) > 0) {
            gsub(/\r/, "", line)
            n = split(line, w, /[ \t]+/)
            for (i = 1; i <= n; i++) if (w[i] != "") skip[w[i]] = 1
        }
    }
    NR == 1 { next }                 # Kopfzeile
    NR > maxn + 1 { exit }
    {
        read++
        domain = tolower($3); tld = tolower($4)
        gsub(/[\r"]/, "", domain); gsub(/[\r"]/, "", tld)
        if (domain == "" || tld == "") { drop["Spalte 3/4 leer"]++; next }
        # Nur echte Zweitniveau-Domains: Untereintraege wie play.google.com
        # liefern kein eigenes Markenwort.
        suffix = "." tld
        if (substr(domain, length(domain) - length(suffix) + 1) != suffix) { drop["TLD passt nicht zur Domain"]++; next }
        label = substr(domain, 1, length(domain) - length(suffix))
        if (index(label, ".") > 0) { drop["Subdomain-Eintrag"]++; next }
        gsub(/[^a-z0-9]/, "", label)
        if (length(label) < 4) { drop["Label unter 4 Zeichen"]++; next }
        if (label in skip) { drop["Infrastruktur/Stoppwort"]++; next }
        if (label in seen) { drop["Dublette"]++; next }
        seen[label] = 1
        kept++
        print label "\t" domain
    }
    END {
        if (debug) {
            printf "  gelesen:      %d\n", read     > "/dev/stderr"
            printf "  uebernommen:  %d\n", kept     > "/dev/stderr"
            for (r in drop) printf "  verworfen %-26s %d\n", r ":", drop[r] > "/dev/stderr"
        }
    }' "$TMP/million.csv" > "$TMP/body.txt" || true

# NICHT "LINES" nennen. Das ist eine Bash-Sondervariable: mit checkwinsize
# - seit Bash 5 standardmaessig an - setzt die Shell LINES und COLUMNS nach
# jedem Kommando auf die Terminalgroesse zurueck. Am 31.08. meldete das
# Skript deshalb "54 Marken" (die Fensterhoehe), waehrend 7324 in der Datei
# standen: Die Pruefung unten sah noch den richtigen Wert, das echo am Ende
# nicht mehr. Ohne Terminal passiert es nicht, also faellt es beim Testen
# per Skript nie auf.
FOUND_BRANDS=$(wc -l < "$TMP/body.txt" | tr -d ' ')

if [[ "$FOUND_BRANDS" -lt 1000 ]]; then
    echo -e "${RED}Nur $FOUND_BRANDS Marken erkannt${NC} - das sieht nach einem Formatwechsel aus."
    echo "Erwartet werden die Spalten: GlobalRank,TldRank,Domain,TLD,..."
    echo "Die ersten beiden Zeilen der geladenen Datei:"
    head -2 "$TMP/million.csv" | sed 's/^/    /'
    echo "Vorhandene Liste bleibt unveraendert."
    exit 1
fi

{
    printf '# Marken-Domains fuer den AI-Spamfilter\n'
    printf '#\n'
    printf '# Erzeugt am %s aus der Majestic Million.\n' "$(date '+%d.%m.%Y %H:%M')"
    printf '# Quelle: https://majestic.com/reports/majestic-million\n'
    printf '# Lizenz: Creative Commons Attribution 3.0 Unported, (c) Majestic-12 Ltd\n'
    printf '#         https://creativecommons.org/licenses/by/3.0/\n'
    printf '#\n'
    printf '# Format: markenname<TAB>echte-domain\n'
    printf '# Nicht von Hand pflegen - wird bei jedem Lauf neu erzeugt.\n'
    printf '# Einzelne Marken ausschliessen: in die skip-Liste im Skript eintragen.\n'
    printf '#\n'
    cat "$TMP/body.txt"
} > "$TMP/brands.txt"

mkdir -p data/ai-checker
mv "$TMP/brands.txt" "$OUT"
chmod 644 "$OUT"

echo -e "${GREEN}[OK]${NC} $FOUND_BRANDS Marken nach $OUT geschrieben"
echo "     Pruefen mit: ai-filter-brands.sh --show hetzner"
