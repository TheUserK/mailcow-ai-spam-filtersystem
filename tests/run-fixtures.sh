#!/bin/bash
# Faehrt das Pruefkorpus gegen den Checker und gibt fuer jeden Fall aus,
# was die lokale Vorpruefung erkennt. Die Faelle stammen aus echten
# Logdatensaetzen (26.-29.08.2026) plus Kontrollfaellen, die NICHT
# anschlagen duerfen.
#
#   tests/run-fixtures.sh                  aktueller Stand
#   tests/run-fixtures.sh > vorher.json    vor einer Aenderung
#   diff <(...) ...                        danach vergleichen
#
# Wichtig: Der Checker ist ein Endpunkt, sein Router laeuft beim Include
# sofort los. Deshalb wird hier eine Bibliotheksfassung ohne Router gebaut.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/files/ai-checker/ai-mail-checker.php"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

start=$(grep -n '^//  ROUTER$' "$src" | cut -d: -f1)
end=$(grep -n '^//  MAIL-KONTEXT$' "$src" | cut -d: -f1)
{ sed -n "1,$((start-2))p" "$src"; sed -n "$((end-1)),\$p" "$src"; } > "$tmp/lib.php"

# getLocalDomains() fragt die Mailcow-Datenbank. Im Test gibt es die nicht,
# und ein leeres Ergebnis laesst partOfRealConversation() vorsichtshalber
# alles als echte Konversation gelten - dann pruefen die Faelle nichts mehr.
# Also die Domains der Pruefmails fest einsetzen.
perl -0pi -e 's/(function getLocalDomains\(\) \{)/$1\n    return ["moving-pictures.de", "karrerlabs.de", "karrer.info"];/' "$tmp/lib.php"
php -l "$tmp/lib.php" >/dev/null

# Die Markenliste liegt im Betrieb neben dem Checker. Fuer den Testlauf
# dieselbe Nachbarschaft herstellen, sonst prueft brand_domains.txt nichts.
[ -f "$root/tests/brand_domains.sample.txt" ] \
  && cp "$root/tests/brand_domains.sample.txt" "$tmp/brand_domains.txt"

# Dasselbe fuer den Unternehmenskontext - liegt im Betrieb ebenfalls neben
# dem Checker und wird ueber __DIR__ gefunden.
[ -f "$root/tests/business_context.sample.json" ] \
  && cp "$root/tests/business_context.sample.json" "$tmp/business_context.json"

php -r 'require $argv[1]; require $argv[2];' "$tmp/lib.php" "$root/tests/fixtures.php"
