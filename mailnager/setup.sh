#!/bin/bash
# setup.sh - install or update mailnager
#
# Install / update to the latest release:
#   curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/mailnager/setup.sh | bash
#
# Options (add after: | bash -s -- <options>):
#   --ref <tag|branch>    install a specific release tag (mailnager-v1.0.0)
#                         or a branch (main) for testing
#   --disk hdd|ssd|nvme   override the detected disk type for auto-tune
#   --update              used by the auto-updater (no spool report)
#
# Re-running is safe: program files are replaced, /etc/mailnager.conf
# is kept as is. Only settings that are missing from it are added.

REPO="HanifPaan/S-freakCus"
SUBDIR="mailnager"
TAG_PREFIX="mailnager-v"
RAW_BASE="https://raw.githubusercontent.com/$REPO"
API_RELEASES="https://api.github.com/repos/$REPO/releases?per_page=100"

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BIN="/usr/local/bin/mailnager"
UNINSTALL="/usr/local/bin/mailnager-uninstall"
CONF="/etc/mailnager.conf"
CRON="/etc/cron.d/mailnager"
ROTATE="/etc/logrotate.d/mailnager"
LOG="/var/log/mailnager.log"

ref=""; mode=install; disk_override=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ref)    ref=$2; shift 2 ;;
        --disk)   disk_override=$2; shift 2 ;;
        --update) mode=update; shift ;;
        -h|--help)
            echo "Usage: setup.sh [--ref <tag|branch>] [--disk hdd|ssd|nvme]"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Use the log path from an existing conf (root-owned only)
if [ -f "$CONF" ] && [ "$(stat -c %u "$CONF")" = "0" ] && [ -z "$(find "$CONF" -perm /022)" ]; then
    l=$( . "$CONF" >/dev/null 2>&1; echo "$LOG" ); case "$l" in /*) LOG=$l ;; esac
fi

log()  { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; }
say()  { [ "$mode" = install ] && echo "$*"; }
fail() { echo "ERROR: $*" >&2; log "SETUP: failed - $*"; exit 1; }

WORK=$(mktemp -d /tmp/mailnager-setup.XXXXXX) || { echo "cannot create temp dir"; exit 1; }
trap 'rm -rf "$WORK"; case "${MAILNAGER_TMP:-}" in /tmp/mailnager-update.*) rm -rf "$MAILNAGER_TMP" ;; esac' EXIT

# ---------------- checks ----------------
[ "$(id -u)" -eq 0 ] || fail "Run as root."
[ "${BASH_VERSINFO[0]}" -ge 4 ] || fail "bash 4 or newer is needed."
for c in exim exiqgrep flock find du awk sed install; do
    command -v "$c" >/dev/null 2>&1 || fail "$c not found."
done
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || fail "curl or wget is needed."

exec 8>/var/run/mailnager.setup.lock
flock -n 8 || fail "another setup/update is already running."

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 60 -o "$2" "$1"
    else
        wget -q -T 60 -O "$2" "$1"
    fi
}

latest_tag() {
    fetch "$API_RELEASES" "$WORK/releases.json" || return 1
    tr ',{}' '\n\n\n' < "$WORK/releases.json" | awk -v p="$TAG_PREFIX" '
        /"tag_name"[ ]*:/            { t=$0; sub(/.*"tag_name"[ ]*:[ ]*"/,"",t); sub(/".*/,"",t) }
        /"prerelease"[ ]*:[ ]*false/ { if (index(t,p)==1) print t; t="" }
        /"prerelease"[ ]*:[ ]*true/  { t="" }' |
        grep -E "^${TAG_PREFIX}[0-9]+(\.[0-9]+)*$" | sort -V | tail -n1
}

# ---------------- 1. which version ----------------
if [ -z "$ref" ]; then
    ref=$(latest_tag)
    [ -n "$ref" ] || fail "No release found on GitHub. Publish a release tagged ${TAG_PREFIX}1.0.0, or test with: --ref main"
