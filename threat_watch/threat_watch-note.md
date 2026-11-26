# threat_watch

Every 3 hours, threat_watch logs what visitors from watched countries, and suspicious visitors from any country, did on the server's sites (cPanel or DirectAdmin). **Guard** is an optional add-on that bans attackers automatically, and only runs on servers licensed by Hanif.

---

## Install

As root:
```bash
curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s <cpanel_user>
```
- Several users: `bash -s user1 user2`
- All users: install with no user, then set `SCOPE="all"` in the settings file.

| Path | What |
|---|---|
| `/etc/threat_watch/threat_watch.conf` | settings |
| `/var/log/threat_watch/user/<user>/latest.txt` | latest report per user |
| `/var/log/threat_watch/domain/<domain>/latest.txt` | latest report per domain |
| `/var/log/threat_watch/update.log` | update history |
| `/var/log/threat_watch/guard/guard.log` | guard history |

---

## Which log it reads

threat_watch reads the log of whatever answers visitors first, because that layer sees the real visitor IP. It picks it automatically:

| Server | Log |
|---|---|
| cPanel, Apache or LiteSpeed | `/usr/local/apache/domlogs/<user>/` |
| cPanel with nginx in front | `/var/log/nginx/domains/` |
| DirectAdmin | `/var/log/httpd/domains/` |
| SafeLine WAF in front | `/data/safeline/logs/nginx/safeline/accesslog_1` |

**Check what it picked, and that real IPs show:**
```bash
threat_watch log-source
```
```
source:  safeline   (LOG_SOURCE=auto, SCOPE=all)
log:     /data/safeline/logs/nginx/safeline/accesslog_1  (SafeLine format, all sites in one file)
check:   ✅ 412 different IPs in the last 2000 lines: real visitor IPs visible
```

**Force a source** (only if auto picks wrong), in the conf:
```
LOG_SOURCE="auto"      # auto | apache | nginx | directadmin | safeline
```

If the log shows almost only the server's own IP (a proxy in front hides real visitors), guard **pauses** by itself and says so in `guard status` and `guard.log`. It starts again on its own once real IPs show.

---

## Who it watches (SCOPE)

threat_watch and guard both watch the same accounts. You choose them with `SCOPE` in `/etc/threat_watch/threat_watch.conf`:

| SCOPE | Watches |
|---|---|
| `SCOPE="users"` + `USERS="user1 user2"` | only those users |
| `SCOPE="domains"` + `DOMAINS="a.com b.com"` | only those domains |
| `SCOPE="all"` | every user on the server |

**Watch every user:**
```bash
sed -i 's/^SCOPE=.*/SCOPE="all"/' /etc/threat_watch/threat_watch.conf
```

**Watch only some users:**
```bash
sed -i 's/^SCOPE=.*/SCOPE="users"/; s/^USERS=.*/USERS="user1 user2"/' /etc/threat_watch/threat_watch.conf
```

**Watch only some domains:**
```bash
sed -i 's/^SCOPE=.*/SCOPE="domains"/; s/^DOMAINS=.*/DOMAINS="example.com example.net"/' /etc/threat_watch/threat_watch.conf
```

**Check the current setting:**
```bash
grep -E '^(SCOPE|USERS|DOMAINS)=' /etc/threat_watch/threat_watch.conf
```

The change applies on the next run: within 3 hours for threat_watch, and within 1 minute for guard. To run threat_watch right away:
```bash
threat_watch run
```

---

## Guard (auto-ban)

### Turn it on
```bash
threat_watch guard enable
```

- **Licensed server:**
  ```
  ✅ this server is licensed
  ```
- **Not licensed yet:**
  ```
  ⛔ threat_watch guard: this server (1.2.3.4, myserver) is not licensed yet.
     Ask Hanif to add it. Send him this line:

     5f1c....e9a2 myserver
  ```
  Send that line to Hanif. Once it's added, the server unlocks by itself within 6 hours. To unlock it right away:
  ```bash
  threat_watch guard check
  ```

### Switch mode
Guard starts in **watch** mode, which only reports and never bans.

