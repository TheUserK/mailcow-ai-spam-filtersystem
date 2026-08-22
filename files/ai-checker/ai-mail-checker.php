<?php
// =====================================================================
//  Mailcow AI Spam Filter - Main Analysis Script
//  MIT License
//  Version: 3.0 - additive, low-false-positive scoring
//
//  Prinzip:
//   - Die KI rejected NIE selbst. Sie gibt nur einen graduierten,
//     ADDIERBAREN Score zurueck (positiv = Spam, negativ = Ham).
//   - Lokale Heuristik rejected ebenfalls nicht mehr hart. Sie liefert
//     nur noch (a) einen sicheren Auto-Pass fuer klar vertrauenswuerdige
//     Transaktionsmails und (b) Kontext-Flags fuer die KI.
//   - Rspamd entscheidet am Ende anhand des Gesamtscores.
//
//  Ablage:  /opt/mailcow-dockerized/data/ai-checker/ai-mail-checker.php
// =====================================================================

// ---------------------------------------------------------------------
//  Fehler-Handling & Header
// ---------------------------------------------------------------------
error_reporting(E_ALL);
ini_set('display_errors', '0');
ini_set('log_errors', '1');
ini_set('error_log', '/var/log/ai-checker/php-errors.log');
header('Content-Type: application/json');

// ---------------------------------------------------------------------
//  Provider-Profil. ai-filter-model.sh legt diese Datei an; fehlt sie,
//  gelten die Vorgaben unten unveraendert weiter. Sie liegt im
//  schreibgeschuetzt eingehaengten /app, gehoert root und ist 0600 -
//  denn sie enthaelt den API-Token.
// ---------------------------------------------------------------------
define('PROVIDER_CONF', '/app/provider.conf');

function providerSetting($key) {
    static $conf = null;

    if ($conf === null) {
        $conf = [];
        if (is_readable(PROVIDER_CONF)) {
            $parsed = parse_ini_file(PROVIDER_CONF, false, INI_SCANNER_RAW);
            if (is_array($parsed)) {
                $conf = $parsed;
            }
        }
    }

    $value = $conf[$key] ?? '';
    return is_string($value) ? trim($value) : '';
}

// ---------------------------------------------------------------------
//  KI-Anbieter. Die API ist OpenAI-kompatibel - jeder Anbieter mit
//  diesem Format laesst sich hier eintragen. Die _DEFAULT-Konstanten
//  sind der Auslieferungszustand; install.sh traegt den Token dort ein.
//  Ein Profil in provider.conf hat Vorrang.
// ---------------------------------------------------------------------
define('AI_API_ENDPOINT_DEFAULT', 'https://openai.inference.de-txl.ionos.com/v1/chat/completions');
define('AI_API_TOKEN_DEFAULT', '');
define('AI_MODEL_DEFAULT',        'openai/gpt-oss-120b');

define('AI_API_ENDPOINT', providerSetting('endpoint') ?: AI_API_ENDPOINT_DEFAULT);
define('AI_API_TOKEN',    providerSetting('token')    ?: AI_API_TOKEN_DEFAULT);
define('AI_MODEL',        providerSetting('model')    ?: AI_MODEL_DEFAULT);

// ---------------------------------------------------------------------
//  Timeouts (Sekunden)
// ---------------------------------------------------------------------
// Wie lange die API brauchen darf. Haengt stark am Modell: gpt-oss-120b
// antwortet in rund 1,5 s, Qwen3.5-397B je nach reasoning_effort in 15-27 s.
// Rspamd bricht seinerseits nach http_timeout (Vorgabe 30 s) ab - dieser
// Wert muss darunter bleiben, sonst wartet der Checker auf eine Antwort,
// die niemand mehr entgegennimmt.
define('API_TIMEOUT', providerSetting('api_timeout') !== ''
    ? max(5, (int)providerSetting('api_timeout'))
    : 20);
define('CONNECT_TIMEOUT',  5);

// low | medium | high. Steuert, wie lange das Modell vor der Antwort
// nachdenkt - und damit direkt die Antwortzeit. Leer lassen heisst: Feld
// nicht mitschicken, der Anbieter nimmt seine Vorgabe (bei IONOS medium).
define('AI_REASONING_EFFORT', providerSetting('reasoning_effort'));

// ---------------------------------------------------------------------
//  Mailcow-DB (fuer interne-Mail-Erkennung)
// ---------------------------------------------------------------------
define('MAILCOW_DB_HOST', 'mysql');
define('MAILCOW_DB_NAME', getenv('MAILCOW_DBNAME') ?: 'mailcow');
define('MAILCOW_DB_USER', getenv('MAILCOW_DBUSER') ?: 'mailcow');

// ---------------------------------------------------------------------
//  Logs & Budget
// ---------------------------------------------------------------------
define('STATS_LOG', '/var/log/ai-checker/stats.log');
define('ERROR_LOG', '/var/log/ai-checker/errors.log');
define('MONTHLY_BUDGET_EUR',    50);
define('AVG_COST_PER_CALL_EUR',
    providerSetting('cost_per_call') !== ''
        ? (float)providerSetting('cost_per_call')
        : 0.00034);
// Ein kostenloser Anbieter (cost_per_call = 0) wuerde hier durch Null
// teilen. Dann gibt es schlicht keine Budgetgrenze zu ziehen.
define('MAX_CALLS_PER_MONTH', AVG_COST_PER_CALL_EUR > 0
    ? (int)(MONTHLY_BUDGET_EUR / AVG_COST_PER_CALL_EUR)
    : PHP_INT_MAX);
define('BUDGET_FILE', '/var/log/ai-checker/monthly_budget.json');

// Betreff und Body-Auszug in stats.log schreiben? Das sind Inhaltsdaten von
// Absendern, die dem nie zugestimmt haben - daher standardmaessig AUS.
// Nur zum Debuggen kurzzeitig einschalten, und dann wieder ausschalten.
define('LOG_MAIL_CONTENT', false);

// Betreff mitschreiben. Standardmaessig AN: ohne ihn laesst sich eine
// Zeile im Log nicht beurteilen - "spam, +6.84, von einer Hotmail-Adresse"
// sagt niemandem, ob das Urteil stimmte. Der Betreff ist ein Inhaltsdatum,
// steht aber ohnehin im Postfach des Empfaengers, und von zurueckgehaltenen
// Mails legt mailcow in der Quarantaene die komplette Rohmail ab.
// Aufbewahrung 30 Tage (logrotate), Datei root/0600.
define('LOG_SUBJECT', true);

// Dateirechte fuer die Logdateien. 0600 = nur root, weil selbst die
// pseudonymisierten Eintraege personenbezogene Daten sind.
define('LOG_FILE_MODE', 0600);

// ---------------------------------------------------------------------
//  Score-Grenzen: wie viel darf die KI maximal beitragen?
//  Bewusst niedrig, damit die KI allein keine Mail versenken
//  und keinen klaren Spam allein durchwinken kann.
// ---------------------------------------------------------------------
define('MAX_SPAM_POINTS', 4.0);   // max. Punkte bei sicherem Spam
define('MAX_HAM_POINTS',  3.0);   // max. Punkte Abzug bei sicherem Ham
// ---------------------------------------------------------------------
//  Obergrenzen fuer den GESAMTSCORE (Rspamd + unser Beitrag).
//  Bewusst als Gesamtsumme formuliert und nicht als Punktzahl: nur so ist
//  die Zusicherung "kann nie rejecten" beweisbar, egal was Rspamd vorher
//  schon gefunden hat. Rspamds Reject-Schwelle liegt per Default bei 15.
// ---------------------------------------------------------------------
define('REJECT_THRESHOLD', 15.0);

// Normalfall: darf bis deutlich ueber die Junk-Schwelle, nie bis Reject.
define('MAX_TOTAL_DEFAULT', 12.0);

// Transaktions- und persoenliche Mail: noch vorsichtiger. Eine Rechnung
// oder Bestellbestaetigung darf im Junk landen - abgewiesen werden darf sie
// nie. Hinter Maschinenmail sitzt niemand, der den Bounce bemerkt.
define('MAX_TOTAL_TRANSACTIONAL', 8.0);

// Nur unaufgeforderte Massenmail darf hierhin - und nur, wenn AI_MAY_REJECT
// aktiv ist und die Bedingungen in rejectAllowed() ALLE zutreffen.
define('MAX_TOTAL_REJECTABLE', 18.0);

// Darf eine Mail, die ALLE Bedingungen in analyzeWithAI() erfuellt, bis ueber
// die Reject-Schwelle kommen?
//   true  - ja. Jeder Kandidat wird als "Reject allowed" protokolliert.
//   false - Schattenmodus: derselbe Eintrag erscheint als "Would reject",
//           der Score bleibt aber unter der Schwelle.
// In beiden Faellen landet jeder Kandidat in errors.log - im scharfen Modus
// ist dieses Log die einzige Stelle, an der man sieht, was verworfen wurde.
define('AI_MAY_REJECT', true);

// Bodenwert, sobald die volle Reject-Konjunktion haelt. Die uebliche Kurve
// skaliert mit Wahrscheinlichkeit und Confidence und schoepft selbst bei
// einem klaren Urteil nur rund zwei Drittel aus - viel zu wenig, um eine
// Mail abzuweisen. Wenn das Modell die Kategorie aber ueberhaupt vergibt und
// ein unabhaengiger Strukturbeleg zustimmt, IST das die Aussage. Der Deckel
// begrenzt den Wert danach weiterhin.
define('REJECT_FLOOR', 16.0);

define('MAX_PHISHING_POINTS', 10.0); // Phishing/Fraud darf kraeftig beissen, aber
                                     // bewusst UNTER Rspamds Reject-Schwelle (15):
                                     // die KI allein soll nie eine Mail versenken.


// =====================================================================
//  ROUTER
// =====================================================================
$input = file_get_contents('php://input');
$data = json_decode($input, true);

if (!is_array($data)) {
    respondError('Invalid JSON input');
}

$requestId = substr(md5(uniqid(mt_rand(), true)), 0, 8);
$mail = prepareMailContext($data);

if (isInternalMail($mail['from'], $mail['to'])) {
    respondSuccess(0.0, 'add', 'internal-mail', $requestId);
}

$localResult = analyzeLocally($mail, $requestId);

if (!empty($localResult['handled'])) {
    logStats($requestId, [
        'from' => $mail['from'],
        'to' => $mail['to'],
        'subject' => $mail['subject'],
        'body' => $mail['body'],
        'rspamd_score' => $mail['rspamd_score'],
        'ai_score' => $localResult['score'],
        'ai_action' => $localResult['action'],
        'category' => $localResult['category'] ?? 'unknown',
        'red_flags' => $localResult['red_flags'] ?? [],
        'analysis_source' => $localResult['analysis_source'] ?? 'local',
        'matched_profile' => $localResult['matched_profile'] ?? '',
        'mail_type_guess' => $localResult['mail_type_guess'] ?? '',
        'url_domains' => $mail['url_domains'],
    ]);

    respondSuccess(
        $localResult['score'],
        $localResult['action'],
        $localResult['reason'],
        $requestId
    );
}

if (!checkBudget($requestId)) {
    respondSuccess(0.0, 'add', 'budget-exceeded', $requestId);
}

$result = analyzeWithAI($mail, $localResult, $requestId);

logStats($requestId, [
    'from' => $mail['from'],
    'to' => $mail['to'],
    'subject' => $mail['subject'],
    'body' => $mail['body'],
    'rspamd_score' => $mail['rspamd_score'],
    'ai_score' => $result['score'],
    'ai_action' => $result['action'],
    'category' => $result['category'] ?? 'unknown',
    'red_flags' => $result['red_flags'] ?? [],
    'analysis_source' => $result['analysis_source'] ?? 'ai',
    'evidence' => $result['evidence'] ?? [],
    'reject_eligible' => !empty($result['reject_eligible']),
    'claimed_brand' => $result['claimed_brand'] ?? '',
    'verified_brand' => $result['verified_brand'] ?? '',
    'matched_profile' => $localResult['matched_profile'] ?? '',
    'mail_type_guess' => $localResult['mail_type_guess'] ?? '',
    'url_domains' => $mail['url_domains'],
]);

