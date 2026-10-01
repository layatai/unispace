#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/bootstrap.sh >/dev/null
root="$(pwd)/.build/feature-baseline"
mkdir -p "$root"
xcodebuild build -project UniSpace.xcodeproj -target UniSpaceInfrastructure \
  -configuration Release CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=NO \
  SYMROOT="$root/release-products" OBJROOT="$root/release-intermediates" \
  > "$root/release-build.log" 2>&1 || { tail -80 "$root/release-build.log"; exit 1; }
./Scripts/verify-release-transfer.sh "$root/release-products/Release" "$root/release-products/Release"
