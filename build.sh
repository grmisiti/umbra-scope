#!/bin/zsh
# Builds "build/Umbra Scope.app" with swiftc only (no Xcode project, no offline Metal toolchain).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Umbra Scope.app"
# Paths compiled into the binaries (assert messages, debug info) are made relative, so they don't carry the
# builder's home folder or user name.
MAP=(-ffile-prefix-map="$PWD"=. -ffile-prefix-map="$HOME"=~)
rm -rf build/ScopesPrototype.app   # old name
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ZMQ=third_party/libzmq
[[ -f $ZMQ/build/lib/libzmq.a ]] || { echo "build libzmq first (see README)"; exit 1; }

# Oldest macOS the app runs on (Apple Silicon). Everything compiled here, LibRaw and FFmpeg included, targets it.
MACOS_MIN=14.0
# File decoders: our own LGPL FFmpeg (decoders only, built by tools/build_ffmpeg.sh, shipped inside the app) and the
# Blackmagic RAW SDK (its framework is shipped inside the app too).
BRAW_SDK="/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac"
FF=third_party/ffmpeg-build
[[ -f $FF/lib/libavcodec.dylib ]] || tools/build_ffmpeg.sh
mkdir -p build/obj
clang -O2 "${MAP[@]}" -arch arm64 -mmacosx-version-min=$MACOS_MIN -I$FF/include -c Sources/Decoders/ffmpeg_decoder.c -o build/obj/ffmpeg_decoder.o
clang -O2 "${MAP[@]}" -arch arm64 -mmacosx-version-min=$MACOS_MIN -c Sources/Decoders/file_decoder.c -o build/obj/file_decoder.o
clang++ -std=c++17 -O2 "${MAP[@]}" -arch arm64 -mmacosx-version-min=$MACOS_MIN -I"$BRAW_SDK/Include" -ISources/Decoders \
  -x objective-c++ -c Sources/Decoders/braw_decoder.mm -o build/obj/braw_decoder.o
clang++ -std=c++17 -O2 "${MAP[@]}" -arch arm64 -mmacosx-version-min=$MACOS_MIN -I"$BRAW_SDK/Include" \
  -c "$BRAW_SDK/Include/BlackmagicRawAPIDispatch.cpp" -o build/obj/braw_dispatch.o
LIBRAW=third_party/LibRaw
[[ -f $LIBRAW/lib/libraw_r.a ]] || (cd $LIBRAW && make -f Makefile.dist -j8 library CFLAGS="-O3 -I. -w -DUSE_ZLIB -mmacosx-version-min=$MACOS_MIN ${MAP[*]}")
clang++ -std=c++17 -O2 "${MAP[@]}" -arch arm64 -mmacosx-version-min=$MACOS_MIN -I$LIBRAW -I$FF/include -ISources/Decoders -w \
  -c Sources/Decoders/libraw_decoder.cpp -o build/obj/libraw_decoder.o

swiftc -O -swift-version 5 -target arm64-apple-macos$MACOS_MIN -file-prefix-map "$PWD=." -file-prefix-map "$HOME=~" \
  -import-objc-header Sources/Bridging.h -Xcc -I$ZMQ/include \
  -Xlinker $ZMQ/build/lib/libzmq.a -lc++ \
  build/obj/ffmpeg_decoder.o build/obj/file_decoder.o build/obj/braw_decoder.o build/obj/braw_dispatch.o \
  build/obj/libraw_decoder.o -Xlinker $LIBRAW/lib/libraw_r.a -lz \
  -L$FF/lib -lavformat -lavcodec -lavutil -lswscale -framework CoreServices \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/UmbraScope" Sources/*.swift

cp Shaders/Scopes.metal Resources/ghost-outline.png Resources/wordmark.png Resources/AppIcon.icns "$APP/Contents/Resources/"
# Ship the BRAW SDK framework inside the app, so BRAW opens without the SDK installed.
mkdir -p "$APP/Contents/Frameworks"
[[ -d "$BRAW_SDK/Libraries/BlackmagicRawAPI.framework" ]] && ditto "$BRAW_SDK/Libraries/BlackmagicRawAPI.framework" "$APP/Contents/Frameworks/BlackmagicRawAPI.framework"
# FFmpeg's libraries, under the names the app links them by (@rpath/libavcodec.62.dylib …).
for lib in avformat avcodec avutil swscale; do
  name=$(otool -D $FF/lib/lib$lib.dylib | tail -1 | sed 's#@rpath/##')
  cp -L $FF/lib/$name "$APP/Contents/Frameworks/$name"
done
# The Resolve plugin travels inside the app; the app installs it (Umbra Scope → Install DaVinci Resolve Plugin…).
[[ -d build/UmbraLink.ofx.bundle ]] || Plugin/build_plugin.sh
ditto build/UmbraLink.ofx.bundle "$APP/Contents/Resources/UmbraLink.ofx.bundle"
ditto Resources/Licenses "$APP/Contents/Resources/Licenses"
cp LICENSE "$APP/Contents/Resources/Licenses/UmbraScope-GPL-3.0.txt"
cp NOTICE "$APP/Contents/Resources/Licenses/UmbraScope-NOTICE.txt"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UmbraScope</string>
  <key>CFBundleIdentifier</key><string>com.grmisiti.umbrascope</string>
  <key>CFBundleName</key><string>Umbra Scope</string>
  <key>CFBundleDisplayName</key><string>Umbra Scope</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 The Umbra Scope authors. Free software under GPL-3.0-or-later. Licences: Umbra Scope menu → Licenses.</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Umbra Scope analyses live video from capture cards and cameras.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (no paid Apple account): inner libraries first, then the app.
for f in "$APP"/Contents/Frameworks/*.dylib; do codesign --force --sign - "$f" >/dev/null; done
codesign --force --sign - "$APP/Contents/Frameworks/BlackmagicRawAPI.framework" >/dev/null 2>&1 || true
codesign --force --sign - "$APP/Contents/Resources/UmbraLink.ofx.bundle" >/dev/null
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
