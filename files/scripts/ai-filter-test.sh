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

# Erst einsammeln, dann pruefen - NICHT "... | grep -q".
#
# Bei einer Pipe unter "set -o pipefail" beendet sich "grep -q" beim ersten
# Treffer und schliesst die Pipe. Schreibt der Erzeuger da noch, bekommt er
# SIGPIPE und endet mit 141, und pipefail macht daraus das Ergebnis der
# ganzen Pipe - die Bedingung ist also falsch, obwohl der Treffer da war.
#
# Genau daran scheiterte Punkt 2 bei jedem ERSTEN Aufruf auf zwei Servern:
# "php -m" listet rund 60 Module, "pdo_mysql" steht mittendrin. Beim ersten
# Lauf ist "docker compose exec" langsam genug, dass grep aussteigt, waehrend
# php noch schreibt -> gemeldet wurde "missing". Beim zweiten Lauf ist alles
# warm, php ist vor grep fertig -> "OK". Ein reines Rennen, ohne jeden Bezug
# zum tatsaechlichen Zustand des Containers.
echo -n "1. Health endpoint: "
HEALTH=$($COMPOSE_CMD exec -T ai-checker php -r 'echo file_get_contents("http://localhost:8080/health");' 2>/dev/null)
if [[ "$HEALTH" == *OK* ]]; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}no response${NC}"
    echo "   Check: $COMPOSE_CMD logs ai-checker"
    exit 1
fi

# Direkt fragen statt die Modulliste zu durchsuchen: eine Zeile Ausgabe,
# eindeutige Antwort.
echo -n "2. pdo_mysql present: "
PDO=$($COMPOSE_CMD exec -T ai-checker php -r 'echo extension_loaded("pdo_mysql") ? "yes" : "no";' 2>/dev/null)
if [[ "$PDO" == "yes" ]]; then
    echo -e "${GREEN}OK${NC}"
elif [[ "$PDO" == "no" ]]; then
    echo -e "${RED}missing${NC} - internal-mail detection will not work"
else
    echo -e "${YELLOW}could not be determined${NC} - container did not answer"
fi

echo "3. Analysis round-trip:"
RESULT=$($COMPOSE_CMD exec -T ai-checker php -r '
$data = json_encode([
  "from" => "Test <test@example.com>", "to" => "info@example.org",
  "subject" => "Test", "body" => "This is a test message.", "rspamd_score" => 3.0,
]);
$ctx = stream_context_create(["http" => ["method" => "POST",
  "header" => "Content-Type: application/json", "content" => $data, "ignore_errors" => true]]);
echo file_get_contents("http://localhost:8080/ai-mail-checker.php", false, $ctx);
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
    echo "   Check the API key in $MAILCOW_DIR/data/ai-checker/ai-mail-checker.php"
fi

echo ""
echo "4. Container status:"
$COMPOSE_CMD ps ai-checker
