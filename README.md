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
> `ionos-mail-checker.php` and restart the container. Qualifying mail is then
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
- **Rejection needs a second source** - Only unsolicited bulk can reach the reject threshold, and only when a structural signal that does not come from the AI agrees: cloud-storage-only links, brand impersonation, a blocklist hit, a dangerous attachment or a URL shortener. Plus no trusted-sender match and no reply to an existing thread.
- **Trusted sender profiles** - Known shippers, marketplaces, banks and telecoms (DHL, Amazon, PayPal, Telekom, ...) get a safe local auto-pass (no AI call, no cost) when auth is strong and headers/links align - extendable via `trusted_sender_profiles.json`.
- **Uses Rspamd's own URL reputation** - Spamhaus DBL, SURBL, URIBL, OpenPhish, PhishTank and the fresh-domain zone are queried by stock mailcow anyway; their results are folded into the analysis as risk flags. No extra service, no additional lookups, no new dependency.
- **Brand-impersonation detection** - Catches "PayPal" or "DHL" claimed in the sender name/address when the domain doesn't actually belong to that brand (typosquats and foreign domains).
- **Internal-mail detection** - Mail between two local Mailcow domains skips analysis entirely (queries the Mailcow DB for active domains).
- **Low False Positives** - "When in doubt, it's legitimate" is the guiding rule of both the local checks and the AI prompt.
- **Update-Resilient** - Survives Mailcow updates, includes health check and auto-repair
- **Budget Protection** - Monthly spending limits with automatic tracking
- **Privacy-conscious defaults** - Inbound mail only (your users' outgoing mail is never sent to the AI), no mail content in the logs by default, 7-day retention

## Detection Categories

Legitimate, Spam, Phishing, Fraud, Pharma, Marketing

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
3. Embed it directly into the deployed `ionos-mail-checker.php`
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

`/opt/mailcow-dockerized/data/ionos-checker/ionos-mail-checker.php`

```php
define('IONOS_API_ENDPOINT', 'https://openai.inference.de-txl.ionos.com/v1/chat/completions');
define('IONOS_API_TOKEN', '...');       // filled in by install.sh
define('IONOS_MODEL', 'openai/gpt-oss-120b');
define('MONTHLY_BUDGET_EUR', 50);
define('MAX_SPAM_POINTS', 4.0);         // max score for regular spam/marketing
define('MAX_HAM_POINTS', 3.0);          // max score deduction for confident ham
define('MAX_PHISHING_POINTS', 10.0);    // max score for phishing/fraud - deliberately below Rspamd's reject threshold (15)
```

Edit the file directly and restart the container. To add your own trusted senders (business partners, internal tools, ...) without touching the code, copy `trusted_sender_profiles.json.example` to `trusted_sender_profiles.json` in the same directory and list their domains.

Rspamd-side behavior (which score range triggers an AI call, log-only mode, sender whitelist that skips the AI call entirely) is configured in `/opt/mailcow-dockerized/data/conf/rspamd/lua/ai-filter-settings.lua`.

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
ionos-stats.sh                    # View statistics
ionos-test.sh                     # Quick API test
ai-filter-healthcheck.sh          # Health check (can run via cron)
install.sh --check                # Full installation check
```

## After Mailcow Updates

The filter is designed to survive updates. If something breaks:

```bash
ai-filter-repair.sh               # Auto-repairs the filter
```

For automatic monitoring, add to crontab:
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

If you want every component brought to the shipped version instead, use
`--reinstall`. It keeps your API key and `trusted_sender_profiles.json` and
overwrites everything else - settings, the rspamd `ai_filter` group and the
compose override - writing a backup of each file it touches. Other groups in
`groups.conf` and other services in the override file are left alone.

What the upgrade replaces, and what it leaves alone:

| | |
|---|---|
| Replaced | `ionos-mail-checker.php` (your API key is read out first and put back), `router.php`, `Dockerfile`, `ai-content-filter.lua`, the scripts in `/usr/local/bin` |
| Kept | `ai-filter-settings.lua`, `trusted_sender_profiles.json`, your `groups.conf` and `rspamd.local.lua` entries |
| Offered | `docker-compose.override.yml` - only updated after you confirm, and only if `ionos-checker` is the sole service in it. A backup is written either way. If the file defines other services, the installer prints what to merge and changes nothing |

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
- Subject and body excerpts are **not logged by default**. Set
  `LOG_MAIL_CONTENT` to `true` in `ionos-mail-checker.php` only for temporary
  debugging.
- Log files are created `0600`, the log directory `0700`.
- 7-day retention via logrotate.

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
