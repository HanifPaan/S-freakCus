# How to pause (without uninstalling)

Stop deleting, keep everything installed:

```bash
sed -i 's/^DRYRUN=.*/DRYRUN=1/' /etc/mailnager.conf
```

It still checks and logs what it *would* remove, but deletes nothing.

Resume:

```bash
sed -i 's/^DRYRUN=.*/DRYRUN=0/' /etc/mailnager.conf
```