respondSuccess(
    $result['score'],
    $result['action'],
    $result['reason'],
    $requestId
);


// =====================================================================
//  MAIL-KONTEXT
// =====================================================================
function prepareMailContext(array $data) {
    $headers = [];
    if (isset($data['meta']['headers']) && is_array($data['meta']['headers'])) {
        $headers = $data['meta']['headers'];
    }
    if (isset($data['headers']) && is_array($data['headers'])) {
        $headers = array_merge($headers, $data['headers']);
    }

    $auth = [];
    if (isset($data['meta']['auth']) && is_array($data['meta']['auth'])) {
        $auth = $data['meta']['auth'];
    }
    if (isset($data['auth']) && is_array($data['auth'])) {
        $auth = array_merge($auth, $data['auth']);
    }

    $signals = [];
    if (isset($data['meta']['signals']) && is_array($data['meta']['signals'])) {
        $signals = $data['meta']['signals'];
    }
    if (isset($data['signals']) && is_array($data['signals'])) {
        $signals = array_merge($signals, $data['signals']);
    }

    $contentStats = [];
    if (isset($data['meta']['content_stats']) && is_array($data['meta']['content_stats'])) {
        $contentStats = $data['meta']['content_stats'];
    }
    if (isset($data['content_stats']) && is_array($data['content_stats'])) {
        $contentStats = array_merge($contentStats, $data['content_stats']);
    }

    $body = cleanTextValue($data['body'] ?? '');
    $subject = cleanTextValue($data['subject'] ?? '');
    $from = cleanTextValue($data['from'] ?? ($data['from_email'] ?? ''));
    $to = cleanTextValue($data['to'] ?? '');

    $rawUrls = [];
    if (isset($data['meta']['urls'])) {
        $rawUrls = normalizeStringList($data['meta']['urls']);
    }
    if (isset($data['urls'])) {
        $rawUrls = array_values(array_unique(array_merge($rawUrls, normalizeStringList($data['urls']))));
    }

    $urlDomains = [];
    if (isset($data['meta']['url_domains'])) {
        $urlDomains = normalizeDomainList($data['meta']['url_domains']);
    }
    if (isset($data['url_domains'])) {
        $urlDomains = array_values(array_unique(array_merge($urlDomains, normalizeDomainList($data['url_domains']))));
    }

    if (empty($rawUrls) || empty($urlDomains)) {
        $extracted = extractUrlsFromText($body . "\n" . $subject);
        $rawUrls = array_values(array_unique(array_merge($rawUrls, $extracted['urls'])));
        $urlDomains = array_values(array_unique(array_merge($urlDomains, $extracted['domains'])));
    }

    $attachments = normalizeAttachments($data['attachments'] ?? []);
    $fromDomain = normalizeHost($data['from_domain'] ?? extractDomainFromAddress($data['from_email'] ?? $from));
    $toDomain = normalizeHost($data['to_domain'] ?? extractDomainFromAddress($to));
    $replyTo = cleanTextValue($data['reply_to'] ?? ($headers['reply_to'] ?? ''));
    $replyToDomain = normalizeHost($data['reply_to_domain'] ?? extractDomainFromAddress($replyTo));
    $returnPath = cleanTextValue($data['return_path'] ?? ($headers['return_path'] ?? ''));
    $returnPathDomain = normalizeHost($data['return_path_domain'] ?? extractDomainFromAddress($returnPath));
    $messageId = cleanTextValue($data['message_id'] ?? ($headers['message_id'] ?? ''));
    $messageIdDomain = normalizeHost($data['message_id_domain'] ?? extractDomainFromMessageId($messageId));

    $bodyClean = trim(preg_replace('/\s+/u', ' ', strip_tags($body)));

    return [
        'body' => $body,
        'body_clean' => $bodyClean,
        'subject' => $subject !== '' ? $subject : '(no subject)',
        'from' => $from,
        'to' => $to,
        'rspamd_score' => floatval($data['rspamd_score'] ?? 0),
        'attachments' => $attachments,
        'from_email' => cleanTextValue($data['from_email'] ?? $from),
        'from_domain' => $fromDomain,
        'from_display_name' => cleanTextValue($data['from_display_name'] ?? ''),
        'from_smtp' => cleanTextValue($data['from_smtp'] ?? ''),
        'from_smtp_domain' => normalizeHost($data['from_smtp_domain'] ?? extractDomainFromAddress($data['from_smtp'] ?? '')),
        'from_mime' => cleanTextValue($data['from_mime'] ?? ''),
        'from_mime_domain' => normalizeHost($data['from_mime_domain'] ?? extractDomainFromAddress($data['from_mime'] ?? '')),
        'to_domain' => $toDomain,
        'reply_to' => $replyTo,
        'reply_to_domain' => $replyToDomain,
        'return_path' => $returnPath,
        'return_path_domain' => $returnPathDomain,
        'message_id' => $messageId,
        'message_id_domain' => $messageIdDomain,
        // Teil eines laufenden Austauschs? Dann nie abweisen - dahinter
        // steckt eine bestehende Konversation.
        'in_reply_to' => cleanTextValue($data['in_reply_to'] ?? ($headers['in_reply_to'] ?? '')),
        'references' => cleanTextValue($data['references'] ?? ($headers['references'] ?? '')),
        'headers' => [
            'list_unsubscribe' => cleanTextValue($headers['list_unsubscribe'] ?? $data['list_unsubscribe'] ?? ''),
            'list_id' => cleanTextValue($headers['list_id'] ?? $data['list_id'] ?? ''),
            'precedence' => cleanTextValue($headers['precedence'] ?? $data['precedence'] ?? ''),
            'authentication_results' => cleanTextValue($headers['authentication_results'] ?? $data['authentication_results'] ?? ''),
        ],
        'auth' => [
            'spf' => normalizeTriState($auth['spf'] ?? 'unknown'),
            'dkim' => normalizeTriState($auth['dkim'] ?? 'unknown'),
            'dmarc' => normalizeTriState($auth['dmarc'] ?? 'unknown'),
            'whitelisted' => !empty($auth['whitelisted']),
        ],
        'signals' => [
            'mailcow_white' => !empty($signals['mailcow_white']),
            'freemail_from' => !empty($signals['freemail_from']),
            'forged_sender' => !empty($signals['forged_sender']),
            'from_neq_envfrom' => !empty($signals['from_neq_envfrom']),
            'suspicious_reply_to' => !empty($signals['suspicious_reply_to']),
            'has_list_unsubscribe' => !empty($signals['has_list_unsubscribe']) || cleanTextValue($headers['list_unsubscribe'] ?? '') !== '',
            'has_html' => !empty($signals['has_html']) || intval($contentStats['html_part_count'] ?? 0) > 0,
            // URL-Reputation, die Rspamd ohnehin schon ermittelt hat
            // (Spamhaus DBL / SURBL / URIBL / OpenPhish / PhishTank).
            'url_blacklisted' => !empty($signals['url_blacklisted']),
            'url_suspect' => !empty($signals['url_suspect']),
            'url_fresh_domain' => !empty($signals['url_fresh_domain']),
            'url_phishing' => !empty($signals['url_phishing']),
        ],
        'content_stats' => [
            'body_length' => intval($contentStats['body_length'] ?? mb_strlen($body)),
            'text_part_count' => intval($contentStats['text_part_count'] ?? 0),
            'html_part_count' => intval($contentStats['html_part_count'] ?? 0),
            'link_count' => intval($contentStats['link_count'] ?? count($rawUrls)),
            'attachment_count' => intval($contentStats['attachment_count'] ?? count($attachments)),
        ],
        'urls' => array_slice($rawUrls, 0, 25),
        'url_domains' => array_slice($urlDomains, 0, 25),
    ];
}


// =====================================================================
//  LOKALE VORPRUEFUNG
//  Kein Hard-Reject mehr! Nur sicherer Auto-Pass + Kontext-Flags.
// =====================================================================
function analyzeLocally(array $mail, $requestId) {
    $profiles = getTrustedSenderProfiles();
    $matchedProfile = matchTrustedProfile($mail, $profiles);
    $authStrength = evaluateAuthStrength($mail);

    $dangerousAttachments = findDangerousAttachments($mail['attachments']);
    $shortenerDomains = findShortenerDomains($mail['url_domains']);
    $riskFlags = [];
    $trustFlags = [];

    if (!empty($matchedProfile['key'])) {
        $trustFlags[] = 'matched-profile:' . $matchedProfile['key'];
    }

    if ($authStrength === 'strong') {
        $trustFlags[] = 'auth:strong';
    } elseif ($authStrength === 'medium') {
        $trustFlags[] = 'auth:medium';
    } elseif ($authStrength === 'suspicious') {
        $riskFlags[] = 'auth:suspicious';
    }

    if (!empty($mail['signals']['forged_sender'])) {
        $riskFlags[] = 'forged-sender-symbol';
    }
    if (!empty($mail['signals']['from_neq_envfrom'])) {
        $riskFlags[] = 'from-envfrom-mismatch-symbol';
    }
    if (!empty($mail['signals']['suspicious_reply_to'])) {
        $riskFlags[] = 'suspicious-reply-to-symbol';
    }
    if (!empty($dangerousAttachments)) {
        $riskFlags[] = 'dangerous-attachments:' . implode(',', $dangerousAttachments);
    }
    if (!empty($shortenerDomains)) {
        $riskFlags[] = 'url-shortener:' . implode(',', $shortenerDomains);
    }

    // Rspamds eigene URL-Reputation. Einzeln sagt das wenig - jede legitime
    // Domain ist einmal neu -, aber in Kombination mit einer behaupteten
    // Marke oder einer Geldforderung ist es ein starkes Signal. Genau diese
    // Kombination kann keine Blocklist allein sehen, die KI aber schon.
    if (!empty($mail['signals']['url_blacklisted'])) {
        $riskFlags[] = 'url-blacklisted';
    }
    if (!empty($mail['signals']['url_phishing'])) {
        $riskFlags[] = 'url-known-phishing';
    }
    if (!empty($mail['signals']['url_fresh_domain'])) {
        $riskFlags[] = 'url-fresh-domain';
    }
    if (!empty($mail['signals']['url_suspect'])) {
        $riskFlags[] = 'url-suspect-listing';
    }

    $profile = $matchedProfile['profile'] ?? null;
    $profileKey = $matchedProfile['key'] ?? '';
    $profileKind = $profile['kind'] ?? '';
    $allowedHeaderDomains = $profile['domains'] ?? [];
    $allowedUrlDomains = $profile['url_domains'] ?? $allowedHeaderDomains;

    $replyAligned = $mail['reply_to_domain'] === '' || empty($allowedHeaderDomains) || domainMatchesAny($mail['reply_to_domain'], $allowedHeaderDomains);
    $returnAligned = $mail['return_path_domain'] === '' || empty($allowedHeaderDomains) || domainMatchesAny($mail['return_path_domain'], $allowedHeaderDomains);
    $messageIdAligned = $mail['message_id_domain'] === '' || empty($allowedHeaderDomains) || domainMatchesAny($mail['message_id_domain'], $allowedHeaderDomains);
    $urlsAligned = empty($allowedUrlDomains) || allDomainsAllowed($mail['url_domains'], $allowedUrlDomains);

    if ($profile && !$replyAligned) {
        $riskFlags[] = 'reply-to-domain-mismatch';
    }
    if ($profile && !$returnAligned) {
        $riskFlags[] = 'return-path-domain-mismatch';
    }
    if ($profile && !$messageIdAligned) {
        $riskFlags[] = 'message-id-domain-mismatch';
    }
    if ($profile && !$urlsAligned) {
        $riskFlags[] = 'url-domain-mismatch';
    }

    if (!empty($mail['headers']['list_unsubscribe']) || !empty($mail['headers']['list_id'])) {
        $trustFlags[] = 'newsletter-headers-present';
    }

    if ($profile && $replyAligned && $returnAligned && $messageIdAligned && $urlsAligned) {
        $trustFlags[] = 'profile-alignment:good';
    }

    // Marken-Impersonation: gibt sich die Mail als bekannte Marke aus,
    // obwohl die Domain nicht passt? (Typosquat oder fremde Domain)
    $impersonation = detectBrandImpersonation($mail);
    $impersonationScore = 0.0;
    if ($impersonation !== null) {
        $impersonationScore = $impersonation['score'];
        $riskFlags[] = 'brand-impersonation:' . $impersonation['brand']
            . ':' . $impersonation['kind'];
    }

    $baseLocalContext = [
        'handled' => false,
        'analysis_source' => 'local-precheck',
        'matched_profile' => $profileKey,
        'matched_profile_kind' => $profileKind,
        'auth_strength' => $authStrength,
        'impersonation_score' => $impersonationScore,
        'risk_flags' => array_values(array_unique($riskFlags)),
        'trust_flags' => array_values(array_unique($trustFlags)),
    ];

    // Sicherer Auto-Pass: bekannter Absender (Domain matcht ein Profil),
    // starke Auth, alle Header/URLs aligned, keine Red Flags -> kein
    // KI-Call noetig (spart Geld). Die Kombi aus Profil-Match + starker
    // Auth + Alignment ist Beweis genug, dass die Mail echt ist.
    // Ein Profil-Match darf einen Blocklist-Treffer nicht ueberstimmen: auch
    // ein echter Absender kann eine kompromittierte Subdomain verlinken.
    $urlReputationClean = empty($mail['signals']['url_blacklisted'])
        && empty($mail['signals']['url_phishing'])
        && empty($mail['signals']['url_suspect']);

    $canAutoPass = $profile
        && $authStrength === 'strong'
        && empty($dangerousAttachments)
        && empty($shortenerDomains)
        && $urlReputationClean
        && $replyAligned
        && $returnAligned
        && $messageIdAligned
        && $urlsAligned
        && $impersonationScore === 0.0;

    if ($canAutoPass) {
        return array_merge($baseLocalContext, buildLocalDecision(
            0.0,
            'pass',
            'trusted-transactional',
            'legitimate',
            []
        ));
    }

    return $baseLocalContext;
}


