#!/usr/bin/env bash
# install.sh - install or reinstall threat_watch
#
#   curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s intellia
#   curl -fsSL .../install.sh | bash -s user1 user2       # several users
#   curl -fsSL .../install.sh | bash -s                   # no user yet: edit the settings file after
#
# Downloads threat_watch.sh and threat_watch.conf from the newest
# threat_watch-vX.Y.Z release. An existing settings file is never overwritten.
#
# Environment:
#   TW_VERSION=1.0.0   install this release instead of the newest one
#   TW_SRC=/path       copy the files from this folder instead of downloading

set -euo pipefail

REPO="HanifPaan/S-freakCus"
APP=/opt/threat_watch
LINK=/usr/local/bin/threat_watch
CONF_DIR=/etc/threat_watch
CONF=$CONF_DIR/threat_watch.conf
CRON=/etc/cron.d/threat_watch

die() { echo "install: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
command -v curl >/dev/null || die "curl is required"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- get the files --------------------------------------------------------
if [[ -n "${TW_SRC:-}" ]]; then
    cp "$TW_SRC/threat_watch.sh" "$TW_SRC/threat_watch.conf" "$TMP/"
    VER="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$TMP/threat_watch.sh")"
else
    VER="${TW_VERSION:-}"
    if [[ -z "$VER" ]]; then
        VER="$(curl -fsS --max-time 30 "https://api.github.com/repos/$REPO/tags?per_page=100" |
               grep -o '"name": *"threat_watch-v[0-9][0-9.]*"' | grep -o '[0-9][0-9.]*[0-9]' | sort -V | tail -1)" || true
        [[ -n "$VER" ]] || die "no threat_watch release found in $REPO"
    fi
    echo "downloading threat_watch $VER"
    for f in threat_watch.sh threat_watch.conf; do
        curl -fsSL --max-time 60 "https://github.com/$REPO/releases/download/threat_watch-v$VER/$f" -o "$TMP/$f" \
            || die "could not download $f from release threat_watch-v$VER"
    done
fi
bash -n "$TMP/threat_watch.sh" || die "downloaded threat_watch.sh is broken"

# --- put them in place ----------------------------------------------------
install -d -m 0755 "$APP"
install -m 0755 "$TMP/threat_watch.sh" "$APP/threat_watch.sh"
ln -sf "$APP/threat_watch.sh" "$LINK"

install -d -m 0700 "$CONF_DIR"
if [[ -e "$CONF" ]]; then
    echo "kept your settings: $CONF"
else
    install -m 0600 "$TMP/threat_watch.conf" "$CONF"
    [[ $# -gt 0 ]] && sed -i "s/^USERS=\"\"/USERS=\"$*\"/" "$CONF"
    echo "created settings: $CONF"
fi
install -m 0644 "$TMP/threat_watch.conf" "$CONF_DIR/threat_watch.conf.default"   # reference copy of the newest defaults

m=$(( RANDOM % 50 + 5 ))
cat > "$CRON" <<CRONEOF
# threat_watch
$m */3 * * * root $LINK run >/dev/null 2>&1
$(( (m + 20) % 60 )) 4 * * 0 root $LINK update --auto >/dev/null 2>&1
CRONEOF
chmod 0644 "$CRON"

echo
echo "threat_watch $VER installed"
echo "  code     : $APP/threat_watch.sh  (command: threat_watch)"
echo "  settings : $CONF"
echo "  reports  : /var/log/threat_watch/"
echo "  cron     : every 3 hours (minute $m), update check every Sunday"

if grep -q '^SCOPE="users"' "$CONF" && grep -q '^USERS=""' "$CONF"; then
    echo
    echo "No user set yet: edit USERS (or SCOPE) in $CONF, then run: threat_watch run"
else
    echo; echo "first run..."; "$LINK" run
fi
