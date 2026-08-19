# ionos-checker runtime image.
#
# The official php:8.2-cli image does NOT ship pdo_mysql, so the internal-mail
# lookup (getLocalDomains() -> mailcow DB) would fail with "could not find
# driver" on every request. Install it here.
FROM php:8.2-cli

RUN docker-php-ext-install pdo_mysql \
    && rm -rf /var/lib/apt/lists/*
