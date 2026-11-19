# threat_watch: install and view logs

## Install

Run as root on the cPanel server:

```bash
curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s <user>
```

- `<user>` is the cPanel user to watch. List several users with spaces: `bash -s <user1> <user2>`, or leave it empty and set the users in the settings file afterwards.
- The installer does a first run straight away.
- Running it again is safe: it keeps your settings.

Check that it's installed:

```bash
threat_watch version
cat /etc/cron.d/threat_watch
```

## Change what it watches

```bash
nano /etc/threat_watch/threat_watch.conf
```

| To do this | Set |
|---|---|
| watch one or more users | `SCOPE="users"` and `USERS="<user1> <user2>"` |
| watch every cPanel user | `SCOPE="all"` |
| watch only some domains | `SCOPE="domains"` and `DOMAINS="<domain1> <domain2>"` |
| change countries | `WATCH="ID"`, `WHITELIST="MY"` (2-letter country codes) |
| never log an IP | `WHITELIST_IPS="<ip1> <ip2>"` |

Changes apply on the next run. To run now:

```bash
threat_watch run
```

## View logs

### Newest report for a user

```bash
cat /var/log/threat_watch/user/<user>/latest.txt
```

For a domain (when `SCOPE="domains"`):

```bash
cat /var/log/threat_watch/domain/<domain>/latest.txt
```

### Older reports

A report file is only saved when something was found.

```bash
ls -lt /var/log/threat_watch/user/<user>/
cat /var/log/threat_watch/user/<user>/YYYY-MM-DD_HHMM.txt
```

### Only the suspicious part

```bash
sed -n '/^SUSPICIOUS/,/^VISITORS FROM/p' /var/log/threat_watch/user/<user>/latest.txt
```

### Search for an IP in all reports

```bash
grep -rn "<ip>" /var/log/threat_watch/
```

### Did it run? Did it update?

```bash
tail /var/log/threat_watch/run.log       # one line per run
cat /var/log/threat_watch/update.log     # every update check
```

### How to read a report

```
=== 2026-11-19 12:47 | user/exampleuser | new lines: 1520 | flagged IPs: 3 (suspicious: 1, from ID: 2)

SUSPICIOUS
  203.0.113.10 [ID] 3 req  example.com
    17/Nov/2026:14:40:31  example.com    POST /index.php?option=com_jce HTTP/1.1  200  <- bad request

VISITORS FROM ID
  198.51.100.20 [ID] 3 req  example.com
    18/Nov/2026:10:02:11  example.com    GET / HTTP/1.1  200
```

- `[ID]` is the country, and `3 req` is the number of requests in this run.
- `<- bad request`, `<- hacking tool` and `<- many .php 404s` explain why an IP is suspicious.
- The number after the request is the HTTP status. A **200 on a suspicious line means the request worked**, so check that file on the server.

## Other commands

```bash
threat_watch test-ip <ip>       # show an IP's country
threat_watch update              # update now (it also checks every Sunday)
threat_watch uninstall           # remove the code + cron, keep logs and settings
threat_watch uninstall --purge   # remove everything
```
