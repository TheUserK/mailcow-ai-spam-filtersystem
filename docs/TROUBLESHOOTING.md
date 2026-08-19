# Troubleshooting Guide

## Quick Diagnosis

Run the health check first:
```bash
ai-filter-healthcheck.sh
# or
install.sh --check
```

## Container Issues

### Container Won't Start

```bash
docker compose logs ai-checker
```

Common fixes:
```bash
# Check PHP syntax
docker compose exec ai-checker php -l /app/ai-mail-checker.php

# Fix permissions
chmod 755 /opt/mailcow-dockerized/data/ai-checker
chmod 644 /opt/mailcow-dockerized/data/ai-checker/router.php
chmod 600 /opt/mailcow-dockerized/data/ai-checker/ai-mail-checker.php
```

### Health Check Failing

```bash
docker compose exec ai-checker curl -s http://localhost:8080/health
# Should return: OK
```

## After a Mailcow Update

A mailcow update should not affect the filter - it is an untracked file in
`plugins.d/`, and `update.sh` neither commits nor cleans those. To confirm:

```bash
ls -la /opt/mailcow-dockerized/data/conf/rspamd/plugins.d/ai-content-filter.lua
grep -A2 ai-content-filter /opt/mailcow-dockerized/data/conf/rspamd/rspamd.conf.local
docker compose logs rspamd-mailcow | grep "AI Content Filter initialized"
```

Both the file and the section matter. Without the section rspamd finds the
file, logs `disabling unconfigured lua module`, and carries on without it -
no error, no symbol, no analysis.

If the file is gone, reinstalling puts it back:
```bash
cd /opt/mailcow-ai-spam-filtersystem && git pull && ./install.sh --reinstall
```

Coming from an older version, the filter sat in `lua/` with a loader line in
`rspamd.local.lua` - a tracked mailcow file, so the line was lost whenever the
update's merge hit a conflict there. `install.sh` removes both leftovers, and
the health check fails if either is still present, since they would load the
filter a second time.

## Emails Not Being Analyzed

```bash
docker compose logs rspamd-mailcow | grep "AI Filter"
```

**Possible reasons (all expected, working as intended):**
- The mail was sent by one of your own authenticated users (outbound is never analysed)
- The mail is being re-delivered by your own sieve forwarding. It was analysed when it arrived; forwarding rewrites the envelope and breaks SPF/DKIM, so a second pass would judge the same message on worse evidence and bill a second API call for it
- Both sender and recipient are on a local Mailcow domain (internal mail)
- Sender matched a trusted-sender profile with strong auth and aligned headers/links (local auto-pass)
- Rspamd score already outside the `skip_score_above`/`skip_score_below` range in `ai-filter-settings.lua`
- Sender is in the Lua-level whitelist (`whitelist_domains`/`whitelist_senders`)
- Log-only mode is active (`log_only_mode = true` in `ai-filter-settings.lua`)
- Budget exceeded - check `monthly_budget.json`

Check `stats.log` for the `analysis_source` field (`local-precheck`, `local`, `ai`, `system`) to see which of these applied.

## API Issues

### Invalid or Missing API Key

```bash
# Check the key is embedded in ai-mail-checker.php
grep "AI_API_TOKEN" /opt/mailcow-dockerized/data/ai-checker/ai-mail-checker.php
```

### Budget Exceeded

```bash
cat /opt/mailcow-dockerized/data/logs/ai-checker/monthly_budget.json
```

Reset (use with caution):
```bash
echo '{"month":"2025-12","calls":0,"estimated_cost_eur":0}' > \
  /opt/mailcow-dockerized/data/logs/ai-checker/monthly_budget.json
```

### API Timeouts

Increase the timeout constants in `ai-mail-checker.php`:
```php
define('API_TIMEOUT', 30);
define('CONNECT_TIMEOUT', 10);
```

And in `ai-filter-settings.lua`:
```lua
http_timeout = 45.0,
```

### API/network errors

A failed call to the AI (timeout, HTTP error, unparseable response) fails
open: the checker returns score 0 rather than penalizing the mail, and Rspamd
falls back to its normal (non-AI) scoring for that mail. Check `errors.log`
for the reason.

