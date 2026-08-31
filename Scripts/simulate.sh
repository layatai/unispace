#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
./Scripts/bootstrap.sh >/dev/null

build_root="$(pwd)/.build/simulation"
xcodebuild build \
  -project UniSpace.xcodeproj \
  -scheme UniSpaceSimulation \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$build_root" \
  CODE_SIGNING_ALLOWED=NO >/dev/null

if [[ $# -eq 0 ]]; then
  set -- run-two --scenario all --json
fi
exec "$build_root/Build/Products/Debug/UniSpaceSimulation" "$@"
