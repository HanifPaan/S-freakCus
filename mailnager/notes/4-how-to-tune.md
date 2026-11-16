# How to tune for your server

Check your server: `nproc` (cores), `free -h` (RAM), `df -h /var` (free space).

| Server | BATCH_SIZE | BATCH_SLEEP | MAX_PER_RUN |
| --- | --- | --- | --- |
| 1-2 cores, 2-4 GB RAM | 100 | 8 | 2000 |
| 3-4 cores, 4-8 GB RAM | 250 | 5 | 5000 |
| 6-8 cores, 8-16 GB RAM | 500 | 3 | 10000 |
| 12+ cores, 32 GB+ RAM | 1000 | 2 | 0 |

- **HDD:** half the `BATCH_SIZE`, double the `BATCH_SLEEP`
- **NVMe:** you can double the `BATCH_SIZE`
- **MAX_SIZE_MB:** about 10% of free space (at least 1024)
- **MAX_INODES:** about 5% of free inodes (at most 300000)

Server slow during cleanup? Raise `BATCH_SLEEP`.
Spool keeps growing? Lower `MAX_AGE` to `43200`.
