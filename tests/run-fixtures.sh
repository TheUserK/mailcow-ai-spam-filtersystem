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

# Domain-Rang-Datenbank: im Betrieb SQLite, hier aus einer Textdatei
# gebaut, damit im Repo nichts Binaeres liegt.
#
# Gebaut wird sie mit PHPs pdo_sqlite, NICHT mit dem sqlite3-CLI. Das CLI
# ist auf vielen Systemen nicht installiert, und der alte Aufbau hat es
# dann stillschweigend uebersprungen: Die Rang-Datenbank fehlte, alle
# sender_global_rank-Erwartungen wurden null, und der Lauf brach mit
# "erwartet 7967, erhalten null" ab - ein Fehler, der wie ein Bug im
# Checker aussieht und keiner ist. pdo_sqlite braucht der Checker
# ohnehin, also ist es keine zusaetzliche Abhaengigkeit.
if [ -f "$root/tests/domain_ranks.sample.tsv" ]; then
  php -r '
    $db = new PDO("sqlite:" . $argv[1]);
    $db->exec("CREATE TABLE ranks (domain TEXT, global_rank INTEGER, tld_rank INTEGER)");
    $ins = $db->prepare("INSERT INTO ranks VALUES (?, ?, ?)");
    foreach (file($argv[2], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if ($line === "" || $line[0] === "#") { continue; }
        $f = explode("	", $line);
        if (count($f) < 3) { continue; }
        $ins->execute([trim($f[0]), (int)$f[1], (int)$f[2]]);
    }
    $db->exec("CREATE INDEX idx_domain ON ranks(domain)");
  ' "$tmp/domain_ranks.sqlite" "$root/tests/domain_ranks.sample.tsv"
fi

php -r 'require $argv[1]; require $argv[2];' "$tmp/lib.php" "$root/tests/fixtures.php"
