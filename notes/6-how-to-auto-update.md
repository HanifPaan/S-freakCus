# How to turn auto-update on or off

Off:

```bash
sed -i 's/^AUTO_UPDATE=.*/AUTO_UPDATE=0/' /etc/mailnager.conf
mailnager --apply
```

On:

```bash
sed -i 's/^AUTO_UPDATE=.*/AUTO_UPDATE=1/' /etc/mailnager.conf
mailnager --apply
```

Check: `mailnager --check-update` shows `Auto-update: on` or `off`.

When on, it checks once a day and installs new releases only.