// =====================================================================
//  KI-ANALYSE
//  Gibt nur einen graduierten, addierbaren Score zurueck. Kein Reject.
// =====================================================================
function analyzeWithAI(array $mail, array $localContext, $requestId) {

    $systemPrompt = <<<'PROMPT'
Du bist ein vorsichtiger E-Mail-Spam-Analyst.
Schaetze, wie wahrscheinlich diese Mail unerwuenschter Spam, Phishing oder Betrug ist.

GRUNDREGEL: Im Zweifel ist die Mail legitim.
Eine verlorene echte Mail ist viel schlimmer als ein durchgerutschter Spam.

Als Spam/Phishing nur bei KLAREN Signalen einstufen:
- Geldforderungen, Gebuehren, angebliche Erstattungen
- Passwort-/Login-/Konto-Verifikation, Sicherheitswarnungen
- gefaelschter Absender (From/Reply-To/Return-Path passen nicht zusammen)
- Druck, Drohung, kuenstliche Dringlichkeit
- Potenz-/Abnehm-/Medikamenten-Werbung
- Paket-Scams mit fremden Link-Domains oder Gebuehrenforderung

Als legitim einstufen:
- normale Geschaefts- und Privatmails
- erwartete Newsletter mit List-Unsubscribe
- Transaktionsmails (Bestellung, Rechnung, Versand) von stimmigen Absendern
- ein niedriger oder negativer Rspamd-Score ist ein Vertrauenssignal

Die Risk-/Trust-Flags der lokalen Vorpruefung sind nur Hinweise, kein Urteil.
Ausnahme: Ein Flag "brand-impersonation:MARKE" bedeutet, dass sich der
Absender als bekannte Marke ausgibt, obwohl die Domain nicht dazu passt.
Das ist ein starkes Phishing-Signal — stufe solche Mails als "phishing" ein,
ausser es gibt einen klaren, legitimen Grund (z.B. ein erkennbarer Reseller).

Zu den URL-Flags (kommen aus etablierten Blocklisten, nicht von dir zu pruefen):
- "url-blacklisted" / "url-known-phishing": eine verlinkte Domain steht auf
  einer Malware-/Phishing-Blockliste. Sehr verlaesslich — als "phishing" oder
  "spam" einstufen, ausser die Mail ist offensichtlich eine Warnung DARUEBER.
- "url-fresh-domain": eine verlinkte Domain existiert erst seit wenigen Tagen.
  ALLEIN bedeutet das wenig — jede legitime Domain ist einmal neu, und junge
  Startups, Kampagnenseiten und Shoplinks sind voellig normal.
  ZUSAMMEN mit einer behaupteten Marke, einer Login-/Verifikations-
  Aufforderung oder einer Geldforderung ist es dagegen ein sehr starkes
  Phishing-Signal. Genau diese Kombination ist deine Aufgabe.
- "url-suspect-listing": schwache Listung, nur ein leichter Hinweis.

KATEGORIE - waehle genau eine. Sie entscheidet, wie hart die Mail
behandelt werden darf, also waehle sie sorgfaeltig:

Geschuetzt (werden nie abgewiesen, hoechstens einsortiert):
- "legitimate": normale erwuenschte Mail
- "transactional": Bestellung, Rechnung, Versand, Buchung, Zahlung,
  Passwort-Reset, Bestaetigungscode, Vertragsdokument
- "personal": von einem Menschen an einen Menschen geschrieben
- "newsletter": Newsletter, den der Empfaenger erkennbar bestellt hat -
  identifizierbarer Absender, Impressum, funktionierender Abmeldelink
- "marketing": kommerzielle Mail eines IDENTIFIZIERBAREN Anbieters, zu dem
  eine Geschaeftsbeziehung plausibel ist

Angreifbar (duerfen abgewiesen werden):
- "clickbait": Sensationsaufhaenger ohne erkennbaren Absender, dessen einziger
  Zweck der Klick ist. Prominente, Gesundheits- oder Reichtumsversprechen,
  kein konkretes Angebot, keine Beziehung zum Empfaenger, meist Wegwerfdomain.
  Abgrenzung zu "newsletter": dort gibt es eine Marke, ein Impressum und ein
  Abo. Fehlt beides und ist der Aufhaenger reisserisch -> clickbait.
- "spam": unaufgeforderte Massenmail von unbekanntem oder Wegwerf-Absender
- "pharma": Medikamente, Potenzmittel, Abnehmpraeparate
- "phishing": Abgriff von Zugangsdaten oder Identitaet
- "fraud": Betrug, Vorschussbetrug, CEO-Fraud, Erpressung

WICHTIG: Eine Mail, die sich als Bestellbestaetigung, Rechnung oder
Passwort-Reset AUSGIBT, es aber nicht ist, ist "phishing" - niemals
"transactional". Die geschuetzten Kategorien gelten nur fuer echte Vertreter.

Im Zweifel die geschuetztere Kategorie waehlen. Ausnahme: Bei "clickbait"
darfst du dich klar festlegen - ein Fehlurteil kostet dort niemanden etwas.

ABSENDER-BEHAUPTUNG - "claimed_brand":
Als welches Unternehmen oder welche Organisation gibt sich diese Mail aus?
Trage den Namen so ein, wie er behauptet wird ("N26", "Sparkasse",
"Trade Republic", "Volksbank Mittelhessen"). Es zaehlt nur, wofuer sich der
ABSENDER ausgibt - nicht, welche Firmen im Text vorkommen. Eine Rechnung, die
ein anderes Unternehmen erwaehnt, behauptet nicht, von ihm zu sein.
Leer lassen, wenn die Mail keine Organisation vorgibt zu sein (Privatmail,
namenlose Massenmail). Keine Gattungsbegriffe wie "Ihre Bank" oder "Support".

Diese Angabe wird maschinell gegen die tatsaechliche Absenderdomain geprueft.
Rate nicht - im Zweifel leer lassen.

Antworte AUSSCHLIESSLICH mit diesem JSON, ohne weiteren Text:
{"spam_probability": 0.0-1.0, "confidence": 0.0-1.0, "category": "legitimate|transactional|personal|newsletter|marketing|clickbait|spam|pharma|phishing|fraud", "claimed_brand": "", "red_flags": ["..."], "reasoning": "kurze Begruendung"}

Zahlen IMMER als Ziffern schreiben (0.9), niemals als Wort.
"reasoning" hoechstens 150 Zeichen - laengere Antworten werden abgeschnitten.
PROMPT;

    $body = mb_substr($mail['body_clean'], 0, 3000);

    // Nur abweichende Header zeigen (sonst leer -> weniger Rauschen)
    $replyDom  = ($mail['reply_to_domain']   !== '' && $mail['reply_to_domain']   !== $mail['from_domain']) ? $mail['reply_to_domain']   : '';
    $returnDom = ($mail['return_path_domain'] !== '' && $mail['return_path_domain'] !== $mail['from_domain']) ? $mail['return_path_domain'] : '';

    $attachmentNames = array_map(function ($a) {
        return $a['name'] ?? '';
    }, $mail['attachments']);

    $userPrompt = sprintf(
        "From: %s\n"            .
        "From-Domain: %s\n"     .
        "Display-Name: %s\n"    .
        "Subject: %s\n"         .
        "Rspamd-Score: %.1f\n"  .
        "SPF/DKIM/DMARC: %s / %s / %s\n" .
        "Reply-To-Domain (falls abweichend): %s\n" .
        "Return-Path-Domain (falls abweichend): %s\n" .
        "URL-Domains: %s\n"     .
        "Anhaenge: %s\n"        .
        "Trust-Flags: %s\n"     .
        "Risk-Flags: %s\n\n"    .
        "Body:\n%s",
        safePromptValue($mail['from']),
        safePromptValue($mail['from_domain']),
        safePromptValue($mail['from_display_name']),
        safePromptValue($mail['subject']),
        $mail['rspamd_score'],
        safePromptValue($mail['auth']['spf']),
        safePromptValue($mail['auth']['dkim']),
        safePromptValue($mail['auth']['dmarc']),
        safePromptValue($replyDom),
        safePromptValue($returnDom),
        safePromptValue(formatListForPrompt($mail['url_domains'])),
        safePromptValue(formatListForPrompt($attachmentNames)),
        safePromptValue(formatListForPrompt($localContext['trust_flags'] ?? [])),
        safePromptValue(formatListForPrompt($localContext['risk_flags'] ?? [])),
        $body
    );

    $payload = [
        'model' => AI_MODEL,
        'messages' => [
            ['role' => 'system', 'content' => $systemPrompt],
            ['role' => 'user',   'content' => $userPrompt],
        ],
        'temperature' => 0.0,
        // max_tokens ist bei IONOS deprecated und faellt ohne Wert auf 16
        // zurueck. Das Budget ist bewusst grosszuegig: Reasoning-Modelle
        // denken erst und antworten dann - bei 600 stand das Urteil zwar
        // laengst fest, aber das JSON brach mitten im "reasoning" ab.
        // Abgerechnet wird ohnehin nur, was tatsaechlich erzeugt wird.
        'max_completion_tokens' => 2000,
        // Structured Outputs: das Modell KANN kein anderes Format mehr
        // liefern. Ersetzt das Bitten im Systemprompt durch eine Zusage
        // des Anbieters.
        'response_format' => [
            'type' => 'json_schema',
            'json_schema' => [
                'name'   => 'mail_verdict',
                'strict' => true,
                'schema' => [
                    'type' => 'object',
                    'properties' => [
                        'spam_probability' => ['type' => 'number', 'minimum' => 0, 'maximum' => 1],
                        'confidence'       => ['type' => 'number', 'minimum' => 0, 'maximum' => 1],
                        'category'         => [
                            'type' => 'string',
                            'enum' => [
                                'legitimate', 'transactional', 'personal',
                                'newsletter', 'marketing',
                                'clickbait', 'spam', 'pharma', 'phishing', 'fraud',
                            ],
                        ],
                        'claimed_brand' => ['type' => 'string'],
                        'red_flags' => ['type' => 'array', 'items' => ['type' => 'string']],
                        'reasoning' => ['type' => 'string'],
                    ],
                    'required' => [
                        'spam_probability', 'confidence', 'category',
                        'claimed_brand', 'red_flags', 'reasoning',
                    ],
                    'additionalProperties' => false,
                ],
            ],
        ],
    ];

    if (AI_REASONING_EFFORT !== '') {
        $payload['reasoning_effort'] = AI_REASONING_EFFORT;
    }

    // --- Ein Call, ein Retry. ---
    // Ausnahme: lehnt ein Anbieter das Schema mit einem 400er ab, wird
    // genau einmal ohne response_format wiederholt. Nicht jeder
    // OpenAI-kompatible Endpoint kann Structured Outputs, und ein
    // Anbieterwechsel darf den Filter nicht stillegen.
    // Zeitbudget statt Versuchsbudget. Rspamd bricht die gesamte Aufgabe
    // nach task_timeout ab (bei mailcow 25 s) und erzwingt dann ein SOFT
    // REJECT - die Mail wird abgewiesen, nicht bloss unbewertet gelassen.
    // Zwei volle Timeouts hintereinander reissen diese Grenze immer, egal
    // wie kurz das einzelne Timeout gesetzt ist. Also wird nur noch dann
    // ein zweites Mal gefragt, wenn dafuer auch Zeit uebrig ist.
    $deadline = microtime(true) + API_TIMEOUT;

    $result = null; $httpCode = 0; $curlErr = ''; $schemaDropped = false;
    for ($attempt = 1; $attempt <= 2; $attempt++) {
        $remaining = (int)ceil($deadline - microtime(true));
        if ($attempt > 1 && $remaining < 3) {
            logError($requestId, 'No time left for a second attempt', [
                'http_code' => $httpCode,
                'budget'    => API_TIMEOUT,
            ]);
            break;
        }
        $ch = curl_init(AI_API_ENDPOINT);
        curl_setopt_array($ch, [
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
            CURLOPT_HTTPHEADER     => [
                'Authorization: Bearer ' . AI_API_TOKEN,
                'Content-Type: application/json',
            ],
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => max(3, $remaining),
            CURLOPT_CONNECTTIMEOUT => CONNECT_TIMEOUT,
            CURLOPT_SSL_VERIFYPEER => true,
        ]);
        $result   = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $curlErr  = curl_error($ch);
        curl_close($ch);

        if ($httpCode === 200) break;

        if ($httpCode === 400 && !$schemaDropped && isset($payload['response_format'])) {
            unset($payload['response_format']);
            $schemaDropped = true;
            logError($requestId, 'Provider rejected response_format - retrying without schema', [
                'endpoint' => AI_API_ENDPOINT,
                'model'    => AI_MODEL,
            ]);
            // Zaehlt nicht als Netzwerkversuch: sonst haette eine Mail bei
            // einem spaeteren 5xx drei Anlaeufe a API_TIMEOUT, und rspamd
            // liefe uns vorher in seinen eigenen http_timeout.
            $attempt--;
            continue;
        }

        if ($httpCode >= 400 && $httpCode < 500) break;  // Client-Fehler: kein Retry
        usleep(500 * 1000);
    }

    if ($httpCode !== 200) {
        logError($requestId, 'API request failed', ['http_code' => $httpCode, 'curl_error' => $curlErr]);
        return neutralResponse("api-error-http-$httpCode");
    }

    $apiResponse = json_decode($result, true);
    $content = $apiResponse['choices'][0]['message']['content'] ?? '';
    $content = trim(preg_replace('/```json\s*|\s*```/', '', $content));
    if (preg_match('/\{[\s\S]*\}/', $content, $m)) {
        $content = $m[0];
    }

    $content = sanitizeAiNumberWords($content);

    $analysis = json_decode($content, true);

    // Abgeschnittene Antworten sind der haeufigste Parse-Fehler: die Zahlen
    // stehen am Anfang und sind laengst vollstaendig, nur das "reasoning" am
    // Ende bricht mitten im Satz ab. Die Mail deswegen unbewertet zu lassen
    // waere Verschwendung - also die Felder herausfischen.
    $recovered = false;
    if (!is_array($analysis) || !isset($analysis['spam_probability'])) {
        $salvaged = recoverTruncatedAnalysis($content);
        if ($salvaged !== null) {
            $analysis = $salvaged;
            $recovered = true;
        }
    }

    if (!is_array($analysis) || !isset($analysis['spam_probability'])) {
        // finish_reason und Tokenverbrauch mitschreiben. Ohne die beiden
        // sieht ein leerer Inhalt genauso aus wie Muell vom Anbieter -
        // dabei ist "reasoning hat das Budget aufgebraucht" (finish_reason
        // = length, completion_tokens am Limit) ein voellig anderer Fehler
        // mit einer voellig anderen Abhilfe.
        logError($requestId, 'Failed to parse AI response', [
            'content'          => mb_substr($content, 0, 300),
            'content_empty'    => ($content === ''),
            'finish_reason'    => $apiResponse['choices'][0]['finish_reason'] ?? '?',
            'completion_tokens' => $apiResponse['usage']['completion_tokens'] ?? null,
            'reasoning_tokens' => $apiResponse['usage']['completion_tokens_details']['reasoning_tokens'] ?? null,
            'model'            => AI_MODEL,
            'reasoning_effort' => AI_REASONING_EFFORT !== '' ? AI_REASONING_EFFORT : '(provider default)',
        ]);
        return neutralResponse('parse-error');
    }

    if ($recovered) {
        logError($requestId, 'Recovered truncated AI response', [
            'spam_probability' => $analysis['spam_probability'],
            'confidence' => $analysis['confidence'] ?? null,
            'category' => $analysis['category'] ?? null,
        ]);
    }

    $category = cleanTextValue($analysis['category'] ?? 'unknown');

    $score = scoreFromAi(
        $analysis['spam_probability'],
        $analysis['confidence'] ?? 0.5,
        $category
    );

    // Marken-Impersonation (Typosquat / gefaelschter Absendername) aus der
    // lokalen Vorpruefung legt einen Boden drauf und blockt den Ham-Rescue.
    // So faellt ein "booking.co"-Phishing nicht durch, selbst wenn die KI
    // es faelschlich als legitim einstuft.
    $impersonation = floatval($localContext['impersonation_score'] ?? 0);
    if ($impersonation > 0) {
        $score = min(max($score, 0.0) + $impersonation, MAX_PHISHING_POINTS);
    }

    // --- Wie hart darf diese Mail behandelt werden? ---
    $policy     = categoryPolicy($category);
    $confidence = floatval($analysis['confidence'] ?? 0.5);
    $evidence   = collectStructuralEvidence($mail, $localContext, $analysis);

    // Ein Reject verlangt die Zustimmung einer zweiten, unabhaengigen Quelle.
    // Die KI allein reicht nicht: sie kann sich irren, und ein Reject ist die
    // einzige Entscheidung hier, die sich nicht zuruecknehmen laesst.
    $strong = strongEvidence($evidence);
    $verifiedBrand = verifiedBrandSender($mail);
    $rejectEligible = $policy['may_reject']
        && $confidence >= 0.80
        && !empty($strong)
        && empty($localContext['matched_profile'])
        && $verifiedBrand === ''
        && $mail['in_reply_to'] === '';

    $ceiling = ($rejectEligible && AI_MAY_REJECT)
        ? MAX_TOTAL_REJECTABLE
        : $policy['max_total'];

    if ($rejectEligible) {
        $score = max($score, REJECT_FLOOR);
    }

    $scoreBeforeCeiling = $score;
    $score = clampToTotalCeiling($score, $mail['rspamd_score'], $ceiling);

    // Jeden Kandidaten protokollieren - scharf wie im Schattenmodus. Eine
    // abgewiesene Mail hinterlaesst sonst keine Spur, die man nachlesen
    // koennte: sie taucht in keinem Postfach auf und in keiner Quarantaene,
    // die man taeglich anschaut.
    if ($rejectEligible) {
        $wouldScore = clampToTotalCeiling($scoreBeforeCeiling, $mail['rspamd_score'], MAX_TOTAL_REJECTABLE);
        $wouldTotal = $mail['rspamd_score'] + $wouldScore;
        if ($wouldTotal >= REJECT_THRESHOLD) {
            logError($requestId, AI_MAY_REJECT ? 'Reject allowed' : 'Would reject (shadow mode)', [
                'category'     => $category,
                'confidence'   => $confidence,
                'evidence'     => $evidence,
                'from'         => anonymizeAddress($mail['from']),
                'to'           => anonymizeAddress($mail['to']),
                'total_score'  => round($wouldTotal, 2),
                'applied'      => AI_MAY_REJECT,
            ]);
        }
    }

    return [
        'score'           => $score,
        'action'          => 'add',   // KI rejected nie — addiert nur
        'reason'          => $category . ': ' . cleanTextValue($analysis['reasoning'] ?? ''),
        'category'        => $category,
        'red_flags'       => normalizeStringList($analysis['red_flags'] ?? []),
        'analysis_source' => 'ai',
        'evidence'        => $evidence,
        'reject_eligible' => $rejectEligible,
        'claimed_brand'   => trim((string)($analysis['claimed_brand'] ?? '')),
        'verified_brand'  => $verifiedBrand,
    ];
}


