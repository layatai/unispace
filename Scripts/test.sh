#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mode="${1:---full}"
case "$mode" in
  --full|--unit|--input-smoke) ;;
  *)
    echo "Usage: Scripts/test.sh [--full|--unit|--input-smoke]" >&2
    exit 2
    ;;
esac

./Scripts/bootstrap.sh >/dev/null
mkdir -p .build/test-results

signing_arguments=()
configure_signing() {
  local development_identity="${UNISPACE_DEVELOPMENT_IDENTITY:-}"
  local development_team="${UNISPACE_DEVELOPMENT_TEAM:-}"
  local identity_record
  if [[ -z "$development_identity" || -z "$development_team" ]]; then
    identity_record="$(security find-identity -v -p codesigning 2>/dev/null |
      sed -n '/"Apple Development:/ { p; q; }')"
    development_identity="${development_identity:-$(sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*\([A-F0-9]*\).*/\1/p' <<<"$identity_record")}"
    development_team="${development_team:-$(sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p' <<<"$identity_record")}"
  fi
  if [[ -z "$development_identity" || -z "$development_team" ]]; then
    echo "A matching Apple Development identity is required for signed tests." >&2
    exit 2
  fi
  signing_arguments=(
    "CODE_SIGN_STYLE=Manual"
    "DEVELOPMENT_TEAM=$development_team"
    "CODE_SIGN_IDENTITY=$development_identity"
  )
}

common_arguments=(
  test
  -project UniSpace.xcodeproj
  -scheme UniSpace
  -destination 'platform=macOS,arch=arm64'
)

if [[ "$mode" == "--input-smoke" ]]; then
  configure_signing
  touch .build/input-smoke.enabled
  trap 'rm -f .build/input-smoke.enabled' EXIT
  xcodebuild "${common_arguments[@]}" \
    -only-testing:UniSpaceInfrastructureTests/NativeInputSmokeTests \
    "${signing_arguments[@]}"
  exit 0
fi

result_name="FullTests"
performance_test="UniSpaceInfrastructureTests/TwoProcessSimulationTests/testTwoProcessSimulationMeetsProtocolLatencyAndRecoveryGates"
test_arguments=("-skip-testing:$performance_test")
if [[ "$mode" == "--unit" ]]; then
  result_name="UnitTests"
  test_arguments+=("-skip-testing:UniSpaceUITests" "CODE_SIGNING_ALLOWED=NO")
else
  configure_signing
  test_arguments+=("${signing_arguments[@]}")
fi

result_bundle=".build/test-results/$result_name.xcresult"
rm -rf "$result_bundle"
xcodebuild "${common_arguments[@]}" \
  -enableCodeCoverage YES \
  -resultBundlePath "$result_bundle" \
  "${test_arguments[@]}"
node ./Scripts/check-coverage.mjs "$result_bundle"
./Scripts/simulate.sh run-two --samples 500 --json
