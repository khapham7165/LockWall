#!/bin/zsh
# Builds build/LockWall.app; `./build.sh install` also replaces /Applications/LockWall.app and relaunches it.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
[[ -f Resources/AppIcon.icns ]] || swift Tools/make-icon.swift Resources

APP=build/LockWall.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LockWall "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "built $APP"

if [[ "${1:-}" == install ]]; then
  pkill -x LockWall && sleep 1 || true
  rm -rf /Applications/LockWall.app
  cp -R "$APP" /Applications/
  open /Applications/LockWall.app
  echo "installed /Applications/LockWall.app"
fi
