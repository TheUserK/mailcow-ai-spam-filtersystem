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
//  davor der Ordner. Welche Spalte was ist, steht in doveadms Kopfzeile
//  und wird von dort gelesen, nicht abgezaehlt: Mit -A stellt doveadm
//  eine Spalte "username" voran, die niemand angefordert hat - bis 12.11.
//  verrutschte dadurch alles um eins, und als Datum galt immer "heute".
//
//  Daraus:
//    INBOX + Spam-Kennzeichen   -> "rescued"  (aus dem Junk zurueckgeholt)
//    INBOX ohne Kennzeichen, aber vom Checker als Junk/Reject vermerkt
//                               -> "rescued"  (aus der Quarantaene
//                                  freigegeben - siehe recordFlagged())
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

// Spaltenname -> Position, aus der Kopfzeile. Vorgabe fuer den Fall,
// dass keine kommt: die angeforderte Reihenfolge mit vorangestelltem
// "username".
$columns = ['username' => 1, 'user' => 2, 'date.saved' => 3,
            'hdr.x-spam-flag' => 4, 'hdr.x-spam' => 5, 'hdr.message-id' => 6, 'hdr.from' => 7];

// Fuer die Quarantaene-Erkennung wird die Datenbank auch im Probelauf
// gelesen - geschrieben wird dort nichts.
$lookupDb = relationshipDb();
$flaggedLookup = $lookupDb
    ? $lookupDb->prepare('SELECT ts FROM flagged WHERE rcpt = ? AND mid = ? AND sender = ?')
    : null;
$releases = [];   // [rcpt][sender] => ts
$column = function (array $fields, $name) use (&$columns) {
    return isset($columns[$name], $fields[$columns[$name]]) ? $fields[$columns[$name]] : '';
};

$found = [];      // [rcpt][sender] => ['verdict' => ..., 'ts' => ...]
$flaggedInbox = [];
$flaggedJunk = [];
$lines = 0;
$undated = 0;

while (($line = fgets(STDIN)) !== false) {
    $fields = explode("\t", rtrim($line, "\r\n"));
    if (in_array('hdr.from', $fields, true) && in_array('date.saved', $fields, true)) {
        // Kopfzeile von doveadm: Spalten neu zuordnen.
        $columns = array_flip($fields);
        continue;
    }
    if (count($fields) < 4) {
        continue;
    }
    $lines++;
    $folder  = $fields[0];
    $rcpt    = strtolower(trim($column($fields, 'username') ?: $column($fields, 'user')));
    $saved   = strtotime(feedbackUnescape($column($fields, 'date.saved')));
    if ($saved === false) {
        $undated++;
    }
    $ts      = $saved ?: time();
    $flagged = preg_match('/^\s*yes/i', feedbackUnescape($column($fields, 'hdr.x-spam-flag'))) === 1
            || preg_match('/^\s*yes/i', feedbackUnescape($column($fields, 'hdr.x-spam'))) === 1;
    $from    = feedbackAddress(feedbackUnescape($column($fields, 'hdr.from')));

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
    $sender = relationshipSenderKey($from);
    if ($folder === 'INBOX' && $flagged) {
        $verdict = 'rescued';
    } elseif ($folder === 'JUNK' && !$flagged) {
        $verdict = 'junked';
    } elseif ($folder === 'INBOX' && $flaggedLookup && $sender !== '') {
        // Ohne Kennzeichen im Posteingang, obwohl der Checker genau diese
        // Mail in Junk oder Ablehnung geschoben hatte: freigegeben.
        $mid = messageIdHash(feedbackUnescape($column($fields, 'hdr.message-id')));
        if ($mid !== '') {
            try {
                $flaggedLookup->execute([$rcpt, $mid, $sender]);
                if ($flaggedLookup->fetchColumn() !== false) {
                    $verdict = 'rescued';
                    $releases[$rcpt][$sender] = $ts;
                }
            } catch (Exception $e) {
                // Ohne Abgleich bleibt es bei "kein Urteil".
            }
        }
    }
    // Post von sich selbst oder aus der eigenen Domain ist kein Urteil
    // ueber einen Absender.
    if ($verdict === '' || $sender === '' || $sender === $rcpt
        || $sender === registrableDomain(substr(strrchr($rcpt, '@') ?: '', 1))) {
        continue;
    }
    if (!isset($found[$rcpt][$sender]) || $found[$rcpt][$sender]['ts'] < $ts) {
        $found[$rcpt][$sender] = ['verdict' => $verdict, 'ts' => $ts,
            'released' => isset($releases[$rcpt][$sender]) && $releases[$rcpt][$sender] === $ts];
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
            // Eine Freigabe aus der Quarantaene bleibt gueltig: Die haengt
            // nicht am Kennzeichen, das dieses Postfach liegen laesst.
            if ($entry['verdict'] === 'rescued' && empty($entry['released'])) {
                unset($found[$rcpt][$sender]);
            }
        }
    }
}

