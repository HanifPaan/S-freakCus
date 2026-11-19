# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions: [SemVer](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-19

### Added
- Incremental reading of cPanel/Apache domlogs (per-file inode + offset), with
  catch-up from rotated `<log>-Mon-YYYY.gz` archives.
- Country lookup from the RIR delegation files (IPv4 + IPv6), refreshed weekly;
  optional MaxMind/DB-IP `.mmdb` support via `mmdblookup`.
- Configurable `WATCH_COUNTRIES` (or `ALL`), `WHITELIST_COUNTRIES`,
  `WHITELIST_IPS`, `WHITELIST_CIDRS`.
- Classification into attack / scanner / fake_bot / bot / normal using
  editable rule files; local rule overrides and `DISABLED_RULES`.
- Rules based on a real Joomla compromise (Nov 2026): JCE upload,
  PHP in `tmp/` / `images/` / `media/`, AcyMailing `*.png?.php` probes,
  known webshell names, `.php` 404 floods.
- Reports: per-run summary, suspicious details (TXT + CSV), repeat offenders,
  run log; automatic retention.
- `install.sh` for install / upgrade / per-account cron / uninstall.
- Safe writes into user-owned folders (root-owned dir checks, `O_NOFOLLOW`,
  atomic rename), sanitised report text.
- End-to-end test suite and GitHub release workflow.