| Want | Command |
|---|---|
| Ban mode (real bans) | `sed -i 's/^GUARD_MODE=.*/GUARD_MODE="ban"/' /etc/threat_watch/threat_watch.conf` |
| Back to watch mode | `sed -i 's/^GUARD_MODE=.*/GUARD_MODE="watch"/' /etc/threat_watch/threat_watch.conf` |
| Turn guard off | `threat_watch guard disable` |
| Turn guard on again | `threat_watch guard enable` |
| Check the current mode | `threat_watch guard status` |

Changes take effect within 1 minute. Switching mode or turning guard off does **not** remove bans that already happened. To remove one:
```bash
threat_watch guard unban <IP>
```

### Watch guard live
```bash
tail -f /var/log/threat_watch/guard/guard.log
```
- `WOULD BAN` = watch mode, reported only
- `BANNED` = ban mode, IP was banned (with rule, site, URL, ban length and strike)
- `ALERT` = someone used the theme/plugin editor or uploaded a plugin (never banned)
- `WARNING` = guard paused (see "Which log it reads")

Press `Ctrl+C` to stop watching.

### Licence list (Hanif)
`threat_watch/approved_servers.txt` in this repo:
```
MODE ban
<code> <server-name>
```
- `<code>` = `echo -n <server-ip> | sha256sum`. The IP itself is never written in the file.
- **Add a server:** paste its line → Commit.
- **Remove a server:** delete its line → Commit.
- **All servers:** set `MODE ban`, `MODE watch` (report only) or `MODE off`.

### What guard bans

**Hard rules: banned on the first hit, for 7 days**
| Rule | Means |
|---|---|
| `code_in_data_dir` | a code file opened in `tmp/`, `cache/`, `images/`, `media/`, `uploads/`, `logs/` or `wp-content/uploads/` |
| `upload_exploit` | a POST to a known upload hole (JCE, SP Page Builder) |
| `command_payload` | commands hidden in the URL (`cmd=`, base64 `echo`, `eval(`) |

**Soft rules: counted first, then a ladder**
| Rule | Means | 1 strike |
|---|---|---|
| `secret_files` | asking for `.env`, `.git/`, `.aws/`, `.ssh/`, `wp-config.php` backups, key files | 3 hits in 10 min |
| `wp_login` | **failed** WordPress logins (`wp-login.php`, `xmlrpc.php`). Successful logins never count. | 5 failed in 10 min |

```
1 strike            -> banned 1 hour
comes back, strikes again -> banned 1 hour
5th strike in 7 days      -> banned 7 days
```

**Range ban: a whole /24 block**
When **4 or more different IPs from the same /24** (for example `1.2.3.0`–`1.2.3.255`) are banned by hard rules within **10 minutes**, the whole block is banned for 7 days. This stops bots that use a new IP for every try. A block that holds an office or whitelisted IP is never range-banned.

**Alert only: never bans**
| Rule | Means |
|---|---|
| `wp_editor` | someone opened the theme/plugin editor or uploaded a plugin/theme. Check it was you. |

**Never banned:** the office IPs (built in), the server's own IPs, private IPs, WordPress.com/Jetpack, `WHITELIST_IPS` in the conf, CSF allow/ignore and the Imunify whitelist.

Uses Imunify360 if present, otherwise CSF, otherwise ipset. When an IP is banned, its open connections are cut too.

### Tune the rules
In `/etc/threat_watch/threat_watch.conf`:
```
GUARD_SECRET_FILES="yes"      # secret_files on/off
GUARD_WP_LOGIN="yes"          # wp_login on/off
GUARD_WP_EDITOR="alert"       # alert | off
GUARD_SECRET_HITS=3           # secret_files hits in the window = 1 strike
GUARD_LOGIN_HITS=5            # failed logins in the window = 1 strike
GUARD_SOFT_WINDOW_MIN=10      # the window (minutes)
GUARD_SOFT_BAN_MIN=60         # 1 strike = banned this long (minutes)
GUARD_SOFT_STRIKES=5          # strikes in 7 days before the 7-day ban
GUARD_BAN_DAYS=7              # length of a normal ban
GUARD_RANGE_BAN="yes"         # whole /24 bans on/off
GUARD_RANGE_IPS=4             # IPs from one /24 ...
GUARD_RANGE_WINDOW_MIN=10     # ... banned within this many minutes = ban the /24
```

---

## Guard Console (web page)

A web page on port 6181 showing guard's bans and log, with a Settings tab. Login is by username and password, and only allowed IPs can open it.

