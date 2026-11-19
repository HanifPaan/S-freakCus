# threat_watch

Every 3 hours, threat_watch logs what visitors from chosen countries (default Indonesia) and **suspicious visitors from any country** did on your cPanel sites. It only reports. Nothing is blocked.

## Files

| File | What it is |
|---|---|
| `threat_watch.sh` | the code |
| `threat_watch.conf` | the settings (default copy) |
| `install.sh` | one-line installer |

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s intellia
```

This downloads the newest `threat_watch-vX.Y.Z` release, sets up the cron jobs, and does a first run. You can list several users (`bash -s user1 user2`), or none and set them in the settings file afterwards. Running the installer again never overwrites your settings.

| Installed to | |
|---|---|
| `/opt/threat_watch/threat_watch.sh` | code (command: `threat_watch`) |
| `/etc/threat_watch/threat_watch.conf` | your settings |
| `/etc/threat_watch/threat_watch.conf.default` | the newest default settings, for reference |
| `/etc/cron.d/threat_watch` | run every 3 hours, update check every Sunday |

## Commands

| Command | What it does |
|---|---|
| `threat_watch run` | check new log lines now |
| `threat_watch update` | update the code to the newest release (also runs every Sunday) |
| `threat_watch test-ip 1.2.3.4` | show an IP's country |
| `threat_watch uninstall` | remove the code and cron (`--purge` also removes logs and settings) |
| `threat_watch version` | show the installed version |

Updates replace only `threat_watch.sh`. Settings and logs are never touched.

## Settings: `/etc/threat_watch/threat_watch.conf`

| Setting | Meaning |
|---|---|
| `SCOPE` | `all` (every cPanel user), `users` or `domains` |
| `USERS` / `DOMAINS` | which users or domains to check |
| `WATCH` | countries to log, e.g. `"ID"` or `"ID GM"` |
| `WHITELIST` | countries whose normal visits are not logged (suspicious ones still are) |
| `WHITELIST_IPS` | IPs that are never logged |
| `BAD_REQUESTS` / `BAD_AGENTS` | what counts as suspicious (regex) |
| `PHP_404_LIMIT` | `.php` 404s in one run that make a visitor suspicious |
| `KEEP_DAYS` | delete reports older than this |

Changes apply on the next run.

## Logs

```
/var/log/threat_watch/user/<user>/latest.txt           newest report
/var/log/threat_watch/user/<user>/YYYY-MM-DD_HHMM.txt   one per run (only when something was found)
/var/log/threat_watch/domain/<domain>/...               same, when SCOPE="domains"
/var/log/threat_watch/run.log                           one line per run
/var/log/threat_watch/update.log                        every update check (manual / auto, old -> new version)
```

## Releasing a new version

1. Change `VERSION="x.y.z"` at the top of `threat_watch.sh`.
2. Create a GitHub release tagged `threat_watch-vx.y.z` and attach **`threat_watch.sh`** and **`threat_watch.conf`**.
3. Servers update themselves on Sunday, or straight away with `threat_watch update`.

## Notes

- Only new log lines are read each run. Positions and the country list are kept in `/var/lib/threat_watch/`.
- The country list is downloaded once a week from the official internet registries.
- Only IPv4 addresses get a country. IPv6 visitors are still checked for suspicious requests.