// ---------------------------------------------------------------------
//  Wie hart darf eine Kategorie behandelt werden?
//
//  'points'     - wie viel die KI selbst hoechstens beitragen darf
//  'max_total'  - Obergrenze fuer Rspamd-Score PLUS unseren Beitrag
//  'may_reject' - darf diese Kategorie ueberhaupt bis zur Reject-Schwelle?
//
//  Die Deckelung ist bewusst als GESAMTSUMME formuliert. Nur so laesst sich
//  zusichern, dass eine geschuetzte Kategorie nie abgewiesen wird - egal wie
//  viele Punkte Rspamd vorher schon vergeben hat.
// ---------------------------------------------------------------------
function categoryPolicy($category) {
    switch ($category) {
        // Geschuetzt: hinter Transaktions- und Maschinenmail sitzt niemand,
        // der einen Bounce bemerkt. Die darf hoechstens einsortiert werden.
        case 'legitimate':
        case 'transactional':
        case 'personal':
            return ['points' => MAX_SPAM_POINTS, 'max_total' => MAX_TOTAL_TRANSACTIONAL, 'may_reject' => false];

        // Erwuenschte oder zumindest zuordenbare Werbung: darf in den Junk,
        // aber nicht verworfen werden.
        case 'newsletter':
        case 'marketing':
            return ['points' => MAX_SPAM_POINTS + 1.0, 'max_total' => MAX_TOTAL_DEFAULT, 'may_reject' => false];

        // Angreifbar. Bei clickbait kostet ein Fehlurteil praktisch nichts:
        // niemand vermisst die Mail, niemand meldet sich.
        case 'clickbait':
        case 'spam':
        case 'pharma':
        case 'phishing':
        case 'fraud':
            // max_total bleibt bewusst der Normalwert. Bis zur Reject-Schwelle
            // kommt eine Mail nur, wenn zusaetzlich die Konjunktion in
            // analyzeWithAI() haelt - nicht schon durch ihre Kategorie.
            return ['points' => MAX_PHISHING_POINTS, 'max_total' => MAX_TOTAL_DEFAULT, 'may_reject' => true];
    }

    // Unbekannte Kategorie -> vorsichtig behandeln.
    return ['points' => MAX_SPAM_POINTS, 'max_total' => MAX_TOTAL_DEFAULT, 'may_reject' => false];
}