fi
[[ $ref =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid --ref '$ref'"
if [[ $ref == "$TAG_PREFIX"* ]]; then ver=${ref#"$TAG_PREFIX"}; else ver=$ref; fi

old=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$BIN" 2>/dev/null | head -1)
[ -z "$old" ] && [ -f "$BIN" ] && old="legacy"

say "== mailnager setup: installing v$ver${old:+ (installed: v$old)} =="

# ---------------- 2. download and check files ----------------
for f in mailnager uninstall.sh; do
    fetch "$RAW_BASE/$ref/$SUBDIR/$f" "$WORK/$f" || fail "download failed: $f ($ref)"
    head -1 "$WORK/$f" | grep -q '^#!/bin/bash' || fail "$f from $ref does not look like a script"
    bash -n "$WORK/$f" 2>/dev/null || fail "syntax error in $f from $ref"
done
grep -q '^VERSION="dev"$' "$WORK/mailnager" || fail "version marker missing in mailnager"
sed -i "s/^VERSION=\"dev\"$/VERSION=\"$ver\"/" "$WORK/mailnager"

# ---------------- 3. spool report (install only) ----------------
if [ "$mode" = install ]; then
    echo "-- Current spool state --"
    echo "   inodes      : $(find /var/spool/exim/input 2>/dev/null | wc -l)"
    echo "   size        : $(du -sh /var/spool/exim/input 2>/dev/null | awk '{print $1}')"
    echo "   queue       : $(exim -bpc 2>/dev/null)"
    echo "   older 1 day : $(exiqgrep -o 86400 -c 2>/dev/null)"
fi

# ---------------- 4. auto-tune from server resources ----------------
# About 80% of the recommended values (slightly below), see README.
rank() { case $1 in nvme) echo 1 ;; ssd) echo 2 ;; vm|unknown) echo 3 ;; hdd) echo 4 ;; esac; }
detect_disk() {   # slowest disk under the given folder wins
    local src best=unknown n t r
    src=$(findmnt -no SOURCE --target "$1" 2>/dev/null | head -1); src=${src%%[*}
    [ -b "$src" ] || { echo unknown; return; }
    while read -r n t r; do
        [ "$t" = disk ] || continue
        case $n in
            nvme*) d=nvme ;;
            vd*|xvd*) [ "$r" = 0 ] && d=ssd || d=vm ;;
            *) [ "$r" = 0 ] && d=ssd || d=hdd ;;
        esac
        if [ "$best" = unknown ] || [ "$(rank "$d")" -gt "$(rank "$best")" ]; then best=$d; fi
    done < <(lsblk -rnso NAME,TYPE,ROTA "$src" 2>/dev/null)
    echo "$best"
}
clamp() { local v=$1; [ "$v" -lt "$2" ] && v=$2; [ "$v" -gt "$3" ] && v=$3; echo "$v"; }

cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
ram_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
spool_dir=/var/spool/exim; [ -d "$spool_dir" ] || spool_dir=/var
disk=${disk_override:-$(detect_disk "$spool_dir")}
case "$disk" in nvme|ssd|hdd|vm|unknown) ;; *) fail "--disk must be hdd, ssd or nvme" ;; esac

if   [ "$cores" -lt 3 ];  then ct=1; elif [ "$cores" -lt 6 ];  then ct=2; elif [ "$cores" -lt 12 ]; then ct=3; else ct=4; fi
if   [ "$ram_mb" -lt 3500 ]; then rt=1; elif [ "$ram_mb" -lt 7500 ]; then rt=2; elif [ "$ram_mb" -lt 30000 ]; then rt=3; else rt=4; fi
tier=$(( ct < rt ? ct : rt ))
case $tier in
    1) T_BATCH_SIZE=80;  T_BATCH_SLEEP=10; T_MAX_PER_RUN=1600 ;;
    2) T_BATCH_SIZE=200; T_BATCH_SLEEP=6;  T_MAX_PER_RUN=4000 ;;
    3) T_BATCH_SIZE=400; T_BATCH_SLEEP=4;  T_MAX_PER_RUN=8000 ;;
    4) T_BATCH_SIZE=800; T_BATCH_SLEEP=3;  T_MAX_PER_RUN=16000 ;;
