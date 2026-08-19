#!/bin/bash
# Quick test script

echo "=== IONOS Checker Test ==="
echo ""

echo "1. Health Check:"
docker compose exec ionos-checker php -r 'echo file_get_contents("http://localhost:8080/health");' && echo " ✓" || echo " ✗"

echo ""
echo "2. API Test:"
docker compose exec ionos-checker php -r '
$data = json_encode(["from"=>"test@test.com","to"=>"info@test.de","subject"=>"Test","body"=>"Test","rspamd_score"=>6.0]);
$context = stream_context_create(["http"=>["method"=>"POST","header"=>"Content-Type: application/json","content"=>$data]]);
echo file_get_contents("http://localhost:8080/ionos-mail-checker.php", false, $context);
' | jq -r '"Score: \(.score), Action: \(.action), Category: \(.category)"'

echo ""
echo "3. Container Status:"
docker compose ps ionos-checker

echo ""
