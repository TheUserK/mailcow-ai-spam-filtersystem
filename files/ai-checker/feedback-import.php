<?php
// =====================================================================
//  Uebernimmt, was ai-filter-feedback.sh aus den Postfaechern gelesen
//  hat, in die Beziehungs-Datenbank des Checkers.
//
//  Laeuft IM ai-checker-Container (dort gibt es PHP mit pdo_sqlite und
//  dieselben Funktionen, mit denen der Checker seinen Absender-Schluessel
//  bildet). Wird nicht ueber HTTP erreicht - router.php reicht nur an
//  ai-mail-checker.php durch.
//
//  Eingabe auf STDIN, eine Zeile je Mail, im Tab-Format von doveadm,
//  davor der Ordner:
//    <INBOX|JUNK> TAB user TAB date.saved TAB x-spam-flag TAB x-spam TAB from
//
//  Daraus:
//    INBOX + Spam-Kennzeichen   -> "rescued"  (aus dem Junk zurueckgeholt)
//    JUNK  ohne Spam-Kennzeichen -> "junked"   (von Hand hineingeschoben)
//  Alles andere sagt nichts und wird verworfen. Gespeichert wird je
//  Postfach und Absender nur die juengste Entscheidung.
//
//  Aufruf:  php feedback-import.php [--dry-run]
// =====================================================================
if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}

define('AI_FILTER_LIBRARY', true);
require __DIR__ . '/ai-mail-checker.php';

$dryRun = in_array('--dry-run', $argv, true);

// doveadm maskiert im Tab-Format Sonderzeichen mit \001 + Kennbuchstabe.
function feedbackUnescape($value) {
    return trim(strtr($value, ["\x01n" => ' ', "\x01r" => '', "\x01t" => ' ', "\x010" => '', "\x011" => '']));
}

// Die Adresse aus einer From-Kopfzeile. Der Anzeigename darf selbst wie
// eine Adresse aussehen ("service@paypal.com" <x@boese.example>) - es
// zaehlt die in spitzen Klammern, sonst die letzte.
function feedbackAddress($header) {
    if (preg_match_all('/<\s*([^<>\s]+@[^<>\s]+)\s*>/', $header, $m) && !empty($m[1])) {
        return strtolower(end($m[1]));
    }
    if (preg_match_all('/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/', $header, $m) && !empty($m[0])) {
        return strtolower(end($m[0]));
    }
    return '';
}

// Ausgenommene Postfaecher oder ganze Domains, eine Angabe je Zeile.
function feedbackExcluded($rcpt) {
    static $list = null;
    if ($list === null) {
        $list = [];
        $file = __DIR__ . '/feedback_exclude.txt';
        if (is_readable($file)) {
            foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
                $line = strtolower(trim(preg_replace('/#.*$/', '', $line)));
                if ($line !== '') {
                    $list[$line] = true;
                }
            }
        }
    }
    $domain = substr(strrchr($rcpt, '@') ?: '', 1);
    return isset($list[$rcpt]) || ($domain !== '' && isset($list[$domain]));
}

$found = [];      // [rcpt][sender] => ['verdict' => ..., 'ts' => ...]
$flaggedInbox = [];
$flaggedJunk = [];
$lines = 0;

