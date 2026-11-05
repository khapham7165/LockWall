#!/bin/zsh
# Builds a universal build/LockWall.app.
#   ./build.sh           build only
#   ./build.sh install   also replace /Applications/LockWall.app and relaunch
#   ./build.sh release   also zip it as build/LockWall-<version>.zip for GitHub Releases
set -euo pipefail
cd "${0:A:h}"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
BIN=$(swift build -c release $ARCHS --show-bin-path)
[[ -f Resources/AppIcon.icns ]] || swift Tools/make-icon.swift Resources

APP=build/LockWall.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LockWall" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/LockWall"))"

case "${1:-}" in
  install)
    pkill -x LockWall && sleep 1 || true
    rm -rf /Applications/LockWall.app
    cp -R "$APP" /Applications/
    open /Applications/LockWall.app
    echo "installed /Applications/LockWall.app"
    ;;
  release)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
    ZIP=build/LockWall-$VERSION.zip
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"  # ditto keeps the code signature intact
    echo "packaged $ZIP ($(du -h "$ZIP" | cut -f1)), sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    ;;
esac
