# ai-checker runtime image.
#
# The official php images do NOT ship pdo_mysql, so the internal-mail lookup
# (getLocalDomains() -> mailcow DB) would fail with "could not find driver"
# on every request. Install it here.
#
# pdo_sqlite is for the domain-rank lookup (ai-filter-rank.sh): one million
# rows is too much to hold in a PHP array in each of the four request
# workers (measured ~120MB per worker, ~480MB total) - SQLite reads only the
# pages a query needs, and the OS page cache is shared across all four
# workers automatically, unlike PHP's own per-process static cache.
#
# php:8-cli folgt jeder neuen 8.x-Version (8.5, 8.6, ...) samt Patches und
# Debian-Sicherheitsupdates. Bewusst NICHT php:cli: das springt eines Tages
# unbeaufsichtigt auf PHP 9. Aktuell gehalten wird das Image von
# ai-filter-update-image.sh (woechentlich per Cron, mit Rollback).
FROM php:8-cli

# pdo_sqlite needs libsqlite3-dev at build time (the sqlite3 pkg-config
# package) - unlike pdo_mysql, the base image has neither the lib nor the
# headers, so the configure step fails without it ("Package 'sqlite3',
# required by 'virtual:world', not found").
#
# mbstring und curl waren bis PHP 8.5 fest im Basis-Image einkompiliert.
# Das php:8-cli mit PHP 8.6.0 bringt mbstring nicht mehr mit -
# ai-filter-update-image.sh hat das Image deshalb zurueckgehalten. Beide
# werden jetzt nur nachgebaut, wenn sie fehlen: so bleibt der Build auf
# aelteren Basis-Images unveraendert und bricht auf neueren nicht.
# mbstring braucht dafuer oniguruma (libonig-dev), curl libcurl.
RUN set -eux; \
    exts="pdo_mysql pdo_sqlite"; \
    pkgs="libsqlite3-dev"; \
    if ! php -m | grep -qix mbstring; then exts="$exts mbstring"; pkgs="$pkgs libonig-dev"; fi; \
    if ! php -m | grep -qix curl;     then exts="$exts curl";     pkgs="$pkgs libcurl4-openssl-dev"; fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends $pkgs; \
    rm -rf /var/lib/apt/lists/*; \
    docker-php-ext-install $exts; \
    for e in pdo_mysql pdo_sqlite mbstring curl json; do php -m | grep -qix "$e"; done
