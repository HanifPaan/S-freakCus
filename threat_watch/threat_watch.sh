#!/usr/bin/env bash
# threat_watch.sh - every 3 hours, log what visitors from chosen countries and
# suspicious visitors (any country) did on your cPanel sites.
#
#   threat_watch run                 check new log lines now (cron does this every 3h)
#   threat_watch update              update the code to the newest release
#   threat_watch test-ip IP [IP..]   show the country of an IP
#   threat_watch uninstall [--purge] remove cron + code (--purge: also logs + settings)
#   threat_watch version
#
# Settings: /etc/threat_watch/threat_watch.conf
# Install:  curl -fsSL https://raw.githubusercontent.com/HanifPaan/S-freakCus/main/threat_watch/install.sh | bash -s intellia

VERSION="1.0.0"
REPO_DEFAULT="HanifPaan/S-freakCus"

APP=/opt/threat_watch
BIN=$APP/threat_watch.sh
LINK=/usr/local/bin/threat_watch
CONF=/etc/threat_watch/threat_watch.conf
CRON=/etc/cron.d/threat_watch
STATE=/var/lib/threat_watch
LOGS=/var/log/threat_watch

set -uo pipefail
export LC_ALL=C
umask 077

die() { echo "threat_watch: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "run as root"; }

load_conf() {
    [[ -r "$CONF" ]] || die "missing $CONF (install with install.sh)"
    # shellcheck source=/dev/null
    source "$CONF"
    SCOPE="${SCOPE:-users}"; DOMLOGS="${DOMLOGS:-/usr/local/apache/domlogs}"
    REPO="${REPO:-$REPO_DEFAULT}"; KEEP_DAYS="${KEEP_DAYS:-30}"
    PHP_404_LIMIT="${PHP_404_LIMIT:-20}"; MAX_LINES_PER_IP="${MAX_LINES_PER_IP:-30}"
}

# ---------------------------------------------------------------- country list
RANGES="$STATE/ranges.txt"
RIR_URLS="https://ftp.apnic.net/stats/apnic/delegated-apnic-latest
https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-latest
https://ftp.arin.net/pub/stats/arin/delegated-arin-extended-latest
https://ftp.afrinic.net/pub/stats/afrinic/delegated-afrinic-latest
https://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-latest"

refresh_countries() {
    [[ -s "$RANGES" && -z "$(find "$RANGES" -mtime +7 2>/dev/null)" ]] && return 0
    local tmp; tmp="$(mktemp "$STATE/ranges.XXXX")"
    for url in ${TW_RIR_URLS:-$RIR_URLS}; do curl -fsS --max-time 120 "$url" 2>/dev/null; done |
      awk -F'|' '$3 == "ipv4" && ($7 == "allocated" || $7 == "assigned") && $2 ~ /^[A-Z][A-Z]$/ {
          split($4, o, "."); s = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
          printf "%.0f %.0f %s\n", s, s + $5 - 1, $2 }' | sort -n > "$tmp"
    if [[ -s "$tmp" ]]; then mv "$tmp" "$RANGES"
    else rm -f "$tmp"; echo "threat_watch: could not download the country list" >&2; [[ -s "$RANGES" ]] || return 1
    fi
}

# Shared awk code: load ranges into S/E/C, country(ip) by binary search.
AWK_COUNTRY='
function load_ranges(f,   l, p) { while ((getline l < f) > 0) { split(l, p, " "); R++; S[R] = p[1] + 0; E[R] = p[2] + 0; C[R] = p[3] } }
function country(ip,   o, n, lo, hi, m) {
    if (ip in CC) return CC[ip]
    CC[ip] = "??"
    if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return "??"
    split(ip, o, "."); n = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
    lo = 1; hi = R
    while (lo <= hi) { m = int((lo + hi) / 2); if (n < S[m]) hi = m - 1; else if (n > E[m]) lo = m + 1; else { CC[ip] = C[m]; break } }
    return CC[ip]
}'

