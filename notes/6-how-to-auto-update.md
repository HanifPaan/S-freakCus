# How to turn auto-update on or off

```bash
nano /etc/exim_queue_guard.conf
```

- `AUTO_UPDATE=1` = on (checks once a day)
- `AUTO_UPDATE=0` = off

Apply it now:

```bash
/usr/local/bin/exim_queue_guard.sh --apply
```

Update by hand anytime (works even when off):

```bash
/usr/local/bin/exim_queue_guard.sh --update
```

See your version: `/usr/local/bin/exim_queue_guard.sh --check-update`
