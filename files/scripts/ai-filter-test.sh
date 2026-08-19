#!/bin/bash
# Quick end-to-end check: is the checker reachable, and does a request come
# back with a usable verdict?

set -uo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [[ -z "${MAILCOW_DIR:-}" ]]; then
    for dir in /opt/mailcow-dockerized /opt/mailcow; do
        [[ -f "$dir/mailcow.conf" ]] && MAILCOW_DIR="$dir" && break
    done
fi
[[ -n "${MAILCOW_DIR:-}" ]] || { echo -e "${RED}Mailcow directory not found${NC}"; exit 1; }

# Frueher fehlte dieses cd, wodurch das Skript nur aus dem Mailcow-Verzeichnis
# heraus funktionierte - "docker compose" braucht die compose-Dateien.
cd "$MAILCOW_DIR" || exit 1

if docker compose version &> /dev/null; then COMPOSE_CMD="docker compose"
elif docker-compose version &> /dev/null; then COMPOSE_CMD="docker-compose"
else echo -e "${RED}Docker Compose not found${NC}"; exit 1; fi

echo "=== AI Filter Test ==="
echo ""

echo -n "1. Health endpoint: "
if $COMPOSE_CMD exec -T ionos-checker php -r 'echo file_get_contents("http://localhost:8080/health");' 2>/dev/null | grep -q OK; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}no response${NC}"
    echo "   Check: $COMPOSE_CMD logs ionos-checker"
    exit 1
fi

echo -n "2. pdo_mysql present: "
if $COMPOSE_CMD exec -T ionos-checker php -m 2>/dev/null | grep -q pdo_mysql; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}missing${NC} - internal-mail detection will not work"
fi

echo "3. Analysis round-trip:"
RESULT=$($COMPOSE_CMD exec -T ionos-checker php -r '
$data = json_encode([
  "from" => "Test <test@example.com>", "to" => "info@example.org",
  "subject" => "Test", "body" => "This is a test message.", "rspamd_score" => 3.0,
]);
$ctx = stream_context_create(["http" => ["method" => "POST",
  "header" => "Content-Type: application/json", "content" => $data, "ignore_errors" => true]]);
echo file_get_contents("http://localhost:8080/ionos-mail-checker.php", false, $ctx);
' 2>/dev/null)

if [[ -z "$RESULT" ]]; then
    echo -e "   ${RED}no response from the checker${NC}"
    exit 1
fi

if command -v jq >/dev/null; then
    echo "$RESULT" | jq -r '"   score=\(.score)  action=\(.action)  reason=\(.reason)"' 2>/dev/null \
        || { echo -e "   ${RED}unparseable response:${NC} $RESULT"; exit 1; }
else
    echo "   $RESULT"
fi

# Ein "api-error" heisst: der Checker laeuft, aber der KI-Anbieter antwortet
# nicht - meist ein falscher oder abgelaufener API-Key.
if echo "$RESULT" | grep -q "api-error"; then
    echo -e "   ${YELLOW}The checker works, but the AI provider did not answer.${NC}"
    echo "   Check the API key in $MAILCOW_DIR/data/ionos-checker/ionos-mail-checker.php"
fi

echo ""
echo "4. Container status:"
$COMPOSE_CMD ps ionos-checker
