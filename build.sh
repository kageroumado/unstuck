#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Unstuck"
BUNDLE_ID="glass.kagerou.unstuck"
VERSION="1.0"
APP="build/${APP_NAME}.app"
# Ad-hoc by default; export SIGNING_IDENTITY="Developer ID Application: …" to ship.
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

rm -rf build
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

echo "Compiling app…"
swiftc -O -parse-as-library -import-objc-header CursorShim.h Sources/*.swift -o "${APP}/Contents/MacOS/${APP_NAME}"

echo "Rendering icon…"
swiftc -O Icon/makeicon.swift -o build/makeicon
./build/makeicon build/icon_1024.png >/dev/null
mkdir -p build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Kagerou</string>
</dict>
</plist>
PLIST

echo "Signing…"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  codesign --force --sign - "${APP}"
else
  codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${APP}"
fi
codesign --verify --strict --verbose=2 "${APP}"

echo "Zipping…"
ditto -c -k --keepParent "${APP}" "build/${APP_NAME}-${VERSION}.zip"
echo "Built: build/${APP_NAME}-${VERSION}.zip"
