#!/bin/bash
# builds build/Watchlist.app and build/bin/watchlist (the cli used for cron and launchd)
set -euo pipefail
cd "$(dirname "$0")"

# use full xcode when command line tools are the active developer dir
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --product WatchlistApp
swift build -c release --product watchlist
BIN="$(swift build -c release --show-bin-path)"

APP="build/Watchlist.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/bin
cp "$BIN/WatchlistApp" "$APP/Contents/MacOS/Watchlist"
cp "$BIN/watchlist" build/bin/watchlist

# app icon, regenerated when make_icon.swift changes
if [ ! -f build/AppIcon.icns ] || [ make_icon.swift -nt build/AppIcon.icns ]; then
    rm -rf build/AppIcon.iconset
    swift make_icon.swift build/AppIcon.iconset >/dev/null
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Watchlist</string>
    <key>CFBundleDisplayName</key><string>Watchlist</string>
    <key>CFBundleIdentifier</key><string>local.personal.watchlist</string>
    <key>CFBundleExecutable</key><string>Watchlist</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# sign with a local apple development identity when one exists, so macOS treats every rebuild as the
# same app and remembers privacy permissions (like access to the documents folder). otherwise ad hoc.
# override with SIGN_IDENTITY="name or hash", or SIGN_IDENTITY=- to force ad hoc.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP" >/dev/null
codesign --force --sign "$IDENTITY" build/bin/watchlist >/dev/null
if [ "$IDENTITY" = "-" ]; then
    echo "Signed ad hoc (no Apple Development identity found)"
else
    echo "Signed with a local Apple Development identity"
fi

# nudge finder and the dock to pick up the new icon
touch "$APP"

echo "Built $APP"
echo "Built build/bin/watchlist"

# an already running copy keeps using the old build until it is fully quit
if pgrep -f "Watchlist.app/Contents/MacOS/Watchlist" >/dev/null; then
    echo "Note: Watchlist is still running the previous build. Quit it fully (menu bar icon > Quit Watchlist, or Cmd+Q) and reopen."
fi
