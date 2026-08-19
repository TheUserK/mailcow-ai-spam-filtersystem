# Configuration Guide

There is no `config.ini` in v3. Configuration is split across two files:

1. **`/opt/mailcow-dockerized/data/ai-checker/ai-mail-checker.php`** - API key, budget, scoring caps (PHP constants near the top of the file)
2. **`/opt/mailcow-dockerized/data/conf/rspamd/lua/ai-filter-settings.lua`** - when the AI gets called at all, log-only mode, sender whitelist

Plus an optional **`trusted_sender_profiles.json`** for your own trusted senders.

After changes to the PHP file, restart the container:
```bash
docker compose restart ai-checker
```

After changes to the Lua settings or filter, restart Rspamd:
```bash
docker compose restart rspamd-mailcow
```

## ai-mail-checker.php constants

| Constant | Default | Description |
|---|---|---|
| `AI_API_ENDPOINT` | `https://openai.inference.de-txl.ionos.com/v1/chat/completions` | OpenAI-compatible API endpoint |
| `AI_API_TOKEN` | (filled in by install.sh) | Your IONOS API key |
| `AI_MODEL` | `openai/gpt-oss-120b` | Model name |
| `API_TIMEOUT` | `20` | API request timeout (seconds) |
| `CONNECT_TIMEOUT` | `5` | Connection timeout (seconds) |
| `MAILCOW_DB_HOST` / `MAILCOW_DB_NAME` / `MAILCOW_DB_USER` | `mysql` / `$MAILCOW_DBNAME` / `$MAILCOW_DBUSER` | Used for the internal-mail lookup. Name, user and password all come from container env vars fed by mailcow's `DBNAME`/`DBUSER`/`DBPASS` in `docker-compose.override.yml` |
| `MONTHLY_BUDGET_EUR` | `50` | Monthly budget in EUR |
| `AVG_COST_PER_CALL_EUR` | `0.00034` | Estimated cost per API call, used to derive the monthly call limit |
| `MAX_SPAM_POINTS` | `4.0` | Max score the AI can add for `spam`/`marketing`/`pharma` |
| `MAX_HAM_POINTS` | `3.0` | Max score the AI can *subtract* for confident ham |
| `MAX_PHISHING_POINTS` | `10.0` | Max score for `phishing`/`fraud` - deliberately kept **below** Rspamd's reject threshold (15) so the AI can never reject a mail on its own |
| `LOG_MAIL_CONTENT` | `false` | Write subject and a body excerpt to `stats.log`. Off by default - these are content data of senders who never consented. Only enable temporarily for debugging |
| `LOG_FILE_MODE` | `0600` | Permissions for newly created log files |

**Note:** The API is OpenAI-compatible. Other GDPR-compliant providers with the same API format should work, but only IONOS is officially tested.

There are no operation modes, philosophy settings or probability/confidence
thresholds anymore - the AI never decides reject/quarantine/pass itself, it
only contributes a score, and Rspamd's own metric/action thresholds (the
same ones that apply to every other Rspamd rule) make that call. To make the
filter more or less aggressive overall, tune Rspamd's action thresholds, or
lower/raise `MAX_SPAM_POINTS` / `MAX_PHISHING_POINTS` here.

## Reinstalling from scratch

`install.sh --upgrade` deliberately preserves your configuration. To pull
every component up to the version shipped in this repo instead:

```bash
sudo ./install.sh --reinstall
```

Kept: your API key (read out of the deployed script) and
`trusted_sender_profiles.json`. Overwritten: `ai-filter-settings.lua`, the
`ai_filter` block in `groups.conf`, `docker-compose.override.yml`, and all
PHP/Lua/script files. Every overwritten file is backed up first. Other groups
in `groups.conf` and other services in the override file are not touched.

## Categories and how hard each may be treated

The AI picks exactly one category, and that choice decides the ceiling on
the **total** score - Rspamd's own points plus the filter's contribution.
Expressing the limit as a total rather than as a point budget is what makes
"this category is never rejected" an actual guarantee instead of an estimate.

