# threat_watch

Every few hours, threat_watch reads the **new** lines in a cPanel account's Apache domlogs and finds the visitors from the countries you choose (Indonesia by default). It sorts each visitor into one of five categories:

| Category | Meaning |
|---|---|
| **attack** | exploit uploads (JCE, AcyMailing), webshell access, PHP run from `tmp/` / `images/` / `media/`, code/SQL injection in the URL |
| **scanner** | probing: `.git`/`.env`, CMS version files, backups, phpMyAdmin, hacking tools, many `.php` 404s |
| **fake_bot** | claims to be Googlebot/Bingbot/... but comes from a watched country |
| **bot** | known crawlers (Semrush, Ahrefs, Telegram, ...) |
| **normal** | everything else |

It only writes reports. It never blocks anything.

It needs **Python 3.6+ with the standard library only**, so there's nothing to `pip install`. It runs on CentOS 7, AlmaLinux 8/9 and CloudLinux with cPanel.

---

## How a run works

```
cron (every 3h) -> lock -> read only new log lines -> country lookup per unique IP
               -> classify watched visitors -> write reports -> delete old reports
```

- **Incremental.** Each log's inode and byte offset are saved in `STATE_DIR`. The next run continues from there, and half-written lines wait for the next run.
- **Rotation safe.** When cPanel rotates a log between runs, the lines written before the rotation are read back from `~/logs/<log>-Mon-YYYY.gz`, using the last timestamp so nothing is counted twice.
- **Local country lookup.** The country table is built from the official RIR delegation files (APNIC, RIPE, ARIN, AFRINIC, LACNIC) once a week. There are no per-IP API calls. A MaxMind/DB-IP `.mmdb` file through `mmdblookup` is also supported.
- **Cheap.** It runs under `nice 19` and `ionice idle` with a 10-minute hard limit. A few MB of new log lines take about 1–3 s of CPU.

## Install

```bash
git clone https://github.com/<you>/threat-watch.git
cd threat-watch
sudo ./install.sh --account exampleuser            # code -> /opt/threat_watch, config, cron every 3h
```

Then:

```bash
C=/etc/threat_watch/exampleuser.conf
sudo nano $C                                        # check WATCH_COUNTRIES / WHITELIST_*
sudo /opt/threat_watch/threat_watch.sh -c $C --validate
sudo /opt/threat_watch/threat_watch.sh -c $C --refresh-geo     # build the country table (~1 min)
sudo /opt/threat_watch/threat_watch.sh -c $C --test-ip 140.213.184.73 175.136.5.5
sudo /opt/threat_watch/threat_watch.sh -c $C --dry-run --details   # preview, saves nothing
sudo /opt/threat_watch/threat_watch.sh -c $C --stdout              # first real run
```

To add another account, run `sudo ./install.sh --account otheruser`. Each account gets its own config, state and cron entry.

### Upgrade

```bash
cd threat-watch && git pull            # or download a release tarball
sudo ./install.sh --upgrade            # replaces code + shipped rules, keeps configs and local rules
```

### Uninstall

```bash
sudo ./install.sh --account exampleuser --uninstall          # remove cron
sudo ./install.sh --account exampleuser --uninstall --purge  # ...and its state
```

## Reports

These are written to `OUTPUT_DIR`, by default `/home/<account>/logs/threat_watch/`:

```
2026-11-19_1205_summary.txt      per run: totals, per-domain table, suspicious IPs, top normal visitors, bots
2026-11-19_1205_suspicious.txt   per run (only if any): per IP reasons, user-agents, sample log lines
2026-11-19_1205_suspicious.csv   same, for spreadsheets / scripts
latest_summary.txt               copy of the newest summary
repeat_offenders.txt             IPs flagged in several runs (kept REPEAT_KEEP_DAYS days)
threat_watch.log                 what each run did (files, lines, warnings)
```

**Hits** are attack requests that got an HTTP 2xx response. Treat any hit as a possible successful upload or shell, and check that path on disk.

Per-run reports older than `RETENTION_DAYS` (30) are deleted automatically.

## Configuration

See [`threat_watch.conf.example`](threat_watch.conf.example). Every setting is documented there. The main ones:

| Setting | Default | Notes |
|---|---|---|
| `WATCH_COUNTRIES` | `ID` | ISO codes, space separated, e.g. `"ID GM CN"`, or `ALL` |
| `WHITELIST_COUNTRIES` | `MY` | never analysed or reported |
| `WHITELIST_IPS` / `WHITELIST_CIDRS` | localhost | your office, monitoring, the server itself |
| `DOMAINS` | all | limit to some domains of the account |
| `OUTPUT_DIR` | `/home/<account>/logs/threat_watch` | reports |
| `STATE_DIR` | `/var/lib/threat_watch` | positions, country table, history |
| `GEO_PROVIDER` | `rir` | or `mmdb` with `GEO_MMDB_FILE` |
| `SCANNER_404_THRESHOLD` | `20` | `.php` 404s per run that make a visitor a scanner |
| `DISABLED_RULES` | | e.g. `wordpress_probe` if a site runs WordPress |

Run `--validate` after editing. It catches typos, bad country codes and bad regexes.

## Rules

The rules are plain text files in `rules/`, with one rule per line: `<rule_name> <regex>`. They're matched case-insensitively. The first match wins, and attack rules are checked before scanner rules, which are checked before bot rules.

| File | Matched against |
|---|---|
| `attack.rules` | `"METHOD URL"`, e.g. `POST /index.php?option=com_jce` |
| `scanner.rules` | `"METHOD URL"` |
| `scanner_ua.rules` | User-Agent |
| `bot_ua.rules` | User-Agent (rule name = bot name in the report) |

To tune them without losing your changes on upgrade, use `/etc/threat_watch/rules.local/` (the `LOCAL_RULES_DIR` setting):

- **Add a rule:** put a new `name regex` line in `rules.local/<kind>.rules`.
- **Change a shipped rule:** use the **same name** in `rules.local/<kind>.rules`.
- **Turn a rule off:** add its name to `DISABLED_RULES` in the config.

## Commands

```
threat_watch.sh -c CONF                 normal run (what cron does)
threat_watch.sh -c CONF --stdout        normal run, also print the summary
threat_watch.sh -c CONF --dry-run       analyse + print; no state, no reports
threat_watch.sh -c CONF --dry-run --details
threat_watch.sh -c CONF --since-start   re-read live logs from the beginning
threat_watch.sh -c CONF --validate      check config and rules
threat_watch.sh -c CONF --refresh-geo   rebuild the country table now
threat_watch.sh -c CONF --test-ip IP..  show country and decision for IPs
threat_watch.sh --version
```

Exit codes: `0` ok, `1` config error, `2` security refusal, `3` country table unavailable. When another run is still going, the new run exits `0` with a notice.

## Security notes

`/home/<account>/logs` belongs to the account user, so if the site is compromised the attacker can write there too. A root script that writes into a folder the attacker controls is dangerous, because it can be tricked through symlinks. threat_watch guards against this:

- The reports folder must be **owned by root, not group/world-writable, and not a symlink**. If not, the run stops with exit `2`.
- Every file is written **inside that folder by file descriptor, with `O_NOFOLLOW`, then atomically renamed**, so a planted symlink is replaced rather than followed.
- State (positions, history, country table) lives in `/var/lib/threat_watch/`, which the account can't reach.
- Log text in the reports is sanitised. Control characters and bidi overrides are shown as `\x..`, so a crafted User-Agent can't mess with your terminal. CSV cells starting with `= + - @` are prefixed with `'`.
- Rotated archives are opened with `O_NOFOLLOW` and capped at `ARCHIVE_MAX_MB`.

## Development and releases

```bash
bash tests/run_tests.sh        # end-to-end tests with fixture logs, no network, no root
```

The release flow:

1. Update `VERSION` and add a section to `CHANGELOG.md` (`## [1.1.0] - YYYY-MM-DD`).
2. Commit, then `git tag v1.1.0 && git push --tags`.
3. GitHub Actions (`.github/workflows/release.yml`) runs the tests, checks that the tag matches `VERSION`, and publishes `threat_watch-1.1.0.tar.gz` with its SHA-256 and the changelog section as release notes.

Versioning follows [SemVer](https://semver.org/): new rules or settings are a minor release, fixes are a patch, and config or report format changes that break things are a major release.
