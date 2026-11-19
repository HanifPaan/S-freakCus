#!/usr/bin/env bash
# run_tests.sh - end-to-end tests with fixture logs and a fake country table.
# No network, no root needed. Exit code 0 = all passed.

set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$HERE")"
FIX="$HERE/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
has()  { grep -qE -- "$2" "$1" && ok "$3" || { bad "$3"; echo "       (pattern: $2 in $1)"; }; }
hasnt(){ grep -qE -- "$2" "$1" && { bad "$3"; echo "       (unexpected: $2 in $1)"; } || ok "$3"; }

mkdir -p "$WORK/domlogs" "$WORK/archive" "$WORK/rules.local"
cp "$FIX"/*_log "$WORK/domlogs/"
chmod 700 "$WORK"

CONF="$WORK/test.conf"
cat > "$CONF" <<EOF
INSTANCE_NAME="test"
DOMLOG_DIR="$WORK/domlogs"
ARCHIVE_DIR="$WORK/archive"
OUTPUT_DIR="$WORK/out"
STATE_DIR="$WORK/state"
WATCH_COUNTRIES="ID"
WHITELIST_COUNTRIES="MY"
WHITELIST_IPS="127.0.0.1"
RIR_SOURCES="file://$FIX/delegated-test.txt"
LOCAL_RULES_DIR="$WORK/rules.local"
TOP_NORMAL="5"
EOF

run() { "$ROOT/threat_watch.sh" -c "$CONF" "$@"; }

echo "== validate"
run --validate > "$WORK/validate.txt" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "validate exit 0" || { bad "validate exit $rc"; cat "$WORK/validate.txt"; }
has "$WORK/validate.txt" "logs found +: 2" "bytes_log excluded"

echo "== test-ip"
run --test-ip 140.213.184.73 175.136.5.5 66.249.66.1 2001:448a::1 8.8.8.8 bogus > "$WORK/ip.txt" 2>&1
has "$WORK/ip.txt" "140.213.184.73 +country=ID +-> watch" "ID ip watched"
has "$WORK/ip.txt" "175.136.5.5 +country=MY +-> whitelist" "MY ip whitelisted"
has "$WORK/ip.txt" "66.249.66.1 +country=US +-> other" "US ip other"
has "$WORK/ip.txt" "2001:448a::1 +country=ID" "IPv6 lookup"
has "$WORK/ip.txt" "8.8.8.8 +country=\?\?" "unknown ip"
has "$WORK/ip.txt" "bogus +invalid" "invalid ip"

echo "== dry run writes nothing"
run --dry-run --details > "$WORK/dry.txt" 2>&1
has "$WORK/dry.txt" "dry run" "dry run banner"
[[ ! -e "$WORK/out" ]] && ok "no output dir on dry run" || bad "output dir created on dry run"
[[ ! -e "$WORK/state/test/state.json" ]] && ok "no state on dry run" || bad "state written on dry run"

echo "== first run"
run --stdout > "$WORK/run1.txt" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "run exit 0" || { bad "run exit $rc"; cat "$WORK/run1.txt"; }
S="$WORK/out/latest_summary.txt"
D="$(ls "$WORK"/out/*_suspicious.txt 2>/dev/null | head -1)"
[[ -n "$D" ]] && ok "suspicious file written" || bad "no suspicious file"
has "$S" "^  attack +3 " "3 attack IPs"
has "$S" "140.213.184.73 +ID +attack" "jce POST + acym shell = attack"
has "$S" "140.213.185.165 +ID +attack +2 +2" "tmp shells with 2 hits"
has "$S" "112.215.50.219 +ID +attack .*tmp_file_access" "upload check on /tmp/*.txt = attack"
has "$S" "140.213.20.20 +ID +fake_bot" "fake googlebot from ID"
has "$S" "112.215.2.2 +ID +scanner .*php_404_x25" "404 flood -> scanner"
has "$S" "112.215.1.1 +ID +scanner .*hidden_files" ".git probe -> scanner"
has "$S" "112.215.3.3 +ID +scanner .*http_library" "python-requests -> scanner"
has "$S" "semrush +1 +1" "semrush counted as bot"
has "$S" "140.213.10.5 +ID +6 " "normal visitor across 2 domains"
has "$S" "2001:448a:1000::5 +ID" "ipv6 normal visitor"
has "$S" "1 whitelisted" "MY visitor whitelisted"
has "$S" "1 unparsable" "bad line counted"
hasnt "$S" "175.136.5.5" "whitelisted IP not listed"
hasnt "$S" "139.47.19.242|149.154.161.214|66.249.66.1" "other countries not listed"
hasnt "$D" $'\x1b' "escape chars removed"
has "$D" '\\x1b\[31mRED\\u202eUA' "escape chars shown safely"
has "$WORK/out/repeat_offenders.txt" "140.213.184.73" "offenders file"
perm=$(stat -c %a "$WORK/out"); [[ "$perm" == "700" ]] && ok "out dir 700" || bad "out dir perm $perm"
perm=$(stat -c %a "$S"); [[ "$perm" == "600" ]] && ok "report 600" || bad "report perm $perm"

echo "== second run reads only new lines"
sleep 1
echo '140.213.184.73 - - [17/Nov/2026:17:40:31 +0800] "POST /index.php?option=com_jce HTTP/1.1" 200 125 "-" "x"' \
    >> "$WORK/domlogs/example.my-ssl_log"
printf '140.213.1.1 - - [17/Nov/2026:17:41:00 +0800] "GET /partial' >> "$WORK/domlogs/example.my-ssl_log"
run > /dev/null 2>&1
S2="$WORK/out/latest_summary.txt"
has "$S2" "Logs: +2 files, 1 new lines" "only 1 complete new line"
has "$S2" "140.213.184.73 +ID +attack +1 .* 2 " "repeat count = 2"
has "$WORK/out/repeat_offenders.txt" "140.213.184.73 +ID +attack +2" "offender runs=2"

echo "== partial line finished later"
printf ' HTTP/1.1" 200 10 "-" "Mozilla"\n' >> "$WORK/domlogs/example.my-ssl_log"
sleep 1
run > /dev/null 2>&1
has "$S2" "1 new lines" "partial line picked up once complete"
has "$S2" "140.213.1.1 +ID +1 " "completed line parsed"

echo "== rotation catch-up from archive"
L="$WORK/domlogs/example.my-ssl_log"
echo '112.215.77.7 - - [17/Nov/2026:21:00:00 +0800] "GET /.env HTTP/1.1" 404 10 "-" "Mozilla"' >> "$L"
gzip -c "$L" > "$WORK/archive/example.my-ssl_log-Nov-2026.gz"
rm -f "$L"
echo '112.215.88.8 - - [17/Nov/2026:21:51:00 +0800] "GET / HTTP/1.1" 200 10 "-" "Mozilla"' > "$L"
sleep 1
run > /dev/null 2>&1
has "$S2" "1 rotated" "rotation detected"
has "$S2" "112.215.77.7 +ID +scanner" "line before rotation recovered from archive"
has "$S2" "112.215.88.8 +ID +1 " "new file read from start"
hasnt "$S2" "140.213.184.73 .*example\.my" "old lines not re-read from archive"
has "$S2" "Logs: +2 files, 2 new lines" "exactly 1 archive line + 1 new line"

echo "== local rules + disabled rules"
echo 'my_probe ^GET\s+/secret-test' > "$WORK/rules.local/scanner.rules"
echo '112.215.99.9 - - [17/Nov/2026:22:00:00 +0800] "GET /secret-test HTTP/1.1" 404 10 "-" "Mozilla"' >> "$L"
echo '112.215.99.8 - - [17/Nov/2026:22:00:01 +0800] "GET /.env HTTP/1.1" 404 10 "-" "Mozilla"' >> "$L"
echo 'DISABLED_RULES="hidden_files"' >> "$CONF"
sleep 1
run > /dev/null 2>&1
has "$S2" "112.215.99.9 +ID +scanner .*my_probe" "local rule applied"
has "$S2" "112.215.99.8 +ID +1 " "disabled rule not applied"

echo "== security checks"
mkdir -p "$WORK/evil"
ln -s "$WORK/evil" "$WORK/linkout"
sed -i "s#^OUTPUT_DIR=.*#OUTPUT_DIR=\"$WORK/linkout\"#" "$CONF"
run > "$WORK/sec.txt" 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "symlinked output dir refused (exit 2)" || bad "symlink not refused (exit $rc)"
sed -i "s#^OUTPUT_DIR=.*#OUTPUT_DIR=\"$WORK/out\"#" "$CONF"
chmod 777 "$WORK/out"
run > "$WORK/sec2.txt" 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "world-writable output dir refused" || bad "writable dir not refused (exit $rc)"
chmod 700 "$WORK/out"

echo "== bad config"
echo 'WATCH_COUNTRIES="Indonesia"' > "$WORK/bad.conf"
echo "DOMLOG_DIR=\"$WORK/domlogs\"" >> "$WORK/bad.conf"
echo "OUTPUT_DIR=\"$WORK/out\"" >> "$WORK/bad.conf"
"$ROOT/threat_watch.sh" -c "$WORK/bad.conf" --validate > "$WORK/bad.txt" 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "invalid country code rejected" || bad "bad config exit $rc"
has "$WORK/bad.txt" "not 2-letter country codes: INDONESIA" "clear error message"

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
