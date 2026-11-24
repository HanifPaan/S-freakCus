# threat_watch

Every 3 hours, threat_watch logs what visitors from watched countries, and suspicious visitors from any country, did on cPanel sites. **Guard** is an optional add-on that bans attackers automatically, and only runs on servers licensed by Hanif.

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

## Who it watches (SCOPE)

threat_watch and guard both watch the same accounts. You choose them with `SCOPE` in `/etc/threat_watch/threat_watch.conf`:

| SCOPE | Watches |
|---|---|
| `SCOPE="users"` + `USERS="user1 user2"` | only those cPanel users |
| `SCOPE="domains"` + `DOMAINS="a.com b.com"` | only those domains |
| `SCOPE="all"` | every cPanel user on the server |

**Watch every user:**
```bash
sed -i 's/^SCOPE=.*/SCOPE="all"/' /etc/threat_watch/threat_watch.conf
```

**Watch only some users:**
```bash
sed -i 's/^SCOPE=.*/SCOPE="users"/; s/^USERS=.*/USERS="intellia user2"/' /etc/threat_watch/threat_watch.conf
```

**Watch only some domains:**
```bash
sed -i 's/^SCOPE=.*/SCOPE="domains"/; s/^DOMAINS=.*/DOMAINS="intelli.asia example.com"/' /etc/threat_watch/threat_watch.conf
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
  ⛔ threat_watch guard: this server (1.2.3.4, server9) is not licensed yet.
     Ask Hanif to add it. Send him this line:

     5f1c....e9a2 server9
  ```
  Send that line to Hanif. Once it's added, the server unlocks by itself within 6 hours. To unlock it right away:
  ```bash
  threat_watch guard check
  ```

Guard starts in **watch** mode (report only). To start real bans:
```bash
sed -i 's/^GUARD_MODE=.*/GUARD_MODE="ban"/' /etc/threat_watch/threat_watch.conf
```

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
| Rule | Means |
|---|---|
| `code_in_data_dir` | a code file opened in `tmp/`, `cache/`, `images/`, `media/`, `uploads/`, `logs/` or `wp-content/uploads/` |
| `upload_exploit` | a POST to a known upload hole (`option=com_jce`) |
| `command_payload` | commands hidden in the URL (`cmd=`, base64 `echo`, `eval(`) |

Uses Imunify360 if present, otherwise CSF, otherwise ipset. Bans expire after 7 days. Never bans Hanif's IP, whitelisted IPs, or the server's own IPs.

---

## Commands

| Command | Does |
|---|---|
| `threat_watch run` | check logs now (cron does this every 3 hours) |
| `threat_watch test-ip IP` | show an IP's country |
| `threat_watch version` | show the version |
| `threat_watch update` | update to the newest release (also runs every Sunday) |
| `threat_watch versions` | list saved versions |
| `threat_watch rollback [VER]` | go back to the previous or a chosen version |
| `threat_watch guard status` | guard mode, licence, firewall, active bans |
| `threat_watch guard bans` | who is banned and until when |
| `threat_watch guard unban IP` | remove a ban |
| `threat_watch guard id` | print this server's licence line |
| `threat_watch guard disable` | turn guard off |
| `threat_watch guard telegram TOKEN CHAT_ID` | send guard alerts to Telegram |
| `threat_watch uninstall [--purge]` | remove (`--purge` also removes settings and logs) |

---

## Releasing a new version (Hanif)

1. Change `VERSION="x.y.z"` at the top of `threat_watch.sh`.
2. GitHub → Releases → **Draft a new release** → tag `threat_watch-vx.y.z`.
3. Attach `threat_watch.sh`, `threat_watch.conf` and `setup.sh`, then **Publish**.

Servers update on Sunday, or right away with `threat_watch update`. Settings are never overwritten, and old versions are kept for rollback.
