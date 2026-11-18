#!/bin/bash
# Builds build/TaskBoard.app: the menu bar app with the `taskboard` CLI inside it.
#
#   scripts/build-app.sh             build
#   scripts/build-app.sh --install   build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
APP="build/TaskBoard.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/TaskBoardApp" "$APP/Contents/MacOS/TaskBoardApp"
cp "$BIN/taskboard" "$APP/Contents/MacOS/taskboard"
# The browser extension travels with the app, so Settings can point at it.
mkdir -p "$APP/Contents/Resources"
cp -R extension "$APP/Contents/Resources/extension"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Task Board</string>
    <key>CFBundleDisplayName</key><string>Task Board</string>
    <key>CFBundleIdentifier</key><string>io.github.simple-task-board</string>
    <key>CFBundleExecutable</key><string>TaskBoardApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app menu. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature, so macOS will run it locally. Not notarized.
codesign --force --sign - "$APP/Contents/MacOS/taskboard"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x TaskBoardApp 2>/dev/null || true
    rm -rf "/Applications/TaskBoard.app"
    cp -R "$APP" "/Applications/TaskBoard.app"
    open "/Applications/TaskBoard.app"
    echo "Installed and launched /Applications/TaskBoard.app"
fi
