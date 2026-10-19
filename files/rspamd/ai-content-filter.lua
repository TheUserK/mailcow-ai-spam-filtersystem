-- === AI Content Filter for Mailcow ===
-- GitHub: https://github.com/TheUserK/mailcow-ai-spam-filtersystem
-- MIT License
--
-- Talks to ai-mail-checker.php (additive, low-false-positive engine).
-- The checker sets no action itself - it only returns a graduated, signed
-- score (positive = spam/phishing, negative = ham) that gets added straight
-- into Rspamd's own metric, and Rspamd's action thresholds decide from the
-- resulting total. That describes the mechanism, not the outcome: for
-- unsolicited bulk the returned score may deliberately be large enough to
-- cross the reject threshold.

local rspamd_logger = require "rspamd_logger"
local rspamd_http = require "rspamd_http"
local ucl = require "ucl"

-- Load settings.
--
-- Die Datei gehoert dem Betreiber - install.sh legt sie nur an, wenn sie
-- fehlt. Deshalb kann sie aelter sein als dieses Skript und Schluessel
-- nicht kennen, die spaeter dazugekommen sind. Fruehere Fassungen zogen
-- die Vorgaben nur, wenn die Datei GANZ fehlschlug; ein einzelner
-- fehlender Schluessel blieb nil und landete so in der HTTP-Anfrage.
-- Darum jetzt: Vorgaben immer definieren, Datei darueberlegen.
local defaults = {
  checker_url = 'http://ai-checker:8080/ai-mail-checker.php',
  skip_score_above = 15.0,
  skip_score_below = -10.0,
  http_timeout = 22.0,   -- muss unter Rspamds task_timeout (25s) bleiben
  log_only_mode = false,
  whitelist_domains = {},
  whitelist_senders = {},
}

local settings_path = '/etc/rspamd/lua/ai-filter-settings.lua'
local settings_chunk = loadfile(settings_path)
if settings_chunk then
  settings_chunk()
else
  rspamd_logger.errx(rspamd_config, 'AI Filter: Cannot load settings from %s, using defaults', settings_path)
end

if type(ai_filter_settings) ~= 'table' then
  ai_filter_settings = {}
end

for key, value in pairs(defaults) do
  if ai_filter_settings[key] == nil then
    ai_filter_settings[key] = value
    rspamd_logger.infox(rspamd_config, 'AI Filter: %s not set in settings, using default', key)
  end
end

local cfg = ai_filter_settings

-- Well-known freemail providers. Used only as a soft context signal for the
-- AI/local-precheck (e.g. a freemail sender claiming to be a company is more
-- suspicious) - never a decision on its own.
local freemail_domains = {
  ['gmail.com'] = true, ['googlemail.com'] = true,
  ['gmx.de'] = true, ['gmx.net'] = true, ['gmx.at'] = true, ['gmx.ch'] = true,
  ['web.de'] = true, ['t-online.de'] = true,
  ['outlook.com'] = true, ['outlook.de'] = true, ['hotmail.com'] = true, ['live.com'] = true,
  ['yahoo.com'] = true, ['yahoo.de'] = true,
  ['icloud.com'] = true, ['me.com'] = true, ['aol.com'] = true,
  ['mail.com'] = true, ['protonmail.com'] = true, ['proton.me'] = true,
}

-- Returns 'pass' / 'fail' / 'unknown' based on which Rspamd auth symbols
-- already fired for this task (SPF/DKIM/DMARC checks run earlier in the
-- pipeline than this postfilter).
local function auth_status(task, allow_symbols, fail_symbols)
  for _, sym in ipairs(allow_symbols) do
    if task:get_symbol(sym) then
      return 'pass'
    end
  end
  for _, sym in ipairs(fail_symbols) do
    if task:get_symbol(sym) then
      return 'fail'
    end
  end
  return 'unknown'
end

-- Summe der Abzuege aus GELERNTEN Ham-Symbolen (Bayes, Fuzzy, Neural).
-- Die stammen aus Benutzeraktionen - wer eine Mail aus dem Junk zurueck
-- in den Posteingang schiebt, trainiert sie als Ham. Am 16.10. kam so eine
-- Anwaltsnetzwerk-Werbung bei -11.75 an: BAYES_HAM -5.50 plus
-- LOCAL_FUZZY_WHITE -4.34, offenbar nach einer frueher "geretteten"
-- aehnlichen Mail. Ohne diese beiden waeren es -1.9 gewesen.
local learned_ham_symbols = {
  'BAYES_HAM', 'LOCAL_FUZZY_WHITE', 'FUZZY_WHITE',
  'NEURAL_HAM', 'NEURAL_HAM_LONG', 'NEURAL_HAM_SHORT',
}
local function learned_ham_points(task)
  local sum = 0.0
  for _, sym in ipairs(learned_ham_symbols) do
    local res = task:get_symbol(sym)
    for _, r in ipairs(res or {}) do
      local s = tonumber(r.score) or 0.0
      if s < 0 then
        sum = sum + s
      end
    end
  end
  return sum
