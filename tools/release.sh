#!/bin/zsh
# Builds the DMG and publishes it as a GitHub Release (tag v<version>, version from the app's Info.plist).
# Usage: tools/release.sh [--publish]   Without --publish it only builds and shows what would be released.
# Requires: gh (logged in), a clean git tree pushed to origin.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

tools/make_dmg.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "build/Umbra Scope.app/Contents/Info.plist")
TAG="v$VERSION"
DMG="dist/UmbraScope-$VERSION.dmg"
SUM="$DMG.sha256"
(cd dist && shasum -a 256 "UmbraScope-$VERSION.dmg" > "UmbraScope-$VERSION.dmg.sha256")

NOTES=$(cat <<NOTES_EOF
Umbra Scope $VERSION — Apple Silicon, macOS 14+.

1. Open the DMG and drag Umbra Scope to Applications.
2. First launch: System Settings → Privacy & Security → Open Anyway (the app is not notarized).
3. Umbra Scope offers to install the DaVinci Resolve plugin (Umbra Link, OpenFX); restart Resolve afterwards.

Abra o DMG, arraste para Applications, libere em Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim; o app oferece instalar o plugin do Resolve.

SHA-256: $(cut -d' ' -f1 "$SUM")
NOTES_EOF
)

echo "tag:   $TAG"
echo "asset: $DMG ($(du -h "$DMG" | cut -f1)) + $SUM"

if (( ! PUBLISH )); then
  echo "dry run — nothing published. Re-run with --publish to create the release."
  exit 0
fi

[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean — commit first" >&2; exit 1; }
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || { echo "HEAD is not pushed to origin" >&2; exit 1; }
gh release view "$TAG" >/dev/null 2>&1 && { echo "release $TAG already exists" >&2; exit 1; }

gh release create "$TAG" "$DMG" "$SUM" --target "$(git rev-parse HEAD)" --title "Umbra Scope $VERSION" --notes "$NOTES"
echo "published $TAG"
