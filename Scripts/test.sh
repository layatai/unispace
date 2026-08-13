#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/bootstrap.sh >/dev/null
test_arguments=()
if [[ "${1:-}" == "--unit" ]]; then
  test_arguments+=("-skip-testing:UniSpaceUITests" "CODE_SIGNING_ALLOWED=NO")
fi
xcodebuild test \
  -project UniSpace.xcodeproj \
  -scheme UniSpace \
  -destination 'platform=macOS,arch=arm64' \
  "${test_arguments[@]}"
