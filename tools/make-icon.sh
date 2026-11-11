#!/bin/sh
# Renders the icon: app/AppIcon.icns, plus docs/icon.png for the README
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swift tools/make-icon.swift "$TMP/icon.png"
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o app/AppIcon.icns
mkdir -p docs
sips -z 256 256 "$TMP/icon.png" --out docs/icon.png >/dev/null
rm -rf "$TMP"
echo "done: app/AppIcon.icns, docs/icon.png"