// ---------------------------------------------------------------------
//  Belege, die NICHT von der KI stammen. Fuer ein Reject muss mindestens
//  einer davon zutreffen: eine zweite, unabhaengige Quelle soll dem Urteil
//  zustimmen, damit ein Modellfehler allein keine Mail verwirft.
// ---------------------------------------------------------------------
function collectStructuralEvidence(array $mail, array $localContext, array $analysis = []) {
    $evidence = [];

    if (allUrlsAreCloudStorage($mail['url_domains'])) {
        $evidence[] = 'cloud-storage-only-links';
    }
    if (floatval($localContext['impersonation_score'] ?? 0) > 0) {
        $evidence[] = 'brand-impersonation';
    }
    if (!empty($mail['signals']['url_blacklisted']) || !empty($mail['signals']['url_phishing'])) {
        $evidence[] = 'url-on-blocklist';
    }
    if (!empty(findDangerousAttachments($mail['attachments']))) {
        $evidence[] = 'dangerous-attachment';
    }
    if (!empty(findShortenerDomains($mail['url_domains']))) {
        $evidence[] = 'url-shortener';
    }
    // Nur wenn die Markenliste NICHT schon zugeschlagen hat - sonst
    // stuende derselbe Sachverhalt zweimal als "zwei" Belege da.
    if (floatval($localContext['impersonation_score'] ?? 0) <= 0
        && claimedBrandMismatch($mail, $analysis)) {
        $evidence[] = 'brand-claim-mismatch';
    }

    return $evidence;
}

// ---------------------------------------------------------------------
//  Kommt die Mail nachweislich VON der Marke, deren Domain sie traegt?
//
//  Die Markenliste haelt zu jeder Marke ihre echten Absenderdomains. Passt
//  eine From-Domain dazu, wirft detectBrandImpersonation() bisher einfach
//  null zurueck - die Erkenntnis "das ist wirklich Google" verpuffte.
//
//  Sie ist aber das Gegenstueck zu matched_profile und gehoert genauso
//  behandelt: Eine per DMARC beglaubigte Mail von google.com IST Google
//  und darf nicht abgewiesen werden, egal was in ihr verlinkt ist.
//
//  Am 21.08. wurde genau so eine Mail verworfen. Sie verlinkte
//  myaccount.google.com, store.google.com, g.co und c.gle - allesamt
//  Google - und Googles eigener Kurzdienst steht auf einer Phishing-
//  Blockliste, weil Phisher ihn missbrauchen. Der Beleg war technisch
//  richtig und die Schlussfolgerung trotzdem falsch.
//
//  Ein Faelscher kommt hier nicht durch: ohne bestandenes DMARC fuer die
//  echte Markendomain ist die Auth-Staerke nie 'strong'.
// ---------------------------------------------------------------------
function verifiedBrandSender(array $mail) {
    $domain = normalizeHost($mail['from_domain']);
    if ($domain === '' || evaluateAuthStrength($mail) !== 'strong') {
        return '';
    }

    foreach (getImpersonationBrands() as $brand => $realDomains) {
        foreach ($realDomains as $rd) {
            $rd = normalizeHost($rd);
            if ($domain === $rd || endsWith($domain, '.' . $rd)) {
                return $brand;
            }
        }
    }
    return '';
}

// ---------------------------------------------------------------------
//  Nicht jeder Beleg wiegt gleich schwer, der Reject-Gate fragte aber nur
//  "ist ueberhaupt einer da". Drei Klassen stuetzen sich auf eine externe,
//  vom Absender nicht beeinflussbare Quelle - eine gepflegte Markenliste,
//  eine Reputations-Blockliste, eine gefaehrliche Dateiendung. Die duerfen
//  eine Ablehnung allein tragen.
//
//  Die uebrigen sind Indizien. "brand-claim-mismatch" hat in der Praxis
//  dreimal gefeuert und lag dreimal daneben: eine Reederei ("Scenic
//  Eclipse" aus mail.scenic.eu), eine Schule ("Deutsche Schule Malaga"
//  aus dinantia.email) und ein Vermessungsbuero ("Latitude Surveying Ltd"
//  aus lats.co.nz - ihre eigene Abkuerzung). Firmen heissen eben nicht wie
//  ihre Domain. Als Bestaetigung bleibt der Hinweis wertvoll, als
//  alleiniger Grund fuer eine unwiderrufliche Ablehnung taugt er nicht.
// ---------------------------------------------------------------------
function strongEvidence(array $evidence) {
    static $strong = [
        'brand-impersonation',   // Markenliste mit hinterlegten Echt-Domains
        'url-on-blocklist',      // externe Reputationsdaten
        'dangerous-attachment',  // ausfuehrbarer Anhang
    ];
    return array_values(array_intersect($evidence, $strong));
}

// ---------------------------------------------------------------------
//  Object-Storage-Hoster. Landingpages dort sind bei Bulk-Versendern
//  beliebt, weil die Domain reputabel ist und auf keiner Blockliste steht
//  noch je stehen wird. Einzelne solche Links sind voellig normal
//  (Rechnungen, Exporte) - verdaechtig ist erst, wenn eine Mail AUSSER
//  diesen gar keine Links hat, also nicht einmal auf den eigenen Absender
//  verweist.
// ---------------------------------------------------------------------
function allUrlsAreCloudStorage(array $domains) {
    $domains = normalizeDomainList($domains);
    if (empty($domains)) {
        return false;
    }

    $storageHosts = [
        'storage.googleapis.com', 'firebasestorage.googleapis.com',
        's3.amazonaws.com', 'amazonaws.com',
        'blob.core.windows.net', 'core.windows.net',
        'digitaloceanspaces.com', 'backblazeb2.com', 'r2.dev',
        'storage.yandexcloud.net', 'objectstorage.oraclecloud.com',
        'oss-cn-hangzhou.aliyuncs.com', 'aliyuncs.com',
    ];

    foreach ($domains as $domain) {
        if (!domainMatchesAny($domain, $storageHosts)) {
            return false;
        }
    }

    return true;
}

// ---------------------------------------------------------------------
//  Deckelt unseren Beitrag so, dass die Gesamtsumme die Obergrenze der
//  Kategorie nicht ueberschreitet. Ham-Abzuege bleiben unangetastet, und
//  wenn Rspamd allein schon ueber der Grenze liegt, legen wir nichts drauf -
//  statt die Mail kuenstlich zu retten.
// ---------------------------------------------------------------------
function clampToTotalCeiling($score, $rspamdScore, $ceiling) {
    if ($score <= 0) {
        return $score;
    }
    $headroom = $ceiling - $rspamdScore;
    if ($headroom <= 0) {
        return 0.0;
    }
    return round(min($score, $headroom), 2);
}

// ---------------------------------------------------------------------
//  Manche Modelle geben Ziffern gelegentlich als Wort aus ("0. nine" statt
//  0.9). Das JSON ist dann unparsebar, obwohl der Inhalt brauchbar waere.
//  Nur in Zahlkontexten ersetzen, damit "one-time password" im Reasoning
//  nicht zerschossen wird.
// ---------------------------------------------------------------------
function sanitizeAiNumberWords($content) {
    static $words = [
        'zero' => '0', 'one' => '1', 'two' => '2', 'three' => '3', 'four' => '4',
        'five' => '5', 'six' => '6', 'seven' => '7', 'eight' => '8', 'nine' => '9',
    ];
    $alternatives = implode('|', array_keys($words));

    // "0. nine" / "0.nine"  ->  "0.9"
    $content = preg_replace_callback(
        '/(\d+\.)\s*(' . $alternatives . ')\b/i',
        function ($m) use ($words) { return $m[1] . $words[mb_strtolower($m[2])]; },
        $content
    );

    // '"confidence": nine'  ->  '"confidence": 9'
    $content = preg_replace_callback(
        '/("(?:spam_probability|confidence)"\s*:\s*)(' . $alternatives . ')\b/i',
        function ($m) use ($words) { return $m[1] . $words[mb_strtolower($m[2])]; },
        $content
    );

    return $content;
}

// ---------------------------------------------------------------------
//  Rettet die Kernfelder aus einer abgeschnittenen Antwort. Gibt null
//  zurueck, wenn nicht einmal die Wahrscheinlichkeit lesbar ist - dann war
//  die Antwort wirklich unbrauchbar.
// ---------------------------------------------------------------------
function recoverTruncatedAnalysis($content) {
    if (!preg_match('/"spam_probability"\s*:\s*(0(?:\.\d+)?|1(?:\.0+)?)/', $content, $p)) {
        return null;
    }

    $analysis = ['spam_probability' => floatval($p[1])];

    if (preg_match('/"confidence"\s*:\s*(0(?:\.\d+)?|1(?:\.0+)?)/', $content, $c)) {
        $analysis['confidence'] = floatval($c[1]);
    }
    if (preg_match('/"category"\s*:\s*"([a-z_-]+)"/i', $content, $cat)) {
        $analysis['category'] = $cat[1];
    }
    // red_flags nur uebernehmen, wenn das Array geschlossen ist - ein
    // abgeschnittenes Array wuerde halbe Flags liefern.
    if (preg_match('/"red_flags"\s*:\s*\[([^\]]*)\]/', $content, $rf)) {
        preg_match_all('/"([^"]*)"/', $rf[1], $items);
        $analysis['red_flags'] = $items[1];
    }
    if (preg_match('/"reasoning"\s*:\s*"([^"]*)/', $content, $r)) {
        $analysis['reasoning'] = rtrim($r[1]) . ' [abgeschnitten]';
    }

    return $analysis;
}

// ---------------------------------------------------------------------
//  Wahrscheinlichkeit + Confidence  ->  ein graduierter, signierter Score
//
//  p=0.95 c=0.9 -> +3.24   |  p=0.50 -> 0.00  |  p=0.05 c=0.9 -> -2.43
// ---------------------------------------------------------------------
function scoreFromAi($probability, $confidence, $category = '') {
    $probability = max(0.0, min(1.0, floatval($probability)));
    $confidence  = max(0.0, min(1.0, floatval($confidence)));

    // Gefaehrliche Kategorien duerfen hoeher raus. Ein als "phishing" oder
    // "fraud" eingestuftes Mail ist kaum je ein False-Positive, also kriegt
    // die KI hier mehr Spielraum als bei Marketing/Spam.
    $policy  = categoryPolicy($category);
    $maxSpam = $policy['points'];

    $direction = ($probability - 0.5) * 2.0;     // -1 .. +1
    $magnitude = abs($direction) * $confidence;  //  0 .. 1

    if ($direction >= 0) {
        return round($magnitude * $maxSpam, 2);   // Spam/Phishing -> positiv
    }
    return round(-$magnitude * MAX_HAM_POINTS, 2);       // Ham  -> negativ
}


// =====================================================================
//  HELFER
// =====================================================================
function getLocalDomains() {
    static $domains = null;
    static $lastFetch = 0;

    if ($domains !== null && (time() - $lastFetch) < 3600) {
        return $domains;
    }

    try {
        $pdo = new PDO(
            'mysql:host=' . MAILCOW_DB_HOST . ';dbname=' . MAILCOW_DB_NAME,
            MAILCOW_DB_USER,
            getenv('MAILCOW_DBPASS')
        );
        $domains = $pdo->query('SELECT domain FROM domain WHERE active = 1')->fetchAll(PDO::FETCH_COLUMN);
        $domains = normalizeDomainList($domains);
        $lastFetch = time();
    } catch (Exception $e) {
        logError('system', 'Failed to fetch local domains: ' . $e->getMessage());
        $domains = [];
    }

    return $domains;
}

