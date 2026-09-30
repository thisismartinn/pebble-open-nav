#!/bin/bash
# Builds an unsigned build/PebbleOpenNav.ipa. Needs Xcode 26+ and XcodeGen (brew install xcodegen).
# Sideloadly or AltStore sign it with your own Apple ID when you install it.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project PebbleOpenNav.xcodeproj -target PebbleOpenNav -configuration Release -sdk iphoneos \
  SYMROOT="$PWD/build/xcode" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

# Liquid Glass needs the app linked against the iOS 26+ SDK (Xcode 26+); older SDKs
# run in compatibility mode with the old look. Fail loudly instead of shipping that.
APP=build/xcode/Release-iphoneos/PebbleOpenNav.app
PL=$APP/Info.plist
sdk=$(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$PL")
minos=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PL")
echo "DTSDKName=$sdk DTXcode=$(/usr/libexec/PlistBuddy -c 'Print :DTXcode' "$PL") MinimumOSVersion=$minos"
sdkver=${sdk#iphoneos}
if [ "${sdkver%%.*}" -lt 26 ]; then
  echo "error: built with $sdk; Liquid Glass needs the iOS 26+ SDK (Xcode 26+)" >&2
  exit 1
fi
if [ "$minos" != "17.0" ]; then
  echo "error: MinimumOSVersion is $minos, expected 17.0" >&2
  exit 1
fi

if [ ! -d "$APP/PlugIns/PebbleOpenNavWidgets.appex" ]; then
  echo "error: Live Activity extension missing from $APP/PlugIns" >&2
  exit 1
fi

rm -rf build/Payload build/PebbleOpenNav.ipa
mkdir -p build/Payload
cp -R "$APP" build/Payload/
(cd build && zip -qr PebbleOpenNav.ipa Payload)
echo "Built $(pwd)/build/PebbleOpenNav.ipa"
