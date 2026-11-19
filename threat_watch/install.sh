#!/usr/bin/env bash
# install.sh - install or upgrade threat_watch and set up one instance.
#
#   ./install.sh --account exampleuser            install/upgrade + config + cron
#   ./install.sh --account exampleuser --no-cron  install/upgrade + config only
#   ./install.sh --upgrade                     update code only (keeps configs)
#   ./install.sh --account exampleuser --uninstall   remove that instance's cron
#   ./install.sh --account exampleuser --uninstall --purge   ...and its state
#
# Options:
#   --prefix DIR     install code here (default /opt/threat_watch)
#   --hours N        run every N hours (default 3)

set -euo pipefail

PREFIX="/opt/threat_watch"
CONF_DIR="/etc/threat_watch"
STATE_BASE="/var/lib/threat_watch"
ACCOUNT=""
HOURS=3
DO_CRON=1
UNINSTALL=0
PURGE=0
UPGRADE_ONLY=0

die() { echo "install.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --account)   ACCOUNT="${2:-}"; shift 2 ;;
        --prefix)    PREFIX="${2:-}"; shift 2 ;;
        --hours)     HOURS="${2:-}"; shift 2 ;;
        --no-cron)   DO_CRON=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --purge)     PURGE=1; shift ;;
        --upgrade)   UPGRADE_ONLY=1; shift ;;
        -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
        *)           die "unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run as root"
[[ "$HOURS" =~ ^[0-9]+$ && "$HOURS" -ge 1 && "$HOURS" -le 24 ]] || die "--hours must be 1-24"
if [[ $UPGRADE_ONLY -eq 0 ]]; then
    [[ -n "$ACCOUNT" ]] || die "--account is required (or use --upgrade)"
    [[ "$ACCOUNT" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid account name: $ACCOUNT"
fi

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CRON_FILE="/etc/cron.d/threat_watch_${ACCOUNT}"
CONF_FILE="$CONF_DIR/${ACCOUNT}.conf"

if [[ $UNINSTALL -eq 1 ]]; then
    rm -f "$CRON_FILE" && echo "removed $CRON_FILE"
    if [[ $PURGE -eq 1 ]]; then
        rm -rf "${STATE_BASE:?}/${ACCOUNT}" && echo "removed $STATE_BASE/$ACCOUNT"
        echo "kept $CONF_FILE and the reports folder (delete by hand if wanted)"
    fi
    exit 0
fi

# --- code -------------------------------------------------------------------
install -d -m 0755 "$PREFIX" "$PREFIX/lib" "$PREFIX/rules"
install -m 0755 "$SRC/threat_watch.sh" "$PREFIX/threat_watch.sh"
install -m 0644 "$SRC/lib/threat_watch.py" "$PREFIX/lib/threat_watch.py"
install -m 0644 "$SRC"/rules/*.rules "$PREFIX/rules/"
install -m 0644 "$SRC/VERSION" "$PREFIX/VERSION"
install -m 0644 "$SRC/threat_watch.conf.example" "$PREFIX/threat_watch.conf.example"
echo "installed threat_watch $(cat "$SRC/VERSION") to $PREFIX"

install -d -m 0700 "$CONF_DIR" "$CONF_DIR/rules.local" "$STATE_BASE"
for kind in attack scanner scanner_ua bot_ua; do
    f="$CONF_DIR/rules.local/$kind.rules"
    [[ -e "$f" ]] || printf '# local %s rules: <rule_name> <regex>\n' "$kind" > "$f"
done

[[ $UPGRADE_ONLY -eq 1 ]] && { echo "upgrade done (configs untouched)"; exit 0; }

# --- config -----------------------------------------------------------------
if [[ -e "$CONF_FILE" ]]; then
    echo "kept existing $CONF_FILE"
else
    sed "s/__ACCOUNT__/${ACCOUNT}/g" "$SRC/threat_watch.conf.example" > "$CONF_FILE"
    chmod 0600 "$CONF_FILE"
    echo "created $CONF_FILE  (review WATCH_COUNTRIES / WHITELIST_* before the first run)"
fi

"$PREFIX/threat_watch.sh" -c "$CONF_FILE" --validate || die "config check failed; fix $CONF_FILE and re-run"

# --- cron -------------------------------------------------------------------
if [[ $DO_CRON -eq 1 ]]; then
    # spread instances over the hour so they do not all start at :00
    minute=$(( $(printf '%s' "$ACCOUNT" | cksum | cut -d' ' -f1) % 50 + 5 ))
    cat > "$CRON_FILE" <<EOF
# threat_watch for account ${ACCOUNT} - managed by install.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${minute} */${HOURS} * * * root ${PREFIX}/threat_watch.sh -c ${CONF_FILE} >/dev/null 2>&1
EOF
    chmod 0644 "$CRON_FILE"
    echo "cron: $CRON_FILE  (minute ${minute}, every ${HOURS}h)"
fi

echo
echo "Next:"
echo "  $PREFIX/threat_watch.sh -c $CONF_FILE --refresh-geo     # build the country table now"
echo "  $PREFIX/threat_watch.sh -c $CONF_FILE --dry-run         # preview without saving"
echo "  $PREFIX/threat_watch.sh -c $CONF_FILE --stdout          # first real run"
