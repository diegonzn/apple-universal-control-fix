#!/bin/bash
# Stops and removes uc-watchdog. Logs are kept; delete them by hand if you want.

LABEL=local.uc-watchdog

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/uc-watchdog.sh"
echo "[OK] uc-watchdog removed. Logs left in ~/Library/Logs/uc-watchdog.{log,err}"