end

-- True as soon as any one of the given symbols fired for this task.
local function any_symbol(task, symbols)
  for _, sym in ipairs(symbols) do
    if task:get_symbol(sym) then
      return true
    end
  end
  return false
end

-- Rspamd already queries Spamhaus DBL, SURBL, URIBL, OpenPhish and PhishTank
-- for every mail. Those results were being thrown away here - we just pass
-- them on as context so the checker and the AI can combine them with the
-- sender-side signals. No extra lookups, no new dependency.

-- Link domain is on a blocklist as outright malicious.
local uribl_bad_symbols = {
  'URIBL_BLACK', 'URIBL_RED',
  'SURBL_MULTI', 'MW_SURBL_MULTI', 'PH_SURBL_MULTI',
  'ABUSE_SURBL', 'CRACKED_SURBL',
  'DBL_SPAM', 'DBL_PHISH', 'DBL_MALWARE', 'DBL_BOTNET',
  'DBL_ABUSE', 'DBL_ABUSE_PHISH', 'DBL_ABUSE_MALWARE', 'DBL_ABUSE_BOTNET',
  'RSPAMD_URIBL', 'SEM_URIBL', 'SEM_URIBL_UNKNOWN',
  'RBL_INTERSERVER_URI', 'RBL_INTERSERVER_BAD_URI',
}

-- Weaker listings - suspicious, not a verdict.
local uribl_suspect_symbols = {
  'URIBL_GREY', 'DBL_ABUSE_REDIR',
}

-- Domain first seen within the last ~15 days. On its own this means little
-- (every legitimate domain is new once), but combined with a claimed brand
-- or a payment request it is a strong phishing signal.
local fresh_domain_symbols = {
  'SEM_URIBL_FRESH15', 'SEM_URIBL_FRESH15_UNKNOWN',
}

-- Phishing-Feeds: die URL steht auf OpenPhish/PhishTank oder traegt das
-- Muster gekaperter WordPress-Seiten.
--
-- Rspamds "PHISHING" (Linktext zeigt eine andere Domain als das Linkziel)
-- stand bis 14.10. ebenfalls hier und wurde damit zum Blocklisten-Treffer.
-- Am 12.10. wies das eine echte Seminar-Einladung einer Rechtsanwaltskammer
-- ab: Linktext mit der eigenen Kurzdomain, Ziel die eigene Langdomain -
-- "PHISHING(rak-m.de->rak-muenchen.de)". Jetzt getrennt uebergeben, mit den
-- Domain-Paaren; der Checker entscheidet, ob es zaehlt.
local phishing_symbols = {
  'PHISHED_OPENPHISH', 'PHISHED_PHISHTANK', 'HACKED_WP_PHISHING',
}

-- Die Domain-Paare aus Rspamds PHISHING, z.B. "text.de->ziel.de".
local function link_text_mismatches(task)
  local pairs_out = {}
  local res = task:get_symbol('PHISHING')
  if not res then
    return false, pairs_out
  end
  for _, r in ipairs(res) do
    for _, opt in ipairs(r.options or {}) do
      table.insert(pairs_out, tostring(opt))
    end
  end
  return true, pairs_out
end

-- Die ABSENDERADRESSE selbst steht auf einer Blockliste bekannter
-- Spamversender. Am 15.09. kam Kaltakquise von einer outlook.com-Adresse,
-- die bei MSBL mit 7.50 gelistet war - adressgenau, mit Treffer sowohl auf
-- from_mime als auch auf from_smtp. Wir haben bis dahin ausschliesslich
-- URL-Blocklisten ausgewertet, also genau die Quelle ignoriert, die bei
-- Freemail als einzige etwas aussagt: Die Domain ist outlook.com, daraus
-- folgt nichts, aus der Adresse sehr wohl.
--
-- Bewusst NUR adressgenaue Listen. Keine IP-RBLs: Bei Gmail, Outlook und
-- jedem grossen Versanddienstleister teilen sich Millionen Absender
-- dieselben IPs, ein Treffer dort sagt ueber diese eine Mail nichts.
local sender_blocklist_symbols = {
  'MSBL_EBL', 'RBL_MSBL_EBL',
}

-- Nur die Listen, die ausdruecklich Phishing oder Schadcode fuehren.
-- Bewusst getrennt von uribl_bad_symbols: DBL_SPAM oder URIBL_BLACK
-- treffen auch mal die Werbedomain eines echten Lieferanten. Fuer einen
-- Absender auf der Whitelist hebt nur DIESE Sorte Treffer die Zustellung
-- allein auf - siehe whitelistAbuse() im Checker.
local malicious_url_symbols = {
  'DBL_PHISH', 'DBL_MALWARE', 'DBL_BOTNET',
  'DBL_ABUSE_PHISH', 'DBL_ABUSE_MALWARE', 'DBL_ABUSE_BOTNET',
  'PH_SURBL_MULTI', 'MW_SURBL_MULTI',
  'PHISHED_OPENPHISH', 'PHISHED_PHISHTANK',
}