function isInternalMail($from, $to) {
    $domains = getLocalDomains();
    if (empty($domains)) {
        return false;
    }

    $fromDomain = extractDomainFromAddress($from);
    $toDomain = extractDomainFromAddress($to);

    return in_array($fromDomain, $domains, true) && in_array($toDomain, $domains, true);
}

function getTrustedSenderProfiles() {
    static $profiles = null;

    if ($profiles !== null) {
        return $profiles;
    }

    $profiles = [
        'dhl' => [
            'kind' => 'shipping',
            'domains' => ['dhl.de', 'dhl.com', 'dpdhl.com', 'deutschepost.de'],
            'url_domains' => ['dhl.de', 'dhl.com', 'dpdhl.com', 'deutschepost.de'],
            'brands' => ['dhl', 'deutsche post', 'deutschepost'],
        ],
        'dpd' => [
            'kind' => 'shipping',
            'domains' => ['dpd.de', 'dpd.com'],
            'url_domains' => ['dpd.de', 'dpd.com'],
            'brands' => ['dpd'],
        ],
        'hermes' => [
            'kind' => 'shipping',
            'domains' => ['myhermes.de', 'hermesworld.com'],
            'url_domains' => ['myhermes.de', 'hermesworld.com'],
            'brands' => ['hermes', 'myhermes'],
        ],
        'ups' => [
            'kind' => 'shipping',
            'domains' => ['ups.com'],
            'url_domains' => ['ups.com'],
            'brands' => ['ups'],
        ],
        'gls' => [
            'kind' => 'shipping',
            'domains' => ['gls-group.eu', 'gls-pakete.de'],
            'url_domains' => ['gls-group.eu', 'gls-pakete.de'],
            'brands' => ['gls'],
        ],
        'shop-apotheke' => [
            'kind' => 'pharmacy',
            'domains' => ['shop-apotheke.com', 'shop-apotheke.de'],
            'url_domains' => ['shop-apotheke.com', 'shop-apotheke.de'],
            'brands' => ['shop apotheke', 'shop-apotheke'],
        ],
        'docmorris' => [
            'kind' => 'pharmacy',
            'domains' => ['docmorris.de', 'docmorris.com'],
            'url_domains' => ['docmorris.de', 'docmorris.com'],
            'brands' => ['docmorris'],
        ],
        'amazon' => [
            'kind' => 'marketplace',
            'domains' => ['amazon.de', 'amazon.com'],
            'url_domains' => ['amazon.de', 'amazon.com'],
            'brands' => ['amazon'],
        ],
        'paypal' => [
            'kind' => 'finance',
            'domains' => ['paypal.com', 'paypal.de'],
            'url_domains' => ['paypal.com', 'paypal.de'],
            'brands' => ['paypal'],
        ],
        'telekom' => [
            'kind' => 'telecom',
            'domains' => ['telekom.de', 't-online.de'],
            'url_domains' => ['telekom.de', 't-online.de'],
            'brands' => ['telekom', 't-online'],
        ],
        'vodafone' => [
            'kind' => 'telecom',
            'domains' => ['vodafone.de', 'vodafone.com'],
            'url_domains' => ['vodafone.de', 'vodafone.com'],
            'brands' => ['vodafone'],
        ],
        'sipgate' => [
            'kind' => 'telecom',
            'domains' => ['sipgate.de'],
            'url_domains' => ['sipgate.de'],
            'brands' => ['sipgate'],
        ],
        'fonial' => [
            'kind' => 'telecom',
            'domains' => ['fonial.de'],
            'url_domains' => ['fonial.de'],
            'brands' => ['fonial'],
        ],
    ];

    foreach ($profiles as $key => $profile) {
        $profiles[$key] = normalizeProfile($profile);
    }

    $customFile = __DIR__ . '/trusted_sender_profiles.json';
    if (is_file($customFile)) {
        $customProfiles = json_decode(file_get_contents($customFile), true);
        if (is_array($customProfiles)) {
            foreach ($customProfiles as $key => $profile) {
                if (!is_array($profile)) {
                    continue;
                }
                if (isset($profiles[$key])) {
                    $profiles[$key] = normalizeProfile(mergeProfileConfig($profiles[$key], $profile));
                } else {
                    $profiles[$key] = normalizeProfile($profile);
                }
            }
        }
    }

    return $profiles;
}

function normalizeProfile(array $profile) {
    return [
        'kind' => cleanTextValue($profile['kind'] ?? 'generic'),
        'domains' => normalizeDomainList($profile['domains'] ?? []),
        'url_domains' => normalizeDomainList($profile['url_domains'] ?? ($profile['domains'] ?? [])),
        'brands' => normalizeKeywordList($profile['brands'] ?? []),
    ];
}

function mergeProfileConfig(array $base, array $override) {
    $merged = $base;

    foreach (['kind'] as $scalarKey) {
        if (isset($override[$scalarKey]) && is_string($override[$scalarKey]) && trim($override[$scalarKey]) !== '') {
            $merged[$scalarKey] = $override[$scalarKey];
        }
    }

    foreach (['domains', 'url_domains', 'brands'] as $listKey) {
        if (isset($override[$listKey]) && is_array($override[$listKey])) {
            $merged[$listKey] = array_values(array_unique(array_merge($merged[$listKey] ?? [], $override[$listKey])));
        }
    }

    return $merged;
}

function matchTrustedProfile(array $mail, array $profiles) {
    $best = ['key' => '', 'profile' => null, 'score' => 0, 'sources' => []];

    foreach ($profiles as $key => $profile) {
        $score = 0;
        $sources = [];

        if (domainMatchesAny($mail['from_domain'], $profile['domains'])) {
            $score += 5; $sources[] = 'from_domain';
        }
        if ($mail['from_mime_domain'] !== '' && domainMatchesAny($mail['from_mime_domain'], $profile['domains'])) {
            $score += 2; $sources[] = 'from_mime_domain';
        }
        if ($mail['from_smtp_domain'] !== '' && domainMatchesAny($mail['from_smtp_domain'], $profile['domains'])) {
            $score += 2; $sources[] = 'from_smtp_domain';
        }
        if ($mail['return_path_domain'] !== '' && domainMatchesAny($mail['return_path_domain'], $profile['domains'])) {
            $score += 1; $sources[] = 'return_path_domain';
        }
        if ($mail['message_id_domain'] !== '' && domainMatchesAny($mail['message_id_domain'], $profile['domains'])) {
            $score += 1; $sources[] = 'message_id_domain';
        }

        if ($score > $best['score']) {
            $best = ['key' => $key, 'profile' => $profile, 'score' => $score, 'sources' => $sources];
        }
    }

    return $best['score'] > 0 ? $best : ['key' => '', 'profile' => null, 'score' => 0, 'sources' => []];
}

// ---------------------------------------------------------------------
//  Marken, die haeufig fuer Phishing missbraucht werden, mit ihren
//  ECHTEN Domains. Reine lokale Liste — kein externer Call.
//  Ergaenzbar ueber trusted_sender_profiles.json ist bewusst getrennt:
//  hier geht's nur um Impersonation-Erkennung.
// ---------------------------------------------------------------------
function getImpersonationBrands() {
    return [
        'paypal'          => ['paypal.com', 'paypal.de'],
        'amazon'          => ['amazon.de', 'amazon.com', 'amazon.co.uk'],
        'booking'         => ['booking.com'],
        'booking.com'     => ['booking.com'],
        'western digital' => ['westerndigital.com', 'wd.com'],
        // Bewusst OHNE live.com/outlook.com: das sind freie Postfachdomains.
        // Wer dort ein Konto anlegt, setzt seinen Anzeigenamen selbst auf
        // "Microsoft" - als Freibrief taugen sie nicht.
        'microsoft'       => ['microsoft.com', 'office.com', 'microsoftonline.com'],
        'apple'           => ['apple.com', 'icloud.com'],
        'netflix'         => ['netflix.com'],
        'ebay'            => ['ebay.de', 'ebay.com'],
        'google'          => ['google.com', 'google.de', 'googlegroups.com'],
        'dhl'             => ['dhl.de', 'dhl.com', 'dpdhl.com'],
        'dpd'             => ['dpd.de', 'dpd.com'],
        'ups'             => ['ups.com'],
        'gls'             => ['gls-group.eu', 'gls-pakete.de'],
        'hermes'          => ['myhermes.de', 'hermesworld.com'],
        'fedex'           => ['fedex.com'],
        'sparkasse'       => ['sparkasse.de'],
        'volksbank'       => ['vr.de', 'volksbank.de'],
        'commerzbank'     => ['commerzbank.de'],
        'deutsche bank'   => ['deutsche-bank.de', 'db.com'],
        'dkb'             => ['dkb.de'],
        'ing'             => ['ing.de'],
        'postbank'        => ['postbank.de'],
        'telekom'         => ['telekom.de', 't-online.de'],
        'vodafone'        => ['vodafone.de'],
        'o2'              => ['o2online.de', 'telefonica.de'],
        '1und1'           => ['1und1.de', 'ionos.de'],

        // Direktbanken und Fintechs. Genau die Ecke, aus der die
        // "Ihr Konto wurde gesperrt"-Mails kommen - und die hier lange
        // gefehlt hat, weshalb solche Mails keine Struktur-Evidenz
        // bekamen und damit nie abgewiesen werden konnten.
        'n26'             => ['n26.com', 'n26.de'],
        'revolut'         => ['revolut.com'],
        'wise'            => ['wise.com', 'transferwise.com'],
        'trade republic'  => ['traderepublic.com'],
        'traderepublic'   => ['traderepublic.com'],
        'klarna'          => ['klarna.com', 'klarna.de'],
        'comdirect'       => ['comdirect.de'],
        'consorsbank'     => ['consorsbank.de'],
        'targobank'       => ['targobank.de'],
        'norisbank'       => ['norisbank.de'],
        'hypovereinsbank' => ['hypovereinsbank.de', 'unicredit.de'],
        'santander'       => ['santander.de', 'santander.com'],
        'sparda'          => ['sparda.de'],
        'bunq'            => ['bunq.com'],

        // Krypto-Boersen: Kontosperrungen und "Verifizierung noetig"
        'coinbase'        => ['coinbase.com'],
        'binance'         => ['binance.com'],
        'kraken'          => ['kraken.com'],

        // Plattformen mit Konto und Zahlungsdaten
        'whatsapp'        => ['whatsapp.com'],
        'instagram'       => ['instagram.com'],
        'facebook'        => ['facebook.com', 'facebookmail.com'],
        'linkedin'        => ['linkedin.com'],
        'spotify'         => ['spotify.com'],
        'disney'          => ['disney.com', 'disneyplus.com'],
        'adobe'           => ['adobe.com'],
        'zalando'         => ['zalando.de', 'zalando.com'],

        // Post und Behoerden
        'deutsche post'   => ['deutschepost.de', 'dpdhl.com'],
        'elster'          => ['elster.de'],
    ];
}

