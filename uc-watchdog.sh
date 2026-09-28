#!/bin/bash
# uc-watchdog: keeps macOS Universal Control connected.
#
# Follows the UniversalControl connection log live. When the peer Mac drops
# and does not come back on its own within UC_GRACE seconds, it restarts
# rapportd and sharingd (the Continuity daemons UC depends on). If the link
# is still down it retries with growing waits (1, 2, 5, 10 min) so it does
# not hammer the system while the other Mac is asleep.
#
# Runs as a per-user LaunchAgent (see install.sh). Needs no root.
# https://github.com/diegonzn/universal-control-watchdog

GRACE=${UC_GRACE:-15}
NOTIFY=${UC_NOTIFY:-1}
LOG=${UC_LOG:-"$HOME/Library/Logs/uc-watchdog.log"}
BACKOFF=(60 120 300 600)

state=unknown; down_since=0; last_fix=0; tries=0

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Keep the log small: past 1 MB, keep only the last 2000 lines.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

fix() {
    killall rapportd sharingd 2>/dev/null
    last_fix=$(date +%s); tries=$((tries + 1))
    log "fix #$tries (down for $((last_fix - down_since))s)"
    if [ "$NOTIFY" = 1 ]; then
        osascript -e 'display notification "Connection lost, restarting rapportd/sharingd" with title "Universal Control"' >/dev/null 2>&1
    fi
}

# log stream feeds a FIFO so we can read with a timeout and still notice if
# the stream dies (in bash 3.2 'read -t' returns the same on timeout and EOF).
FIFO=$(mktemp -u "${TMPDIR:-/tmp}/uc-watchdog.XXXXXX")
mkfifo "$FIFO"
/usr/bin/log stream --style compact \
    --predicate 'process == "UniversalControl" AND category == "CONN"' > "$FIFO" &
STREAM=$!
exec 3< "$FIFO"
rm -f "$FIFO"
trap 'kill $STREAM 2>/dev/null' EXIT

log "start (grace=${GRACE}s, pid $$)"
while :; do
    if IFS= read -r -t 5 line <&3; then
        case "$line" in
            *"update connections:"*"-> []")
                if [ "$state" != down ]; then
                    state=down; down_since=$(date +%s); log "down"
                fi ;;
            *"update connections:"*"-> ["*"(connected)]")
                [ "$state" = down ] && log "reconnected after $(($(date +%s) - down_since))s"
                state=up; tries=0 ;;
        esac
    elif ! kill -0 $STREAM 2>/dev/null; then
        log "log stream ended, exiting so launchd restarts us"; exit 1
    fi

    if [ "$state" = down ]; then
        now=$(date +%s)
        if [ $tries -eq 0 ]; then
            [ $((now - down_since)) -ge $GRACE ] && fix
        else
            i=$((tries - 1)); [ $i -gt 3 ] && i=3
            [ $((now - last_fix)) -ge ${BACKOFF[$i]} ] && fix
        fi
    fi
done