local virus_symbols = {
  'CLAM_VIRUS',
}

-- =====================================================================
--  Eigene Whitelist (ai-filter-whitelist.sh)
--
--  Anders als die Mailcow-Whitelist ist das kein Freibrief: Eine Mail von
--  einem eingetragenen Absender wird zugestellt - egal was Rspamd oder die
--  KI vom Inhalt halten -, AUSSER es gibt starke Hinweise, dass das Konto
--  missbraucht wird. Ein gekapertes Lieferantenpostfach, das ploetzlich
--  "neue Bankverbindung" schreibt, ist genau der Fall, den eine starre
--  Whitelist durchwinkt.
--
--  Zwei Bedingungen, damit ein Eintrag ueberhaupt greift:
--    1. Der sichtbare Absender (From-Kopfzeile) passt zum Eintrag.
--    2. Der Absender ist fuer genau diese Domain authentifiziert. Sonst
--       koennte jeder "From: lieferant.de" hineinschreiben.
--
--  Die Datei wird alle 60 s neu gelesen - kein Rspamd-Neustart noetig.
-- =====================================================================
local whitelist_path = '/etc/rspamd/lua/ai-filter-whitelist.map'
local whitelist_ttl = 60
local whitelist_cache = { loaded_at = nil, domains = {}, addresses = {}, count = 0 }

local function load_whitelist()
  local now = os.time()
  if whitelist_cache.loaded_at and now - whitelist_cache.loaded_at < whitelist_ttl then
    return whitelist_cache
  end

  local domains, addresses, count = {}, {}, 0
  local f = io.open(whitelist_path, 'r')
  if f then
    for line in f:lines() do
      local entry = (line:gsub('#.*$', '')):match('^%s*(%S+)')
      if entry then
        entry = entry:lower()
        if entry:find('@', 1, true) then
          addresses[entry] = true
        else
          domains[entry] = true
        end
        count = count + 1
      end
    end
    f:close()
  end

  whitelist_cache = { loaded_at = now, domains = domains, addresses = addresses, count = count }
  return whitelist_cache
end

-- Eintrag "lieferant.de" gilt auch fuer mail.lieferant.de, ein Eintrag mit
-- @ nur fuer genau diese Adresse.
local function whitelist_entry_for(addr, domain)
  local wl = load_whitelist()
  if wl.count == 0 then
    return nil
  end
  addr, domain = addr:lower(), domain:lower()
  if addr ~= '' and wl.addresses[addr] then
    return addr, 'address'
  end
  local d = domain
  while d and d ~= '' do
    if wl.domains[d] then
      return d, 'domain'
    end
    d = d:match('^[^.]+%.(.+)$')
  end
  return nil
end

