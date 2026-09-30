#!/bin/bash
# Quick local type-check of the iOS sources without Xcode, via Mac Catalyst and the
# Command Line Tools SDK. ActivityKit is unavailable on Catalyst, so Live Activity
# code is fenced with `#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)`
# and only compiled for real by build-ipa.sh (CI).
set -uo pipefail
cd "$(dirname "$0")/.."
SDK=$(xcrun --show-sdk-path)
ARGS=(-typecheck -swift-version 5 -target arm64-apple-ios17.0-macabi -sdk "$SDK"
  -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks"
  -I "$SDK/System/iOSSupport/usr/lib/swift" -L "$SDK/System/iOSSupport/usr/lib/swift")
status=0
echo "== app";    swiftc "${ARGS[@]}" Sources/Core/*.swift Sources/App/*.swift Sources/Shared/*.swift || status=1
echo "== widget"; swiftc "${ARGS[@]}" -parse-as-library Sources/Widget/*.swift Sources/Shared/*.swift || status=1
[ $status -eq 0 ] && echo "typecheck OK"
exit $status
