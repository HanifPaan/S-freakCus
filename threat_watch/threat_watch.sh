#!/usr/bin/env bash
# threat_watch.sh - entry point for cron and manual runs.
#
# Finds a Python 3 interpreter, then runs lib/threat_watch.py at the lowest
# CPU/IO priority with a hard time limit. All arguments are passed through.
#
#   threat_watch.sh -c /etc/threat_watch/exampleuser.conf            # normal run
#   threat_watch.sh -c /etc/threat_watch/exampleuser.conf --dry-run  # look, don't write
#   threat_watch.sh -c /etc/threat_watch/exampleuser.conf --validate
#   threat_watch.sh --help
#
# Environment:
#   THREAT_WATCH_TIMEOUT   max seconds per run (default 600)
#   THREAT_WATCH_PYTHON    force a specific python3 binary

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
CORE="$SELF_DIR/lib/threat_watch.py"
TIMEOUT_SECS="${THREAT_WATCH_TIMEOUT:-600}"

if [[ ! -f "$CORE" ]]; then
    echo "threat_watch: missing $CORE" >&2
    exit 1
fi

PY="${THREAT_WATCH_PYTHON:-}"
if [[ -z "$PY" ]]; then
    for cand in python3 /usr/libexec/platform-python /usr/bin/python3.12 /usr/bin/python3.11 \
                /usr/bin/python3.9 /usr/bin/python3.8 /usr/bin/python3.6; do
        if command -v "$cand" >/dev/null 2>&1; then
            PY="$(command -v "$cand")"
            break
        fi
    done
fi
if [[ -z "$PY" ]]; then
    echo "threat_watch: no python3 found (set THREAT_WATCH_PYTHON)" >&2
    exit 1
fi
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)'; then
    echo "threat_watch: $PY is older than Python 3.6" >&2
    exit 1
fi

export LC_ALL=C
umask 077

cmd=("$PY" -I "$CORE" "$@")
if command -v timeout >/dev/null 2>&1; then
    cmd=(timeout "$TIMEOUT_SECS" "${cmd[@]}")
fi
if command -v ionice >/dev/null 2>&1; then
    cmd=(ionice -c3 "${cmd[@]}")
fi
exec nice -n 19 "${cmd[@]}"
