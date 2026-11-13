# How to test (nothing gets deleted)

```bash
sed -i 's/^DRYRUN=.*/DRYRUN=1/' /etc/exim_queue_guard.conf
/usr/local/bin/exim_queue_guard.sh
tail -3 /var/log/exim_queue_guard.log
```

Turn it back on:

```bash
sed -i 's/^DRYRUN=.*/DRYRUN=0/' /etc/exim_queue_guard.conf
```

No new log line? The spool is under the limits. That's normal.
