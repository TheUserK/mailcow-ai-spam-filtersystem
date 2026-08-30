<?php
// Prueffaelle aus echten Logdatensaetzen vom 26.-29.08. plus Kontrollfaelle.
// Wird vor und nach dem Umbau ausgefuehrt; die Ausgaben muessen identisch
// sein, ausser bei den Aenderungen, die bewusst gemacht wurden.

function fixtures() {
    $base = [
        'auth' => ['spf' => 'pass', 'dkim' => 'pass', 'dmarc' => 'pass'],
        'signals' => [],
        'content_stats' => [],
        'urls' => [],
        'attachments' => [],
        'headers' => [],
    ];

    $cases = [];

    $cases['google-praemie'] = array_replace_recursive($base, [
        'from' => 'news-noreply@google.com', 'from_email' => 'news-noreply@google.com',
        'from_display_name' => 'Google Play',
        'to' => 'andi@karrer.info',
        'subject' => 'Andreas, deine woechentliche Praemie ist da',
        'body' => 'Deine Play Points sind da. Jetzt einloesen.',
        'rspamd_score' => 0.5,
        'urls' => ['https://c.gle/abc', 'https://play.google.com/points'],
            'url_domains' => ['c.gle','support.google.com','myaccount.google.com','play.google.com'],
        'signals' => ['url_phishing' => true, 'has_list_unsubscribe' => true],
        'headers' => ['list_unsubscribe' => '<https://google.com/unsub>'],
    ]);

    $cases['ecuador-fraud'] = array_replace_recursive($base, [
        'from' => 'blanca@cu.ucsg.edu.ec', 'from_email' => 'blanca@cu.ucsg.edu.ec',
        'from_display_name' => 'Blanca',
        'to' => 'info@karrerlabs.de',
        'subject' => '', 'body' => 'Good day. I have a confidential proposal for you.',
        'rspamd_score' => 11.66,
    ]);

    $cases['kandao-newsletter'] = array_replace_recursive($base, [
        'from' => 'marketing@usa.kandaovr.com', 'from_email' => 'marketing@usa.kandaovr.com',
        'from_display_name' => 'Kandao Technology',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Firmware Update: Meeting Ultra V4.9',
        'body' => 'Improved audio routing, new language support, and bug fixes. Learn more.',
        'rspamd_score' => 7.34,
        'urls' => ['https://ctrk.klclick1.com/x', 'https://linkedin.com/company/kandao'],
            'url_domains' => ['ctrk.klclick1.com','manage.kmail-lists.com','linkedin.com','youtube.com'],
        'signals' => ['forged_sender' => true, 'from_neq_envfrom' => true, 'has_list_unsubscribe' => true],
        'headers' => ['list_unsubscribe' => '<https://manage.kmail-lists.com/u>'],
    ]);

    $cases['blutzucker-spam'] = array_replace_recursive($base, [
        'from' => 'support@arrow.onetwotee.shop', 'from_email' => 'support@arrow.onetwotee.shop',
        'from_display_name' => 'Gesundheit',
        'to' => 'info@karrerlabs.de',
        'subject' => 'Deine Gesundheit beginnt mit stabilem Blutzucker!',
        'body' => 'Jetzt lesen und profitieren.',
        'rspamd_score' => 7.53,
        'urls' => ['https://storage.googleapis.com/xy/index.html'],
            'url_domains' => ['storage.googleapis.com'],
        'signals' => ['has_list_unsubscribe' => true],
        'headers' => ['list_unsubscribe' => '<https://onetwotee.shop/u>'],
    ]);

    $cases['wagner-barelink'] = array_replace_recursive($base, [
        'from' => 'thomas.wagner83@yahoo.com', 'from_email' => 'thomas.wagner83@yahoo.com',
        'from_display_name' => 'Thomas Wagner',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Link zum Plugin',
        'body' => "Wie versprochen findest du hier den Link zum WordPress Plugin.\nhttps://neo-plugins.com/v27/neo-alt/\nViele Gruesse, Thomas Wagner",
        'rspamd_score' => -0.5,
        'urls' => ['https://neo-plugins.com/v27/neo-alt/'],
            'url_domains' => ['neo-plugins.com'],
        'signals' => ['freemail_from' => true, 'unknown_sender' => true],
    ]);

    $cases['libero-rolename'] = array_replace_recursive($base, [
        'from' => 'TeaFranchi8855@libero.it', 'from_email' => 'TeaFranchi8855@libero.it',
        'from_display_name' => 'Support Service',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Booker letter on suite requires action',
        'body' => 'Guest Experience Report. Automated Message. Dear Hotel Partner, a guest has reported an issue.',
        'rspamd_score' => 2.3,
        'signals' => ['freemail_from' => true],
    ]);

    $cases['marcablanca-injection'] = array_replace_recursive($base, [
        'from' => 'wordpress@marcablancadigital.com', 'from_email' => 'wordpress@marcablancadigital.com',
        'from_display_name' => 'Marca Blanca Digital',
        'to' => 'andi@karrer.info',
        'subject' => '[Marca Blanca Digital] Datos de acceso',
        'body' => 'Tus datos de acceso. Haz clic aqui.',
        'rspamd_score' => -1.06,
        'urls' => ['https://fsegrdxd.blogspot.ug/x', 'https://marcablancadigital.com/login'],
            'url_domains' => ['fsegrdxd.blogspot.ug','marcablancadigital.com'],
    ]);

    $cases['fake-thread-outlook'] = array_replace_recursive($base, [
        'from' => 'AvaJonesas@outlook.com', 'from_email' => 'AvaJonesas@outlook.com',
        'from_display_name' => 'Ava Jones',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Re- Neu gestalten',
        'body' => "Hallo! Ich warte noch auf Ihre Antwort.\n\nFrom: Ava Jonesa\nSent: Sunday, August 9, 2026 5:16 PM\nSubject: Re- Neu gestalten\n\nHallo, ich hoffe es geht Ihnen gut.",
        'rspamd_score' => 2.1,
        'signals' => ['freemail_from' => true, 'unknown_sender' => true],
    ]);

    $cases['saubere-geschaeftsmail'] = array_replace_recursive($base, [
        'from' => 'buchhaltung@lieferant.de', 'from_email' => 'buchhaltung@lieferant.de',
        'from_display_name' => 'Buchhaltung Lieferant GmbH',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Rechnung 2026-0815',
        'body' => 'Sehr geehrte Damen und Herren, anbei die Rechnung fuer den August. Mit freundlichen Gruessen.',
        'rspamd_score' => -1.2,
        'urls' => ['https://lieferant.de/portal'],
            'url_domains' => ['lieferant.de'],
    ]);

    $cases['echte-weiterleitung'] = array_replace_recursive($base, [
        'from' => 'kollege@partner.de', 'from_email' => 'kollege@partner.de',
        'from_display_name' => 'Max Kollege',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Fwd: Protokoll Besprechung',
        'body' => "Zur Info.\n\nVon: Anna Muster\nGesendet: Montag, 5. Mai 2026 09:12\nAn: max@partner.de\nBetreff: Protokoll",
        'rspamd_score' => 0.2,
    ]);

    // --- Pfade, die das erste Korpus NICHT abgedeckt hat -------------------
    $cases['gefaehrlicher-anhang'] = array_replace_recursive($base, [
        'from' => 'rechnung@unbekannt-gmbh.net', 'from_email' => 'rechnung@unbekannt-gmbh.net',
        'from_display_name' => 'Rechnungsstelle',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Ihre Rechnung', 'body' => 'Anbei die Rechnung.',
        'rspamd_score' => 3.0,
        'attachments' => [['name' => 'Rechnung.pdf.exe', 'size' => 12000]],
    ]);

    $cases['kurzlink'] = array_replace_recursive($base, [
        'from' => 'info@aktion.de', 'from_email' => 'info@aktion.de',
        'from_display_name' => 'Aktion',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Angebot', 'body' => 'Hier klicken: https://bit.ly/xyz',
        'rspamd_score' => 4.0,
        'urls' => ['https://bit.ly/xyz'], 'url_domains' => ['bit.ly'],
    ]);

    $cases['typosquat-paypal'] = array_replace_recursive($base, [
        'from' => 'service@paypa1-sicherheit.com', 'from_email' => 'service@paypa1-sicherheit.com',
        'from_display_name' => 'PayPal Service',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Ihr PayPal Konto wurde eingeschraenkt',
        'body' => 'Bitte bestaetigen Sie Ihre Daten.',
        'rspamd_score' => 5.0,
        'auth' => ['spf' => 'fail', 'dkim' => 'none', 'dmarc' => 'fail'],
        'urls' => ['https://paypa1-sicherheit.com/login'], 'url_domains' => ['paypa1-sicherheit.com'],
    ]);

    $cases['gekapertes-unikonto'] = array_replace_recursive($base, [
        'from' => 'prof@uni-beispiel.edu', 'from_email' => 'prof@uni-beispiel.edu',
        'from_display_name' => 'Prof. Beispiel',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Confidential', 'body' => 'I need your urgent assistance with a transfer.',
        'rspamd_score' => 3.5,
        'reply_to' => 'collector999@gmail.com',
        'signals' => ['freemail_reply_to' => true, 'suspicious_reply_to' => true],
    ]);

    $cases['newsletter-mit-abo'] = array_replace_recursive($base, [
        'from' => 'newsletter@tchibo.de', 'from_email' => 'newsletter@tchibo.de',
        'from_display_name' => 'Tchibo',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Diese Woche bei Tchibo',
        'body' => 'Sie erhalten diese Mail, weil Sie sich angemeldet haben.',
        'rspamd_score' => 0.4,
        'urls' => ['https://tchibo.de/aktion'], 'url_domains' => ['tchibo.de'],
        'signals' => ['has_list_unsubscribe' => true],
        'headers' => ['list_unsubscribe' => '<https://tchibo.de/u>', 'list_id' => 'tchibo'],
    ]);

    $cases['google-groups-mit-boesem-link'] = array_replace_recursive($base, [
        'from' => 'noreply@google.com', 'from_email' => 'noreply@google.com',
        'from_display_name' => 'Google Groups',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Neue Nachricht in der Gruppe',
        'body' => 'Ein Mitglied hat geschrieben. Siehe Link.',
        'rspamd_score' => 1.0,
        'urls' => ['https://boese-domain.tk/x'],
        'url_domains' => ['groups.google.com', 'boese-domain.tk'],
        'signals' => ['url_blacklisted' => true],
    ]);

    // Gefaelschter Thread-Header: Angreifer setzt In-Reply-To selbst.
    $cases['phishing-mit-erfundenem-thread'] = array_replace_recursive($base, [
        'from' => 'service@wntppcagency.com', 'from_email' => 'service@wntppcagency.com',
        'from_display_name' => 'onPhase Support',
        'to' => 'info@karrerlabs.de',
        'subject' => 'Case #00216349 - Your Feedback Is Important To Us was created',
        'body' => 'A case was created for you. Please review.',
        'rspamd_score' => 9.0,
        'in_reply_to' => '<abc123@wntppcagency.com>',
        'urls' => ['https://onphase.my.salesforce.com/x'],
        'url_domains' => ['onphase.my.salesforce.com'],
        'signals' => ['url_blacklisted' => true, 'suspicious_reply_to' => true],
    ]);

    // Echte Antwort auf unsere eigene Post - muss geschuetzt bleiben.
    $cases['echte-antwort-auf-uns'] = array_replace_recursive($base, [
        'from' => 'kunde@partner.de', 'from_email' => 'kunde@partner.de',
        'from_display_name' => 'Kunde',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Re: Angebot 2026-08',
        'body' => 'Danke, passt so. Bitte um Rechnung.',
        'rspamd_score' => 8.0,
        'in_reply_to' => '<xyz@moving-pictures.de>',
        'signals' => ['reply_to_our_mail' => true, 'url_blacklisted' => true],
    ]);

    // Kaltakquise: Rollenanspruch steht im Text, nicht im Anzeigenamen.
    $cases['sytx-rolle-im-text'] = array_replace_recursive($base, [
        'from' => 'svitlanavilchinska@gmail.com', 'from_email' => 'svitlanavilchinska@gmail.com',
        'from_display_name' => 'Svitlana Vilchynska',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Syt-X - High-Fidelity 3D & Motion Production Support',
        'body' => 'To the Moving Pictures Team, I am reaching out to introduce Syt-X. My name is Svitlana Vilchynska, Art Manager at Syt-X. We act as a production extension for creative teams.',
        'rspamd_score' => 3.0,
        'signals' => ['freemail_from' => true, 'unknown_sender' => true],
    ]);

    // Erfundene Vorgangsnummer ohne nachweisbaren Thread.
    $cases['erfundenes-ticket'] = array_replace_recursive($base, [
        'from' => 'service@wntppcagency.com', 'from_email' => 'service@wntppcagency.com',
        'from_display_name' => 'onPhase',
        'to' => 'info@karrerlabs.de',
        'subject' => 'Case #00216349 - Your Feedback Is Important To Us was created',
        'body' => 'A case has been created for you.',
        'rspamd_score' => 9.0,
        'in_reply_to' => '<abc@wntppcagency.com>',
        'url_domains' => ['onphase.my.salesforce.com'],
        'signals' => ['url_blacklisted' => true],
    ]);

    // Echtes Ticketsystem, das auf unsere eigene Mail antwortet.
    $cases['echtes-ticket-auf-uns'] = array_replace_recursive($base, [
        'from' => 'support@dienstleister.de', 'from_email' => 'support@dienstleister.de',
        'from_display_name' => 'Support',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Ticket #44821 wurde erstellt',
        'body' => 'Ihre Anfrage wurde aufgenommen.',
        'rspamd_score' => 1.0,
        'signals' => ['reply_to_our_mail' => true],
    ]);

    // Blocklisten-Treffer nur auf der eigenen, DMARC-sauberen Domain.
    $cases['blocklist-eigene-domain'] = array_replace_recursive($base, [
        'from' => 'news@shop-mit-ruf.de', 'from_email' => 'news@shop-mit-ruf.de',
        'from_display_name' => 'Shop',
        'to' => 'info@moving-pictures.de',
        'subject' => 'Angebote der Woche',
        'body' => 'Unsere Angebote.',
        'rspamd_score' => 2.0,
        'url_domains' => ['shop-mit-ruf.de', 'www.shop-mit-ruf.de'],
        'signals' => ['url_blacklisted' => true],
    ]);

    return $cases;
}

