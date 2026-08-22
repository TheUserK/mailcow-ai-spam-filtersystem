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
  skip_score_above = 14.0,
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

-- Rspamd's own phishing module: link text does not match link target, or the
-- URL is on OpenPhish/PhishTank.
local phishing_symbols = {
  'PHISHING', 'PHISHED_OPENPHISH', 'PHISHED_PHISHTANK', 'HACKED_WP_PHISHING',
}

local function header_str(task, name)
  local h = task:get_header(name)
  if h then
    return tostring(h)
  end
  return ''
end

rspamd_config:register_symbol({
  name = 'AI_CONTENT_FILTER',
  type = 'postfilter',
  callback = function(task)
    local score = task:get_metric_score('default')[1]

    -- Skip if score is already decisive
    if score >= cfg.skip_score_above or score < cfg.skip_score_below then
      return false
    end

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

    local from_addr = from_smtp_addr ~= '' and from_smtp_addr or from_mime_addr
    if from_addr == '' then
      from_addr = 'unknown'
    end
    local from_email = from_mime_addr ~= '' and from_mime_addr or from_addr
    local from_domain_for_freemail = from_mime_domain ~= '' and from_mime_domain or from_smtp_domain

    -- Check sender whitelist (skips the AI call entirely)
    if from_smtp_domain ~= '' then
      for _, d in ipairs(cfg.whitelist_domains) do
        if from_smtp_domain:lower() == d:lower() then
          rspamd_logger.infox(task, 'AI Filter: whitelisted domain %s, skipping', from_smtp_domain)
          return false
        end
      end
    end
    if from_addr ~= 'unknown' then
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

    -- URL reputation Rspamd has already established for this mail
    local url_blacklisted = any_symbol(task, uribl_bad_symbols)
    local url_suspect     = any_symbol(task, uribl_suspect_symbols)
    local url_fresh       = any_symbol(task, fresh_domain_symbols)
    local url_phishing    = any_symbol(task, phishing_symbols)

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
        has_list_unsubscribe = list_unsubscribe ~= '',
        has_html = html_part_count > 0,
        url_blacklisted = url_blacklisted,
        url_suspect = url_suspect,
        url_fresh_domain = url_fresh,
        url_phishing = url_phishing,
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
    }

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
          return
        end

        local parser = ucl.parser()
        if parser:parse_string(body) then
          local result = parser:get_object()
          local ai_score = tonumber(result.score) or 0.0

          rspamd_logger.infox(task, 'AI Filter: result score=%.2f action=%s category=%s reason=%s',
            ai_score, tostring(result.action), tostring(result.category), tostring(result.reason))

          if cfg.log_only_mode then
            rspamd_logger.infox(task, 'AI Filter: LOG-ONLY mode, would have added score=%.2f', ai_score)
            return
          end

          if math.abs(ai_score) > 0.01 then
            task:insert_result('AI_CONTENT_SCORE', ai_score, result.reason or result.category or '')
          end
        else
          rspamd_logger.warnx(task, 'AI Filter: failed to parse checker response')
        end
      end,
      timeout = cfg.http_timeout
    })

    return true
  end,
  priority = 10
})

rspamd_config:set_metric_symbol({
  name = 'AI_CONTENT_SCORE',
  score = 1.0,
  description = 'AI content policy check (additive, signed score)',
  group = 'ai_filter'
})

rspamd_logger.infox(rspamd_config, '=== AI Content Filter initialized ===')