esac
case $disk in
    hdd)  T_BATCH_SIZE=$(( T_BATCH_SIZE / 2 )); T_BATCH_SLEEP=$(( T_BATCH_SLEEP * 2 )) ;;
    nvme) T_BATCH_SIZE=$(( T_BATCH_SIZE * 2 )) ;;
esac

free_mb=$(df -Pm "$spool_dir" | awk 'NR==2{print $4}')
free_in=$(df -Pi "$spool_dir" | awk 'NR==2{print $4}')
T_MAX_SIZE_MB=$(clamp $(( ${free_mb:-0} * 8 / 100 )) 1024 20480)
case "$free_in" in ''|*[!0-9]*|0) T_MAX_INODES=240000 ;; *) T_MAX_INODES=$(clamp $(( free_in * 4 / 100 )) 20000 240000) ;; esac

# Keep an existing cron schedule / log retention when adding those settings
old_sched=$(grep -v '^#' "$CRON" 2>/dev/null | grep -v -- '--auto-update' | grep mailnager | head -1 | awk '{print $1,$2,$3,$4,$5}')
[[ $old_sched =~ ^[0-9*/,-]+( [0-9*/,-]+){4}$ ]] || old_sched="0 * * * *"
old_keep=$(awk '$1=="rotate"{print $2; exit}' "$ROTATE" 2>/dev/null)
case "$old_keep" in ''|*[!0-9]*) old_keep=2 ;; esac
upd_sched="$(( RANDOM % 60 )) $(( 2 + RANDOM % 4 )) * * *"   # random 02:00-05:59, spreads GitHub requests

# KEY | value | comment
settings() {
cat <<EOF
SPOOL|"/var/spool/exim/input"|folder that is checked
MAX_INODES|$T_MAX_INODES|clean up when inodes in SPOOL reach this
MAX_SIZE_MB|$T_MAX_SIZE_MB|clean up when SPOOL size reaches this (MB)
MAX_AGE|86400|remove mail older than this (seconds; 86400 = 1 day)
BATCH_SIZE|$T_BATCH_SIZE|messages removed per batch
BATCH_SLEEP|$T_BATCH_SLEEP|seconds to pause between batches
MAX_PER_RUN|$T_MAX_PER_RUN|max messages removed per run (0 = no cap)
DRYRUN|0|1 = log only, delete nothing
SCHEDULE|"$old_sched"|cron time for the check (default: every hour)
AUTO_UPDATE|1|1 = update daily from GitHub releases, 0 = off
UPDATE_SCHEDULE|"$upd_sched"|cron time for the daily update check
LOG|"/var/log/mailnager.log"|log file
LOG_KEEP|$old_keep|old monthly log files to keep
EOF
}
line() { printf '%-30s # %s\n' "$1=$2" "$3"; }

specs="$cores cores, $(( ram_mb / 1024 )).$(( ram_mb % 1024 * 10 / 1024 )) GB RAM, disk=$disk, $(( ${free_mb:-0} / 1024 )) GB free on $spool_dir"

# ---------------- 5. install program files ----------------
install -o root -g root -m 700 "$WORK/mailnager" "$BIN.new" && mv -f "$BIN.new" "$BIN" || fail "cannot install $BIN"
install -o root -g root -m 700 "$WORK/uninstall.sh" "$UNINSTALL.new" && mv -f "$UNINSTALL.new" "$UNINSTALL" || fail "cannot install $UNINSTALL"
say "-- Installed $BIN and $UNINSTALL"

