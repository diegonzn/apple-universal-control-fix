#!/bin/bash
# Installs (or reinstalls) uc-watchdog as a per-user LaunchAgent. No sudo.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=local.uc-watchdog
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 "$DIR/uc-watchdog.sh" "$HOME/.local/bin/uc-watchdog.sh"
sed -e "s|__HOME__|$HOME|g" -e "s|__LABEL__|$LABEL|g" "$DIR/uc-watchdog.plist" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1

if launchctl print "gui/$(id -u)/$LABEL" | grep -q "state = running"; then
    echo "[OK] uc-watchdog is running. Log: ~/Library/Logs/uc-watchdog.log"
else
    echo "[WARN] uc-watchdog is not running. Check ~/Library/Logs/uc-watchdog.err"
    exit 1
fi
