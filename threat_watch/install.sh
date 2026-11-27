#!/usr/bin/env bash
# install.sh - one-line installer for threat_watch and kicks. It installs the files
# attached to the newest GitHub release of the tool you choose.
#
#   threat_watch:
#   curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s user1
#   curl -fsSL .../install.sh | bash -s user1 user2
#
#   kicks:
#   curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s -- --kicks
#
# Environment:
#   TW_VERSION=1.6.0     install this release instead of the newest (kicks: KICKS_VERSION=1.0.0)
#   TW_SRC=/some/dir     install from a local folder with the 3 files (testing)
#
# Release files: threat_watch = threat_watch.sh threat_watch.conf setup.sh
#                kicks        = kicks.py kicks.conf kicks_setup.sh

set -euo pipefail
REPO="HanifPaan/S-freakCus"
die() { echo "install: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
command -v curl >/dev/null || die "curl is required"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

APP="threat_watch"; FILES="threat_watch.sh threat_watch.conf setup.sh"; VER="${TW_VERSION:-}"
if [[ "${1:-}" == "--kicks" ]]; then
    shift; APP="kicks"; FILES="kicks.py kicks.conf kicks_setup.sh"; VER="${KICKS_VERSION:-}"
fi
D="$TMP/$APP"; mkdir -p "$D"

if [[ -n "${TW_SRC:-}" ]]; then
    for f in $FILES; do cp "$TW_SRC/$f" "$D/" || die "$f not found in $TW_SRC"; done
else
    if [[ -z "$VER" ]]; then
        VER="$(curl -fsS --max-time 30 "https://api.github.com/repos/$REPO/tags?per_page=100" |
               grep -o "\"name\": *\"$APP-v[0-9][0-9.]*\"" | grep -o '[0-9][0-9.]*[0-9]' | sort -V | tail -1)" || true
        [[ -n "$VER" ]] || die "no $APP release found in $REPO"
    fi
    echo "downloading $APP $VER"
    for f in $FILES; do
        curl -fsSL --max-time 60 "https://github.com/$REPO/releases/download/$APP-v$VER/$f" -o "$D/$f" \
          || die "release $APP-v$VER is missing $f (attach: $FILES)"
    done
    if [[ "$APP" == "kicks" ]]; then
        grep -q "^VERSION = \"$VER\"" "$D/kicks.py" || die "kicks.py in release $VER has a different VERSION"
    else
        grep -q "^VERSION=\"$VER\"" "$D/threat_watch.sh" || die "threat_watch.sh in release $VER has a different VERSION"
    fi
fi
for f in $FILES; do
    case "$f" in
        *.sh) head -1 "$D/$f" | grep -q '^#!/usr/bin/env bash' && bash -n "$D/$f" || die "$f is broken" ;;
    esac
done
if [[ "$APP" == "kicks" ]]; then bash "$D/kicks_setup.sh" --install; else bash "$D/setup.sh" --install "$@"; fi
