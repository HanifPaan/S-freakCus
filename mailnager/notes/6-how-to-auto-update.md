# How to turn auto-update on or off

```bash
nano /etc/mailnager.conf
```

- `AUTO_UPDATE=1` = on (checks once a day)
- `AUTO_UPDATE=0` = off

Apply it now:

```bash
mailnager --apply
```

Update by hand anytime (works even when off):

```bash
mailnager --update
```

See your version: `mailnager --check-update`