## Internal-Mail Detection Not Working

`isInternalMail()` needs a working connection to the Mailcow database.

```bash
# Is MAILCOW_DBPASS set in the container?
docker compose exec ai-checker env | grep MAILCOW_DBPASS
```

If it's missing, add `- MAILCOW_DBPASS=${DBPASS}` to the `ai-checker`
service's `environment:` section in `docker-compose.override.yml` (next to
`TZ`) and restart the container. Check `errors.log` for
"Failed to fetch local domains" if it's set but still failing.

## False Positives

**Legitimate emails being flagged?**

1. **Check the stats log:**
   ```bash
   tail -20 /opt/mailcow-dockerized/data/logs/ai-checker/stats.log | python3 -m json.tool
   ```
   Look at `red_flags`, `risk_flags`-equivalent info in `reason`, and `matched_profile`.

2. **Add the sender to `trusted_sender_profiles.json`** (see [CONFIGURATION.md](CONFIGURATION.md)) if it's a recurring, legitimate sender - this also protects it against brand-impersonation false positives for that domain going forward.

3. **Whitelist trusted senders** in `ai-filter-settings.lua` to skip the AI call entirely (only for sources you fully trust):
   ```lua
   whitelist_domains = {'trusted-partner.de'},
   whitelist_senders = {'noreply@bank.de'},
   ```

4. **Lower `MAX_SPAM_POINTS` / `MAX_PHISHING_POINTS`** in `ai-mail-checker.php` if the AI's contribution is too aggressive relative to your Rspamd reject/quarantine thresholds.

## Too Much Spam Getting Through

1. Raise `MAX_SPAM_POINTS` / `MAX_PHISHING_POINTS` in `ai-mail-checker.php`
2. Lower Rspamd's own quarantine/reject action thresholds (they now make the final call using the total score, including the AI's contribution)
3. Widen the AI-call range in `ai-filter-settings.lua` (lower `skip_score_above`, raise `skip_score_below`) so more borderline mail reaches the AI

## Configuration Not Taking Effect

1. **PHP constants (ai-mail-checker.php):** Restart ai-checker container
   ```bash
   docker compose restart ai-checker
   ```

2. **Lua settings (ai-filter-settings.lua):** Restart Rspamd
   ```bash
   docker compose restart rspamd-mailcow
   ```

3. **trusted_sender_profiles.json:** No restart needed - it's re-read on the next request (cached in-process per request only), but the file must be valid JSON or it's silently ignored. Validate with `php -r 'var_dump(json_decode(file_get_contents("trusted_sender_profiles.json")) !== null);'`

## Debugging

### Monitor Live

```bash
# AI analysis results
tail -f /opt/mailcow-dockerized/data/logs/ai-checker/stats.log | python3 -m json.tool

# Errors
tail -f /opt/mailcow-dockerized/data/logs/ai-checker/errors.log | python3 -m json.tool

# Rspamd filter activity
docker compose logs -f rspamd-mailcow | grep "AI Filter"
```

## Common Error Messages

| Error / reason | Cause | Fix |
|-------|-------|-----|
| `api-error-http-NNN` | AI API call failed | Check IONOS API status/key; fails open (score 0) |
| `budget-exceeded` | Monthly budget limit reached | Raise `MONTHLY_BUDGET_EUR` or wait for next month; fails open (score 0) |
| `parse-error` | AI returned invalid JSON | Usually transient, check error log |
| `internal-mail` | Both sender and recipient are on a local Mailcow domain | Expected, not an error |
| `trusted-transactional` | Local auto-pass via a trusted sender profile | Expected, not an error |

## Getting Help

1. Run `ai-filter-healthcheck.sh`
2. Check logs (stats.log, errors.log)
3. Open GitHub issue with:
   - Health check output
   - Relevant log entries (anonymized)
   - `ai-mail-checker.php` **without the API key line**
   - Mailcow version (`cat /opt/mailcow-dockerized/mailcow.conf | grep MAILCOW`)
