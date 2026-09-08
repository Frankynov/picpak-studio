#!/bin/bash
# Builds PicPak Studio and assembles a double-clickable .app bundle.
# No Xcode required — just the Swift toolchain from the Command Line Tools.
#
#   ./build.sh            release, universal (Apple silicon + Intel)
#   ./build.sh debug      debug, this machine's architecture only — much faster
#
# `swift build --arch arm64 --arch x86_64` would be the obvious way to get a
# universal binary, but it routes through xcbuild, which ships only with full
# Xcode. Building each slice with --triple and joining them with lipo needs
# nothing but the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${1:-release}
APP="build/PicPak Studio.app"

DEPLOYMENT=14.0
ARM_TRIPLE="arm64-apple-macosx$DEPLOYMENT"
INTEL_TRIPLE="x86_64-apple-macosx$DEPLOYMENT"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "$CONFIG" = "debug" ]; then
  echo "▸ Compiling (debug, native only)…"
  swift build -c debug
  cp "$(swift build -c debug --show-bin-path)/PicPakStudio" "$APP/Contents/MacOS/PicPak Studio"
else
  echo "▸ Compiling (release, Apple silicon)…"
  swift build -c release --triple "$ARM_TRIPLE"
  echo "▸ Compiling (release, Intel)…"
  swift build -c release --triple "$INTEL_TRIPLE"

  ARM_BIN="$(swift build -c release --triple "$ARM_TRIPLE" --show-bin-path)/PicPakStudio"
  INTEL_BIN="$(swift build -c release --triple "$INTEL_TRIPLE" --show-bin-path)/PicPakStudio"

  echo "▸ Joining into a universal binary…"
  lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP/Contents/MacOS/PicPak Studio"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PicPak Studio</string>
  <key>CFBundleDisplayName</key><string>PicPak Studio</string>
  <key>CFBundleExecutable</key><string>PicPak Studio</string>
  <key>CFBundleIdentifier</key><string>com.picpak.studio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>PicPak Studio</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key>
  <string>PicPak Studio sends posters to your Tesserae server on the local network.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PicPak Studio Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key>
      <array><string>com.picpak.studio.document</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>PNG image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.png</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.picpak.studio.document</string>
      <key>UTTypeDescription</key><string>PicPak Studio Project</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>picpak</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (ad-hoc signing skipped)"
touch "$APP"

echo "▸ Done: $APP"
lipo -archs "$APP/Contents/MacOS/PicPak Studio" | sed 's/^/  architectures: /' 
