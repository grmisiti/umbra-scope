#!/bin/zsh
# Builds the app and packs it into dist/UmbraScope-<version>.dmg: the app, a link to Applications and the
# first-launch guide. Ad-hoc signed — no paid Apple developer account involved.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
APP="build/Umbra Scope.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
STAGE=build/dmg
rm -rf $STAGE && mkdir -p $STAGE dist
ditto "$APP" "$STAGE/Umbra Scope.app"
ln -s /Applications "$STAGE/Applications"
cp "Resources/dmg/LEIA-ME · READ ME.txt" "$STAGE/"
DMG=dist/UmbraScope-$VERSION.dmg
rm -f $DMG
hdiutil create -volname "Umbra Scope $VERSION" -srcfolder $STAGE -fs APFS -format UDZO -ov $DMG >/dev/null
codesign --force --sign - $DMG
echo "built $DMG ($(du -h $DMG | cut -f1))"