| Category | Total capped at | May be rejected |
|---|---|---|
| `legitimate`, `transactional`, `personal` | `MAX_TOTAL_TRANSACTIONAL` (8) | never |
| `newsletter`, `marketing` | `MAX_TOTAL_DEFAULT` (12) | never |
| `clickbait`, `spam`, `pharma`, `phishing`, `fraud` | `MAX_TOTAL_DEFAULT` (12) | only via the conjunction below |

Nothing reaches the reject threshold on its category alone. It additionally
takes **all** of:

- the category is one of the attackable ones
- `confidence` >= 0.80
- at least one structural signal that does **not** come from the AI:
  cloud-storage-only links, brand impersonation, a blocklist hit, a
  dangerous attachment, or a URL shortener
- no trusted sender profile matched
- no `In-Reply-To` header, i.e. the mail is not part of an ongoing exchange

The structural signal is the point of the exercise: a reject always needs a
second, independent source to agree, so a single wrong model verdict cannot
discard mail on its own.

When all of it holds, `REJECT_FLOOR` applies. The usual curve scales with
probability and confidence and only reaches about two thirds of the budget
even on a clear verdict - far too little to reject. Once the category is
assigned and a structural signal agrees, the category *is* the verdict, so
the score no longer scales down.

**`AI_MAY_REJECT` controls whether that actually happens.** Either way every
qualifying mail is written to `errors.log`: as `Reject allowed` when armed,
as `Would reject (shadow mode)` when not, with the category, the confidence,
the structural evidence and the resulting total.

Read that log. A rejected mail leaves no other trace - it reaches no mailbox
and no quarantine anyone opens daily, and the only party who notices is the
sender, who gets a bounce. Automated senders do not notice at all.

Setting it to `false` first and reading a week or two of `Would reject`
entries is the cautious path:

```bash
grep -E "Reject allowed|Would reject" data/logs/ai-checker/errors.log | jq -r \
  '"\(.timestamp) \(.context.category) \(.context.total_score) \(.context.from) \(.context.evidence|join(","))"'
```

`stats.log` carries `evidence` and `reject_eligible` per mail for the same
purpose.

## Trusted sender profiles

Built-in profiles (DHL, DPD, Hermes, UPS, GLS, Shop-Apotheke, DocMorris,
Amazon, PayPal, Telekom, Vodafone, sipgate, fonial) let a mail skip the AI
call entirely when:
- the sender domain (From, MIME-From, SMTP-From, Return-Path or Message-Id) matches the profile, AND
- SPF/DKIM/DMARC auth is strong, AND
- Reply-To, Return-Path, Message-Id and every link domain also belong to the profile, AND
- there are no dangerous attachments, URL shorteners, or detected brand impersonation

To add your own (business partners, internal tools, ...), copy
`trusted_sender_profiles.json.example` next to `ai-mail-checker.php` and
rename it to `trusted_sender_profiles.json`:

```json
{
  "my-partner": {
    "kind": "business-partner",
    "domains": ["partner-domain.example"],
    "url_domains": ["partner-domain.example"],
    "brands": ["my partner"]
  }
}
```

Using the key of a built-in profile (e.g. `"dhl"`) merges your `domains` /
`url_domains` / `brands` into the existing one instead of replacing it.

A profile match alone is not a bypass - it only enables the local auto-pass
*if* auth and header/link alignment also check out. A mismatched profile
(e.g. a mail claiming to be DHL from a domain not in the profile) still goes
to the AI, with that mismatch passed along as a risk flag.

## Brand impersonation detection

Independent of the trusted-sender profiles, the checker maintains a small
list of frequently-impersonated brands (PayPal, Amazon, banks, shippers,
Microsoft, Apple, ...) and checks only the From display-name and address
(never the body - mentioning a brand in the text is normal) for a claimed
brand whose domain doesn't match:
- **Typosquat** (edit distance <= 2, e.g. `booking.co` vs `booking.com`) adds a large fixed score and blocks the AI from rescuing the mail into ham
- **Foreign domain** (brand named, domain unrelated) adds a smaller fixed score and is passed to the AI as a strong phishing signal