// ---------------------------------------------------------------------
//  Der listenlose Gegenpart zu detectBrandImpersonation(). Eine Liste
//  kann nie jede Bank, jedes Fintech und jede Regionalkasse kennen - die
//  N26-Phishing-Mail vom 20.08. kam genau durch diese Luecke.
//
//  Hier nennt die KI die behauptete Marke, geprueft wird sie aber
//  maschinell: steckt der Name in der tatsaechlichen Absenderdomain?
//  Die KI liefert nur die Behauptung, das Urteil faellt Code - damit
//  bleibt der Beleg unabhaengig genug fuer den Reject-Gate.
//
//  Der entscheidende Schutz ist die Kopplung an die Auth-Staerke: Firmen
//  versenden staendig ueber Dienstleister (Mailchimp, Brevo, Sendgrid)
//  und behaupten dabei ihren eigenen Namen aus fremder Domain. Solche
//  Post ist SPF/DKIM-sauber. Nur wenn die Authentifizierung NICHT stark
//  ist, zaehlt eine Abweichung als Beleg.
// ---------------------------------------------------------------------
function claimedBrandMismatch(array $mail, array $analysis) {
    $token = brandToken((string)($analysis['claimed_brand'] ?? ''));

    // Zu kurz ist keine Marke ("AG", "eG"), und Gattungsbegriffe sind es
    // erst recht nicht - die wuerden gegen jede Domain "abweichen".
    if (mb_strlen($token) < 3 || isGenericSenderClaim($token)) {
        return false;
    }

    $domain = normalizeHost($mail['from_domain']);
    if ($domain === '') {
        return false;
    }

    // Traegt die Absenderdomain die Marke? Firmennamen sind fast nie mit
    // ihrer Domain identisch: "Albana Hotel & Suites Silvaplana" versendet
    // aus hotelalbana.ch. Ein Vergleich auf Gleichheit hat genau diesen
    // echten Newsletter am 20.08. als Betrug ausgewiesen.
    //
    // Deshalb wortweise: Gattungsbegriffe raus, und wenn ein wesentliches
    // Wort in der Domain vorkommt, gehoeren Behauptung und Absender
    // zusammen. Geprueft wird nur gegen die letzten beiden Label, damit
    // "paypal.com.evil.ru" sich nicht durch das vorangestellte "paypal"
    // freikaufen kann.
    $orgDomain = brandToken(implode('', organisationalLabels($domain)));
    if ($orgDomain !== '') {
        if (mb_strpos($orgDomain, $token) !== false) {
            return false;
        }
        foreach (significantBrandWords($analysis['claimed_brand'] ?? '') as $word) {
            if (mb_strpos($orgDomain, $word) !== false) {
                return false;
            }
        }
    }

    // Bekannte, legitime Abweichung? Amazon versendet aus amazonses.com,
    // Microsoft aus outlook.com. Dafuer - und nur noch dafuer - dient die
    // Markenliste hier.
    foreach (getImpersonationBrands() as $brand => $realDomains) {
        $known = brandToken($brand);
        if ($known === '' || mb_strpos($token, $known) === false) {
            continue;
        }
        foreach ($realDomains as $rd) {
            $rd = normalizeHost($rd);
            if ($domain === $rd || endsWith($domain, '.' . $rd)) {
                return false;
            }
        }
    }

    return evaluateAuthStrength($mail) !== 'strong';
}

// Zerlegt eine Markenbehauptung in ihre aussagekraeftigen Woerter.
// Rechtsformen und Branchenwoerter fliegen raus - "Hotel" oder "GmbH"
// steckt in tausenden Domains und wuerde jede Pruefung entwerten.
// Uebrig bleibt, was die Firma tatsaechlich identifiziert.
function significantBrandWords($claim) {
    static $filler = [
        'hotel', 'hotels', 'suites', 'resort', 'gmbh', 'ag', 'sa', 'sarl',
        'kg', 'ohg', 'ug', 'ltd', 'llc', 'inc', 'bv', 'nv', 'oy', 'aps',
        'group', 'gruppe', 'holding', 'company', 'team', 'service',
        'services', 'shop', 'store', 'online', 'deutschland', 'germany',
        'schweiz', 'austria', 'europe', 'international', 'the', 'und', 'and',
    ];

    $words = preg_split('/[^\p{L}\p{N}]+/u', mb_strtolower((string)$claim), -1, PREG_SPLIT_NO_EMPTY);
    $out = [];
    foreach ($words as $w) {
        // Unter vier Zeichen ist ein Wort zu unspezifisch, um eine
        // Uebereinstimmung zu tragen - ausser es traegt eine Ziffer
        // ("N26", "1und1"), dann ist es gerade sehr spezifisch.
        if (in_array($w, $filler, true)) {
            continue;
        }
        if (mb_strlen($w) >= 4 || preg_match('/\d/', $w)) {
            $out[] = $w;
        }
    }
    return $out;
}

// Normalisiert einen Marken- oder Domainnamen auf reine Buchstaben und
// Ziffern in Kleinschreibung: "Trade Republic" -> "traderepublic".
function brandToken($value) {
    return mb_strtolower(preg_replace('/[^\p{L}\p{N}]+/u', '', (string)$value));
}

// Die letzten beiden Label einer Domain - eine Naeherung fuer die
// registrierbare Domain, ohne Public Suffix List. Bei "n26.co.uk" greift
// sie daneben; solche Faelle deckt die Markenliste oben ab.
function organisationalLabels($domain) {
    $parts = explode('.', $domain);
    return array_slice($parts, -2);
}

// Wofuer sich halb Deutschland ausgibt, ist keine Marke. Ohne diese
// Bremse wuerde jedes "Kundenservice" gegen jede Domain abweichen.
function isGenericSenderClaim($token) {
    static $generic = [
        'bank', 'ihrebank', 'sparkasse2', 'support', 'kundenservice',
        'kundendienst', 'service', 'team', 'info', 'noreply', 'kontakt',
        'sicherheit', 'security', 'admin', 'administrator', 'buchhaltung',
        'rechnung', 'versand', 'newsletter', 'mailer', 'postmaster',
        'finanzamt2', 'onlinebanking', 'zahlungsdienst',
    ];
    return in_array($token, $generic, true);
}

// ---------------------------------------------------------------------
//  Wird die Marke wirklich behauptet - oder steckt sie nur zufaellig in
//  einem laengeren Wort? "ing" in "Marketing", "Holding", "Consulting",
//  "ups" in "Backups", "google" in "googlegroups.com": mit blossem
//  Teilstring-Vergleich bekam jede dieser voellig legitimen Firmen einen
//  Impersonation-Score von 7.0 und damit die Reject-Evidenz.
//
//  Regel: unmittelbar vor und nach der Marke darf kein BUCHSTABE stehen.
//  Ziffern und Trennzeichen zaehlen als Grenze, damit "paypal-service@",
//  "N26" und "1und1" weiter greifen.
//
//  Bewusst in Kauf genommen: "paypalservice@..." ohne Trennzeichen wird
//  so nicht mehr erkannt. Das ist der richtige Tausch - eine faelschlich
//  abgewiesene Geschaeftsmail wiegt schwerer als ein Phishing, das die KI
//  ohnehin noch bewertet, nur eben ohne automatisches Reject.
// ---------------------------------------------------------------------
function brandIsClaimed($claimSurface, $brand) {
    $pattern = '/(?<![\p{L}])' . preg_quote($brand, '/') . '(?![\p{L}])/u';
    return (bool)preg_match($pattern, $claimSurface);
}

// ---------------------------------------------------------------------
//  Prueft, ob sich die Mail als bekannte Marke AUSGIBT, obwohl die
//  Absender-Domain nicht dazu passt. Schaut NUR auf Display-Name und
//  From-Adresse — ueber eine Marke im Body zu reden ist voellig normal
//  und darf nie einen Treffer ausloesen.
//
//  Rueckgabe: null | ['brand'=>.., 'kind'=>.., 'distance'=>.., 'score'=>..]
// ---------------------------------------------------------------------
function detectBrandImpersonation(array $mail) {
    $brands = getImpersonationBrands();

    // Behauptungsflaeche: nur Absendername + From-Adresse
    $claimSurface = mb_strtolower(trim($mail['from_display_name'] . ' ' . $mail['from']));
    $fromDomain = normalizeHost($mail['from_domain']);

    if ($claimSurface === '' || $fromDomain === '') {
        return null;
    }

    foreach ($brands as $brand => $realDomains) {
        // Wird die Marke im Absendernamen ueberhaupt behauptet?
        if (!brandIsClaimed($claimSurface, $brand)) {
            continue;
        }

        // Gehoert die Absender-Domain wirklich zur Marke? -> alles gut, echte Mail
        foreach ($realDomains as $rd) {
            $rd = normalizeHost($rd);
            if ($fromDomain === $rd || endsWith($fromDomain, '.' . $rd)) {
                return null;
            }
        }

        // Marke behauptet, Domain passt NICHT. Wie nah dran ist der Fake?
        $minDist = PHP_INT_MAX;
        foreach ($realDomains as $rd) {
            $d = levenshtein($fromDomain, normalizeHost($rd));
            if ($d < $minDist) {
                $minDist = $d;
            }
        }

        // Typosquat (booking.co vs booking.com): sehr sicheres Signal,
        // praktisch nie ein legitimer Absender -> harter Boden.
        if ($minDist <= 2) {
            return ['brand' => $brand, 'kind' => 'typosquat', 'distance' => $minDist, 'score' => 6.0];
        }

        // Marke im Namen, aber voellig fremde Domain (paypal von xyz.ru):
        // sehr verdaechtig. Reseller sind selten, drum kraeftiger Schubs —
        // aber Reject nur wenn die KI zusaetzlich "phishing" sagt.
        return ['brand' => $brand, 'kind' => 'foreign-domain', 'distance' => $minDist, 'score' => 7.0];
    }

    return null;
}
function evaluateAuthStrength(array $mail) {
    $passCount = 0;
    $failCount = 0;

    foreach (['spf', 'dkim', 'dmarc'] as $key) {
        $status = $mail['auth'][$key] ?? 'unknown';
        if ($status === 'pass') {
            $passCount++;
        } elseif ($status === 'fail') {
            $failCount++;
        }
    }

    // DMARC schlaegt alles andere. Besteht es, ist die From-Domain
    // nachweislich autorisiert - dann ist ein abweichender Envelope kein
    // Verdachtsmoment, sondern der Normalfall.
    //
    // Genau daran ist der Hotel-Newsletter am 20.08. gescheitert: Campaign
    // Monitor versendet als "...@cmail19.com" mit From "hotel@hotelalbana.ch".
    // Rspamd setzt dafuer FORGED_SENDER und FROM_NEQ_ENVFROM - bei JEDEM
    // Newsletter-Dienstleister. Diese Pruefung lief vor der DMARC-Abfrage
    // und stufte deshalb sauber authentifizierte Post als verdaechtig ein.
    if (($mail['auth']['dmarc'] ?? '') === 'pass') {
        return 'strong';
    }

    if ($failCount > 0) {
        return 'suspicious';
    }

    // Ohne DMARC-Beleg bleibt ein abweichender Absender ein Warnzeichen.
    if (!empty($mail['signals']['forged_sender']) || !empty($mail['signals']['from_neq_envfrom'])) {
        return 'suspicious';
    }

    if ($passCount >= 2) {
        return 'strong';
    }

    if ($passCount === 1 || $mail['rspamd_score'] <= 1.0) {
        return 'medium';
    }

    return 'unknown';
}
function buildLocalDecision($score, $action, $reason, $category, array $redFlags) {
    return [
        'handled' => true,
        'score' => $score,
        'action' => $action,
        'reason' => $reason,
        'category' => $category,
        'red_flags' => $redFlags,
        'analysis_source' => 'local',
    ];
}

function neutralResponse($reason) {
    return [
        'score' => 0.0,
        'action' => 'add',
        'reason' => $reason,
        'category' => 'neutral',
        'red_flags' => [],
        'analysis_source' => 'system',
    ];
}

function respondSuccess($score, $action, $reason, $requestId) {
    header('Content-Type: application/json');
    echo json_encode([
        'score' => round($score, 2),
        'action' => $action,
        'reason' => $reason,
        'request_id' => $requestId,
    ]);
    exit;
}

function respondError($message) {
    header('Content-Type: application/json');
    http_response_code(400);
    echo json_encode(['error' => $message]);
    exit;
}