function runFixtures() {
    $out = [];
    foreach (fixtures() as $name => $data) {
        $mail  = prepareMailContext($data);
        $local = analyzeLocally($mail, 'test');
        $ev    = collectStructuralEvidence($mail, $local, ['claimed_brand' => '']);

        $scores = [];
        foreach ([['spam', 0.85, 0.90], ['phishing', 0.95, 0.92], ['marketing', 0.20, 0.80],
                  ['newsletter', 0.15, 0.90], ['legitimate', 0.05, 0.95], ['personal', 0.10, 0.90]] as $s) {
            $scores[$s[0]] = scoreFromAi($s[1], $s[2], $s[0]);
        }

        $out[$name] = [
            'auth_strength'  => $local['auth_strength'] ?? '',
            'verified_brand' => $local['verified_brand'] ?? '',
            'impersonation'  => $local['impersonation_score'] ?? 0,
            'handled'        => !empty($local['handled']),
            'risk_flags'     => $local['risk_flags'] ?? [],
            'trust_flags'    => $local['trust_flags'] ?? [],
            'evidence'       => $ev,
            'strong'         => strongEvidence($ev),
            // Entscheidet mit ueber die Ablehnung: ein nachweisbarer
            // Austausch schuetzt, ein selbst geschriebener Header nicht.
            'echter_thread'  => partOfRealConversation($mail),
            'scoreFromAi'    => $scores,
        ];
    }
    return $out;
}

echo json_encode(runFixtures(), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";
