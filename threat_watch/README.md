# threat_watch

Every 3 hours, threat_watch logs what visitors from chosen countries (default Indonesia) and **suspicious visitors from any country** did on your cPanel sites. It only reports. Nothing is blocked.

## Files

| File | What it is |
|---|---|
| `threat_watch.sh` | the code |
| `threat_watch.conf` | the settings (default copy) |
| `setup.sh` | install/upgrade steps |
| `install.sh` | one-line installer for threat_watch and kicks, stays in the repo |

`threat_watch.sh`, `threat_watch.conf` and `setup.sh` are attached to every threat_watch release. kicks releases carry `kicks.py`, `kicks.conf` and `kicks_setup.sh`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s user1
```

This downloads the newest `threat_watch-vX.Y.Z` release, sets up the cron jobs, and does a first run. You can list several users (`bash -s user1 user2`), or none and set them in the settings file afterwards. Running the installer again never overwrites your settings.

| Installed to | |
|---|---|
| `/opt/threat_watch/threat_watch.sh` | code (command: `threat_watch`) |
| `/etc/threat_watch/threat_watch.conf` | your settings |
| `/etc/threat_watch/threat_watch.conf.default` | the newest default settings, for reference |
| `/etc/cron.d/threat_watch` | run every 3 hours, update check every Sunday, guard every minute |

## Commands

| Command | What it does |
|---|---|
| `threat_watch run` | check new log lines now |
| `threat_watch update` | update to the newest release, and kicks too if installed (every Sunday only if `AUTO_UPDATE="yes"`) |
| `threat_watch versions` | list every version saved on this server |
| `threat_watch rollback [VER]` | go back to the previous version, or to any saved one |
| `threat_watch test-ip 1.2.3.4` | show an IP's country |
| `threat_watch uninstall` | remove the code and cron (`--purge` also removes logs and settings) |
| `threat_watch version` | show the installed version |

Updates come only from the release: code, cron, and any **new** settings (added to the end of your settings file with their defaults; a copy of the file is saved in `/etc/threat_watch/backup/` first). Your existing settings and logs are never changed. Every version is kept in `/var/lib/threat_watch/versions/`, so you can roll back. A broken download is refused and the old version stays.

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

## Guard (auto-ban), optional

Every minute, guard checks new log lines and bans IPs that do things real visitors never do:

| Rule | Example |
|---|---|
| `code_in_data_dir` | `GET /tmp/x.php`, `/images/a.PHP`, `/wp-content/uploads/b.phtml` |
| `upload_exploit` | `POST /index.php?option=com_jce` |
| `command_payload` | `?yoru=ZWNobyAn…`, `?cmd=id`, `eval(` in the URL |

- **Off by default.** Enable it with `threat_watch guard enable`. It starts in `watch` mode (report only), and you set `GUARD_MODE="ban"` when you're happy.
- **Only runs on licensed servers.** `approved_servers.txt` (in this folder) lists a code for each server IP (`echo -n IP | sha256sum`), so the IPs stay hidden. Unlicensed servers print the line to send Hanif.
- **Firewall:** Imunify360, CSF, or ipset/iptables, chosen automatically. Bans expire after 7 days.
- **Never bans:** Hanif's IP, whitelisted IPs (conf + CSF allow/ignore + Imunify whitelist) or the server's own IPs.
- **Safety:** at most 20 bans per hour per server, and `MODE watch` / `MODE off` in `approved_servers.txt` is a fleet-wide switch.
- **Telegram:** one message per run, only when something happened.

| Command | What it does |
|---|---|
| `threat_watch guard enable` / `disable` | switch guard on or off on this server |
| `threat_watch guard check` | re-download the licence list now and show if this server is licensed |
| `threat_watch guard id` | print this server's line for `approved_servers.txt` |
| `threat_watch guard status` | mode, firewall, approval, active bans |
| `threat_watch guard bans` | list active bans |
| `threat_watch guard unban IP` | remove a ban |
| `threat_watch guard telegram TOKEN CHAT_ID` | set where alerts go |
| `threat_watch guard test-alert` | send a test Telegram message |

Logs: `/var/log/threat_watch/guard/guard.log` (every ban and decision) and `runs.log`.

## Logs

```
/var/log/threat_watch/user/<user>/latest.txt           newest report
/var/log/threat_watch/user/<user>/YYYY-MM-DD_HHMM.txt   one per run (only when something was found)
/var/log/threat_watch/domain/<domain>/...               same, when SCOPE="domains"
/var/log/threat_watch/run.log                           one line per run
/var/log/threat_watch/update.log                        every update check (manual / auto, old -> new version)
```

## Notes

- Only new log lines are read each run. Positions and the country list are kept in `/var/lib/threat_watch/`.
- The country list is downloaded once a week from the official internet registries.
- Only IPv4 addresses get a country. IPv6 visitors are still checked for suspicious requests.

## kicks

kicks is a separate tool in this repo (releases `kicks-vX.Y.Z`): it stops floods and bad bots in the kernel. Install:

```bash
curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s -- --kicks
```

See `kicks-note.md` for how to use it.
