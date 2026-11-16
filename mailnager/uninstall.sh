#!/bin/bash
# uninstall.sh - remove mailnager completely, including its settings and logs.
#
#   /usr/local/bin/mailnager-uninstall          asks before removing
#   /usr/local/bin/mailnager-uninstall --yes    no question (for scripts)
#
# Or straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/mailnager/uninstall.sh | bash -s -- --yes

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BIN="/usr/local/bin/mailnager"
UNINSTALL="/usr/local/bin/mailnager-uninstall"
CONF="/etc/mailnager.conf"
CRON="/etc/cron.d/mailnager"
ROTATE="/etc/logrotate.d/mailnager"
LOCK="/var/run/mailnager.lock"
SETUP_LOCK="/var/run/mailnager.setup.lock"
LOG="/var/log/mailnager.log"

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

if [ "${1:-}" != "--yes" ]; then
    if { exec 3</dev/tty; } 2>/dev/null; then
        read -r -p "Remove mailnager, its settings and all its logs? [y/N] " a <&3
        exec 3<&-
        case "$a" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
    else
        echo "No terminal to ask on. Run again with --yes to confirm."; exit 1
    fi
fi

# Log path from the conf, if it was changed
if [ -f "$CONF" ] && [ "$(stat -c %u "$CONF")" = "0" ]; then
    l=$( . "$CONF" >/dev/null 2>&1; echo "$LOG" )
    case "$l" in /*.log) LOG=$l ;; esac
fi

# 1. stop new runs
removed=()
[ -e "$CRON" ] && rm -f "$CRON" && removed+=("$CRON")

# 2. wait for a cleanup that is running right now (up to 10 minutes)
if [ -e "$LOCK" ]; then
    exec 9>"$LOCK"
    flock -w 600 9 || echo "Warning: a cleanup run is still going; removing anyway."
fi

# 3. remove everything
for f in "$BIN" "$UNINSTALL" "$CONF" "$ROTATE" "$LOCK" "$SETUP_LOCK" \
         "$LOG" "$LOG".[0-9]* "$LOG"-[0-9]*; do
    [ -e "$f" ] || continue
    rm -f "$f" && removed+=("$f")
done

if [ ${#removed[@]} -eq 0 ]; then
    echo "mailnager was not installed. Nothing removed."
else
    echo "mailnager removed. Deleted:"
    printf '   %s\n' "${removed[@]}"
fi