function logStats($requestId, $data) {
    $from = $data['from'] ?? '';
    $to = $data['to'] ?? '';

    $entry = [
        'timestamp' => date('c'),
        'id' => $requestId,
        'from' => anonymizeAddress($from),
        'to' => anonymizeAddress($to),
        'rspamd_score' => floatval($data['rspamd_score'] ?? 0),
        'ai_score' => round(floatval($data['ai_score'] ?? 0), 2),
        'ai_action' => $data['ai_action'] ?? 'add',
        'category' => $data['category'] ?? 'unknown',
        'red_flags' => array_slice(normalizeStringList($data['red_flags'] ?? []), 0, 8),
        'analysis_source' => $data['analysis_source'] ?? 'unknown',
        'matched_profile' => $data['matched_profile'] ?? '',
        'mail_type_guess' => $data['mail_type_guess'] ?? '',
        'url_domains' => array_slice(normalizeDomainList($data['url_domains'] ?? []), 0, 8),
        // Strukturbelege und Reject-Freigabe mitschreiben: nur so laesst sich
        // im Schattenmodus nachvollziehen, welche Mails abgewiesen wuerden.
        'evidence' => normalizeStringList($data['evidence'] ?? []),
        'reject_eligible' => !empty($data['reject_eligible']),
        'claimed_brand' => mb_substr((string)($data['claimed_brand'] ?? ''), 0, 60),
        // Wer hier steht, ist per DMARC als diese Marke beglaubigt und
        // wird nie abgewiesen - das will man im Log sehen koennen.
        'verified_brand' => mb_substr((string)($data['verified_brand'] ?? ''), 0, 40),
    ];

    // Betreff: siehe LOG_SUBJECT, standardmaessig an.
    if (LOG_SUBJECT) {
        $entry['subject'] = mb_substr($data['subject'] ?? '', 0, 120);
    }

    // Der Body-Auszug bleibt getrennt davon und aus. Er ist um ein
    // Vielfaches aussagekraeftiger ueber den Inhalt als eine Betreffzeile
    // und wird zum Beurteilen eines Urteils nicht gebraucht.
    if (LOG_MAIL_CONTENT) {
        $entry['body_preview'] = mb_substr(trim(preg_replace('/\s+/u', ' ', strip_tags($data['body'] ?? ''))), 0, 220);
    }

    appendLogLine(STATS_LOG, $entry);
}

function logError($requestId, $message, $context = []) {
    $entry = [
        'timestamp' => date('c'),
        'id' => $requestId,
        'level' => 'ERROR',
        'message' => $message,
        'context' => $context,
    ];

    appendLogLine(ERROR_LOG, $entry);
}

// Schreibt eine JSON-Zeile und stellt sicher, dass die Datei beim ersten
// Anlegen nicht world-readable ist - die Eintraege sind personenbezogen.
function appendLogLine($file, array $entry) {
    $isNew = !file_exists($file);
    @file_put_contents(
        $file,
        json_encode($entry, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n",
        FILE_APPEND | LOCK_EX
    );
    if ($isNew) {
        @chmod($file, LOG_FILE_MODE);
    }
}

function checkBudget($requestId) {
    $now = new DateTime();
    $currentMonth = $now->format('Y-m');
    $budget = ['month' => $currentMonth, 'calls' => 0, 'estimated_cost_eur' => 0];

    if (file_exists(BUDGET_FILE)) {
        $stored = json_decode(file_get_contents(BUDGET_FILE), true);
        if (is_array($stored) && isset($stored['month'])) {
            $budget = $stored;
        }
    }

    if ($budget['month'] !== $currentMonth) {
        $budget = ['month' => $currentMonth, 'calls' => 0, 'estimated_cost_eur' => 0];
    }

    if (($budget['calls'] ?? 0) >= MAX_CALLS_PER_MONTH) {
        logError($requestId, 'Monthly budget exceeded', [
            'calls' => $budget['calls'],
            'limit' => MAX_CALLS_PER_MONTH,
            'cost_eur' => round($budget['estimated_cost_eur'], 2),
        ]);
        return false;
    }

    $budget['calls'] = intval($budget['calls'] ?? 0) + 1;
    $budget['estimated_cost_eur'] = $budget['calls'] * AVG_COST_PER_CALL_EUR;

    file_put_contents(BUDGET_FILE, json_encode($budget), LOCK_EX);

    return true;
}

function cleanTextValue($value) {
    if (!is_string($value) && !is_numeric($value)) {
        return '';
    }
    return trim((string) $value);
}

function normalizeTriState($value) {
    $value = mb_strtolower(cleanTextValue($value));
    if (in_array($value, ['pass', 'fail', 'unknown'], true)) {
        return $value;
    }
    return 'unknown';
}

function normalizeStringList($values) {
    if (!is_array($values)) {
        return [];
    }

    $normalized = [];
    foreach ($values as $value) {
        if (is_array($value)) {
            $value = $value['url'] ?? $value['value'] ?? '';
        }
        $value = cleanTextValue($value);
        if ($value !== '') {
            $normalized[] = $value;
        }
    }

    return array_values(array_unique($normalized));
}

function normalizeKeywordList($values) {
    $normalized = [];
    foreach (normalizeStringList($values) as $value) {
        $normalized[] = mb_strtolower($value);
    }
    return array_values(array_unique($normalized));
}

function normalizeDomainList($values) {
    $normalized = [];
    foreach (normalizeStringList($values) as $value) {
        $host = normalizeHost($value);
        if ($host !== '') {
            $normalized[] = $host;
        }
    }
    return array_values(array_unique($normalized));
}

function normalizeAttachments($attachments) {
    if (!is_array($attachments)) {
        return [];
    }

    $normalized = [];
    foreach ($attachments as $attachment) {
        if (!is_array($attachment)) {
            continue;
        }
        $normalized[] = [
            'name' => cleanTextValue($attachment['name'] ?? '(unnamed)'),
            'type' => cleanTextValue($attachment['type'] ?? 'unknown'),
            'size' => intval($attachment['size'] ?? 0),
        ];
    }

    return $normalized;
}

function extractDomainFromAddress($value) {
    $value = cleanTextValue($value);
    if ($value === '') {
        return '';
    }

    if (preg_match('/<([^>]+)>/', $value, $matches)) {
        $value = $matches[1];
    }

    if (preg_match('/@([^>\s]+)/', $value, $matches)) {
        return normalizeHost($matches[1]);
    }

    return normalizeHost($value);
}

function extractDomainFromMessageId($value) {
    $value = cleanTextValue($value);
    if ($value === '') {
        return '';
    }

    if (preg_match('/@([^>\s]+)/', $value, $matches)) {
        return normalizeHost($matches[1]);
    }

    return '';
}

function normalizeHost($value) {
    $value = cleanTextValue($value);
    if ($value === '') {
        return '';
    }

    $value = mb_strtolower($value);
    $value = preg_replace('/^[^@]+@/', '', $value);
    $value = preg_replace('/^https?:\/\//', '', $value);
    $value = preg_replace('/^www\./', '', $value);
    $value = preg_replace('/[\/?#].*$/', '', $value);
    $value = preg_replace('/:\d+$/', '', $value);
    $value = trim($value, " .<>()[]\t\r\n");

    return $value;
}

function extractHostFromUrl($url) {
    $url = cleanTextValue($url);
    if ($url === '') {
        return '';
    }

    $candidate = $url;
    if (!preg_match('~^[a-z]+://~i', $candidate)) {
        $candidate = 'https://' . $candidate;
    }

    $parts = parse_url($candidate);
    return normalizeHost($parts['host'] ?? '');
}

function extractUrlsFromText($text) {
    $urls = [];
    $domains = [];

    if (!is_string($text) || trim($text) === '') {
        return ['urls' => [], 'domains' => []];
    }

    if (preg_match_all('~https?://[^\s<>"\']+|www\.[^\s<>"\']+~iu', $text, $matches)) {
        foreach ($matches[0] as $rawUrl) {
            $rawUrl = rtrim($rawUrl, ".,;:!?");
            $urls[] = $rawUrl;
            $host = extractHostFromUrl($rawUrl);
            if ($host !== '') {
                $domains[] = $host;
            }
        }
    }

    return [
        'urls' => array_values(array_unique($urls)),
        'domains' => array_values(array_unique($domains)),
    ];
}

function domainMatchesAny($domain, array $allowedDomains) {
    $domain = normalizeHost($domain);
    if ($domain === '') {
        return false;
    }

    foreach ($allowedDomains as $allowedDomain) {
        $allowedDomain = normalizeHost($allowedDomain);
        if ($allowedDomain === '') {
            continue;
        }
        if ($domain === $allowedDomain || endsWith($domain, '.' . $allowedDomain)) {
            return true;
        }
    }

    return false;
}

function allDomainsAllowed(array $domains, array $allowedDomains) {
    $domains = normalizeDomainList($domains);
    if (empty($domains)) {
        return true;
    }

    foreach ($domains as $domain) {
        if (!domainMatchesAny($domain, $allowedDomains)) {
            return false;
        }
    }

    return true;
}

function endsWith($value, $suffix) {
    if ($suffix === '') {
        return true;
    }
    return substr($value, -strlen($suffix)) === $suffix;
}
function countKeywordHits($haystack, array $keywords) {
    $haystack = mb_strtolower(cleanTextValue($haystack));
    if ($haystack === '') {
        return 0;
    }

    $hits = 0;
    foreach ($keywords as $keyword) {
        $keyword = mb_strtolower(cleanTextValue($keyword));
        if ($keyword !== '' && mb_strpos($haystack, $keyword) !== false) {
            $hits++;
        }
    }

    return $hits;
}

function findDangerousAttachments(array $attachments) {
    $dangerousExtensions = [
        'exe', 'js', 'jse', 'vbs', 'vbe', 'scr', 'bat', 'cmd', 'com',
        'ps1', 'jar', 'hta', 'iso', 'img', 'lnk', 'chm', 'ace',
    ];

    $hits = [];
    foreach ($attachments as $attachment) {
        $name = mb_strtolower($attachment['name'] ?? '');
        if ($name === '' || strpos($name, '.') === false) {
            continue;
        }
        $extension = pathinfo($name, PATHINFO_EXTENSION);
        if (in_array($extension, $dangerousExtensions, true)) {
            $hits[] = $extension;
            continue;
        }
        if ($extension === 'zip' && preg_match('/invoice|rechnung|document|doc|scan|payment|bestellung/i', $name)) {
            $hits[] = 'zip-suspicious-name';
        }
    }

    return array_values(array_unique($hits));
}

function findShortenerDomains(array $domains) {
    $shorteners = [
        'bit.ly', 'tinyurl.com', 't.co', 'rb.gy', 'shorturl.at',
        'goo.gl', 'ow.ly', 'buff.ly', 'is.gd', 'tiny.cc',
    ];

    $hits = [];
    foreach (normalizeDomainList($domains) as $domain) {
        if (domainMatchesAny($domain, $shorteners)) {
            $hits[] = $domain;
        }
    }

    return array_values(array_unique($hits));
}
// Pseudonymisiert eine Absender-/Empfaengeradresse fuer das Log.
// Wichtig: der Eingabewert ist oft der komplette From-HEADER
// ("Max Mustermann <max@example.org>"). Ohne das Herausloesen der Adresse
// wuerde hier der Klarname statt des Local-Parts maskiert werden.
function anonymizeAddress($address) {
    $address = cleanTextValue($address);

    if (preg_match('/<([^>]+)>/', $address, $matches)) {
        $address = trim($matches[1]);
    }

    if (strpos($address, '@') === false) {
        return 'unknown';
    }

    list($local, $domain) = explode('@', $address, 2);
    $domain = trim($domain, " .<>()[]\t\r\n");

    return mb_substr($local, 0, 3) . '***@' . $domain;
}

function formatListForPrompt(array $items) {
    $items = normalizeStringList($items);
    if (empty($items)) {
        return '(none)';
    }
    return implode(', ', array_slice($items, 0, 15));
}

function safePromptValue($value) {
    $value = cleanTextValue($value);
    return $value !== '' ? $value : '(none)';
}
