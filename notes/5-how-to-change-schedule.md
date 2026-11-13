# How to change how often it runs

```bash
nano /etc/exim_queue_guard.conf
```

Change `SCHEDULE`:

| How often | Value |
| --- | --- |
| Every hour | `SCHEDULE="0 * * * *"` |
| Every 3 hours | `SCHEDULE="0 */3 * * *"` |
| Once a day at 2am | `SCHEDULE="0 2 * * *"` |

Apply it now:

```bash
/usr/local/bin/exim_queue_guard.sh --apply
```
