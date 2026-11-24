#!/bin/bash
# archives the iphone app and uploads it to app store connect for testflight.
#
#   ./release_phone.sh            archive and upload
#   ./release_phone.sh --no-upload  archive and export an .ipa to build/phone/export only
#
# needs, once: an app record in app store connect with bundle id io.github.jonathangarro.screenbook, and your
# apple account signed in to xcode (settings, accounts) so -allowProvisioningUpdates can sign and upload.
# the version comes from VERSION; the build number is the current time, so every upload is unique.
# testflight builds use cloudkit's production environment: deploy the schema in the cloudkit console first.
set -euo pipefail

# config
cd "$(dirname "$0")"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TEAM_ID="WAFG79SSX5"
VERSION="$(cat VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
OUT="build/phone"
ARCHIVE="$OUT/Screenbook.xcarchive"
UPLOAD=1
[ "${1:-}" = "--no-upload" ] && UPLOAD=0

# project
(cd Xcode && xcodegen generate --quiet)

# archive
rm -rf "$ARCHIVE"
xcodebuild -project Xcode/ScreenbookApps.xcodeproj -scheme ScreenbookPhone -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    -allowProvisioningUpdates archive -quiet

# export, and upload unless asked not to
DEST="upload"
[ $UPLOAD = 0 ] && DEST="export"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$DEST</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
rm -rf "$OUT/export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" -allowProvisioningUpdates

if [ $UPLOAD = 1 ]; then
    echo "Uploaded Screenbook $VERSION ($BUILD). It shows in TestFlight after apple finishes processing, usually 5 to 30 minutes."
else
    echo "Exported $OUT/export/Screenbook.ipa ($VERSION, build $BUILD)"
fi
