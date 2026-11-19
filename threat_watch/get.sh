#!/usr/bin/env bash
# get.sh - one-line installer / upgrader for threat_watch
#
#   curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/get.sh | sudo bash -s -- --account intellia
#   curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/get.sh | sudo bash -s -- --upgrade
#
# Options (after "bash -s --"):
#   --account NAME   cPanel account to watch (asked if missing and a terminal is available)
#   --upgrade        update the code only, keep configs
#   --version X.Y.Z  install a specific release instead of the newest one
#   --hours N        run every N hours (default 3)
#   --no-cron        do not create the cron entry
#   --run-now        do a first real run right after installing
#
# Environment:
#   THREAT_WATCH_REPO         owner/repo (default HanifPaan/S-freakCus)
#   THREAT_WATCH_TARBALL_URL  download this tarball instead (testing / mirrors)

set -euo pipefail

REPO="${THREAT_WATCH_REPO:-HanifPaan/S-freakCus}"
ACCOUNT=""
VERSION=""
UPGRADE=0
RUN_NOW=0
PASS=()

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mthreat_watch:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --account) ACCOUNT="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --upgrade) UPGRADE=1; shift ;;
        --run-now) RUN_NOW=1; shift ;;
        --hours)   PASS+=(--hours "${2:-}"); shift 2 ;;
        --no-cron) PASS+=(--no-cron); shift ;;
        -h|--help) sed -n '2,19p' "$0" 2>/dev/null || true; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run as root:  curl -fsSL <url> | sudo bash -s -- --account NAME"
command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"

if [[ $UPGRADE -eq 0 && -z "$ACCOUNT" ]]; then
    if (exec </dev/tty) 2>/dev/null; then
        printf 'cPanel account to watch: ' > /dev/tty
        read -r ACCOUNT < /dev/tty || ACCOUNT=""
    fi
    [[ -n "$ACCOUNT" ]] || die "--account is required, e.g.  ... | sudo bash -s -- --account intellia"
fi
if [[ -n "$ACCOUNT" ]]; then
    [[ "$ACCOUNT" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid account name: $ACCOUNT"
    [[ -d "/usr/local/apache/domlogs/$ACCOUNT" ]] || say "warning: /usr/local/apache/domlogs/$ACCOUNT not found (is the account name right?)"
fi

# --- pick the release ---------------------------------------------------------
if [[ -n "${THREAT_WATCH_TARBALL_URL:-}" ]]; then
    URL="$THREAT_WATCH_TARBALL_URL"
    REF="custom"
else
    if [[ -n "$VERSION" ]]; then
        REF="threat_watch-v${VERSION#v}"
    else
        say "looking up the newest threat_watch release in $REPO"
        REF="$(curl -fsSL "https://api.github.com/repos/$REPO/tags?per_page=100" 2>/dev/null \
            | grep -o '"name": *"threat_watch-v[0-9][0-9.]*"' \
            | sed 's/.*"threat_watch-v\([0-9.]*\)"/\1/' \
            | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)"
        if [[ -n "$REF" ]]; then
            REF="threat_watch-v$REF"
        else
            say "no release tag found, using the main branch"
            REF="main"
        fi
    fi
    URL="https://codeload.github.com/$REPO/tar.gz/$REF"
fi

# --- download + extract ---------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "downloading $REF"
curl -fsSL "$URL" -o "$TMP/src.tar.gz" || die "download failed: $URL"
tar -xzf "$TMP/src.tar.gz" -C "$TMP" || die "could not extract the download"
SRC="$(find "$TMP" -mindepth 1 -maxdepth 3 -type f -name install.sh -path '*threat_watch*' -printf '%h\n' | head -1)"
[[ -n "$SRC" && -f "$SRC/lib/threat_watch.py" ]] || die "threat_watch folder not found in the download"

# --- install ----------------------------------------------------------------------
if [[ $UPGRADE -eq 1 && -z "$ACCOUNT" ]]; then
    bash "$SRC/install.sh" --upgrade
    say "upgraded to threat_watch $(cat "$SRC/VERSION")"
    exit 0
fi

bash "$SRC/install.sh" --account "$ACCOUNT" ${PASS[@]+"${PASS[@]}"}

CONF="/etc/threat_watch/$ACCOUNT.conf"
TW="/opt/threat_watch/threat_watch.sh"

say "building the country table (first time takes about a minute)"
"$TW" -c "$CONF" --refresh-geo || say "warning: country table not built yet; it will be retried on the next run"

if [[ $RUN_NOW -eq 1 ]]; then
    say "first run"
    "$TW" -c "$CONF" --stdout || true
fi

cat <<EOF

threat_watch $(cat "$SRC/VERSION") is installed for account '$ACCOUNT'.
  config  : $CONF
  reports : /home/$ACCOUNT/logs/threat_watch/
  cron    : /etc/cron.d/threat_watch_$ACCOUNT

Try:
  $TW -c $CONF --test-ip 1.2.3.4
  $TW -c $CONF --dry-run --details
EOF