**Turn it on:**
```bash
threat_watch gui-enable
```
It asks for a username (Enter = `admin`) and shows the password **once**. Then open `https://<server-ip>:6181`.

**Open port 6181 (TCP in) in the firewall**, or the page times out:

- **Imunify360** (port blocking mode `DENY`): add `6181` to `TCP_IN_IPv4`. The update replaces the whole list, so include your current ports:
  ```bash
  imunify360-agent config show | grep -o '"TCP_IN_IPv4": \[[^]]*\]'      # see the current list
  imunify360-agent config update '{"FIREWALL": {"TCP_IN_IPv4": ["20","21","22","25","53","80","443", ... ,"6181"]}}'
  ```
  Or in WHM: Imunify360 → Settings → Firewall → TCP incoming ports → add `6181` → Save.
- **CSF**: `gui-enable` / `gui-allow` add each allowed IP to `csf.allow` for port 6181. If it still times out, add `6181` to `TCP_IN` in `/etc/csf/csf.conf`, then run `csf -r`.
- **Provider firewall** (e.g. OVH Network Firewall, cloud security groups): allow TCP 6181 there too.

Only IPs added with `gui-allow` can sign in, even when the port is open.

**On the page:**
- Search by IP or site, filter by rule or ban type (long / 1-hour strike), and choose rows per page (25, 50, 100, 250, All).
- Click a row to see what that IP tried and the result.
- **Release** on a row removes that ban right away and clears the IP's strikes, after asking you to confirm. Every release is logged with who did it.
- The copy buttons copy only the rows matching the filters.

**Settings tab:**
- Sections: Mode, Rules, What it checks, Ban lengths and strikes, Range ban, Ban limits, Never-ban IPs (with names), Telegram alerts (choose what is sent, quiet hours, test message), 3-hourly report, Version and updates.
- A changed field turns yellow and shows its old value. Nothing is saved until you press **Save**, which asks for your password again.
- **Default** on a section fills in the default values (you still press Save). **Reset all** does the same for every section except Mode, What it checks and Never-ban IPs.
- Each save keeps a copy of the settings file in `/etc/threat_watch/backup/` and appears in **History** with who changed it. **Undo** there puts the old values back.
- **Export / Import** copies settings from one server to another. Users and domains are not copied.
- **Ban an IP now**: ban an IP or a `/24` for a chosen time, with a note. Office and never-ban IPs are refused.
- **Test a request**: paste a URL to see which rule would catch it. Nothing is banned.
- **Version and updates**: shows the newest release and its notes; **Update now** asks for your password, keeps your settings and saves the old version for rollback.
- Licence, allowed IPs, password and the Telegram token can only be changed on the server.

The same settings from the command line:
```bash
threat_watch settings get              # current values
threat_watch settings history          # who changed what
threat_watch settings undo 12          # undo change #12
threat_watch guard ban 203.0.113.9 1d "note"
threat_watch guard test-url GET /wp-content/uploads/x.php
```

| Command | Does |
|---|---|
| `threat_watch gui-status` | running or not, URL, username, last logins |
| `threat_watch gui-allow IP` / `gui-deny IP` | allow / remove an IP |
| `threat_watch gui-ip-list` | list the allowed IPs |
| `threat_watch gui-passwd-reset` | new password, shown once, signs everyone out |
| `threat_watch gui-disable` | stop the page and close the port |

---

## Commands

| Command | Does |
|---|---|
| `threat_watch run` | check logs now (cron does this every 3 hours) |
| `threat_watch test-ip IP` | show an IP's country |
| `threat_watch log-source` | which log is read, and whether real IPs show |
| `threat_watch version` | show the version |
| `threat_watch update` | update to the newest release (also runs every Sunday) |
| `threat_watch versions` | list saved versions |
| `threat_watch rollback [VER]` | go back to the previous or a chosen version |
| `threat_watch guard status` | guard mode, licence, firewall, log source, active bans (long / short) |
| `threat_watch guard bans` | who is banned, until when, and their strike |
| `threat_watch guard unban IP` | remove a ban (also clears that IP's strikes) |
| `threat_watch guard id` | print this server's licence line |
| `threat_watch guard disable` | turn guard off |
| `threat_watch guard telegram TOKEN CHAT_ID` | send guard alerts to Telegram |
| `threat_watch uninstall [--purge]` | remove (`--purge` also removes settings and logs) |
