#!/bin/sh
# Builds build/wallMatch.app. With --install, also copies it to /Applications
set -e
cd "$(dirname "$0")"
APP=build/wallMatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 \
    app/*.swift -o "$APP/Contents/MacOS/wallMatch"
cp app/Info.plist "$APP/Contents/"
cp app/AppIcon.icns wallmatch.py "$APP/Contents/Resources/"
codesign --force -s - "$APP"
echo "built: $PWD/$APP"

if [ "$1" = "--install" ]; then
    osascript -e 'quit app "wallMatch"' 2>/dev/null || true
    rm -rf /Applications/wallMatch.app
    cp -R "$APP" /Applications/
    echo "installed: /Applications/wallMatch.app"
fi
