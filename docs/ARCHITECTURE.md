# Architecture

## Design Principle (v3)

The checker never sets an action itself, neither the local heuristics nor
the AI. Both only ever return a graduated, signed score - positive pushes
towards spam, negative pushes towards ham - which gets **added** to Rspamd's
own metric.

That is a statement about the mechanism, not a promise that nothing is ever
rejected: for unsolicited bulk the score may deliberately be large enough
that Rspamd's own reject threshold is crossed. The guarantee lies in the
caps below, not in the fact that we only return a number. Rspamd's own action thresholds (defaults: reject around 15,
quarantine lower) make the final call based on the *total* score, same as
for every other Rspamd rule.

What the checker controls is how far it may push that total, and it decides
that from the category. Protected categories - `legitimate`, `transactional`,
`personal`, `newsletter`, `marketing` - are capped below the reject
threshold, so no misjudgement of a real order confirmation or a personal
message can discard it; the worst case is the junk folder. `legitimate`,
`transactional` and `personal` can only be broken open by the category
override below.

Only unsolicited bulk (`clickbait`, `spam`, `pharma`, `phishing`, `fraud`) may
go further, and never on the model's word alone. There are two ways in:

- **Evidence path** - confidence >= 0.80 and at least one structural signal
  established outside the model (see `strongEvidence()` in
  [CONFIGURATION.md](CONFIGURATION.md#evidence-strong-and-weak) - brand
  impersonation, a blocklist hit, a hijacked reply-to, a fabricated ticket,
  and eight others).
- **AI-confident path** - confidence >= 0.90 *and* the model's own raw score
  >= 7.0, with no structural signal required. The model's contribution alone
  is still capped well under the reject threshold, so Rspamd's own score has
  to independently supply the rest for the total to actually cross it.

A protected category can be broken open by the evidence path only when
`brand-impersonation` fires together with a second, independent strong
signal (the **category override** - a single brand-list match alone still
protects `legitimate`/`transactional`/`personal`).

Either way, no trusted-sender match and no reply to an existing thread (a
forgeable `In-Reply-To` header is not enough by itself - see
`partOfRealConversation()`) are required. A single wrong verdict therefore
cannot throw mail away - a second, independent source always has to agree.
See [CONFIGURATION.md](CONFIGURATION.md#two-paths-to-the-reject-threshold)
for the full mechanics.

## System Overview

```
Incoming Email
     |
     v
+---------------------+
| Rspamd              |
| Traditional Filters |
| Score: -10 to 15    |
+----------+----------+
           |
           v (Postfilter, if score -10.0 to 14.0)
+---------------------+
| AI_CONTENT_FILTER   |
| Lua Module          |
| (ai-content-filter  |
|  .lua)              |
+----------+----------+
           |
           v (HTTP POST, internal network)
+---------------------+
| PHP Checker         |
| ai-checker:8080  |
| (ai-mail-checker    |
|  .php)              |
+----------+----------+
           |
           +--> internal mail (both sides local)?      -> score 0, done
           |
           +--> trusted sender profile + strong auth +
           |    aligned headers/links?                 -> local auto-pass, score 0, done
           |
           v (otherwise)
+---------------------+
| AI Provider         |
| (IONOS AI Hub)       |
| GPT-OSS-120B         |
| Frankfurt/Berlin     |
+----------+----------+
           |
           v (JSON: spam_probability, confidence, category)
+---------------------+
| Graduated score      |
| (+points for spam/   |
|  phishing, -points   |
|  for confident ham)  |
+----------+----------+
           |
           v (score ADDED to Rspamd's metric, never a direct action)
+---------------------+
| Rspamd Final Action |
| Pass / Quarantine   |
| / Reject             |
| (based on total      |
|  score, incl. every  |
|  other Rspamd rule)  |
+---------------------+
```

## Components

### 1. Docker Container (ai-checker)
- **Image:** built from `php:8.4-cli` + `pdo_mysql` (the official image does not ship it, and the internal-mail lookup needs it)
- **Network:** mailcow-network (internal), plus reaches the mailcow `mysql` container for internal-mail detection
- **Health:** HTTP /health endpoint
- **Resources:** ~50MB RAM, minimal CPU
- **Config:** constants at the top of `ai-mail-checker.php` (no config.ini)

### 2. PHP Script (ai-mail-checker.php)
- Receives email context via HTTP POST from Rspamd (from/to, headers, SPF/DKIM/DMARC results, URLs, attachments, content stats, ...)
- Checks whether both sides are local Mailcow domains (Mailcow DB lookup) -> skip
- Matches the sender against built-in + custom trusted sender profiles (shippers, marketplaces, banks, telecoms) and checks Reply-To/Return-Path/Message-Id/link-domain alignment -> safe auto-pass if everything lines up and auth is strong
- Checks for brand impersonation via three mechanisms: a hand-curated list of real brand domains (typosquat/foreign-domain), a generated list of several thousand brands from the Majestic Million (`knownBrandDomains()`), and a weaker word-match fallback (`claimedBrandMismatch()`) - see [CONFIGURATION.md](CONFIGURATION.md#brand-impersonation-three-paths)
- Turns Rspamd's URL-reputation symbols into risk flags. A blocklist hit also blocks the trusted-sender auto-pass, since even a genuine sender can link a compromised subdomain
- Computes all structural evidence once (`structuralSignals()`/`collectStructuralEvidence()`) - fake threads, hijacked reply-to, fabricated tickets, role claims on freemail, free-hosting links, and more - shared between the AI prompt's risk flags and the reject-eligibility check, so the two can never drift apart
- Otherwise calls the AI with a compact prompt built from the mail + the local risk/trust flags, and turns `spam_probability` + `confidence` + `category` into a bounded, signed score
- Applies the reject-eligibility conjunction, the category override, the junk floor and the two reject paths (see [Design Principle](#design-principle-v3) above)
- Manages budget tracking
- Never returns a `reject` action - always `add` (or `pass` for the two skip cases above), with a numeric score for Rspamd to add

### 3. Rspamd Lua Filter (ai-content-filter.lua)
- Installed in `plugins.d/`, auto-loaded by rspamd as a module (needs the two-line section in `rspamd.conf.local` to not be disabled as "unconfigured" - see [Update Resilience](#update-resilience) below)
- Reads settings from `ai-filter-settings.lua`, which stays in `lua/` and is loaded explicitly via `loadfile()`, not auto-loaded
- Postfilter stage (priority 10)
- Skips authenticated senders, so outgoing mail from your own users is never sent to the AI provider
- Skips mail re-delivered by the server's own sieve forwarding (`SIEVE_HOST`, `LOCAL_OUTBOUND`). It was already analysed on ingress with the authentication intact, which forwarding destroys - a forwarded legitimate mail otherwise presents exactly the signature of a forged one
- Checks the Lua-level sender whitelist before making any API call at all (saves cost)
- Gathers SPF/DKIM/DMARC results, Reply-To/Return-Path/Message-Id, List-Unsubscribe/List-Id, forged-sender signals, URLs/link-domains, attachments and content stats from the task, and sends them to the PHP checker
- Also forwards the URL reputation Rspamd has already established for the mail (Spamhaus DBL, SURBL, URIBL, OpenPhish, PhishTank, and the SEM fresh-domain zone). These lookups happen anyway as part of stock mailcow - reading their symbols costs nothing and adds no dependency
- Adds the returned score directly to the `AI_CONTENT_SCORE` symbol (no more weight division or forced reject - the number the checker returns *is* the Rspamd score delta)
- Supports log-only mode (calls the checker, logs what it would have added, but doesn't apply it)

### 4. Two independent Rspamd modules, not the checker
- `AI_FILTER_FISHY_TLD` (multimap, weight 2.5): sender domain on an abused TLD (`.shop`, `.top`, `.icu`, ...), list at `data/conf/rspamd/ai-filter-tlds.map`. Never blocks alone
- Greylisting (`data/conf/rspamd/local.d/greylisting.conf`, threshold 4.0): delays first-contact mail Rspamd already finds middling by a few minutes

### 5. AI Analysis
- Model: GPT-OSS-120B (120B parameters)
- Returns `spam_probability` (0-1), `confidence` (0-1), a `category` (`legitimate`/`transactional`/`personal`/`newsletter`/`marketing`/`clickbait`/`spam`/`pharma`/`phishing`/`fraud`) and `claimed_brand` (free text - who the mail claims to be from, used by the list-free brand-impersonation path)
- The category caps how far the score can swing: attackable categories can go up to `MAX_PHISHING_POINTS` (10 - high enough to reach reject together with other signals, low enough never to get there alone), everything else is capped at `MAX_SPAM_POINTS` (4) on the spam side and `MAX_HAM_POINTS` (3) on the ham side

## File Structure

```
/opt/mailcow-dockerized/
+-- data/
|   +-- ai-checker/
|   |   +-- ai-mail-checker.php           # PHP analysis script (incl. API key + all config constants)
|   |   +-- router.php                       # HTTP router
|   |   +-- provider.conf                    # active model/provider (root 0600, not in git)
|   |   +-- brand_domains.txt                # generated Majestic-Million brand list (not shipped, not in git)
|   |   +-- trusted_sender_profiles.json.example  # template for custom trusted senders
|   |   +-- trusted_sender_profiles.json     # your custom trusted senders (optional, not shipped)
|   +-- conf/rspamd/
|   |   +-- plugins.d/
|   |   |   +-- ai-content-filter.lua   # Main filter logic, untracked, auto-loaded as a module
|   |   +-- rspamd.conf.local       # Two-line section enabling the module above (tracked mailcow stub)
|   |   +-- lua/
|   |   |   +-- ai-filter-settings.lua  # Filter settings, loaded via loadfile()
|   |   +-- local.d/
|   |   |   +-- groups.conf         # Symbol group definition
|   |   |   +-- multimap.conf       # Fishy-TLD scoring entry
|   |   |   +-- greylisting.conf    # Greylisting settings
|   |   +-- ai-filter-tlds.map      # Fishy-TLD list, operator-editable
|   +-- logs/ai-checker/
|       +-- stats.log               # Analysis results
|       +-- errors.log              # Error events
|       +-- monthly_budget.json     # Budget tracking
+-- docker-compose.override.yml     # Container definition
```

`tests/` in this repo (not deployed) holds a fixture corpus (`fixtures.php` +
`run-fixtures.sh`) that runs real false positives and real catches through a
router-stripped copy of the checker on every change, to guard against
regressions.

## Score Calculation

```
direction = (spam_probability - 0.5) * 2      -- -1 .. +1
magnitude = |direction| * confidence          --  0 .. 1

score =  magnitude * max_spam_points   if direction >= 0   (spam/phishing/fraud/pharma/clickbait)
score = -magnitude * MAX_HAM_POINTS    if direction <  0   (confident ham)
```

That raw score is then subject to the category ceiling, the reject paths and
the junk floor described under [Design Principle](#design-principle-v3) above
before it is added to Rspamd's metric.

`max_spam_points` is `MAX_PHISHING_POINTS` (10) for the attackable categories
(`clickbait`/`spam`/`pharma`/`phishing`/`fraud`), otherwise `MAX_SPAM_POINTS`
(4). A detected brand impersonation via the hand-curated list (typosquat or
foreign domain claiming a known brand) adds its own fixed score on top and
blocks the AI from rescuing the mail into a negative (ham) score.

This score is inserted into Rspamd's `AI_CONTENT_SCORE` symbol as-is - no
weight division, no forced reject. Rspamd's normal metric/action
configuration decides what happens once all symbols (including this one)
are summed up.

## Update Resilience

The filter is a single untracked file in `data/conf/rspamd/plugins.d/`,
enabled by a two-line section in `data/conf/rspamd/rspamd.conf.local`.

Both parts are needed. `plugins.d` is listed as `try_path` in rspamd's
`modules` section, so the file is found - but rspamd treats it as a module
and disables any module without a configuration section of its own. A
`local.d/<name>.conf` does not work for custom modules; the section has to be
at top level, which is what `rspamd.conf.local` is for.

Why that survives, from mailcow's `update.sh`:

- it commits only **tracked** files (`git add -u`, `git commit -am`) before
  updating, so untracked files are never part of the commit
- it merges with `git merge -X theirs`, meaning mailcow's version wins any
  conflict - which is why a line appended to the tracked `rspamd.local.lua`
  is unreliable
- it runs no `git clean`, so untracked files are never removed

The settings file stays in `lua/`, also untracked, and is read explicitly by
the filter via `loadfile()` rather than being auto-loaded - keeping it out of
`plugins.d` avoids depending on load order.

## Budget Protection

- Monthly limit configurable (default: EUR 50, `MONTHLY_BUDGET_EUR` constant)
- Per-call cost tracking against `AVG_COST_PER_CALL_EUR`
- Auto-reset on new month
- Budget exceeded: mail passes through with score 0 (fail-open)

## Privacy & GDPR/DSGVO

- All AI processing in German data centers (IONOS Frankfurt/Berlin)
- No data used for AI model training
- Pseudonymised logging (first 3 chars + ***); subject/body excerpts are off by default (`LOG_MAIL_CONTENT`)
- Log files `0600`, log directory `0700`
- 30-day log retention (configurable via logrotate)
- Outbound mail from authenticated users is never analysed
- AVV/DPA available from IONOS
