#!/bin/bash
# uninstall.sh - remove exim_queue_guard completely, including its settings and logs.
#
#   /usr/local/bin/exim_queue_guard_uninstall.sh          asks before removing
#   /usr/local/bin/exim_queue_guard_uninstall.sh --yes    no question (for scripts)
#
# Or straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/exim-queue-guard/uninstall.sh | bash -s -- --yes

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BIN="/usr/local/bin/exim_queue_guard.sh"
UNINSTALL="/usr/local/bin/exim_queue_guard_uninstall.sh"
CONF="/etc/exim_queue_guard.conf"
CRON="/etc/cron.d/exim_queue_guard"
ROTATE="/etc/logrotate.d/exim_queue_guard"
LOCK="/var/run/exim_queue_guard.lock"
SETUP_LOCK="/var/run/exim_queue_guard.setup.lock"
LOG="/var/log/exim_queue_guard.log"

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

if [ "${1:-}" != "--yes" ]; then
    if { exec 3</dev/tty; } 2>/dev/null; then
        read -r -p "Remove exim_queue_guard, its settings and all its logs? [y/N] " a <&3
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
    echo "exim_queue_guard was not installed. Nothing removed."
else
    echo "exim_queue_guard removed. Deleted:"
    printf '   %s\n' "${removed[@]}"
fi