# ---------------------------------------------------------------- targets
# Prints "kind|name|logfile" for every log file in scope.
list_targets() {
    local u d f
    case "$SCOPE" in
      all)
        for d in "$DOMLOGS"/*/; do
            [[ -d "$d" ]] || continue; u="$(basename "$d")"
            for f in "$d"*; do echo "user|$u|$f"; done
        done ;;
      users)
        for u in $USERS; do
            [[ -d "$DOMLOGS/$u" ]] || { echo "threat_watch: no logs for user $u" >&2; continue; }
            for f in "$DOMLOGS/$u"/*; do echo "user|$u|$f"; done
        done ;;
      domains)
        for d in $DOMAINS; do
            local found=0
            for f in "$DOMLOGS"/*/"$d" "$DOMLOGS"/*/"$d"-ssl_log; do
                [[ -f "$f" ]] && { echo "domain|$d|$f"; found=1; }
            done
            if [[ $found -eq 0 ]]; then
                for f in "$DOMLOGS/$d" "$DOMLOGS/$d-ssl_log"; do [[ -f "$f" ]] && echo "domain|$d|$f"; done
            fi
        done ;;
      *) die "SCOPE must be all, users or domains" ;;
    esac | while IFS='|' read -r k n f; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        case "$f" in *-bytes_log|*-ftp_log|*.gz|*.bkup|*.offset|*.old) continue ;; esac
        echo "$k|$n|$f"
    done
}

# ---------------------------------------------------------------- run
cmd_run() {
    need_root; load_conf
    mkdir -p "$STATE" "$LOGS"; chmod 700 "$STATE" "$LOGS"
    exec 9>"$STATE/lock"; flock -n 9 || exit 0
    refresh_countries || exit 1

    declare -A POS
    local p s
    [[ -f "$STATE/positions" ]] && while read -r p s; do POS["$p"]="$s"; done < "$STATE/positions"

    local stamp file_stamp total_lines=0 total_flagged=0 targets=0
    stamp="$(date '+%Y-%m-%d %H:%M')"; file_stamp="$(date +%Y-%m-%d_%H%M)"
    local chunk="$STATE/chunk"

    # group log files by target
    declare -A FILES
    local k n f
    while IFS='|' read -r k n f; do FILES["$k/$n"]+="$f"$'\n'; done < <(list_targets)

    local key
    for key in "${!FILES[@]}"; do
        targets=$((targets + 1))
        local out="$LOGS/$key"; mkdir -p "$out"; chmod 700 "$out"
        local feed="$STATE/feed"; : > "$feed"
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            local size old cnt dom
            size="$(stat -c %s "$f")"; old="${POS[$f]:-0}"
            (( size < old )) && old=0                       # log rotated
            tail -c +"$((old + 1))" "$f" | head -c "$((size - old))" > "$chunk"
            cnt="$(stat -c %s "$chunk")"
            if (( cnt > 0 )) && [[ "$(tail -c 1 "$chunk" | wc -l)" -eq 0 ]]; then
                cnt=$(( cnt - $(tail -c 1048576 "$chunk" | awk 'END { print length($0) }') ))   # leave unfinished line
            fi
            dom="$(basename "$f")"; dom="${dom%-ssl_log}"
            head -c "$cnt" "$chunk" | sed "s|^|$dom |" >> "$feed"
            POS["$f"]=$(( old + cnt ))
        done <<< "${FILES[$key]}"

        local result="$STATE/result"
        TW_BAD="${BAD_REQUESTS:-}" TW_BADUA="${BAD_AGENTS:-}" awk \
            -v ranges="$RANGES" -v watch=" ${WATCH:-} " -v wl=" ${WHITELIST:-} " -v wlip=" ${WHITELIST_IPS:-} " \
            -v limit="$PHP_404_LIMIT" -v maxl="$MAX_LINES_PER_IP" -v stamp="$stamp" -v target="$key" \
            "$AWK_COUNTRY"'
        BEGIN { load_ranges(ranges); bad = tolower(ENVIRON["TW_BAD"]); badua = tolower(ENVIRON["TW_BADUA"]) }
        {
            lines++; dom = $1; ip = $2
            if (index(wlip, " " ip " ")) next
            split($0, q, "\""); req = q[2]; ua = q[6]; split(q[3], st, " "); status = st[1]
            t = substr($5, 2, 20)
            why = ""
            if (bad != "" && tolower(req) ~ bad) why = "bad request"
            else if (badua != "" && tolower(ua) ~ badua) why = "hacking tool"
            else if (status == 404 && req ~ /\.[Pp][Hh][Pp]/ && ++p404[ip] >= limit) why = "many .php 404s"
            c = country(ip)
            watched = index(watch, " " c " ") > 0
            if (why != "") sus[ip] = 1
            else if (!watched || index(wl, " " c " ")) next
            gsub(/[[:cntrl:]]/, "?", req)
            hits[ip]++; cn[ip] = c
            if (!index(" " doms[ip] " ", " " dom " ")) doms[ip] = doms[ip] (doms[ip] ? " " : "") dom
            if (++shown[ip] <= maxl)
                det[ip] = det[ip] sprintf("    %s  %-26s %s  %s%s\n", t, dom, substr(req, 1, 160), status, why != "" ? "  <- " why : "")
        }
        END {
            for (ip in hits) { n++; if (ip in sus) ns++ }
            w = watch; gsub(/^ +| +$/, "", w)
            printf "=== %s | %s | new lines: %d | flagged IPs: %d (suspicious: %d, from %s: %d)\n\n", stamp, target, lines, n, ns, w, n - ns
            if (!n) { print "nothing to report"; exit }
            print "SUSPICIOUS"; if (!ns) print "  none"
            for (ip in sus) printf "  %s [%s] %d req  %s\n%s\n", ip, cn[ip], hits[ip], doms[ip], det[ip]
            printf "\nVISITORS FROM %s\n", w; if (n == ns) print "  none"
            for (ip in hits) if (!(ip in sus)) printf "  %s [%s] %d req  %s\n%s\n", ip, cn[ip], hits[ip], doms[ip], det[ip]
        }' "$feed" > "$result"

        local nlines nflag
        nlines="$(wc -l < "$feed")"; nflag="$(sed -n '1s/.*flagged IPs: \([0-9]*\).*/\1/p' "$result")"
        total_lines=$((total_lines + nlines)); total_flagged=$((total_flagged + ${nflag:-0}))
        cp "$result" "$out/latest.txt"
        [[ "${nflag:-0}" -gt 0 ]] && cp "$result" "$out/$file_stamp.txt"
    done
    rm -f "$chunk" "$STATE/feed" "$STATE/result"

    for p in "${!POS[@]}"; do [[ -f "$p" ]] && echo "$p ${POS[$p]}"; done > "$STATE/positions.new"
    mv "$STATE/positions.new" "$STATE/positions"

    find "$LOGS" -name '20*.txt' -mtime +"$KEEP_DAYS" -delete 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') v$VERSION scope=$SCOPE targets=$targets lines=$total_lines flagged=$total_flagged" >> "$LOGS/run.log"
    tail -n 2000 "$LOGS/run.log" > "$LOGS/run.log.tmp" && mv "$LOGS/run.log.tmp" "$LOGS/run.log"
    [[ -t 1 ]] && echo "done: $targets target(s), $total_lines new lines, $total_flagged flagged IPs -> $LOGS/"
    return 0
}

