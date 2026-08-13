#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/bootstrap.sh >/dev/null
test_arguments=()
if [[ "${1:-}" == "--unit" ]]; then
  test_arguments+=("-skip-testing:UniSpaceUITests" "CODE_SIGNING_ALLOWED=NO")
else
  development_identity="${UNISPACE_DEVELOPMENT_IDENTITY:-}"
  development_team="${UNISPACE_DEVELOPMENT_TEAM:-}"
  if [[ -z "$development_identity" || -z "$development_team" ]]; then
    identity_record="$(security find-identity -v -p codesigning 2>/dev/null |
      sed -n '/"Apple Development:/ { p; q; }')"
    development_identity="${development_identity:-$(sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*\([A-F0-9]*\).*/\1/p' <<<"$identity_record")}"
    development_team="${development_team:-$(sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p' <<<"$identity_record")}"
  fi
  if [[ -z "$development_identity" || -z "$development_team" ]]; then
    echo "A matching Apple Development identity is required for the UI test." >&2
    exit 2
  fi
  test_arguments+=(
    "CODE_SIGN_STYLE=Manual"
    "DEVELOPMENT_TEAM=$development_team"
    "CODE_SIGN_IDENTITY=$development_identity"
  )
fi
xcodebuild test \
  -project UniSpace.xcodeproj \
  -scheme UniSpace \
  -destination 'platform=macOS,arch=arm64' \
  "${test_arguments[@]}"
