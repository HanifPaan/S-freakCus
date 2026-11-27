# kicks

Stops floods and bad bots on cPanel servers. kicks reads the web logs live (every second), judges each IP, and bans bad ones in the kernel (ipset + one raw-table rule), before the website or PHP runs.

It has two parts, each with its own on/off and watch/ban:

| Part | Catches |
|---|---|
| **DoS** | one IP flooding pages, images or login |
| **scrapperReaper** | scrapers, fake Googlebot/Bingbot, honeypot probes (`/.env`, `/.git/` ...), bad user agents, AI bots over their limit, 404 sprees |

- **Off by default.** Both parts start in **watch** mode: they only log what they would ban.
- Same licence as guard: if the server is approved for guard, kicks runs too.
- Runs on **cPanel servers**: Apache, LiteSpeed, cPanel nginx in front, or SafeLine in front. DirectAdmin and non-cPanel servers get "not available" and nothing is touched.
- **Imunify360 servers:** only scrapperReaper runs, and its bans go into Imunify's own block list (with the same 1 h / 6 h / 1 day times). DoS / DDoS is not available there. kicks only touches entries it made itself (comment starts with `kicks:`).
- Office IPs and the never-ban IPs from threat_watch are never banned.
- No alerts.

---

## Install

**If threat_watch is on the server:** open the Guard Console → **kicks → DoS / DDoS** → **Install kicks** (asks for your password), or run:
```bash
threat_watch kicks-install
```
It downloads the newest kicks release into a private temp folder, checks the files (version, syntax), and only then installs. If a check fails, nothing is installed. On servers where kicks can't run (DirectAdmin, non-cPanel) it says why and stops.

**On a server without threat_watch**, as root:
```bash
curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s -- --kicks
```

| Path | What |
|---|---|
| `/etc/kicks/kicks.conf` | settings |
| `/var/log/kicks/kicks.log` | what kicks did (start, rules, auto-ban, settings changes) |
| `/var/log/kicks/bans.log` | every ban and would-ban, one JSON line each |
| `/var/log/kicks/update.log` | update history |
| `/var/lib/kicks/versions/` | every installed version (for rollback) |

---

## Turn it on

First check the server (changes nothing):
```bash
kicks check
```
It shows the licence, the firewall, which log kicks will read, whether that log shows the real visitor IPs, and how bad user agents will be blocked. The last line says `kicks can run here` or `kicks can NOT run here` with the reason.

In the Guard Console: **Settings → kicks → Mode & parts**. When you switch kicks on there, the Console runs the same check first, and refuses to switch it on if the check fails. Or on the server:
```bash
sed -i 's/^KICKS_ENABLED=.*/KICKS_ENABLED=1/' /etc/kicks/kicks.conf
kicks status
```

kicks picks up setting changes by itself within a second (the service starts within a minute after being switched on).

| Want | Setting |
|---|---|
| DoS really bans | `KICKS_DOS_MODE=ban` |
| scrapperReaper really bans | `KICKS_REAPER_MODE=ban` |
| Back to watch | `..._MODE=watch` |
| Turn a part off | `KICKS_DOS=0` or `KICKS_REAPER=0` |

**Which sites** (`KICKS_SCOPE`): `all`, `users` (+ `KICKS_USERS="user1 user2"`) or `domains` (+ `KICKS_DOMAINS="example.com example.net"`). Also in the Console: **Settings → kicks → What it checks**.

---

## Which log kicks reads

kicks reads the log of whatever answers visitors first, because that one has the real visitor IP. It picks it by itself (`LOG_SOURCE=auto`):

| Server | Log |
|---|---|
| Apache or LiteSpeed | `/usr/local/apache/domlogs/` |
| cPanel nginx in front | `/var/log/nginx/domains/` |
| SafeLine in front | `/data/safeline/logs/nginx/safeline/accesslog_1` (requests SafeLine already blocked, status 468, count for floods but not for the crawler rules) |

If most recent log lines come from one internal address (127.0.0.1, a 172.x Docker address or the server's own IP), the log is showing a proxy, not visitors. kicks then refuses to run and says so.

**Blocking bad user agents** (only when scrapperReaper is in ban mode): kicks adds a ModSecurity rule (`/etc/apache2/conf.d/kicks_ua_block.conf`) that gives them 403. It works on Apache and LiteSpeed. Without ModSecurity, Apache gets a rewrite rule instead; on LiteSpeed without ModSecurity, user agents are not blocked by name (bad bots are still banned by IP). With cPanel nginx in front, the same block is also added on the nginx side, so cached pages are covered. Every change is config-tested first and undone if the test fails.

---

## How bans work

| Strike | Ban |
|---|---|
| 1st | 1 hour |
| 2nd | 6 hours |
| 3rd and later | 1 day |

Strikes reset after 7 clean days. DoS and scrapperReaper share strikes.

**DoS limits** (per IP, per 60 seconds): 120 pages, 900 requests (images included), 15 login tries. IPs that look like many real browsers (school, office, mobile network) get 3× the limits.

**Auto-ban on load:** if kicks is in watch mode and both the server load **and** the web traffic jump far above normal, kicks switches to ban by itself. It goes back to watch after 15 minutes of normal. Turn off with `KICKS_AUTO_BAN=no`.

**Safety cap:** more than 40 new bans in one minute = kicks pauses itself (something is probably wrong) and resumes after 30 minutes. `kicks resume` resumes now.

**IPs guard already banned** are skipped, so an IP is not banned twice.

**Reboots and crashes:** every new ban is written to disk straight away (`/var/lib/kicks/`). At boot, the `kicks-boot` service puts the bans back before the web servers start, with the time they had left. On Imunify360 servers, Imunify keeps its own list across reboots.

---

## Release an IP

```bash
kicks unban 203.0.113.9
```
This also removes the IP from guard (threat_watch), and clears its strikes. `threat_watch guard unban <IP>` and the Console's **Release** button do the same.

---

## Commands

| Command | Does |
|---|---|
| `kicks status` | on/off, licence, firewall, which log, user-agent block, modes, auto-ban, paused |
| `kicks check` | can kicks run here? (licence, firewall, real visitor IPs, user-agent block). Changes nothing |
| `kicks list` | current bans with time left and reason |
| `kicks why IP` | strike history of an IP and whether it is banned now |
| `kicks unban IP` | remove a ban (in kicks and guard) |
| `kicks pause` / `kicks resume` | stop banning / start again |
| `kicks settings get` | current settings |
| `kicks settings history` | who changed what |
| `kicks settings undo 12` | undo change #12 |
| `kicks update` | update to the newest release (`threat_watch update` does this too) |
| `kicks versions` | list saved versions |
| `kicks rollback [VER]` | go back to the previous or a chosen version |
| `kicks bugs` | learn from old logs once and print suggested limits (it also runs every night at low priority) |
| `kicks uninstall` | remove rules, bans and the service (settings and logs kept; `--purge` removes everything) |

The services are `kicks` (`systemctl status kicks`) and `kicks-boot` (runs once at boot).