# ---------------------------------------------------------------- update
latest_tag() {
    curl -fsS --max-time 30 "https://api.github.com/repos/$1/tags?per_page=100" 2>/dev/null |
      grep -o '"name": *"threat_watch-v[0-9][0-9.]*"' | grep -o '[0-9][0-9.]*[0-9]' | sort -V | tail -1
}

download_release() {   # repo version dest
    curl -fsSL --max-time 60 "https://github.com/$1/releases/download/threat_watch-v$2/threat_watch.sh" -o "$3" || return 1
    head -1 "$3" | grep -q '^#!/usr/bin/env bash' && grep -q '^VERSION="' "$3" && bash -n "$3"
}

cmd_update() {
    need_root
    local mode="manual"; [[ "${1:-}" == "--auto" ]] && mode="auto"
    local repo="$REPO_DEFAULT"; [[ -r "$CONF" ]] && repo="$(. "$CONF"; echo "${REPO:-$REPO_DEFAULT}")"
    mkdir -p "$LOGS"; chmod 700 "$LOGS"
    local ulog="$LOGS/update.log" now; now="$(date '+%Y-%m-%d %H:%M:%S')"
    local new; new="$(latest_tag "$repo")"
    if [[ -z "$new" ]]; then
        echo "$now [$mode] FAILED: could not read releases from $repo" >> "$ulog"; die "could not check for updates"
    fi
    if [[ "$(printf '%s\n%s\n' "$VERSION" "$new" | sort -V | tail -1)" == "$VERSION" ]]; then
        echo "$now [$mode] up to date ($VERSION)" >> "$ulog"
        [[ -t 1 ]] && echo "already up to date ($VERSION)"; return 0
    fi
    local tmp; tmp="$(mktemp)"
    if download_release "$repo" "$new" "$tmp"; then
        install -m 0755 "$tmp" "$BIN"; rm -f "$tmp"
        echo "$now [$mode] updated $VERSION -> $new" >> "$ulog"
        [[ -t 1 ]] && echo "updated $VERSION -> $new"; return 0
    fi
    rm -f "$tmp"
    echo "$now [$mode] FAILED: download/check of $new failed, kept $VERSION" >> "$ulog"
    die "update to $new failed, kept $VERSION"
}

# ---------------------------------------------------------------- uninstall
cmd_uninstall() {
    need_root
    rm -f "$CRON" "$LINK"; rm -rf "$APP"
    echo "removed cron, $APP and $LINK"
    if [[ "${1:-}" == "--purge" ]]; then
        rm -rf "$STATE" "$LOGS" /etc/threat_watch; echo "removed $STATE $LOGS /etc/threat_watch"
    else
        echo "kept $CONF and $LOGS (use --purge to remove them)"
    fi
}

cmd_test_ip() {
    [[ -s "$RANGES" ]] || die "no country list yet (run: threat_watch run)"
    printf '%s\n' "$@" | awk -v ranges="$RANGES" "$AWK_COUNTRY"' BEGIN { load_ranges(ranges) } { printf "%-16s %s\n", $1, country($1) }'
}

case "${1:-}" in
    run)        cmd_run ;;
    update)     shift; cmd_update "$@" ;;
    uninstall)  shift; cmd_uninstall "$@" ;;
    test-ip)    shift; [[ $# -gt 0 ]] || die "usage: threat_watch test-ip IP [IP..]"; cmd_test_ip "$@" ;;
    version)    echo "threat_watch $VERSION" ;;
    *)          sed -n '2,13p' "$0" 2>/dev/null || echo "usage: threat_watch run|update|uninstall|test-ip|version" ;;
esac
