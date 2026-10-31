#!/bin/sh
# Builds FreeTube for iOS and packages it as an unsigned .ipa (for sideloading tools that re-sign it).
#   ./ios/build.sh            build the .ipa into ios/build/FreeTube.ipa
#   ./ios/build.sh simulator  build for the iOS Simulator into ios/build/simulator
set -eu
IOS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$IOS_DIR")"
BUILD="$IOS_DIR/build"
MODE="${1:-device}"

cd "$ROOT"
rm -rf "$ROOT/dist/ios"
pnpm run pack:ios

rm -rf "$IOS_DIR/Generated"
mkdir -p "$IOS_DIR/Generated"
cp -R "$ROOT/dist/ios" "$IOS_DIR/Generated/web"
cp "$ROOT/dist/botGuardScript.js" "$IOS_DIR/Generated/botGuardScript.js"

cd "$IOS_DIR"
FREETUBE_VERSION="${FREETUBE_VERSION:-$(node -p "require('$ROOT/package.json').version")}" xcodegen generate --quiet

if [ "$MODE" = "simulator" ]; then
  xcodebuild -project FreeTube.xcodeproj -scheme FreeTube -configuration Release \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$BUILD/DerivedData" \
    CODE_SIGNING_ALLOWED=NO -quiet build
  rm -rf "$BUILD/simulator" && mkdir -p "$BUILD/simulator"
  cp -R "$BUILD/DerivedData/Build/Products/Release-iphonesimulator/FreeTube.app" "$BUILD/simulator/"
  echo "Built $BUILD/simulator/FreeTube.app"
  exit 0
fi

xcodebuild -project FreeTube.xcodeproj -scheme FreeTube -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet build

APP="$BUILD/DerivedData/Build/Products/Release-iphoneos/FreeTube.app"
STAGE="$BUILD/ipa"
rm -rf "$STAGE" && mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && rm -f ../FreeTube.ipa && zip -qry ../FreeTube.ipa Payload)
rm -rf "$STAGE"
echo "Built $BUILD/FreeTube.ipa"