## URL reputation from Rspamd

Stock mailcow already queries Spamhaus DBL, SURBL, URIBL, OpenPhish and
PhishTank for every mail, plus the SpamEatingMonkey zone that flags domains
first seen within ~15 days. The filter reads those results and passes them
on as risk flags - no extra lookups, no additional service, nothing to
configure.

| Flag | Meaning | Weight in the decision |
|---|---|---|
| `url-blacklisted` | Link domain on a malware/spam blocklist | Strong. Also blocks the trusted-sender auto-pass |
| `url-known-phishing` | Link on OpenPhish/PhishTank, or Rspamd's phishing module fired | Strong. Also blocks the auto-pass |
| `url-fresh-domain` | Link domain is only days old | Weak on its own - every legitimate domain is new once. Strong **combined** with a claimed brand, a login prompt or a payment request |
| `url-suspect-listing` | Weak listing (grey/redirector) | Hint only |

The point is the combination. A blocklist cannot know that the sender claims
to be PayPal; the brand check cannot know that the linked domain was
registered four days ago. Together they are near enough conclusive, and that
join is what the AI is given.

If you want to see whether these lists are actually answering on your server:

```bash
docker compose exec unbound-mailcow dig +short test.uribl.com.multi.uribl.com
#   expected: 127.0.0.x   |   empty = queries are not getting through
docker compose exec rspamd-mailcow rspamc counters | grep -iE 'blocked|_fail'
#   any non-zero *_BLOCKED / *_FAIL counter means your resolver is being refused
```

## ai-filter-settings.lua

`/opt/mailcow-dockerized/data/conf/rspamd/lua/ai-filter-settings.lua`

| Setting | Default | Description |
|---|---|---|
| `checker_url` | `http://ai-checker:8080/ai-mail-checker.php` | Where Rspamd sends the mail context |
| `skip_score_above` | `14.0` | Skip the AI call if Rspamd's score is already this high (mail is decisive spam already) |
| `skip_score_below` | `-10.0` | Skip the AI call if Rspamd's score is already this low |
| `http_timeout` | `30.0` | HTTP timeout for the checker call |
| `log_only_mode` | `false` | Still calls the checker and logs the result, but never applies the score |
| `whitelist_domains` | `{}` | Sender domains that skip the AI call entirely (Lua table) |
| `whitelist_senders` | `{}` | Sender addresses that skip the AI call entirely (Lua table) |

Example:
```lua
whitelist_domains = {'trusted-partner.de', 'internal.local'},
whitelist_senders = {'noreply@bank.de', 'cron@server.local'},
```

**Note:** Whitelisted senders skip analysis entirely, including the local
trusted-sender/impersonation checks. Prefer `trusted_sender_profiles.json`
for anything where you still want brand-impersonation protection; use the
Lua whitelist only for sources you fully trust and want to save API calls on.

## Performance / cost tuning

### Reduce API Calls
Tighten the score range in `ai-filter-settings.lua`:
```lua
skip_score_above = 12.0,  -- was 14.0
skip_score_below = -5.0,  -- was -10.0
```
Or add more entries to `trusted_sender_profiles.json` so more of your regular
mail (order confirmations, shipping notices, ...) gets a local auto-pass.

### Reduce Costs
- Lower `MONTHLY_BUDGET_EUR` in `ai-mail-checker.php`
- Tighten the score range above (fewer emails analyzed)
- The body is already truncated to 3000 chars before it's sent to the AI

### Improve Detection
- Lower `MAX_SPAM_POINTS` / `MAX_PHISHING_POINTS` if too aggressive, raise them if too much gets through
- Add your legitimate high-volume senders to `trusted_sender_profiles.json` to reduce noise and API cost
- Tune Rspamd's own action thresholds - they now fully control the final decision
