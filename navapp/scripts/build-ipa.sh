#!/bin/bash
# Builds an unsigned build/NavTest.ipa. Needs Xcode and XcodeGen (brew install xcodegen).
# Sideloadly or AltStore sign it with your own Apple ID when you install it.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project NavTest.xcodeproj -target NavTest -configuration Release -sdk iphoneos \
  SYMROOT="$PWD/build/xcode" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

rm -rf build/Payload build/NavTest.ipa
mkdir -p build/Payload
cp -R build/xcode/Release-iphoneos/NavTest.app build/Payload/
(cd build && zip -qr NavTest.ipa Payload)
echo "Built $(pwd)/build/NavTest.ipa"
