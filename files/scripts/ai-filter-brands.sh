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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count)  COUNT="${2:-10000}"; shift 2 ;;
        --show)   ACTION=show; ARG="${2:-}"; shift 2 ;;
        --status) ACTION=status; shift ;;
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

    tail -n +2 "$TMP/million.csv" \
    | head -n "$COUNT" \
    | awk -F, -v skipfile="$TMP/skip.txt" '
        BEGIN { while ((getline w < skipfile) > 0) { gsub(/[ \t]/, "", w); if (w != "") skip[w] = 1 } }
        {
            domain = tolower($3); tld = tolower($4)
            if (domain == "" || tld == "") next
            # Nur echte Zweitniveau-Domains: Untereintraege wie
            # play.google.com liefern kein eigenes Markenwort.
            suffix = "." tld
            if (substr(domain, length(domain) - length(suffix) + 1) != suffix) next
            label = substr(domain, 1, length(domain) - length(suffix))
            if (index(label, ".") > 0) next
            gsub(/[^a-z0-9]/, "", label)
            if (length(label) < 4) next
            if (label in skip) next
            if (label in seen) next
            seen[label] = 1
            print label "\t" domain
        }'
} > "$TMP/brands.txt"

LINES=$(grep -vc '^#' "$TMP/brands.txt" || echo 0)
if [[ "$LINES" -lt 1000 ]]; then
    echo -e "${RED}Nur $LINES Marken erkannt${NC} - das sieht nach einem Formatwechsel aus."
    echo "Vorhandene Liste bleibt unveraendert."
    exit 1
fi

mkdir -p data/ai-checker
mv "$TMP/brands.txt" "$OUT"
chmod 644 "$OUT"

echo -e "${GREEN}[OK]${NC} $LINES Marken nach $OUT geschrieben"
echo "     Pruefen mit: ai-filter-brands.sh --show hetzner"