-- Gleiche Domain oder eine Subdomain der anderen. Strenger als DMARCs
-- "relaxed alignment" (Geschwister-Subdomains zaehlen hier nicht) - fuer
-- eine Zustellgarantie lieber zu streng als zu grosszuegig.
local function domains_aligned(a, b)
  a, b = a:lower(), b:lower()
  if a == '' or b == '' then
    return false
  end
  return a == b
    or a:sub(-(#b + 1)) == '.' .. b
    or b:sub(-(#a + 1)) == '.' .. a
end

-- Ist der sichtbare Absender wirklich der, der er vorgibt zu sein?
-- DMARC entscheidet, wo die Domain eine Policy hat. Ohne Policy (bei
-- kleinen Firmen haeufig) pruefen wir selbst: DKIM-Signatur oder SPF fuer
-- eine Domain, die zur From-Domain passt.
local function sender_authenticated(task, from_domain, smtp_domain)
  if from_domain == '' then
    return false, 'no-from'
  end
  if task:get_symbol('DMARC_POLICY_ALLOW') then
    return true, 'dmarc'
  end
  if any_symbol(task, { 'DMARC_POLICY_REJECT', 'DMARC_POLICY_QUARANTINE', 'DMARC_POLICY_SOFTFAIL' }) then
    return false, 'dmarc-fail'
  end

  local dkim = task:get_symbol('R_DKIM_ALLOW')
  if dkim then
    for _, res in ipairs(dkim) do
      for _, opt in ipairs(res.options or {}) do
        local signer = tostring(opt):match('^([^:]+)')
        if signer and domains_aligned(signer, from_domain) then
          return true, 'dkim'
        end
      end
    end
  end

  if task:get_symbol('R_SPF_ALLOW') and domains_aligned(smtp_domain, from_domain) then
    return true, 'spf'
  end

  return false, 'unauthenticated'
end

-- Was Rspamd selbst schon sicher weiss, ganz ohne Checker: Virus oder ein
-- Link auf einer Phishing-/Malware-Liste. Reicht auch dann, wenn der
-- Checker nicht antwortet.
local function whitelist_local_abuse(task)
  local reasons = {}
  if any_symbol(task, virus_symbols) then
    table.insert(reasons, 'virus')
  end
  if any_symbol(task, malicious_url_symbols) then
    table.insert(reasons, 'malicious-url')
  end
  return reasons
end

-- Zustellen: Aktion "no action" erzwingen. Damit greift weder Junk noch
-- Greylisting noch Reject, auch nicht Rspamds eigener Score oder eine
-- niedrigere Schwelle, die ein Postfach fuer sich eingestellt hat.
-- Hat ein anderes Modul (Virenscanner, Ratelimit) schon eine Aktion
-- festgelegt, bleibt die stehen.
local function whitelist_deliver(task, wl)
  if task:has_pre_result() then
    rspamd_logger.infox(task, 'AI Filter: whitelist %s matched, but another module already set the action - left alone',
      wl.entry)
    return
  end
  if cfg.log_only_mode then
    rspamd_logger.infox(task, 'AI Filter: LOG-ONLY mode, whitelist %s would have forced delivery', wl.entry)
    return
  end
  task:insert_result('AI_WHITELIST', 1.0, wl.entry)
  task:set_pre_result('no action', 'AI whitelist: ' .. wl.entry, 'ai_filter')
  rspamd_logger.infox(task, 'AI Filter: whitelist %s (%s) - delivery forced', wl.entry, wl.auth_via)
end

local function header_str(task, name)
  local h = task:get_header(name)
  if h then
    return tostring(h)
  end
  return ''
end

-- =====================================================================
--  Punktaufschlag fuer Absender auf Wegwerf-Topleveldomains
--
--  Bewusst KEIN Block und kein Reject: 2.5 Punkte reichen allein weder fuer
--  den Junk-Ordner noch fuer eine Ablehnung. Der Aufschlag wirkt nur
--  zusammen mit dem, was Rspamd und die KI ohnehin schon sehen. Auf diesen
--  Endungen gibt es echte Firmen - sie sollen Post schicken koennen, nur
--  eben nicht mit demselben Vertrauensvorschuss wie eine .de-Adresse.
--
--  Bis 11.10. war das eine Multimap-Regel, angehaengt an mailcows eigene
--  local.d/multimap.conf, mit map = "$CONFDIR/ai-filter-tlds.map". Zwei
--  Fehler auf einmal: mailcow haengt nur Unterordner von data/conf/rspamd
--  nach /etc/rspamd, die Map lag aber im Wurzelordner - Rspamd meldete
--  "map file is not found", die Regel hat nie gegriffen. Und die
--  multimap.conf gehoert zu mailcows Repository: Jede Aenderung dort
--  schleppt update.sh als lokalen Commit mit, und sobald upstream dieselbe
--  Datei aendert, bricht das Update mit einem Merge-Konflikt ab.
--
--  Jetzt hier im eigenen Modul (plugins.d, von mailcow nicht getrackt), die
--  Liste in custom/ (gemountet nach /etc/rspamd/custom). Gilt fuer die
--  Absenderdomain, nicht fuer verlinkte Domains: Ein Link auf eine
--  .shop-Seite ist in einem Newsletter voellig normal.
--
--  Liste: data/conf/rspamd/custom/ai-filter-tlds.map, wird alle 60 s neu
--  gelesen. Gewicht: "AI_FILTER_FISHY_TLD" in local.d/groups.conf.
-- =====================================================================
local fishy_tld_path = '/etc/rspamd/custom/ai-filter-tlds.map'
local fishy_tld_cache = { loaded_at = nil, tlds = {} }

local function load_fishy_tlds()
  local now = os.time()
  if fishy_tld_cache.loaded_at and now - fishy_tld_cache.loaded_at < 60 then
    return fishy_tld_cache.tlds
  end
  local tlds = {}
  local f = io.open(fishy_tld_path, 'r')
  if f then
    for line in f:lines() do
      local tld = (line:gsub('#.*$', '')):match('^%s*%.?(%S+)')
      if tld then
        tlds[tld:lower()] = true
      end
    end
    f:close()
  elseif not fishy_tld_cache.loaded_at then
    rspamd_logger.warnx(rspamd_config, 'AI Filter: %s not found - fishy-TLD scoring inactive', fishy_tld_path)
  end
  fishy_tld_cache = { loaded_at = now, tlds = tlds }
  return tlds
end

rspamd_config:register_symbol({
  name = 'AI_FILTER_FISHY_TLD',
  type = 'normal',
  callback = function(task)
    -- Ausgehende Post der eigenen Nutzer bekommt keinen Aufschlag.
    if task:get_user() then
      return false
    end
    local domain = ''
    local from = task:get_from('smtp')
    if from and from[1] and from[1].domain then
      domain = from[1].domain
    end
    if domain == '' then
      local mime = task:get_from('mime')
      if mime and mime[1] and mime[1].domain then
        domain = mime[1].domain
      end
    end
    local tld = domain:lower():match('%.([^.]+)$')
    if tld and load_fishy_tlds()[tld] then
      task:insert_result('AI_FILTER_FISHY_TLD', 1.0, tld)
      return true
    end
    return false
  end,
})

rspamd_config:register_symbol({
  name = 'AI_CONTENT_FILTER',
  type = 'postfilter',
  callback = function(task)
    local score = task:get_metric_score('default')[1]

    -- Skip localhost
    local from = task:get_from('smtp')
    if from and from[1] and from[1].domain == 'localhost' then
      return false
    end

    -- Skip outbound mail from our own authenticated users.
    -- Rspamd in mailcow also sees everything our users SEND. Analysing that
    -- would ship the body of our own users' outgoing mail to the AI provider,
    -- which is a very different thing from filtering inbound spam - both
    -- privacy-wise and cost-wise. Not our job here.
    if task:get_user() then
      return false
    end

    -- Skip mail our own sieve forwarding is re-delivering. We already
    -- analysed it on the way in, and we did it better: forwarding rewrites
    -- the envelope sender and breaks SPF/DKIM, so on the second pass a
    -- legitimate mail looks exactly like a forgery - From still claims the
    -- original sender while the envelope and the authentication no longer
    -- back that up. Re-analysing costs a second API call to reach a worse
    -- verdict on the same message.
    --
    -- Deliberately not keyed on FORWARDED: that also fires for mail an
    -- external forwarder sends us, which we have never seen and do want to
    -- check. SIEVE_HOST and LOCAL_OUTBOUND mark our own re-delivery.
    if task:get_symbol('SIEVE_HOST') or task:get_symbol('LOCAL_OUTBOUND') then
      rspamd_logger.infox(task, 'AI Filter: locally forwarded mail, already analysed on ingress - skipping')
      return false
    end

    -- Sender addresses (envelope + header), with domains as parsed by Rspamd
    local from_smtp = task:get_from('smtp')
    local from_mime = task:get_from('mime')

    local from_smtp_addr, from_smtp_domain = '', ''
    if from_smtp and from_smtp[1] then
      from_smtp_addr = from_smtp[1].addr or ''
      from_smtp_domain = from_smtp[1].domain or ''
    end

    local from_mime_addr, from_mime_domain, from_display_name = '', '', ''
    if from_mime and from_mime[1] then
      from_mime_addr = from_mime[1].addr or ''
      from_mime_domain = from_mime[1].domain or ''
      from_display_name = from_mime[1].name or ''
    end

    -- Eigene Whitelist. Abgeglichen wird die From-KOPFZEILE - das ist der
    -- Absender, den der Empfaenger sieht und dem er vertraut.
    local wl = nil
    local wl_entry, wl_kind = whitelist_entry_for(from_mime_addr, from_mime_domain)
    if wl_entry then
      local ok, via = sender_authenticated(task, from_mime_domain, from_smtp_domain)
      wl = { entry = wl_entry, kind = wl_kind, authenticated = ok, auth_via = via }
      if not ok then
        rspamd_logger.infox(task, 'AI Filter: whitelist %s matched, but sender not authenticated (%s) - normal filtering',
          wl_entry, via)
      end
    end
    local wl_active = wl ~= nil and wl.authenticated

    -- Skip if the outcome is already decided without us.
    --
    -- "Decided" heisst: Rspamd weist ohnehin selbst ab. Deshalb gehoert
    -- skip_score_above auf die Reject-Schwelle und keinen Punkt darunter.
    -- Stand hier 14.0 bei einer Schwelle von 15.0, entstand dazwischen ein
    -- toter Bereich: Die KI wurde als "schon entschieden" uebersprungen,
    -- abgewiesen wurde aber nichts - die Mail ging mit Spam-Kopfzeile durch.
    -- Getroffen hat das ausgerechnet die verdaechtigste Post, je naeher an
    -- der Schwelle, desto weniger Pruefung. Am 13.09. kam so eine
    -- Kaltakquise-Mail bei 14.85 durch, deren Absenderdomain auf zwei
    -- Blocklisten stand (DBL_SPAM + ABUSE_SURBL) - mit KI-Aufruf haette der
    -- Beleg "url-on-blocklist" sehr wahrscheinlich zur Ablehnung gefuehrt.
    -- Am 11.09. dasselbe bei 14.70.
    --
    -- Kosten: ein paar zusaetzliche Aufrufe fuer das schmale Band zwischen
    -- den alten 14.0 und der Schwelle.
    --
    -- Ausnahme Whitelist: Liegt Rspamd ueber der Reject-Schwelle, ist das
    -- bei einem eingetragenen Absender gerade der Fehlalarm, gegen den die
    -- Whitelist schuetzen soll. Geprueft wird dann trotzdem - auf
    -- Missbrauch, nicht auf Spam.
    --
    -- Die Untergrenze zaehlt OHNE gelernte Ham-Symbole (siehe
    -- learned_ham_points). Falsch trainierte Post ist genau die, die die
    -- KI gegenpruefen soll; Rspamds Score selbst bleibt unveraendert.
    local learned = learned_ham_points(task)
    if score - learned < cfg.skip_score_below
        or (score >= cfg.skip_score_above and not wl_active) then
      return false
    end
    if score < cfg.skip_score_below then
      rspamd_logger.infox(task, 'AI Filter: score %s below skip threshold only through learned ham (%s) - analysing anyway',
        score, learned)
    end

    local from_addr = from_smtp_addr ~= '' and from_smtp_addr or from_mime_addr
    if from_addr == '' then
      from_addr = 'unknown'
    end
    local from_email = from_mime_addr ~= '' and from_mime_addr or from_addr
    local from_domain_for_freemail = from_mime_domain ~= '' and from_mime_domain or from_smtp_domain

    -- Alte Liste aus ai-filter-settings.lua: spart nur den KI-Aufruf,
    -- verspricht keine Zustellung. Steht der Absender zusaetzlich auf der
    -- eigenen Whitelist, geht die vor - die braucht den Checker fuer die
    -- Missbrauchspruefung.
    if not wl_active and from_smtp_domain ~= '' then
      for _, d in ipairs(cfg.whitelist_domains) do
        if from_smtp_domain:lower() == d:lower() then
          rspamd_logger.infox(task, 'AI Filter: whitelisted domain %s, skipping', from_smtp_domain)
          return false
        end
      end
    end
    if not wl_active and from_addr ~= 'unknown' then
      for _, s in ipairs(cfg.whitelist_senders) do
        if from_addr:lower() == s:lower() then
          rspamd_logger.infox(task, 'AI Filter: whitelisted sender %s, skipping', from_addr)
          return false
        end
      end
    end

    rspamd_logger.infox(task, 'AI Filter: checking mail from=%s score=%.2f', from_addr, score)

    -- Recipient
    local to_addr = 'unknown'
    local rcpts = task:get_recipients('smtp')
    if rcpts and rcpts[1] and rcpts[1].addr then
      to_addr = rcpts[1].addr
    end

    -- Subject
    local subject = header_str(task, 'Subject')
    if subject == '' then
      subject = '(no subject)'
    end

    -- Body text + part counts
    local body_text = ''
    local text_part_count = 0
    local html_part_count = 0
    local text_parts = task:get_text_parts()
    if text_parts then
      for _, part in ipairs(text_parts) do
        local content = part:get_content('raw_utf')
        if content then
          body_text = body_text .. tostring(content)
        end
        if part:is_html() then
          html_part_count = html_part_count + 1
        else
          text_part_count = text_part_count + 1
        end
      end
    end

    if body_text == '' then
      local parts = task:get_parts()
      if parts then
        for _, part in ipairs(parts) do
          if part:is_text() then
            local content = part:get_content('raw_utf')
            if content then
              body_text = body_text .. tostring(content)
              break
            end
          end
        end
      end
    end

    if body_text == '' and subject ~= '' then
      body_text = '(Mail has no text body, only subject provided)'
    end

    -- Attachments
    local attachments = {}
    local parts = task:get_parts()
    if parts then
      for _, part in ipairs(parts) do
        if part:is_attachment() then
          local filename = part:get_filename()
          local ctype = part:get_type()
          local size = part:get_length()
          if filename and filename ~= '' then
            table.insert(attachments, {
              name = tostring(filename),
              type = ctype and tostring(ctype) or 'unknown',
              size = size or 0
            })
          end
        end
      end
    end

    -- URLs / link domains
    local urls = {}
    local url_domains = {}
    local seen_domains = {}
    local task_urls = task:get_urls()
    if task_urls then
      for _, u in ipairs(task_urls) do
        table.insert(urls, tostring(u))
        local host = u:get_host()
        if host and host ~= '' and not seen_domains[host] then
          seen_domains[host] = true
          table.insert(url_domains, host)
        end
      end
    end

    -- Identity headers relevant for forgery/alignment checks
    local reply_to = header_str(task, 'Reply-To')
    local return_path = header_str(task, 'Return-Path')
    local message_id = header_str(task, 'Message-Id')
    -- Antwort auf eine laufende Konversation? Wird als Schutz gegen ein
    -- versehentliches Reject ausgewertet.
    local in_reply_to = header_str(task, 'In-Reply-To')
    local references = header_str(task, 'References')
    local list_unsubscribe = header_str(task, 'List-Unsubscribe')
    local list_id = header_str(task, 'List-Id')
    -- Fuer die "Undisclosed recipients"-Erkennung: kein einzelner sichtbarer
    -- Empfaenger im To-Header. Die Auswertung (leer, oder RFC-5322-Leerformel
    -- "Undisclosed recipients:;") passiert im PHP-Checker.
    local to_header = header_str(task, 'To')
    -- Cc gehoert dazu: Steht der Absender allein im To, die echten
    -- Empfaenger aber sichtbar im Cc, ist die Liste nicht verborgen.
    local cc_header = header_str(task, 'Cc')
    local precedence = header_str(task, 'Precedence')
    local authentication_results = header_str(task, 'Authentication-Results')

    -- SPF / DKIM / DMARC results already computed earlier in the pipeline
    local spf = auth_status(task, { 'R_SPF_ALLOW' }, { 'R_SPF_FAIL', 'R_SPF_SOFTFAIL', 'R_SPF_PERMFAIL' })
    local dkim = auth_status(task, { 'R_DKIM_ALLOW' }, { 'R_DKIM_REJECT', 'R_DKIM_PERMFAIL', 'R_DKIM_TEMPFAIL' })
    -- Haben wir mit dem Absender schon einmal zu tun gehabt?
    --
    -- known_senders fuehrt bewusst nur ueber FREEMAIL-Absender Buch: bei
    -- Firmendomains gibt es Reputation, DKIM und DMARC, bei Gmail und
    -- Hotmail mit Millionen Konten sagt die Domain nichts. Deshalb ist
    -- "kein KNOWN_SENDER" bei einer Firmendomain voellig normal und darf
    -- NICHT als Erstkontakt gelten - dafuer gibt es UNKNOWN_SENDER, das
    -- nur bei tatsaechlich verfolgten Domains gesetzt wird.
    --
    -- replies erkennt Antworten auf unsere eigene Post. Beides rein lokal.
    --
    -- Ausdruecklich KEIN Freibrief: die meisten Phishing-Mails hier kommen
    -- aus gekaperten Konten echter Organisationen, mit denen man durchaus
    -- schon korrespondiert haben kann. Das Signal geht deshalb nur als
    -- Hinweis an die KI, nicht in die Ablehnlogik.
    local known_sender = task:get_symbol('KNOWN_SENDER') ~= nil
    local unknown_sender = task:get_symbol('UNKNOWN_SENDER') ~= nil
    local is_reply_to_us = task:get_symbol('REPLY') ~= nil

    local dmarc = auth_status(task, { 'DMARC_POLICY_ALLOW' },
      { 'DMARC_POLICY_REJECT', 'DMARC_POLICY_QUARANTINE', 'DMARC_POLICY_SOFTFAIL', 'DMARC_BAD_POLICY' })

    -- Forgery signals from Rspamd's own header-check rules
    local forged_sender = task:get_symbol('FORGED_SENDER') and true or false
    local from_neq_envfrom = task:get_symbol('FROM_NEQ_ENVFROM') and true or false
    local suspicious_reply_to = task:get_symbol('REPLYTO_DOM_NEQ_FROM_DOM') and true or false
    local freemail_from = freemail_domains[from_domain_for_freemail] or false

    -- Der Fingerabdruck eines gekaperten Kontos: Die Mail kommt echt von
    -- einer Universitaet, Firma oder Behoerde - Authentifizierung sauber,
    -- Reputation sauber, weil der Angreifer den richtigen Account benutzt.
    -- Nur die Antwort soll woanders hin, naemlich auf ein Freemail-Postfach
    -- unter seiner Kontrolle.
    --
    -- Deshalb ausdruecklich OHNE Kopplung an schwache Authentifizierung:
    -- bei dieser Betrugsform ist die Auth gerade in Ordnung.
    local freemail_reply_to = task:get_symbol('FREEMAIL_REPLYTO') and true or false

    -- URL reputation Rspamd has already established for this mail
    local url_blacklisted = any_symbol(task, uribl_bad_symbols)
    local url_suspect     = any_symbol(task, uribl_suspect_symbols)
    local url_fresh       = any_symbol(task, fresh_domain_symbols)
    local url_phishing    = any_symbol(task, phishing_symbols)
    local url_text_mismatch, link_mismatches = link_text_mismatches(task)

    -- Adressgenaue Absender-Blockliste (siehe sender_blocklist_symbols).
    local sender_blocklisted = any_symbol(task, sender_blocklist_symbols)

    local request_data = {
      from = header_str(task, 'From') ~= '' and header_str(task, 'From') or from_email,
      to = to_addr,
      subject = subject,
      body = body_text,
      rspamd_score = score,
      attachments = attachments,
      from_email = from_email,
      from_display_name = from_display_name,
      from_smtp = from_smtp_addr,
      from_smtp_domain = from_smtp_domain,
      from_mime = from_mime_addr,
      from_mime_domain = from_mime_domain,
      reply_to = reply_to,
      return_path = return_path,
      message_id = message_id,
      in_reply_to = in_reply_to,
      references = references,
      urls = urls,
      url_domains = url_domains,
      headers = {
        list_unsubscribe = list_unsubscribe,
        list_id = list_id,
        precedence = precedence,
        authentication_results = authentication_results,
        to_header = to_header,
        cc_header = cc_header,
      },
      auth = {
        spf = spf,
        dkim = dkim,
        dmarc = dmarc,
      },
      signals = {
        freemail_from = freemail_from,
        forged_sender = forged_sender,
        from_neq_envfrom = from_neq_envfrom,
        suspicious_reply_to = suspicious_reply_to,
        freemail_reply_to = freemail_reply_to,
        has_list_unsubscribe = list_unsubscribe ~= '',
        has_html = html_part_count > 0,
        url_blacklisted = url_blacklisted,
        url_suspect = url_suspect,
        url_fresh_domain = url_fresh,
        url_phishing = url_phishing,
        url_text_mismatch = url_text_mismatch,
        sender_blocklisted = sender_blocklisted,
        url_malicious = any_symbol(task, malicious_url_symbols),
        virus = any_symbol(task, virus_symbols),
        known_sender = known_sender,
        unknown_sender = unknown_sender,
        reply_to_our_mail = is_reply_to_us,
      },
      content_stats = {
        body_length = #body_text,
        text_part_count = text_part_count,
        html_part_count = html_part_count,
        link_count = #urls,
        attachment_count = #attachments,
      },
      link_mismatches = link_mismatches,
      -- nil, wenn kein Eintrag passt - dann fehlt der Schluessel ganz.
      whitelist = wl,
    }

    -- Whitelist ohne Checker-Urteil (Fehler, Timeout, alte Checker-
    -- Fassung): zustellen, solange Rspamd selbst nichts Hartes gefunden
    -- hat. Eine Stoerung beim KI-Anbieter darf keine freigegebene Post
    -- kosten.
    local function whitelist_fallback(why)
      local abuse = whitelist_local_abuse(task)
      if #abuse > 0 then
        rspamd_logger.infox(task, 'AI Filter: whitelist %s suspended (%s) - %s', wl.entry,
          table.concat(abuse, ','), why)
        return
      end
      whitelist_deliver(task, wl)
    end

    rspamd_http.request({
      task = task,
      url = cfg.checker_url,
      method = 'POST',
      headers = { ['Content-Type'] = 'application/json' },
      body = ucl.to_format(request_data, 'json'),
      callback = function(err, code, body)
        if err or code ~= 200 then
          -- Fail open: a network/HTTP error says nothing about the mail
          -- itself, so we don't penalize it.
          rspamd_logger.warnx(task, 'AI Filter: API error - err=%s code=%s', tostring(err), tostring(code))
          if wl_active then
            whitelist_fallback('checker unavailable')
          end
          return
        end

        local parser = ucl.parser()
        if parser:parse_string(body) then
          local result = parser:get_object()
          local ai_score = tonumber(result.score) or 0.0

          rspamd_logger.infox(task, 'AI Filter: result score=%.2f action=%s category=%s reason=%s',
            ai_score, tostring(result.action), tostring(result.category), tostring(result.reason))

          if wl_active then
            local verdict = type(result.whitelist) == 'table' and result.whitelist.verdict or nil
            if verdict == 'abuse' then
              -- Starke Hinweise auf ein missbrauchtes Konto: Die Whitelist
              -- tritt zurueck, es gilt die normale Bewertung unten.
              local abuse = result.whitelist.abuse
              rspamd_logger.infox(task, 'AI Filter: whitelist %s suspended (%s) - normal filtering', wl.entry,
                type(abuse) == 'table' and table.concat(abuse, ',') or '?')
            elseif verdict == 'deliver' then
              whitelist_deliver(task, wl)
              return
            else
              whitelist_fallback('no whitelist verdict from checker')
              return
            end
          end

          if cfg.log_only_mode then
            rspamd_logger.infox(task, 'AI Filter: LOG-ONLY mode, would have added score=%.2f', ai_score)
            return
          end

          if math.abs(ai_score) > 0.01 then
            task:insert_result('AI_CONTENT_SCORE', ai_score, result.reason or result.category or '')
          end
        else
          rspamd_logger.warnx(task, 'AI Filter: failed to parse checker response')
          if wl_active then
            whitelist_fallback('unparsable checker response')
          end
        end
      end,
      timeout = cfg.http_timeout
    })

    return true
  end,
  priority = 10
})

rspamd_config:set_metric_symbol({
  name = 'AI_FILTER_FISHY_TLD',
  score = 2.5,
  description = 'Absenderdomain auf einer haeufig missbrauchten TLD',
  group = 'ai_filter'
})

rspamd_config:set_metric_symbol({
  name = 'AI_WHITELIST',
  score = 0.0,
  description = 'Sender on the AI filter whitelist, delivery forced',
  group = 'ai_filter'
})

rspamd_config:set_metric_symbol({
  name = 'AI_CONTENT_SCORE',
  score = 1.0,
  description = 'AI content policy check (additive, signed score)',
  group = 'ai_filter'
})

rspamd_logger.infox(rspamd_config, '=== AI Content Filter initialized ===')
