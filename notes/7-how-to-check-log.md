# How to check the log

```bash
tail -20 /var/log/exim_queue_guard.log
```

| You see | Meaning |
| --- | --- |
| `LIMIT HIT` | Spool was over the limit, cleanup started |
| `Removed N messages` | Cleanup done |
| `No messages older than` | Over the limit, but no mail old enough yet |
| `UPDATE: v1.0.0 -> v1.1.0` | Updated |
| `ERROR` | A setting is wrong. Nothing was deleted |

Empty log = spool stayed under the limits. That's good.
