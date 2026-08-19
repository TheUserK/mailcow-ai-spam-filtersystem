# ai-checker runtime image.
#
# The official php images do NOT ship pdo_mysql, so the internal-mail lookup
# (getLocalDomains() -> mailcow DB) would fail with "could not find driver"
# on every request. Install it here.
FROM php:8.4-cli

RUN docker-php-ext-install pdo_mysql
