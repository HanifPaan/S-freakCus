# How to change settings

All settings are in one file:

```bash
nano /etc/exim_queue_guard.conf
```

| Setting | What it does |
| --- | --- |
| `MAX_SIZE_MB` | Start cleanup when the spool is this big (MB) |
| `MAX_INODES` | Start cleanup when the spool has this many files |
| `MAX_AGE` | Remove mail older than this (86400 = 1 day, 43200 = 12 h) |
| `BATCH_SIZE` | Messages removed at a time |
| `BATCH_SLEEP` | Seconds to wait between batches |
| `MAX_PER_RUN` | Max removed per run (0 = no limit) |

Save. The next run uses the new values. Updates never change them.

Numbers only: `300000`, not `300k`.
