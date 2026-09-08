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
FROM php:8.4-cli

RUN docker-php-ext-install pdo_mysql pdo_sqlite
