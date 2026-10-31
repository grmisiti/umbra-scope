#!/bin/zsh
# Builds build/UmbraLink.ofx.bundle (universal arm64 + x86_64) with libzmq linked statically.
# Install with Plugin/install_plugin.sh (copies it into /Library/OFX/Plugins, owned by root).
set -euo pipefail
cd "$(dirname "$0")/.."

# Resolve's copy of the OpenFX 1.4 headers + Support library adds the Metal render extension.
RESOLVE_OFX="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/OpenFX"
OFX=third_party/resolve-openfx
if [[ ! -d $OFX ]]; then
  [[ -d "$RESOLVE_OFX" ]] || { echo "DaVinci Resolve developer files not found at $RESOLVE_OFX"; exit 1; }
  mkdir -p $OFX && cp -R "$RESOLVE_OFX/OpenFX-1.4/include" $OFX/include && cp -R "$RESOLVE_OFX/Support" $OFX/Support
fi
ZMQ=third_party/libzmq
[[ -f $ZMQ/build/lib/libzmq.a ]] || { echo "build libzmq first (see README)"; exit 1; }

BUNDLE=build/UmbraLink.ofx.bundle
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" build/obj

# Only the two OFX entry points are exported, so this bundle's libzmq can't clash with other plugins.
print -l _OfxGetNumberOfPlugins _OfxGetPlugin > build/obj/exports.txt

clang++ -std=c++14 -O2 -ffile-prefix-map="$PWD"=. -ffile-prefix-map="$HOME"=~ -fvisibility=hidden -fvisibility-inlines-hidden \
  -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
  -I $OFX/include -I $OFX/Support/include -I $OFX/Support/Library -I $ZMQ/include \
  -bundle -Wl,-exported_symbols_list,build/obj/exports.txt \
  Plugin/UmbraLink.cpp $OFX/Support/Library/ofxs*.cpp \
  -x objective-c++ -fobjc-arc Plugin/MetalPath.mm -x none \
  $ZMQ/build/lib/libzmq.a -framework Metal -framework Foundation \
  -o "$BUNDLE/Contents/MacOS/UmbraLink.ofx"

# The ghost, named after the plugin identifier: the icon the host shows for the node.
cp Plugin/com.grmisiti.umbrascope.UmbraLink.png "$BUNDLE/Contents/Resources/"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>English</string>
  <key>CFBundleExecutable</key><string>UmbraLink.ofx</string>
  <key>CFBundleIdentifier</key><string>com.grmisiti.umbrascope.UmbraLink</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>UmbraLink</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>1.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUNDLE" >/dev/null
echo "built $BUNDLE"
