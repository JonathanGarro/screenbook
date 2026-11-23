#!/bin/bash
# builds Screenbook.app and the screenbook cli.
#
#   ./build_app.sh             builds /Applications/Screenbook.app (or rebuilds it in ~/Applications if it lives
#                              there) and build/bin/screenbook, signed with your apple development certificate
#   ./build_app.sh --release   builds a notarized dist/Screenbook.dmg to share, and dist/appcast.xml for updates
#
# a release is signed with your "Developer ID Application" certificate and the hardened runtime, notarized by
# apple, and stapled, as an app and then as a dmg, so it opens on any mac without a warning. it needs the notary
# credentials saved once in the keychain:
#     xcrun notarytool store-credentials screenbook --apple-id <email> --team-id <team id>
# (set NOTARY_PROFILE to use credentials saved under another name). updates are signed with the sparkle key in
# the keychain, made once with:
#     .build/artifacts/sparkle/Sparkle/bin/generate_keys --account screenbook
# keep a copy of it (generate_keys --account screenbook -x <file>): installed apps only accept updates signed
# with it. publish a release, tagged with the version in VERSION:
#     gh release create v<version> dist/Screenbook.dmg dist/appcast.xml
set -euo pipefail
cd "$(dirname "$0")"

# config
APP_NAME="Screenbook"
BUNDLE_ID="io.github.jonathangarro.screenbook"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
RELEASES="https://github.com/JonathanGarro/screenbook/releases"
FEED_URL="$RELEASES/latest/download/appcast.xml"
SPARKLE_ACCOUNT="screenbook"
SPARKLE_PUBLIC_KEY="I5gpZ/cfqZwDbFYLrXvXvGJQyytWH3P+5o3ICTvKZXc="
NOTARY_PROFILE="${NOTARY_PROFILE:-screenbook}"
MIN_MACOS="14.0"
RELEASE=0
[ "${1:-}" = "--release" ] && RELEASE=1

# use full xcode when command line tools are the active developer dir; actool and swiftui's macros need it
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# helpers
identity_for() {
    security find-identity -v -p codesigning 2>/dev/null | awk -F'"' -v kind="$1" '$2 ~ "^"kind {print $2; exit}'
}

sign() {
    # sign "<path>" [extra codesign args]; a release adds the hardened runtime and a secure timestamp
    local path="$1"; shift
    local args=(--force --sign "$IDENTITY")
    if [ "$RELEASE" = 1 ]; then args+=(--options runtime --timestamp); fi
    codesign "${args[@]}" "$@" "$path" >/dev/null
}

notarize() {
    # notarize "<zip or dmg>" "<what to staple>"; waits for apple's verdict
    local file="$1" staple="$2" out status id
    echo "Notarizing $(basename "$file") (this usually takes a few minutes)"
    out="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 2h 2>&1)" || true
    status="$(printf '%s\n' "$out" | awk -F': ' '/^ *status:/ {s=$2} END {print s}')"
    id="$(printf '%s\n' "$out" | awk -F': ' '/^ *id:/ {print $2; exit}')"
    if [ "$status" != "Accepted" ]; then
        echo "$out"
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        echo "Apple did not accept $(basename "$file") (status: ${status:-unknown})"
        exit 1
    fi
    xcrun stapler staple "$staple" >/dev/null
}

# main
if [ "$RELEASE" = 1 ]; then
    IDENTITY="$(identity_for "Developer ID Application")"
    [ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate. Add one in Xcode, Settings, Accounts, Manage Certificates."; exit 1; }
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
        echo "No working notary credentials saved as \"$NOTARY_PROFILE\". Save them with:"
        echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id <team id>"
        exit 1
    }
    APP="dist/$APP_NAME.app"
else
    # a stable signature lets macos remember permissions (like a vault in documents) across rebuilds
    IDENTITY="${SIGN_IDENTITY:-$(identity_for "Apple Development")}"
    IDENTITY="${IDENTITY:--}"
    APP="/Applications/$APP_NAME.app"
    [ -d "$HOME/Applications/$APP_NAME.app" ] && APP="$HOME/Applications/$APP_NAME.app"
fi

swift build -c release --product WatchlistApp
swift build -c release --product screenbook
BIN="$(swift build -c release --show-bin-path)"

