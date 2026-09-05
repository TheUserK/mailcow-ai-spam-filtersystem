# Mailcow AI Spam Filter

AI-powered spam filter for Mailcow using IONOS AI Model Hub. Detects sophisticated spam, phishing, CEO fraud, and scams that traditional filters miss.

**Built for GDPR/DSGVO setups** - AI processing runs in German data centers (IONOS Frankfurt/Berlin). It is not "compliant" out of the box: you are the controller, so you still need a DPA/AVV with IONOS, an entry in your records of processing (Art. 30) and a line in your privacy policy. See [Privacy & GDPR/DSGVO](#privacy--gdprdsgvo).

> [!CAUTION]
> **This filter rejects mail, and rejected mail is gone.**
>
> With the shipped defaults (`AI_MAY_REJECT = true`), mail that meets
> [all of these conditions](docs/CONFIGURATION.md#categories-and-how-hard-each-may-be-treated)
> is scored past Rspamd's reject threshold and refused during the SMTP
> transaction. There is no copy in any mailbox. The sending server gets a
> bounce — a person may notice it and call you, an automated sender will not
> notice at all.
>
> To run without that, set `AI_MAY_REJECT` to `false` in
> `ai-mail-checker.php` and restart the container. Qualifying mail is then
> capped below the threshold and only marked as spam.
>
> Either way, **every** candidate is written to `errors.log` with its
> category, confidence and evidence. That log is the only trace a rejected
> mail leaves. Read it.

> [!IMPORTANT]
> **Mail content leaves your server.** For every mail that reaches the AI
> stage, the sender, the subject and up to 3000 characters of the body are
> transmitted to IONOS. Most mail never gets that far, and outgoing mail from
> your own users is never sent at all — but what is sent, is sent.
>
> If you run this for anybody other than yourself, you are the controller
> under GDPR. A data processing agreement with IONOS, an entry in your records
> of processing and a line in your privacy policy are your responsibility, not
> this project's. See [Privacy & GDPR/DSGVO](#privacy--gdprdsgvo) for the full
> list.

> [!NOTE]
> Provided as is under the MIT license, without warranty of any kind. You
> decide whether it fits your setup, and you operate it at your own risk.
> Test it with `log_only_mode = true` before pointing production mail at it.

## Features

- **AI-Powered Analysis** - Uses GPT-OSS-120B (120B parameters) for context-aware detection
- **Processing in Germany** - The AI provider is IONOS (Frankfurt/Berlin), no US transfer
- **Additive scoring** - The AI and the local heuristics only ever add a graduated, signed score (positive = spam, negative = ham) to Rspamd's own metric; Rspamd's own thresholds make the final call. The score a category may contribute is capped as a *total*, so protected categories - transactional mail, personal mail, solicited newsletters - cannot be rejected no matter how badly the AI misjudges them.
- **Two paths to rejection, both gated** - Either a structural signal independent of the model agrees (brand impersonation, a hijacked reply-to, a dangerous attachment, a fabricated ticket number, a link to the real brand domain from an unrelated sender, and others - eleven classes in total), or the model itself is very confident (≥90%) *and* Rspamd's own score clears a real bar on its own (the AI's contribution alone is capped well under the reject threshold, so Rspamd has to agree independently either way). Both paths additionally require: no trusted-sender match, no reply to an existing thread, no verified brand sender.
- **Cases the filter is unsure about get reported, not just logged** - `ai-filter-report.sh` collects contradictions (a phishing verdict on a clean sender, structural evidence on a mail that scored negative, ...) and mails them on weekdays. Newly added evidence classes start on probation - counted, reported, but unable to reject on their own until proven.
- **Trusted sender profiles** - Known shippers, marketplaces, banks and telecoms get a safe local auto-pass (no AI call, no cost) when auth is strong and headers/links align - extendable via `trusted_sender_profiles.json`.
- **Uses Rspamd's own URL reputation** - Spamhaus DBL, SURBL, URIBL, OpenPhish, PhishTank and the fresh-domain zone are queried by stock mailcow anyway; their results are folded into the analysis as risk flags. No extra service, no additional lookups, no new dependency.
- **Brand-impersonation detection, two mechanisms** - A short hand-curated list of real domains per brand catches typosquats and foreign-domain claims; a separately generated list of several thousand brand names (from the Majestic Million, see below) catches the model's own claimed-brand text against a domain that has nothing to do with it. Federated brand names (Sparkasse, Volksbank, Sparda - hundreds of independently run banks sharing one name) are deliberately excluded from the single-domain check, which is structurally wrong for that shape.
- **Fishy-TLD scoring and greylisting** - A small, operator-editable score bump for sender domains on frequently-abused top-level domains (`.shop`, `.top`, `.icu`, ...), and greylisting for anything Rspamd already finds middling - both cheap, both never block on their own.
- **The filter knows what you actually do** - Each of your own domains is classified once from its own website, and that one-line description goes into every prompt. It catches a class of fraud nothing else sees: mail that addresses you as the *provider* of a service you do not offer - a room booking at a software company, sent from a hijacked but perfectly authenticated account. Confirmations for services you bought elsewhere (hotel, flight, invoice) are explicitly excluded - every company books hotels.
- **Internal-mail detection** - Mail between two local Mailcow domains skips analysis entirely (queries the Mailcow DB for active domains).
- **Low False Positives** - "When in doubt, it's legitimate" is the guiding rule of both the local checks and the AI prompt. A fixture corpus (`tests/`) built from real false positives and real catches guards against regressions on every change.
- **Untouched by mailcow updates** - Installed into `plugins.d/`, which mailcow's update never writes to, so there is no loader line that can go missing
- **Budget Protection** - Monthly spending limits with automatic tracking
- **Privacy-conscious defaults** - Inbound mail only (your users' outgoing mail is never sent to the AI), no mail content in the logs by default, 30-day retention

## Detection Categories

`legitimate`, `transactional`, `personal`, `newsletter`, `marketing`, `clickbait`, `spam`, `pharma`, `phishing`, `fraud`

`legitimate`, `transactional` and `personal` are protected: they can only be rejected if brand impersonation co-occurs with a second independent strong signal.

## Requirements

- Mailcow dockerized installation
- IONOS account with AI Model Hub access ([Get API key](https://dcd.ionos.com/))
- Docker Compose V2
- Root access

## Quick Start

```bash
# Clone anywhere on your server
git clone https://github.com/TheUserK/mailcow-ai-spam-filtersystem.git
cd mailcow-ai-spam-filtersystem

# Install (auto-detects Mailcow directory)
sudo ./install.sh
```

The installer will:
1. Auto-detect your Mailcow installation
2. Ask for your IONOS API key
3. Embed it directly into the deployed `ai-mail-checker.php`
4. Install all components
5. Optionally start the filter

**Before you point real mail at it:** set `log_only_mode = true` in
`ai-filter-settings.lua`. The filter then runs and logs its verdicts without
changing delivery, so you can see what it would do to your actual mail flow
first. Turn it off once the results look right to you.

Rejection is active out of the box — see the warning at the top of this file
if that is not what you want.

## Configuration

There is no `config.ini` anymore. All settings live as plain constants near the
top of the deployed checker script:

`/opt/mailcow-dockerized/data/ai-checker/ai-mail-checker.php`

```php
define('AI_API_ENDPOINT_DEFAULT', 'https://openai.inference.de-txl.ionos.com/v1/chat/completions');
define('AI_API_TOKEN_DEFAULT', '...');   // filled in by install.sh
define('AI_MODEL_DEFAULT', 'openai/gpt-oss-120b');
define('MONTHLY_BUDGET_EUR', 50);
define('MAX_SPAM_POINTS', 4.0);         // max score for regular spam/marketing
define('MAX_HAM_POINTS', 3.0);          // max score deduction for confident ham
define('MAX_PHISHING_POINTS', 10.0);    // max score for phishing/fraud - deliberately below Rspamd's reject threshold (15)
```

Edit the file directly and restart the container. To add your own trusted senders (business partners, internal tools, ...) without touching the code, copy `trusted_sender_profiles.json.example` to `trusted_sender_profiles.json` in the same directory and list their domains.

Rspamd-side behavior (which score range triggers an AI call, log-only mode, sender whitelist that skips the AI call entirely) is configured in `/opt/mailcow-dockerized/data/conf/rspamd/lua/ai-filter-settings.lua`.

### Changing the model or the AI provider

Don't edit the endpoint by hand - use the helper. It verifies every change
against the live API first, and writes nothing if the test request fails:

```bash
ai-filter-model.sh                          # what is active right now
ai-filter-model.sh --models                 # what this provider offers
ai-filter-model.sh --model Qwen/Qwen3.5-397B-A17B
ai-filter-model.sh --cost 0.0016            # price per call, feeds the budget guard
ai-filter-model.sh --reasoning low          # less thinking, much faster answers
ai-filter-model.sh --timeout 25             # how long the API may take
ai-filter-model.sh --test                   # probe without changing anything
ai-filter-model.sh --reset                  # back to the shipped defaults
```

The choice is stored in `data/ai-checker/provider.conf` (root, `0600` - it
holds your API token) and takes precedence over the `_DEFAULT` constants above.
Because it is a separate file, `install.sh --reinstall` cannot silently reset it.

The API is OpenAI-compatible, so other providers work too:

```bash
ai-filter-model.sh --use hetzner
```

> [!WARNING]
> Switching provider means mail content is sent to a **different processor**.
> That needs an Art. 28 GDPR data processing agreement with them, an update to
> your Art. 30 records and to your privacy policy - before you switch, not
> after. The script states this and requires you to type the provider name; it
> cannot be waved through with Enter.

Each provider keeps its own token, so switching back does not ask again. If a
provider does not support structured outputs, the checker notices the `400` and
retries once without the schema rather than failing the analysis.

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full reference.

## How It Works

```
Incoming Email
     |
Rspamd (Traditional Filters, Score: -10 to 15)
     |
AI Content Filter (if score between -10.0 and 14.0)
     |
Internal-mail check (both sides on a local Mailcow domain?) -> skip, score 0
     |
Local precheck (trusted sender profile + strong auth + aligned headers?) -> auto-pass, score 0
     |
AI Analysis (GPT-OSS-120B, German data center) -> graduated score, positive or negative
     |
Score is ADDED to Rspamd's metric (the checker sets no action itself)
     |
Rspamd decides: Pass / Quarantine / Reject, based on the total score
```

## Monitoring

```bash
ai-filter-log.sh                  # Recent verdicts, newest last
ai-filter-log.sh -R               # Only mail that qualifies for rejection
ai-filter-log.sh -c clickbait     # Only one category
ai-filter-log.sh -f               # Follow live
ai-filter-log.sh -r -n 40         # Raw JSON, same as tail | jq
ai-filter-log.sh -n 500           # Reaches back into the rotated logs (7 days)
ai-filter-log.sh -e               # errors.log instead

ai-filter-stats.sh                # Summary: sources, categories, score spread, budget
ai-filter-test.sh                 # End-to-end check against the running checker
ai-filter-healthcheck.sh          # Health check (can run via cron)
ai-filter-model.sh                # Which model/provider is active
ai-filter-report.sh               # Cases where the filter contradicts itself
ai-filter-brands.sh --status      # Brand-domain list: size, age, last update
ai-filter-brands.sh               # Regenerate it (downloads the Majestic Million, ~80 MB)
ai-filter-context.sh --status     # What your own domains are classified as
ai-filter-context.sh              # Classify domains that have no entry yet
install.sh --check                # Same health check
```

Timestamps are printed in the server's local time. The checker itself writes
UTC, which is worth knowing when comparing against Rspamd's log.

### Sender history

`install.sh` enables two Rspamd modules that answer, locally, the question every
false positive this week came down to: *do we know this sender?*

- `replies` remembers the Message-IDs of mail you send and raises `REPLY` when
  something answers it. The strongest local ham signal there is.
- `known_senders` keeps a Redis record of senders seen before - deliberately
  only for **freemail** domains. A company domain carries reputation, DKIM and
  DMARC; gmail.com with millions of accounts carries none, and that is where
  the spam in this mailbox comes from. So the absence of `KNOWN_SENDER` on a
  business domain means nothing at all, and is not reported as a first contact.

Both are passed to the model as hints, **not** into the rejection logic, and
that is deliberate: most phishing here arrives from compromised accounts of real
organisations you may well have corresponded with. A known sender is a reason to
lean towards ham, never a free pass. Expiry is raised to 30 days - nobody
answers a quotation within 24 hours.

Neither module talks to anything outside your server.

### Brand-domain list, fishy TLDs, greylisting

`ai-filter-brands.sh` downloads the [Majestic Million](https://majestic.com/reports/majestic-million)
(top 1M sites by referring domains, CC BY 3.0 - free including commercial use,
attribution given here) and extracts brand-name tokens with their real domain
into `data/ai-checker/brand_domains.txt`. The checker uses this to catch a
mail that *claims* to be from a brand ("Ihre DHL Sendung...") sent from a
domain that has nothing to do with it - independent of the small hand-curated
brand list used for typosquat detection.

This list is generated locally on your server and is **not shipped in the
repo** - only the generator script is. `install.sh` builds it once on
install and schedules a weekly refresh (`/etc/cron.d/ai-filter-brands`,
Sundays 04:00). To run it by hand:

```bash
ai-filter-brands.sh              # download + rebuild (~80 MB download)
ai-filter-brands.sh --status     # size and age of the current list
ai-filter-brands.sh --debug      # read/kept/dropped counts, for troubleshooting
```

An install with fewer than 1000 entries is treated as damaged by `install.sh
--upgrade` and rebuilt automatically.

`AI_FILTER_FISHY_TLD` (Rspamd multimap, weight 2.5) adds a small score bump
for sender domains on top-level domains that are frequently abused for spam
(`.shop`, `.top`, `.icu`, ...). The list is yours to edit:
`data/conf/rspamd/ai-filter-tlds.map`. Never enough on its own to change the
outcome.

Greylisting (`greylisting.conf`, threshold 4.0) delays first-contact mail
that Rspamd already finds middling by a few minutes - long enough that most
spam sources, which never retry, give up. Legitimate senders retry
automatically and are not asked twice. This adds latency to some first
contacts, which is worth knowing if you have time-sensitive inbound mail.

### What your own business actually does

Until now the filter judged every mail without knowing who it was for. That
blind spot is what one campaign lives on: on 04.09. four nearly identical
German room-booking enquiries arrived within twenty minutes - from a British
accountancy firm, a Portuguese IT company, a Romanian hotel and a Brazilian
oil mill. Every sender domain real, every one properly authenticated (hijacked
accounts), Rspamd unremarkable, the model's verdict "personal" at -2.16. The
only thing wrong with them: the recipient does not rent out rooms.

`ai-filter-context.sh` fetches each of your own domains' website, follows only
links that actually appear on the page (same domain, nothing guessed), and has
the model describe in one sentence what the business does. The result lands in
`data/ai-checker/business_context.json` and goes into every later prompt.

```bash
ai-filter-context.sh              # classify domains that have no entry yet
ai-filter-context.sh --refresh    # redo all of them
ai-filter-context.sh --status     # what is currently stored
```

`install.sh` runs it once and schedules a weekly pass so domains you add to
mailcow later get picked up; anything still missing an entry also shows up in
the contradiction report. **Read the result once** - the model only sees a
website and can be wrong. To correct an entry, edit its description and set
`"manuell": true`; no later run will touch it again. A domain with no
reachable website is recorded as private, which is a usable statement in
itself.

What matters is the *role*, not the topic: being asked to provide something
you don't offer is the signal. A hotel confirmation, a flight ticket or an
invoice for something you bought yourself is ordinary business mail and is
explicitly excluded, as are applications, press enquiries and official mail.

### The contradiction report

Every mistake this filter has had was found the same way: somebody read a log
line, thought it looked odd, and it turned out to be a bug. That is luck as a
method.

The filter knows its own doubtful cases, though - a phishing verdict on a
DMARC-clean sender, a rejection in a category that has never fired before, a
high Rspamd score the AI called legitimate, structural evidence on a mail that
scored negative. Those patterns are exactly where the real false positives were
found. `ai-filter-report.sh` collects them.

```bash
ai-filter-report.sh                       # print the last 24 hours
ai-filter-report.sh -d 7                  # a whole week
ai-filter-report.sh --set-to you@example.com
ai-filter-report.sh --disable             # stop the mail, keep the tool
```

`install.sh` schedules it for weekdays at 08:00. **Nothing to report means no
mail** - silence is the normal state, so there is nothing to tune out.

Mail is injected straight into mailcow's Postfix container, so it needs no
mailbox, no credentials and no SMTP login. Point it at an address on a
*different* server than the one it watches: if delivery breaks, you want the
report about it to still arrive.

## Mailcow updates

The filter itself cannot be lost. It lives in
`data/conf/rspamd/plugins.d/ai-content-filter.lua` - untracked by mailcow's
repository, and `update.sh` commits only tracked files and runs no
`git clean`, so nothing in the update touches it.

Placing the file there is not sufficient on its own. Rspamd treats anything
in `plugins.d` as a module and disables any module that has no configuration
section of its own:

```
lua module ai-content-filter is enabled but has not been configured
ai-content-filter disabling unconfigured lua module
```

So the installer also adds a two-line section to
`data/conf/rspamd/rspamd.conf.local`. That file is tracked, but mailcow ships
it as an empty stub for exactly this purpose and does not develop it, so a
merge conflict would require mailcow to start writing to it. That is a much
smaller exposure than the previous arrangement, which appended a loader line
to `rspamd.local.lua` - a nine-hundred-line file mailcow works on
continuously.

If that section is ever lost, the filter goes quiet rather than breaking
loudly, so the health check verifies it explicitly.

A cron health check is still worth having, for the checker container and the
API key rather than for the filter:
```
*/30 * * * * /usr/local/bin/ai-filter-healthcheck.sh > /dev/null 2>&1
```

## Upgrading

```bash
cd mailcow-ai-spam-filtersystem
git pull
sudo ./install.sh --upgrade       # Carries your existing API key over
```

Use `--upgrade`, not a plain `install.sh`: without it the installer does not
look for your existing API key and will ask for it again.

What the upgrade replaces, and what it leaves alone:

| | |
|---|---|
| Replaced | `ai-mail-checker.php` (your API key is read out first and put back), `router.php`, `Dockerfile`, `ai-content-filter.lua`, the scripts in `/usr/local/bin` |
| Kept | `ai-filter-settings.lua`, `trusted_sender_profiles.json`, `business_context.json`, `brand_domains.txt` (rebuilt only if under 1000 entries), `ai-filter-tlds.map`, `greylisting.conf`, your `groups.conf` and `rspamd.local.lua` entries |
| Offered | `docker-compose.override.yml` - only updated after you confirm, and only if `ai-checker` is the sole service in it. A backup is written either way. If the file defines other services, the installer prints what to merge and changes nothing |

The override matters: it carries the build context that brings `pdo_mysql`
into the container. An install left on an older override keeps running, but
internal-mail detection stays broken because the PHP driver is missing.

## Uninstallation

```bash
sudo ./uninstall.sh
```

## Privacy & GDPR/DSGVO

### What is sent where

For every mail that actually reaches the AI stage, the following is sent to
IONOS (Frankfurt/Berlin):

| Data | Detail |
|---|---|
| Sender | From header, display name, From/Reply-To/Return-Path domains |
| Subject | full |
| Body | plain text, truncated to 3000 characters |
| Link domains | up to 15 |
| Attachment names | filenames only, never the files |
| Technical signals | Rspamd score, SPF/DKIM/DMARC results, risk/trust flags |

Most mail never gets that far - internal mail, trusted-sender auto-passes and
a decisive Rspamd score all skip the AI call entirely.

**Outgoing mail from your own authenticated users is never analysed** and
never reaches the AI provider.

### Logging

- Logging is **pseudonymised, not anonymised**: `and***@example.com` keeps the
  full domain and stays personal data under GDPR.
- **Subject lines are logged by default** (`LOG_SUBJECT`). Without them a log
  line cannot be judged - "spam, +6.84, from some Hotmail address" tells nobody
  whether the verdict was right, and reviewing verdicts is how this filter gets
  corrected. Set `LOG_SUBJECT` to `false` if you would rather not.
- **Body excerpts are not logged** (`LOG_MAIL_CONTENT`, default `false`). A body
  says far more about the content than a subject line does, and it is not needed
  to check a verdict. Turn it on for temporary debugging only.
- Log files are created `0600`, the log directory `0700`.
- **30-day retention** via logrotate.
- Note what this means: a log entry outlives the recipient deleting the mail,
  and it travels into your backups. For your Art. 30 record: purpose is quality
  assurance of the spam filter, retention 30 days, access root only.

### What you still have to do

This project cannot make you compliant on its own. As the controller you need:

- an **AVV/DPA with IONOS** (they offer one - it has to be actually concluded)
- an entry in your **records of processing activities** (Art. 30)
- a mention in your **privacy policy** - note that senders are affected too,
  and they never consented
- a documented **legitimate interest assessment** (Art. 6 (1) f)
- for employee mailboxes: check **works council** involvement and whether
  private use of the mailbox is allowed
- consider that mail from e.g. pharmacies can contain **Art. 9 data**, for
  which legitimate interest is not a sufficient basis

Verify IONOS' current terms yourself regarding training use of submitted data -
do not rely on this README for that.

## Cost Estimate

**Typical setup (1000 emails/day):**
- Most emails skip the AI call entirely: decisive Rspamd score, internal mail, or a trusted-sender auto-pass
- Only ambiguous mail reaches the AI
- Monthly cost: ~EUR 5-10 (after free period)

Default budget limit: EUR 50/month (~147,000 API calls)

## Documentation

- [Configuration Guide](docs/CONFIGURATION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## License

MIT License - see [LICENSE](LICENSE)

## Credits

- Built for [Mailcow](https://mailcow.email/)
- Powered by [IONOS AI Model Hub](https://cloud.ionos.com/managed/ai-model-hub)
