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

## Brand impersonation: two paths

A rejection needs structural evidence that does not come from the model.
Brand impersonation supplies it in two ways:

**The list** (`getImpersonationBrands()`). For well-known brands it maps the
name to the domains that brand legitimately sends from. A claim in the display
name that does not match one of them scores 6.0 (typosquat) or 7.0 (foreign
domain). Matching requires that no letter sits directly before or after the
brand name, so `ing` does not fire on "Marketing" or "Holding".

Free mailbox domains deliberately do **not** belong on this list. Anyone can
register at `outlook.com` and set their display name to "Microsoft".

**The list-free path** (`claimedBrandMismatch()`). The model returns
`claimed_brand` - who the mail claims to be from. Code, not the model, then
checks whether that name appears as a label of the sender's organisational
domain. A list can never hold every regional bank; this path covers the rest.

It only counts as evidence when authentication is **not** strong, and **a
passing DMARC alone makes it strong**. Every ESP - Campaign Monitor, Mailchimp,
Brevo - puts its own bounce domain in the envelope, so rspamd raises
`FORGED_SENDER` and `FROM_NEQ_ENVFROM` on perfectly legitimate newsletters. If
those signals could still mark a DMARC-passing mail suspicious, the coupling
would fail on exactly the senders it exists to protect.

Matching is word-based, not label equality: companies are rarely named after
their domain. "Albana Hotel & Suites Silvaplana" sends from `hotelalbana.ch`,
and `albana` is what ties the two together. Filler words (`hotel`, `gmbh`,
`group`, `deutschland`, ...) are dropped first so they cannot carry a match.

The known limit: a lookalike domain that contains the brand name escapes this
path - `sparkasse-tan.info` claiming "Sparkasse" is suppressed here. That is
deliberate, because the strict alternative rejected real mail, and the list
path catches those cases anyway. Only an *unlisted* brand with a lookalike
domain slips through both, and there the AI still scores it - it just is not
rejected automatically.

The two never stack: if the list already matched, the generic path stays quiet,
so one fact cannot pose as two independent pieces of evidence.

`claimed_brand` is written to `stats.log`, and a hit shows up as evidence
`brand-claim-mismatch`:

```bash
ai-filter-log.sh -R
jq -r 'select(.evidence|index("brand-claim-mismatch"))|[.from,.claimed_brand]|@tsv' \
  /opt/mailcow-dockerized/data/logs/ai-checker/stats.log
```

## Evidence: strong and weak

A rejection needs structural evidence, but not every kind carries the same
weight. Only these three can justify one on their own:

| Strong - rests on a source the sender cannot influence |
|---|
| `brand-impersonation` - the brand list, with the brand's real domains |
| `url-on-blocklist` - external reputation data |
| `dangerous-attachment` - an executable attachment |

A mail that is **verifiably from** one of the listed brands is never rejected
at all, whatever it links to. The brand list already holds each brand's real
sending domains; if a DMARC-authenticated From matches one, the sender *is*
that brand and the question of impersonation does not arise.

That guard exists because a genuine Google account mail was rejected on
21.08. It linked `myaccount.google.com`, `store.google.com`, `g.co` and
`c.gle` - all Google - and Google's own URL shortener is on a phishing
blocklist because phishers abuse it. The evidence was technically correct and
the conclusion still wrong. A forged sender cannot use this door: without
DMARC passing for the brand's real domain, auth strength is never `strong`.

The rest are hints. They still appear in `stats.log`, and they still inform the
model, but they cannot carry a rejection alone: `brand-claim-mismatch`,
`url-shortener`, `cloud-storage-only-links`.

That split comes from production. `brand-claim-mismatch` fired three times and
was wrong all three: a cruise line (`Scenic Eclipse` from `mail.scenic.eu`), a
German school in Spain (`Deutsche Schule Malaga` from `dinantia.email`) and a
New Zealand survey firm (`Latitude Surveying Ltd` from `lats.co.nz` - their own
initials). Companies are not named after their domains, and no amount of string
matching fixes that. As corroboration the signal is useful; as the sole reason
to bounce a mail it is not.

## Provider profile (provider.conf)

The three `_DEFAULT` constants below are the shipped values. If
`data/ai-checker/provider.conf` exists, its keys win:

