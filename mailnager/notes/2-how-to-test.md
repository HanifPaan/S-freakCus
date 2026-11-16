# How to test (nothing gets deleted)

```bash
sed -i 's/^DRYRUN=.*/DRYRUN=1/' /etc/mailnager.conf
mailnager
tail -3 /var/log/mailnager.log
```

Turn it back on:

```bash
sed -i 's/^DRYRUN=.*/DRYRUN=0/' /etc/mailnager.conf
```

No new log line? The spool is under the limits. That's normal.
