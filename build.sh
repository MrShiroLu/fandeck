#!/bin/sh
# Builds build/Fandeck.app. With --install, also copies it to /Applications. With --zip, packs it for a release.
# With test, runs the logic tests
set -e
cd "$(dirname "$0")"

if [ "$1" = "test" ]; then
    mkdir -p build
    swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14" \
        $(ls app/*.swift | grep -v FandeckApp.swift) tests/*.swift -o build/tests
    exec build/tests build/test-output
fi

APP=build/Fandeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# One binary for Apple silicon and Intel
for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 -parse-as-library -target "$ARCH-apple-macos14" \
        app/*.swift -o "build/Fandeck-$ARCH"
done
lipo -create build/Fandeck-arm64 build/Fandeck-x86_64 -output "$APP/Contents/MacOS/Fandeck"
rm build/Fandeck-arm64 build/Fandeck-x86_64
cp app/Info.plist "$APP/Contents/"
cp app/AppIcon.icns fandeck.py "$APP/Contents/Resources/"
codesign --force -s - "$APP"
echo "built: $PWD/$APP"

if [ "$1" = "--zip" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' app/Info.plist)
    rm -f "build/Fandeck-$VERSION.zip"
    ditto -c -k --norsrc --keepParent "$APP" "build/Fandeck-$VERSION.zip"
    echo "packed: $PWD/build/Fandeck-$VERSION.zip"
fi

if [ "$1" = "--install" ]; then
    osascript -e 'quit app "Fandeck"' 2>/dev/null || true
    rm -rf /Applications/Fandeck.app
    cp -R "$APP" /Applications/
    echo "installed: /Applications/Fandeck.app"
fi