while (($line = fgets(STDIN)) !== false) {
    $fields = explode("\t", rtrim($line, "\r\n"));
    if (count($fields) < 6 || $fields[1] === 'user') {
        continue;   // Kopfzeile von doveadm oder Unvollstaendiges
    }
    $lines++;
    $folder  = $fields[0];
    $rcpt    = strtolower(trim($fields[1]));
    $ts      = strtotime(feedbackUnescape($fields[2])) ?: time();
    $flagged = preg_match('/^\s*yes/i', feedbackUnescape($fields[3])) === 1
            || preg_match('/^\s*yes/i', feedbackUnescape($fields[4])) === 1;
    $from    = feedbackAddress(feedbackUnescape(implode(' ', array_slice($fields, 5))));

    if ($rcpt === '' || feedbackExcluded($rcpt)) {
        continue;
    }
    if ($flagged) {
        if ($folder === 'INBOX') {
            $flaggedInbox[$rcpt] = ($flaggedInbox[$rcpt] ?? 0) + 1;
        } else {
            $flaggedJunk[$rcpt] = ($flaggedJunk[$rcpt] ?? 0) + 1;
        }
    }

    $verdict = '';
    if ($folder === 'INBOX' && $flagged) {
        $verdict = 'rescued';
    } elseif ($folder === 'JUNK' && !$flagged) {
        $verdict = 'junked';
    }
    $sender = relationshipSenderKey($from);
    // Post von sich selbst oder aus der eigenen Domain ist kein Urteil
    // ueber einen Absender.
    if ($verdict === '' || $sender === '' || $sender === $rcpt
        || $sender === registrableDomain(substr(strrchr($rcpt, '@') ?: '', 1))) {
        continue;
    }
    if (!isset($found[$rcpt][$sender]) || $found[$rcpt][$sender]['ts'] < $ts) {
        $found[$rcpt][$sender] = ['verdict' => $verdict, 'ts' => $ts];
    }
}

// Ein Postfach, das gekennzeichnete Post gar nicht in den Junk sortiert
// (mailcow: "Spam nur markieren"), hat sie nicht GERETTET - sie lag nie
// woanders. Dort wuerde jede Spam-Mail als erwuenscht gelernt. Erkennbar
// daran, dass im Posteingang mehr Gekennzeichnetes liegt als im Junk.
$skipped = [];
foreach ($found as $rcpt => $senders) {
    $inbox = $flaggedInbox[$rcpt] ?? 0;
    if ($inbox >= 5 && $inbox > ($flaggedJunk[$rcpt] ?? 0)) {
        $skipped[] = $rcpt;
        foreach ($senders as $sender => $entry) {
            if ($entry['verdict'] === 'rescued') {
                unset($found[$rcpt][$sender]);
            }
        }
    }
}

$counts = ['rescued' => 0, 'junked' => 0];
$db = $dryRun ? null : relationshipDb();
if (!$dryRun && !$db) {
    fwrite(STDERR, "Beziehungs-Datenbank nicht verfuegbar (RELATIONSHIP_MODE=" . RELATIONSHIP_MODE . ")\n");
    exit(1);
}

if ($db) {
    $db->beginTransaction();
    $upsert = $db->prepare('INSERT INTO feedback (rcpt, sender, verdict, ts) VALUES (?, ?, ?, ?)
        ON CONFLICT(rcpt, sender) DO UPDATE SET verdict = excluded.verdict, ts = excluded.ts
        WHERE excluded.ts >= feedback.ts');
}
foreach ($found as $rcpt => $senders) {
    foreach ($senders as $sender => $entry) {
        $counts[$entry['verdict']]++;
        if ($dryRun) {
            echo $entry['verdict'], "\t", $rcpt, "\t", $sender, "\t", date('Y-m-d', $entry['ts']), "\n";
        } else {
            $upsert->execute([$rcpt, $sender, $entry['verdict'], $entry['ts']]);
        }
    }
}
if ($db) {
    // Aufraeumen: abgelaufene Entscheidungen und Absender, von denen seit
    // ueber einem Jahr nichts mehr kam.
    $db->prepare('DELETE FROM feedback WHERE ts < ?')->execute([time() - FEEDBACK_MAX_AGE_DAYS * 86400]);
    $db->prepare('DELETE FROM history WHERE last_seen < ?')->execute([time() - 400 * 86400]);
    $db->commit();
}

fwrite(STDERR, sprintf(
    "%d Mails gelesen: %d Absender zurueckgeholt, %d von Hand aussortiert%s\n",
    $lines, $counts['rescued'], $counts['junked'], $dryRun ? ' (nur Anzeige, nichts gespeichert)' : ''
));
foreach ($skipped as $rcpt) {
    fwrite(STDERR, "Uebersprungen (laesst gekennzeichnete Post im Posteingang): $rcpt\n");
}