```ini
endpoint = https://openai.inference.de-txl.ionos.com/v1/chat/completions
model = openai/gpt-oss-120b
token = eyJ...
cost_per_call = 0.00034
reasoning_effort = low
api_timeout = 25
```

`reasoning_effort` and `api_timeout` exist because answer time is a property of
the model, not of the code. Measured against IONOS:

| Model | reasoning_effort | Answer time |
|---|---|---|
| `openai/gpt-oss-120b` | medium | 1.6 s |
| `openai/gpt-oss-120b` | low | 0.5 s |
| `Qwen/Qwen3.5-397B-A17B` | medium | 26.5 s |
| `Qwen/Qwen3.5-397B-A17B` | low | 14.6 s |

This matters more than it looks. The checker sits synchronously in the delivery
path with four PHP workers, so sustained throughput is roughly
`workers / answer time`. At 26 s that is nine mails a minute - fine on average,
but a burst of twenty arriving together puts the last one past rspamd's
`http_timeout`, and the filter fails open exactly when a spam wave hits.

Leave `reasoning_effort` empty to let the provider decide (IONOS defaults to
`medium`).

### The timeout chain

Three clocks run at once, and their order decides *how* the filter breaks:

```
api_timeout  <  http_timeout  <  task_timeout
   (profile)     (lua settings)    (rspamd)
```

If `http_timeout` expires first, the Lua module fails open and the mail is
delivered without an AI verdict - unfortunate but harmless. If `task_timeout`
expires first, rspamd forces a **soft reject** and the mail is deferred with a
`4.7.1`. The order must therefore never invert.

`ai-filter-model.sh --timeout N` sets all three together, keeping fixed margins,
and restarts both containers. `ai-filter-healthcheck.sh` fails if the order is
ever broken by hand.

`api_timeout` is a **total** budget, not a per-attempt one. The binding limit
is not the module's `http_timeout` but rspamd's global `task_timeout`, 25 s on
mailcow. When that expires rspamd forces a **soft reject** - the mail is
deferred with a `4.7.1`, not merely delivered unscored. A retry after a full
timeout would always blow past it, so the checker only asks a second time if
there is time left in the budget. Keep `api_timeout` at 20 s or below unless
you raise `task_timeout` in mailcow as well.

`cost_per_call` is what the budget guard divides `MONTHLY_BUDGET_EUR` by, so it
has to match the model you are actually paying for - switching model does not
change it on its own. `ai-filter-model.sh --cost 0.0016` sets it and prints how
many calls per month that works out to. `0` disables the limit, for a provider
that does not charge.

Do not write this file by hand - `ai-filter-model.sh` creates it, tests the
settings against the live API before writing, and sets `root`/`0600` because
the file holds your API token. `ai-filter-healthcheck.sh` fails if those
permissions are wrong. `install.sh` never touches the file, so a `--reinstall`
keeps your choice.

## ai-mail-checker.php constants

| Constant | Default | Description |
|---|---|---|
| `AI_API_ENDPOINT_DEFAULT` | `https://openai.inference.de-txl.ionos.com/v1/chat/completions` | OpenAI-compatible API endpoint |
| `AI_API_TOKEN_DEFAULT` | (filled in by install.sh) | Your IONOS API key |
| `AI_MODEL_DEFAULT` | `openai/gpt-oss-120b` | Model name |
| `API_TIMEOUT` | `20` | API request timeout (seconds) |
| `CONNECT_TIMEOUT` | `5` | Connection timeout (seconds) |
| `MAILCOW_DB_HOST` / `MAILCOW_DB_NAME` / `MAILCOW_DB_USER` | `mysql` / `$MAILCOW_DBNAME` / `$MAILCOW_DBUSER` | Used for the internal-mail lookup. Name, user and password all come from container env vars fed by mailcow's `DBNAME`/`DBUSER`/`DBPASS` in `docker-compose.override.yml` |
| `MONTHLY_BUDGET_EUR` | `50` | Monthly budget in EUR |
| `AVG_COST_PER_CALL_EUR` | `0.00034` | Estimated cost per API call, used to derive the monthly call limit. Depends on the model, so a provider profile overrides it; `0` disables the limit |
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
