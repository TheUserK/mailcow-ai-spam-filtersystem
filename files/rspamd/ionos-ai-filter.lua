-- DEPRECATED: This file is kept for v1 compatibility only.
-- New installations use ai-content-filter.lua loaded via dofile().
-- See: files/rspamd/ai-content-filter.lua

-- === IONOS AI FILTER (Added by mailcow-ionos-ai-spam-filter) ===
-- GitHub: https://github.com/TheUserK/mailcow-ai-spam-filtersystem
-- MIT License

local rspamd_logger = require "rspamd_logger"
local rspamd_http = require "rspamd_http"
local ucl = require "ucl"

rspamd_config:register_symbol({
  name = 'IONOS_AI_CHECK',
  type = 'postfilter',
  callback = function(task)
    local score = task:get_metric_score('default')[1]

    if score >= 14.0 or score < -10.0 then
      return false
    end

    local from = task:get_from('smtp')
    if from and from[1] and from[1].domain == 'localhost' then
      return false
    end

    rspamd_logger.infox(task, 'IONOS: Checking mail, score=%.2f', score)

    local to_addr = 'unknown'
    local rcpts = task:get_recipients('smtp')
    if rcpts and rcpts[1] and rcpts[1].addr then
      to_addr = rcpts[1].addr
    end

    local from_addr = 'unknown'
    if from and from[1] and from[1].addr then
      from_addr = from[1].addr
    end

    if from_addr == 'unknown' then
      local from_mime = task:get_from('mime')
      if from_mime and from_mime[1] and from_mime[1].addr then
        from_addr = from_mime[1].addr
      end
    end

    local subject = task:get_header('Subject', false) or
                    task:get_header('subject', false) or
                    '(no subject)'
    subject = tostring(subject)

    local body_text = ''
    local text_parts = task:get_text_parts()
    if text_parts then
      for _, part in ipairs(text_parts) do
        local content = part:get_content('raw_utf')
        if content then
          body_text = body_text .. tostring(content)
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

    local request_data = {
      from = from_addr,
      to = to_addr,
      subject = subject,
      body = body_text,
      rspamd_score = score,
      attachments = attachments
    }

    rspamd_http.request({
      task = task,
      url = 'http://ionos-checker:8080/ionos-mail-checker.php',
      method = 'POST',
      headers = { ['Content-Type'] = 'application/json' },
      body = ucl.to_format(request_data, 'json'),
      callback = function(err, code, body)
        if err or code ~= 200 then
          rspamd_logger.warnx(task, 'IONOS: API error - err=%s code=%s', tostring(err), tostring(code))
          task:insert_result('IONOS_AI_SPAM', 2.0, 'API error - scored conservatively')
          return
        end

        local parser = ucl.parser()
        if parser:parse_string(body) then
          local result = parser:get_object()
          local ai_score = tonumber(result.score) or 0.0

          rspamd_logger.infox(task, 'IONOS: AI response - score=%.2f action=%s category=%s',
            ai_score, tostring(result.action), tostring(result.category))

          if result.action == 'reject' and ai_score > 7.0 then
            task:set_metric_action('default', 'reject')
            task:insert_result('IONOS_AI_SPAM', 10.0, 'AI: ' .. (result.reason or ''))
          elseif ai_score > 0.1 then
            local weight = (result.action == 'quarantine') and 6.0 or 10.0
            task:insert_result('IONOS_AI_SPAM', ai_score / weight, result.reason or '')
          end
        end
      end,
      timeout = 30.0
    })

    return true
  end,
  priority = 10
})

rspamd_config:set_metric_symbol({
  name = 'IONOS_AI_SPAM',
  score = 1.0,
  description = 'IONOS AI detected spam',
  group = 'ionos'
})

rspamd_logger.infox(rspamd_config, '=== IONOS AI Filter initialized ===')

-- === END IONOS AI FILTER ===
