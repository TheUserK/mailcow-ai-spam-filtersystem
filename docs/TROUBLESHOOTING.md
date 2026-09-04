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

### Container healthy, but nothing shows up in stats.log at all

The `/health` endpoint only checks that PHP is answering - not that real mail
analysis actually works. A PHP fatal error in `ai-mail-checker.php` (a typo
after a manual edit, a constant referenced before its `define()` runs, ...)
can mean every single mail gets a plain `HTTP 500` with an **empty body**,
while `/health` stays green and `docker compose logs` shows only ordinary
request/response pairs with no obvious error.

The script forces `display_errors=0` at the top, so this is invisible even
with `-d display_errors=1` on the command line. The actual PHP fatal error is
only in the container's own error log, not in `errors.log`:

```bash
docker compose exec ai-checker tail -30 /var/log/ai-checker/php-errors.log
# or, from outside the container:
tail -30 /opt/mailcow-dockerized/data/logs/ai-checker/php-errors.log
```

Confirm with a direct request - a real 500 with an empty body looks very
different from a normal `add`/`pass` response:
```bash
docker compose exec ai-checker curl -sv -X POST http://localhost:8080/ai-mail-checker.php \
  -d '{}' -H 'Content-Type: application/json'
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
# Which provider, model and token state is actually in effect
ai-filter-model.sh

# Probe the API with the current settings - changes nothing
ai-filter-model.sh --test
```

`ai-filter-model.sh --test` is the reliable check: it asks the API rather than
reading a file, so it also catches an expired token. IONOS tokens are JWTs with
an expiry between 1 hour and 365 days - when one runs out, the filter stops
scoring and only `errors.log` shows it.

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
   ai-filter-log.sh -n 20 -r
   # or: tail -20 /opt/mailcow-dockerized/data/logs/ai-checker/stats.log | python3 -m json.tool
   ```
   Look at `evidence`, `reject_eligible`/`reject_path`, `red_flags`, and `matched_profile`.
   `ai-filter-log.sh -R` shows only mail that qualified for rejection either way.

2. **Add the sender to `trusted_sender_profiles.json`** (see [CONFIGURATION.md](CONFIGURATION.md)) if it's a recurring, legitimate sender - this also protects it against brand-impersonation false positives for that domain going forward.

3. **Whitelist trusted senders** in `ai-filter-settings.lua` to skip the AI call entirely (only for sources you fully trust):
   ```lua
   whitelist_domains = {'trusted-partner.de'},
   whitelist_senders = {'noreply@bank.de'},
   ```

4. **Lower `MAX_SPAM_POINTS` / `MAX_PHISHING_POINTS`** in `ai-mail-checker.php` if the AI's contribution is too aggressive relative to your Rspamd reject/quarantine thresholds.

5. **Check the contradiction report** (`ai-filter-report.sh -d 7`) - it is built specifically to surface exactly this: a rejection or a phishing verdict that looks out of place. It has caught every real false positive in this filter's history so far.

6. **A specific brand keeps getting flagged wrongly?** If it's a federated name shared by many independent organisations (like Sparkasse/Volksbank), a single-domain brand-list entry is structurally wrong for it - see [CONFIGURATION.md](CONFIGURATION.md#brand-impersonation-three-paths). Otherwise check whether `data/ai-checker/brand_domains.txt` (generated, `ai-filter-brands.sh --debug`) has a stale or wrong entry for it.

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
# AI analysis results, one readable line per mail
ai-filter-log.sh -f

# Same, raw JSON
tail -f /opt/mailcow-dockerized/data/logs/ai-checker/stats.log | python3 -m json.tool

# Errors (reject candidates, API/budget failures, ...)
ai-filter-log.sh -e -f
# or: tail -f /opt/mailcow-dockerized/data/logs/ai-checker/errors.log | python3 -m json.tool

# PHP fatal errors - not the same file as errors.log above, see
# "Container healthy, but nothing shows up in stats.log at all"
tail -f /opt/mailcow-dockerized/data/logs/ai-checker/php-errors.log

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
| `Reject allowed` / `Would reject (shadow mode)` in errors.log | A mail qualified for one of the two reject paths | Expected, not an error - see [CONFIGURATION.md](CONFIGURATION.md#two-paths-to-the-reject-threshold). Read it, this is the only trace a rejected mail leaves |
| `Undefined constant "..."` in php-errors.log, every mail failing | A `define()` was moved below code that runs before it - `define()` only executes when its line is reached, unlike function declarations | Move the `define()` above the router / any code path that can call it |

## Getting Help

1. Run `ai-filter-healthcheck.sh`
2. Check logs (stats.log, errors.log, php-errors.log)
3. Open GitHub issue with:
   - Health check output
   - Relevant log entries (anonymized)
   - `ai-mail-checker.php` **without the API key line**
   - Mailcow version (`cat /opt/mailcow-dockerized/mailcow.conf | grep MAILCOW`)
