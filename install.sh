#!/bin/bash
# Installs (or reinstalls) uc-watchdog as a per-user LaunchAgent. No sudo.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=local.uc-watchdog
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 "$DIR/uc-watchdog.sh" "$HOME/.local/bin/uc-watchdog.sh"
sed -e "s|__HOME__|$HOME|g" -e "s|__LABEL__|$LABEL|g" "$DIR/uc-watchdog.plist" > "$PLIST"

# Notification helper with its own icon. osascript notifications always show
# the Script Editor icon, so build a tiny app bundle if swiftc is available.
# Without it the watchdog falls back to plain osascript notifications.
APP="$HOME/.local/share/uc-watchdog/UC Watchdog.app"
rm -rf "$APP"
if xcrun --find swiftc >/dev/null 2>&1; then
    TMP=$(mktemp -d)
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP/AppIcon.iconset"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz "$DIR/notifier/icon.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
        sips -z $((sz * 2)) $((sz * 2)) "$DIR/notifier/icon.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    if iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" &&
       xcrun swiftc -O -suppress-warnings -o "$APP/Contents/MacOS/uc-notify" "$DIR/notifier/notify.swift" &&
       cp "$DIR/notifier/Info.plist" "$APP/Contents/Info.plist" &&
       codesign --force --sign - "$APP" >/dev/null 2>&1; then
        echo "[OK] notification helper built"
    else
        echo "[WARN] could not build the notification helper, using plain notifications"
        rm -rf "$APP"
    fi
    rm -rf "$TMP"
else
    echo "[INFO] swiftc not found (xcode-select --install), using plain notifications"
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1

if launchctl print "gui/$(id -u)/$LABEL" | grep -q "state = running"; then
    echo "[OK] uc-watchdog is running. Log: ~/Library/Logs/uc-watchdog.log"
else
    echo "[WARN] uc-watchdog is not running. Check ~/Library/Logs/uc-watchdog.err"
    exit 1
fi
