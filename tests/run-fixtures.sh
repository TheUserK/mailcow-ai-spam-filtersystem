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
php -l "$tmp/lib.php" >/dev/null

php -r 'require $argv[1]; require $argv[2];' "$tmp/lib.php" "$root/tests/fixtures.php"
