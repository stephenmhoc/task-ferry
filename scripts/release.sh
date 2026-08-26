#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: scripts/release.sh VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must look like 1.2.3" >&2; exit 1; }
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
BUILD_ROOT="${BUILD_ROOT:-$ROOT/build/release}"
SPM_CACHE="$BUILD_ROOT/SourcePackages"
ARCHIVE="$BUILD_ROOT/TaskFerry.xcarchive"
EXPORT="$BUILD_ROOT/export"
STAGING="$BUILD_ROOT/dmg"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-TaskFerry}"
REPOSITORY="${GITHUB_REPOSITORY:-smeriwether/task-ferry}"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$EXPORT" "$STAGING"
cd "$ROOT"

scripts/fetch-cloudflared.sh
xcodegen generate
xcodebuild -resolvePackageDependencies \
  -project TaskFerry.xcodeproj \
  -scheme TaskFerry \
  -clonedSourcePackagesDirPath "$SPM_CACHE"

TASK_FERRY_SPM_CACHE="$SPM_CACHE" scripts/test.sh "$BUILD_ROOT/TestDerivedData"

xcodebuild clean archive \
  -project TaskFerry.xcodeproj \
  -scheme TaskFerry \
  -configuration Release-Direct \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  -clonedSourcePackagesDirPath "$SPM_CACHE" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

EXPORT_OPTIONS="$BUILD_ROOT/ExportOptions.plist"
plutil -create xml1 "$EXPORT_OPTIONS"
plutil -insert method -string developer-id "$EXPORT_OPTIONS"
plutil -insert teamID -string "$APPLE_TEAM_ID" "$EXPORT_OPTIONS"
plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
plutil -insert signingCertificate -string "Developer ID Application" "$EXPORT_OPTIONS"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT"

APP="$EXPORT/TaskFerry.app"
HELPER="$APP/Contents/MacOS/cloudflared"
[[ -x "$HELPER" ]] || { echo "The app is missing cloudflared" >&2; exit 1; }
codesign --verify --strict --verbose=2 "$HELPER"
NOTARY_ZIP="$BUILD_ROOT/TaskFerry-notarize.zip"
DMG="$BUILD_ROOT/TaskFerry-$VERSION.dmg"
ZIP="$BUILD_ROOT/TaskFerry-$VERSION.zip"

ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

cp -R "$APP" "$STAGING/Task Ferry.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Task Ferry" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
codesign --force --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

ditto -c -k --keepParent "$STAGING/Task Ferry.app" "$ZIP"
SIGN_UPDATE="$(find "$SPM_CACHE/artifacts" -path '*/Sparkle/bin/sign_update' -type f -print -quit)"
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  SIGN_OUTPUT="$("$SIGN_UPDATE" "$ZIP" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")"
else
  SIGN_OUTPUT="$("$SIGN_UPDATE" "$ZIP")"
fi
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$SIGN_OUTPUT")"
SIZE="$(stat -f%z "$ZIP")"
[[ -n "$SIGNATURE" ]] || { echo "Sparkle signature was not produced" >&2; exit 1; }

NOTES="<p>${RELEASE_NOTES:-Bug fixes and improvements.}</p>"
cat > "$BUILD_ROOT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Task Ferry Updates</title>
    <link>https://github.com/$REPOSITORY/releases</link>
    <description>Task Ferry updates</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <description><![CDATA[$NOTES]]></description>
      <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <enclosure url="https://github.com/$REPOSITORY/releases/download/v$VERSION/TaskFerry-$VERSION.zip" sparkle:edSignature="$SIGNATURE" length="$SIZE" type="application/octet-stream" />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
EOF

cp "$DMG" "$BUILD_ROOT/TaskFerry.dmg"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

printf 'Release artifacts:\n%s\n%s\n%s\n%s\n' \
  "$DMG" "$BUILD_ROOT/TaskFerry.dmg" "$ZIP" "$BUILD_ROOT/appcast.xml"
