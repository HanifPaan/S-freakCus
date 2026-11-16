# How to release a new version (maintainer)

1. Upload the changed files into `mailnager/` and commit to `main`.
   Keep the line `VERSION="dev"` in `mailnager` as it is.
2. **Releases → Draft a new release**
   - Tag: next version, e.g. `mailnager-v1.0.1` (must say "will be created")
   - Target: `main`
   - Pre-release: **unticked**
3. **Publish.** Servers with auto-update get it within a day.

Always do step 1 before step 2. The tag takes the code from `main` at that moment.

| Change | Version |
| --- | --- |
| Small fix | `1.0.0` → `1.0.1` |
| New feature | `1.0.1` → `1.1.0` |
| Big change | `1.1.0` → `2.0.0` |

Test first on one server: `curl -fsSL .../mailnager/setup.sh | bash -s -- --ref main`