# ---------------- 5b. move over from the old name (exim_queue_guard) ----------------
O_BIN="/usr/local/bin/exim_queue_guard.sh"
O_CONF="/etc/exim_queue_guard.conf"
O_LOG="/var/log/exim_queue_guard.log"
migrated=""
if [ -f "$O_BIN" ] || [ -f "$O_CONF" ]; then
    migrated=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$O_BIN" 2>/dev/null | head -1); migrated=${migrated:-legacy}
    rm -f /etc/cron.d/exim_queue_guard                       # stop old runs
    if [ -e /var/run/exim_queue_guard.lock ]; then           # wait for a running cleanup
        exec 7>/var/run/exim_queue_guard.lock; flock -w 600 7; exec 7>&-
    fi
    if [ -f "$O_CONF" ] && [ ! -f "$CONF" ]; then            # keep all old settings
        sed 's#^LOG="\{0,1\}/var/log/exim_queue_guard\.log"\{0,1\}#LOG="/var/log/mailnager.log"#' "$O_CONF" > "$WORK/conf.old"
        install -o root -g root -m 600 "$WORK/conf.old" "$CONF" || fail "cannot write $CONF"
        l=$( . "$CONF" >/dev/null 2>&1; echo "$LOG" ); case "$l" in /*) LOG=$l ;; esac
    fi
    if [ -f "$O_LOG" ] && [ ! -e /var/log/mailnager.log ]; then   # keep the old log history
        mv "$O_LOG" /var/log/mailnager.log
        for f in "$O_LOG".[0-9]* "$O_LOG"-[0-9]*; do
            [ -e "$f" ] && mv "$f" "/var/log/mailnager.log${f#"$O_LOG"}"
        done
    fi
    rm -f "$O_BIN" /usr/local/bin/exim_queue_guard_uninstall.sh "$O_CONF" /etc/logrotate.d/exim_queue_guard \
          /var/run/exim_queue_guard.lock /var/run/exim_queue_guard.setup.lock
    say "-- Moved over from exim_queue_guard v$migrated: settings and log kept, old files removed"
fi

# ---------------- 6. settings file ----------------
if [ ! -f "$CONF" ]; then
    {
        echo "# /etc/mailnager.conf - settings for mailnager"
        echo "# Edit freely: updates never change values here, they only add new settings."
        echo "# Changes to SCHEDULE / AUTO_UPDATE / UPDATE_SCHEDULE / LOG_KEEP apply on the"
        echo "# next run, or right away with: mailnager --apply"
        echo "#"
        echo "# Auto-tuned on $(date '+%F'): $specs"
        echo
        while IFS='|' read -r k v c; do line "$k" "$v" "$c"; done < <(settings)
    } > "$WORK/conf"
    install -o root -g root -m 600 "$WORK/conf" "$CONF" || fail "cannot write $CONF"
    say "-- Created $CONF (auto-tuned: $specs)"
else
    added=""
    while IFS='|' read -r k v c; do
        grep -q "^$k=" "$CONF" && continue
        [ -z "$added" ] && printf '\n# Added by update to v%s on %s\n' "$ver" "$(date '+%F')" >> "$CONF"
        line "$k" "$v" "$c" >> "$CONF"
        added="$added $k"
    done < <(settings)
    chown root:root "$CONF"; chmod 600 "$CONF"
    if [ -n "$added" ]; then say "-- Kept your settings in $CONF, added:$added"; log "UPDATE: added new settings:$added"
    else say "-- Kept your settings in $CONF (nothing new to add)"; fi
fi

# ---------------- 7. cron + logrotate from the conf ----------------
"$BIN" --apply >/dev/null || fail "$BIN --apply failed - check $CONF (see $LOG)"

if [ -n "$migrated" ]; then
    log "MIGRATE: exim_queue_guard v$migrated -> mailnager v$ver (settings and log kept)"
elif [ "$mode" = update ] || [ -n "$old" ]; then
    log "UPDATE: v${old:-none} -> v$ver"
else
    log "INSTALL: v$ver ($specs)"
fi

# ---------------- summary ----------------
if [ "$mode" = install ]; then
    echo
    echo "== Done: mailnager v$ver =="
    echo "Settings ($CONF):"
    grep -E '^[A-Z_]+=' "$CONF" | sed 's/^/   /'
    echo "Cron ($CRON):"
    grep -v '^#' "$CRON" | sed 's/^/   /'
    echo
    echo "Test first:  sed -i 's/^DRYRUN=.*/DRYRUN=1/' $CONF && $BIN; tail -3 $LOG"
    echo "Uninstall :  $UNINSTALL"
else
    echo "Updated to v$ver."
fi
