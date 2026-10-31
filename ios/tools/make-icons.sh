#!/bin/sh
# Generates the app icon PNGs in FreeTube/Assets.xcassets/AppIcon.appiconset
set -eu
cd "$(dirname "$0")/.."
OUT=FreeTube/Assets.xcassets/AppIcon.appiconset
TMP=$(mktemp -d)
swift tools/make-icons.swift "$TMP"
for name in AppIcon AppIcon-Dark AppIcon-Tinted; do
  qlmanage -t -s 1024 -o "$TMP" "$TMP/$name.svg" >/dev/null
  # App icons must not have an alpha channel
  sips -s format jpeg -s formatOptions 100 "$TMP/$name.svg.png" --out "$TMP/$name.jpg" >/dev/null
  sips -s format png "$TMP/$name.jpg" --out "$OUT/$name.png" >/dev/null
done
rm -rf "$TMP"