# icons: edge to edge art compiled for macos 26, which masks it to its own shape, plus an
# .icns with the rounded shape drawn in for older macos
mkdir -p build
if [ ! -f build/icon.png ] || [ make_icon.swift -nt build/icon.png ]; then
    swift make_icon.swift --full-bleed build/icon.png >/dev/null
    rm -rf build/AppIcon.iconset
    swift make_icon.swift build/AppIcon.iconset >/dev/null
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" build/bin
cp "$BIN/WatchlistApp" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN/screenbook" build/bin/screenbook
# ditto keeps the framework's symlinks
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

ICON_TMP="$(mktemp -d)"
mkdir -p "$ICON_TMP/AppIcon.icon/Assets"
cp build/icon.png "$ICON_TMP/AppIcon.icon/Assets/art.png"
cat > "$ICON_TMP/AppIcon.icon/icon.json" <<JSON
{"groups":[{"layers":[{"image-name":"art.png","name":"art","glass":false}]}],"supported-platforms":{"squares":"shared"}}
JSON
# the app's accent color, the purple from the website, used by system controls (NSAccentColorName)
mkdir -p "$ICON_TMP/Assets.xcassets/AccentColor.colorset"
echo '{"info":{"author":"xcode","version":1}}' > "$ICON_TMP/Assets.xcassets/Contents.json"
cat > "$ICON_TMP/Assets.xcassets/AccentColor.colorset/Contents.json" <<JSON
{"colors":[
 {"idiom":"universal","color":{"color-space":"srgb","components":{"red":"0x4B","green":"0x44","blue":"0xC8","alpha":"1.000"}}},
 {"idiom":"universal","appearances":[{"appearance":"luminosity","value":"dark"}],
  "color":{"color-space":"srgb","components":{"red":"0x8A","green":"0x84","blue":"0xFF","alpha":"1.000"}}}],
 "info":{"author":"xcode","version":1}}
JSON
xcrun actool "$ICON_TMP/AppIcon.icon" "$ICON_TMP/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon --accent-color AccentColor \
    --output-partial-info-plist "$ICON_TMP/partial.plist" >/dev/null
rm -rf "$ICON_TMP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSAccentColorName</key><string>AccentColor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT license</string>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
</dict>
</plist>
PLIST

# sign inside out: sparkle's helpers as its docs lay out, then the app
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$FW/XPCServices/Installer.xpc"
sign "$FW/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
sign "$FW/Autoupdate"
sign "$FW/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
sign build/bin/screenbook

if [ "$RELEASE" = 1 ]; then
    mkdir -p dist
    ditto -c -k --keepParent "$APP" "dist/$APP_NAME.zip"
    notarize "dist/$APP_NAME.zip" "$APP"
    rm -f "dist/$APP_NAME.zip"
    # unversioned, so the site can link to releases/latest/download/Screenbook.dmg
    DMG="dist/$APP_NAME.dmg"
    rm -f "$DMG"
    STAGE="$(mktemp -d)"
    ditto "$APP" "$STAGE/$APP_NAME.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    sign "$DMG"
    notarize "$DMG" "$DMG"
    SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account "$SPARKLE_ACCOUNT" "$DMG")"
    PUBLISHED="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>$APP_NAME $VERSION</title>
      <pubDate>$PUBLISHED</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$RELEASES/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$RELEASES/download/v$VERSION/$APP_NAME.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
    # the version under the site's download buttons
    [ -f docs/index.html ] && sed -i '' -E "s#(<span class=\"version\">Version )[^<]*(</span>)#\1$VERSION\2#g" docs/index.html
    echo "Built $DMG, notarized and ready to share, and dist/appcast.xml. Publish them with:"
    echo "  gh release create v$VERSION $DMG dist/appcast.xml"
    exit 0
fi

# tell finder and the dock about the new icon
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
if [ "$IDENTITY" = "-" ]; then
    echo "Signed ad hoc (no Apple Development identity found); macOS may ask for folder access after each rebuild"
else
    echo "Signed with a local Apple Development identity"
fi
echo "Built $APP"
echo "Built build/bin/screenbook"

# an already running copy keeps using the old build until it is fully quit
if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null; then
    echo "Note: $APP_NAME is still running the previous build. Quit it fully (menu bar icon > Quit $APP_NAME, or Cmd+Q) and reopen."
fi
