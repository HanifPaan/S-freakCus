# Mailnager

Keeps the Exim spool (`/var/spool/exim/input`) from growing without limit on cPanel servers.
On a schedule (hourly by default), it checks the spool's size and inode count. When either one
reaches its limit, it removes queued mail older than `MAX_AGE` (1 day by default), in small
batches with a pause between them so disk I/O stays low.

## Install

Run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/mailnager/setup.sh | bash
```

Setup installs the **latest release**, checks the server's CPU, RAM, disk type and free space,
and writes a settings file tuned slightly below the recommended values (see
[Recommended settings](#recommended-settings)).

Running the same command again on a server that already has it is safe. Program files are
updated, and your settings are kept.

Options (add them after `| bash -s --`):

| Option | Meaning |
| --- | --- |
| `--ref mailnager-v1.0.0` | Install a specific release |
| `--ref main` | Install the current `main` branch (for testing; auto-update moves it to the latest release) |
| `--disk hdd\|ssd\|nvme` | Override the detected disk type for auto-tune |

## Test before going live

```bash
sed -i 's/^DRYRUN=.*/DRYRUN=1/' /etc/mailnager.conf
mailnager
tail -3 /var/log/mailnager.log
sed -i 's/^DRYRUN=.*/DRYRUN=0/' /etc/mailnager.conf
```

## Commands

| Command | What it does |
| --- | --- |
| `mailnager` | Check the spool and clean up if needed (what cron runs) |
| `mailnager --apply` | Rewrite cron and logrotate from the settings file now |
| `mailnager --update` | Update to the latest release now (works even when `AUTO_UPDATE=0`) |
| `mailnager --check-update` | Show the installed and latest version |
| `mailnager --version` | Show the installed version |
| `mailnager-uninstall` | Remove everything (asks first; `--yes` to skip the question) |

## Settings

All settings live in `/etc/mailnager.conf`. **Updates never change a value you set.**
When a new version adds a setting, it is appended to the file with its default value.
Changes take effect on the next run. Run `mailnager --apply` to apply schedule
changes right away.

| Setting | Default | Meaning |
| --- | --- | --- |
| `SPOOL` | `/var/spool/exim/input` | Folder that is checked |
| `MAX_INODES` | auto-tuned | Clean up when inodes in `SPOOL` reach this |
| `MAX_SIZE_MB` | auto-tuned | Clean up when `SPOOL` reaches this size (MB) |
| `MAX_AGE` | `86400` | Remove mail older than this, in seconds (86400 = 1 day, 43200 = 12 h) |
| `BATCH_SIZE` | auto-tuned | Messages removed per batch |
| `BATCH_SLEEP` | auto-tuned | Seconds to pause between batches |
| `MAX_PER_RUN` | auto-tuned | Max messages removed per run (0 = no cap) |
| `DRYRUN` | `0` | `1` = log only, delete nothing |
| `SCHEDULE` | `"0 * * * *"` | Cron time for the check (every hour) |
| `AUTO_UPDATE` | `1` | `1` = update daily from GitHub releases, `0` = off |
| `UPDATE_SCHEDULE` | random time 02:00–05:59 | Cron time for the daily update check |
| `LOG` | `/var/log/mailnager.log` | Log file |
| `LOG_KEEP` | `2` | Old monthly log files to keep |

Numbers only, no units (`300000`, not `300k`). If a value is invalid, the script stops
without deleting anything and writes the error to the log.

## Recommended settings

<!-- Add your recommendation table here (CPU / RAM / disk / storage). -->

Auto-tune at first install uses about **80%** of the recommended batch values, rounded
(a smaller `BATCH_SIZE` and `MAX_PER_RUN`, a longer `BATCH_SLEEP`), and sets limits from
free space on `/var/spool/exim`: `MAX_SIZE_MB` = 8% of free space (1–20 GB), `MAX_INODES` =
4% of free inodes (20k–240k). Servers that already have a settings file keep their values.

## Log

`/var/log/mailnager.log` gets a line only when something happens: a limit hit, a
cleanup result, a settings change applied, an update, or an error. It is rotated monthly,
keeping `LOG_KEEP` old compressed files.

```
2026-11-13 18:00:05 LIMIT HIT: size=4935MB(>=3072MB) | queue=41033
2026-11-13 18:04:12 Removed 5000 messages in 20 batches (247s), 812 old left for next run. Now: ...
2026-11-14 03:45:02 UPDATE: v1.0.0 -> v1.1.0
```

## Uninstall

Removes the script, settings, cron, logrotate, lock files and **all logs**:

```bash
mailnager-uninstall            # asks first
mailnager-uninstall --yes      # no question
# or straight from GitHub:
curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/mailnager/uninstall.sh | bash -s -- --yes
```

## Releasing a new version (maintainer)

Servers only update to **published GitHub releases**, never to plain pushes.

1. Push your changes. Keep the line `VERSION="dev"` in `mailnager` as it is;
   setup writes the real version into it during install.
2. On GitHub, go to **Releases → Draft a new release** and create a tag named
   `mailnager-v<version>`, for example `mailnager-v1.1.0`.
3. Publish it. Servers with `AUTO_UPDATE=1` pick it up within a day. Pre-releases are ignored.

Adding a new setting: add a line for it to the `settings()` list in `setup.sh` and a default
in `mailnager`. Updates append it to existing settings files.

## Moving from exim_queue_guard (old name)

Run the normal install command. Setup finds the old install and moves it over automatically:
your settings and log history are kept (as `/etc/mailnager.conf` and `/var/log/mailnager.log`),
and the old script, cron, logrotate and conf are removed.
