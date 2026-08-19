<?php
// Simple router for health checks
$uri = $_SERVER['REQUEST_URI'] ?? '/';

if ($uri === '/health') {
    http_response_code(200);
    header('Content-Type: text/plain');
    echo 'OK';
    exit;
}

require 'ai-mail-checker.php';
