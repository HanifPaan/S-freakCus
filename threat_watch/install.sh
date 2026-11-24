#!/usr/bin/env bash
# install.sh - one-line installer for threat_watch. This file never needs to
# change: it installs the files attached to the newest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s intellia
#   curl -fsSL .../install.sh | bash -s user1 user2
#
# Environment:
#   TW_VERSION=1.3.0     install this release instead of the newest
#   TW_SRC=/some/dir     install from a local folder with the 3 files (testing)

set -euo pipefail
REPO="HanifPaan/S-freakCus"
FILES="threat_watch.sh threat_watch.conf setup.sh"
die() { echo "install: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
command -v curl >/dev/null || die "curl is required"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
D="$TMP/threat_watch"; mkdir -p "$D"

if [[ -n "${TW_SRC:-}" ]]; then
    for f in $FILES; do cp "$TW_SRC/$f" "$D/" || die "$f not found in $TW_SRC"; done
else
    VER="${TW_VERSION:-}"
    if [[ -z "$VER" ]]; then
        VER="$(curl -fsS --max-time 30 "https://api.github.com/repos/$REPO/tags?per_page=100" |
               grep -o '"name": *"threat_watch-v[0-9][0-9.]*"' | grep -o '[0-9][0-9.]*[0-9]' | sort -V | tail -1)" || true
        [[ -n "$VER" ]] || die "no threat_watch release found in $REPO"
    fi
    echo "downloading threat_watch $VER"
    for f in $FILES; do
        curl -fsSL --max-time 60 "https://github.com/$REPO/releases/download/threat_watch-v$VER/$f" -o "$D/$f" \
          || die "release threat_watch-v$VER is missing $f (attach threat_watch.sh, threat_watch.conf, setup.sh)"
    done
    grep -q "^VERSION=\"$VER\"" "$D/threat_watch.sh" || die "threat_watch.sh in release $VER has a different VERSION"
fi
for f in threat_watch.sh setup.sh; do
    head -1 "$D/$f" | grep -q '^#!/usr/bin/env bash' && bash -n "$D/$f" || die "$f is broken"
done
bash "$D/setup.sh" --install "$@"
