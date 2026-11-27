# kicks

Stops floods and bad bots on cPanel servers. kicks reads the web logs live (every second), judges each IP, and bans bad ones in the kernel (ipset + one raw-table rule), before the website or PHP runs.

It has two parts, each with its own on/off and watch/ban:

| Part | Catches |
|---|---|
| **DoS** | one IP flooding pages, images or login |
| **scrapperReaper** | scrapers, fake Googlebot/Bingbot, honeypot probes (`/.env`, `/.git/` ...), bad user agents, AI bots over their limit, 404 sprees |

- **Off by default.** Both parts start in **watch** mode: they only log what they would ban.
- Same licence as guard: if the server is approved for guard, kicks runs too.
- Runs on **cPanel servers with CSF or no firewall**. On Imunify360, DirectAdmin or servers behind SafeLine it says "not available" and touches nothing.
- Office IPs and the never-ban IPs from threat_watch are never banned.
- No alerts.

---

## Install

**If threat_watch is on the server:** open the Guard Console → **kicks → DoS / DDoS** → **Install kicks** (asks for your password), or run:
```bash
threat_watch kicks-install
```
It downloads the newest kicks release into a private temp folder, checks the files (version, syntax), and only then installs. If a check fails, nothing is installed. On servers where kicks can't run (Imunify360, DirectAdmin, behind SafeLine) it says why and stops.

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

In the Guard Console: **Settings → kicks → Mode & parts**, or on the server:
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
| `kicks status` | on/off, licence, firewall, modes, auto-ban, paused |
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

The service is `kicks` (`systemctl status kicks`).
