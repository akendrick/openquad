#!/bin/sh
# Build OpenQuad.app (unsigned; swift/sign-app.sh signs it). Version 0.1.0 beta 2.
#
#     swift/build-app.sh            -> swift/build/OpenQuad.app
set -eu
here=$(cd "$(dirname "$0")" && pwd)
# Universal: runs on Apple silicon and Intel Macs.
build="swift build -c release --arch arm64 --arch x86_64 --package-path $here/OpenQuadApp"
$build
binary=$($build --show-bin-path)/OpenQuad
app="$here/build/OpenQuad.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/OpenQuad"
iconset="$here/build/AppIcon.iconset"
rm -rf "$iconset"
swift "$here/OpenQuadApp/Icon/make-icon.swift" "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OpenQuad</string>
  <key>CFBundleDisplayName</key><string>OpenQuad</string>
  <key>CFBundleIdentifier</key><string>io.github.akendrick.openquad</string>
  <key>CFBundleExecutable</key><string>OpenQuad</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>0.1.0b2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
echo "built $app"
