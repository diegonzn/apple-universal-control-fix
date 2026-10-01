#!/bin/bash
# uc-watchdog: keeps macOS Universal Control connected.
#
# Follows the UniversalControl log live and acts on three problems:
#
# 1. The peer Mac drops and does not come back within UC_GRACE seconds.
#    Fix #1 restarts only rapportd (the Continuity discovery daemon). If the
#    link is still down 20 s later, fix #2 also restarts sharingd, then it
#    retries with growing waits (1, 2, 5, 10 min) so it does not hammer the
#    system while the other Mac is asleep. sharingd is left alone on the
#    first try because restarting it also breaks Handoff and Universal
#    Clipboard for several minutes.
#
# 2. A "link storm": UniversalControl activates hundreds of rapport links
#    per minute, usually because another Mac on the same Apple ID is nearby
#    with Universal Control off. rapportd goes to 80% CPU and the pointer
#    lags or refuses to cross. Fix: restart UniversalControl and rapportd.
#
# 3. UniversalControl bloated beyond UC_MEM_MAX MB (it leaks link objects
#    during storms and gets slow). Fix: restart UniversalControl.
#
# Runs as a per-user LaunchAgent (see install.sh). Needs no root.
# https://github.com/diegonzn/apple-universal-control-fix

GRACE=${UC_GRACE:-5}
NOTIFY=${UC_NOTIFY:-1}
LOG=${UC_LOG:-"$HOME/Library/Logs/uc-watchdog.log"}
STORM_MAX=${UC_STORM_MAX:-60}   # link activations per minute that count as a storm
MEM_MAX=${UC_MEM_MAX:-200}      # MB of UniversalControl memory that trigger a restart
BACKOFF=(20 60 120 300 600)     # seconds to wait after fix #1, #2, #3, #4, #5+
UC_JOB="gui/$(id -u)/com.apple.ensemble"   # launchd job that runs UniversalControl

state=unknown; down_since=0; last_fix=0; tries=0
acts=0; win_start=$SECONDS; last_uc_restart=-9999; uc_pending=0

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Keep the log small: past 1 MB, keep only the last 2000 lines.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

NOTIFIER="$HOME/.local/share/uc-watchdog/UC Watchdog.app/Contents/MacOS/uc-notify"

# Uses the helper built by install.sh (shows the UC Watchdog icon) if present.
notify() {
    [ "$NOTIFY" = 1 ] || return
    if [ -x "$NOTIFIER" ]; then
        "$NOTIFIER" "Universal Control" "$1" >/dev/null 2>&1 && return
    fi
    osascript -e "display notification \"$1\" with title \"Universal Control\"" >/dev/null 2>&1
}

# Only the first fix of an outage notifies, plus one heads-up when retries
# slow down to every 10 min (the other Mac is probably off or asleep).
fix() {
    tries=$((tries + 1))
    if [ $tries -eq 1 ]; then
        killall rapportd 2>/dev/null; what=rapportd
    else
        killall rapportd sharingd 2>/dev/null; what="rapportd+sharingd"
    fi
    last_fix=$SECONDS
    log "fix #$tries ($what, down for $((last_fix - down_since))s)"
    case $tries in
        1) notify "Connection lost, reconnecting..." ;;
        5) notify "Other Mac not responding (off or asleep?). Retrying quietly every 10 min." ;;
    esac
}

# Restarts UniversalControl (launchd relaunches it) at most once per 10 min.
# $1 goes to the log, $2 to the notification.
restart_uc() {
    [ $((SECONDS - last_uc_restart)) -ge 600 ] || return
    [ "$3" = with_rapportd ] && killall rapportd 2>/dev/null
    launchctl kickstart -k "$UC_JOB" 2>/dev/null
    last_uc_restart=$SECONDS; uc_pending=1
    state=unknown; tries=0
    log "restart UniversalControl: $1"
    notify "$2"
}

# Memory of the UniversalControl process in MB (0 if not running).
uc_mem() {
    local pid rss
    pid=$(pgrep -x UniversalControl | head -1)
    [ -n "$pid" ] || { echo 0; return; }
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    echo $(( ${rss:-0} / 1024 ))
}

# log stream feeds a FIFO so we can read with a timeout and still notice if
# the stream dies (in bash 3.2 'read -t' returns the same on timeout and EOF).
FIFO=$(mktemp -u "${TMPDIR:-/tmp}/uc-watchdog.XXXXXX")
mkfifo "$FIFO"
/usr/bin/log stream --style compact \
    --predicate 'process == "UniversalControl" AND (category == "CONN" OR (category == "EVNT" AND eventMessage CONTAINS "REJECTED") OR (category == "CLinkClient" AND eventMessage BEGINSWITH "Activated: CLinkClient"))' > "$FIFO" &
STREAM=$!
exec 3< "$FIFO"
rm -f "$FIFO"
trap 'kill $STREAM 2>/dev/null' EXIT

log "start (grace=${GRACE}s, storm>${STORM_MAX}/min, mem>${MEM_MAX}MB, pid $$)"
while :; do
    if IFS= read -r -t 5 line <&3; then
        case "$line" in
            *"update connections:"*"-> []")
                if [ "$state" != down ]; then
                    state=down; down_since=$SECONDS; log "down"
                fi ;;
            *"update connections:"*"-> ["*"(connected)]")
                [ "$state" = down ] && log "reconnected after $((SECONDS - down_since))s"
                state=up; tries=0; uc_pending=0 ;;
            # The pointer crossed over but the other Mac refused it, so it
            # snapped back to this screen. Not a drop; logged for diagnosis.
            *"=== REJECTED ==="*)
                log "bounce: other Mac rejected the pointer, it came back" ;;
            # One rapport link activation. A few per minute is normal.
            *"Activated: CLinkClient"*)
                acts=$((acts + 1)) ;;
        esac
    elif ! kill -0 $STREAM 2>/dev/null; then
        log "log stream ended, exiting so launchd restarts us"; exit 1
    fi

    now=$SECONDS

    # Link storm and memory checks, once a minute.
    if [ $((now - win_start)) -ge 60 ]; then
        if [ $acts -ge $STORM_MAX ]; then
            restart_uc "link storm, $acts link activations in 60s" \
                "Link storm detected ($acts links/min). Restarting Universal Control." with_rapportd
        else
            mem=$(uc_mem)
            if [ "$mem" -gt "$MEM_MAX" ]; then
                restart_uc "memory ${mem} MB (limit ${MEM_MAX} MB)" \
                    "Universal Control was using ${mem} MB. Restarting it."
            fi
        fi
        acts=0; win_start=$now
    fi

    # After we restart UniversalControl it must reconnect within 2 min,
    # otherwise treat it as a drop so the normal fix path takes over.
    if [ $uc_pending = 1 ] && [ $((now - last_uc_restart)) -ge 120 ] && [ "$state" != up ]; then
        uc_pending=0; state=down; down_since=$now
        log "down (no reconnect within 120s after restarting UniversalControl)"
    fi

    if [ "$state" = down ]; then
        if [ $tries -eq 0 ]; then
            [ $((now - down_since)) -ge $GRACE ] && fix
        else
            i=$((tries - 1)); [ $i -gt 4 ] && i=4
            [ $((now - last_fix)) -ge ${BACKOFF[$i]} ] && fix
        fi
    fi
done
