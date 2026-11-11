#!/bin/sh
# Builds build/Fandeck.app. With --install, also copies it to /Applications. With test, runs the logic tests
set -e
cd "$(dirname "$0")"

if [ "$1" = "test" ]; then
    mkdir -p build
    swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14 \
        $(ls app/*.swift | grep -v FandeckApp.swift) tests/*.swift -o build/tests
    exec build/tests build/test-output
fi

APP=build/Fandeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 \
    app/*.swift -o "$APP/Contents/MacOS/Fandeck"
cp app/Info.plist "$APP/Contents/"
cp app/AppIcon.icns fandeck.py "$APP/Contents/Resources/"
codesign --force -s - "$APP"
echo "built: $PWD/$APP"

if [ "$1" = "--install" ]; then
    osascript -e 'quit app "Fandeck"' 2>/dev/null || true
    rm -rf /Applications/Fandeck.app
    cp -R "$APP" /Applications/
    echo "installed: /Applications/Fandeck.app"
fi