$counts = ['rescued' => 0, 'junked' => 0, 'released' => 0];
$db = $dryRun ? null : relationshipDb();
if (!$dryRun && !$db) {
    fwrite(STDERR, "Beziehungs-Datenbank nicht verfuegbar (RELATIONSHIP_MODE=" . RELATIONSHIP_MODE . ")\n");
    exit(1);
}

$isNew = null;
if ($db) {
    $db->beginTransaction();
    // Fuer die Wochenbilanz: Nur eine NEUE oder geaenderte Entscheidung
    // zaehlt als Korrektur - dieselbe Mail liegt 14 Tage lang im Fenster
    // und wuerde sonst jede Nacht erneut gezaehlt.
    $known = $db->prepare('SELECT verdict FROM feedback WHERE rcpt = ? AND sender = ?');
    $isNew = function ($rcpt, $sender, $verdict) use ($known) {
        $known->execute([$rcpt, $sender]);
        return $known->fetchColumn() !== $verdict;
    };
    $countCorrection = $db->prepare('INSERT INTO corrections (day, kind, n) VALUES (?, ?, 1)
        ON CONFLICT(day, kind) DO UPDATE SET n = n + 1');
    $upsert = $db->prepare('INSERT INTO feedback (rcpt, sender, verdict, ts) VALUES (?, ?, ?, ?)
        ON CONFLICT(rcpt, sender) DO UPDATE SET verdict = excluded.verdict, ts = excluded.ts
        WHERE excluded.ts >= feedback.ts');
}
foreach ($found as $rcpt => $senders) {
    foreach ($senders as $sender => $entry) {
        $counts[$entry['verdict']]++;
        if (!empty($entry['released'])) {
            $counts['released']++;
        }
        if ($dryRun) {
            echo $entry['verdict'], "\t", $rcpt, "\t", $sender, "\t", date('Y-m-d', $entry['ts']),
                !empty($entry['released']) ? "\taus Quarantaene freigegeben" : '', "\n";
        } else {
            if ($isNew($rcpt, $sender, $entry['verdict'])) {
                $countCorrection->execute([date('Y-m-d'),
                    !empty($entry['released']) ? 'released' : $entry['verdict']]);
            }
            $upsert->execute([$rcpt, $sender, $entry['verdict'], $entry['ts']]);
            if (!empty($entry['released'])) {
                $db->prepare('INSERT OR IGNORE INTO released (rcpt, sender, ts, noted) VALUES (?, ?, ?, ?)')
                   ->execute([$rcpt, $sender, $entry['ts'], time()]);
            }
        }
    }
}
if ($db) {
    // Aufraeumen: abgelaufene Entscheidungen und Absender, von denen seit
    // ueber einem Jahr nichts mehr kam.
    $db->prepare('DELETE FROM feedback WHERE ts < ?')->execute([time() - FEEDBACK_MAX_AGE_DAYS * 86400]);
    $db->prepare('DELETE FROM history WHERE last_seen < ?')->execute([time() - 400 * 86400]);
    // Quarantaene haelt mailcow 30 Tage vor - laenger braucht es die
    // Fingerabdruecke nicht.
    $db->prepare('DELETE FROM flagged WHERE ts < ?')->execute([time() - 45 * 86400]);
    $db->prepare('DELETE FROM campaign WHERE ts < ?')->execute([time() - 7 * 86400]);
    $db->prepare('DELETE FROM volume WHERE day < ?')->execute([date('Y-m-d', time() - 400 * 86400)]);
    $db->prepare('DELETE FROM corrections WHERE day < ?')->execute([date('Y-m-d', time() - 400 * 86400)]);
    $db->prepare('DELETE FROM released WHERE noted < ?')->execute([time() - FEEDBACK_MAX_AGE_DAYS * 86400]);
    $db->commit();
}

fwrite(STDERR, sprintf(
    "%d Mails gelesen: %d Absender zurueckgeholt (davon %d aus der Quarantaene freigegeben), %d von Hand aussortiert%s\n",
    $lines, $counts['rescued'], $counts['released'], $counts['junked'], $dryRun ? ' (nur Anzeige, nichts gespeichert)' : ''
));
if ($undated > 0) {
    fwrite(STDERR, "Hinweis: bei $undated Mails war das Ablagedatum nicht lesbar - dort gilt der heutige Tag\n");
}
foreach ($skipped as $rcpt) {
    fwrite(STDERR, "Uebersprungen (laesst gekennzeichnete Post im Posteingang): $rcpt\n");
}
