#!/usr/bin/env bash
# Fast sanity and regression gate.
#
#   Scripts/sanity.sh                      # code checks only (~2-4 min)
#   Scripts/sanity.sh --live --peer tai@taimb2 --expected-build 46
#                                          # + installed-app checks on both Macs
#
# Code checks: generated project matches project.yml, the pinned regression
# tests, and a short two-process latency simulation. Live checks: the installed
# build on both Macs, then the existing clipboard and Finder file probes in
# Scripts/verify-live-continuity.py (they restore both clipboards).
#
# This is a quick gate, not the full baseline: run Scripts/test-feature-baseline.sh
# before shipping. Statuses follow Docs/feature-baseline.md: a skipped check is
# NOT_TESTED, never PASS; any FAIL makes the script exit non-zero.
set -uo pipefail
cd "$(dirname "$0")/.."

live=0
peer=""
expected_build=""
samples=150
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) live=1 ;;
    --peer) peer="$2"; shift ;;
    --expected-build) expected_build="$2"; shift ;;
    --samples) samples="$2"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ $live == 1 && ( -z "$peer" || -z "$expected_build" ) ]]; then
  echo "--live requires --peer user@host and --expected-build N" >&2
  exit 2
fi

results_dir=".build/sanity/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$results_dir"
statuses=()
record() { statuses+=("$1|$2|$3"); printf '%-11s %-34s %s\n' "$1" "$2" "$3"; }

# Pinned regression tests: one per bug fixed in a shipped or open change. Add a
# line here whenever a fix lands with its own regression test.
regression_tests=(
  # Mac-to-Mac realtime pointer lane exists without a portable receiver (#65).
  "UniSpaceInfrastructureTests/InfrastructureTests/testMacPeersGetAuthenticatedPointerLaneWithoutPortableReceiver"
  "UniSpaceInfrastructureTests/InfrastructureTests/testAuthenticatedPointerLaneLetsMacControllerDialReceiver"
  # Idle cross-machine copy/paste with offline peers in the workspace.
  "UniSpaceInfrastructureTests/ClipboardRegressionTests"
  "UniSpaceApplicationTests/ContinuityDestinationResolverTests"
  # Realtime progress and activation under scheduler load (former CI flakes).
  "UniSpaceApplicationTests/ApplicationTests/testRealtimeProgressKeepsSessionAliveWhenReliableProbeDeliveryStalls"
  "UniSpaceApplicationTests/ApplicationTests/testAcknowledgedActivationBuffersInputUntilPeerAccepts"
  "UniSpaceApplicationTests/ApplicationTests/testAcknowledgedPointerLaneSurvivesIdleAndStillDetectsLostProgress"
  # Display wake on cursor activation (#57).
  "UniSpaceInfrastructureTests/InputPipelineTests/testInjectorMapsActivationAndEveryInputKindWithoutPostingGlobally"
  # Checkpoint timer parks exactly once (former CI flake).
  "UniSpaceInfrastructureTests/TransferQoSInfrastructureTests/testCheckpointingStoreKeepsOneTimerAcrossRepeatedWrites"
)

echo "== Code checks (results in $results_dir)"

# 1. Generated project matches project.yml (CI drift check).
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet >/dev/null 2>&1
  if git diff --quiet -- UniSpace.xcodeproj/project.pbxproj; then
    record PASS "project matches project.yml" ""
  else
    record FAIL "project matches project.yml" "run xcodegen generate and commit project.pbxproj"
  fi
  git checkout -q -- UniSpace.xcodeproj/xcshareddata 2>/dev/null || true
else
  record NOT_TESTED "project matches project.yml" "xcodegen not installed"
fi

# 2. Pinned regression tests.
only_testing=()
for test in "${regression_tests[@]}"; do
  [[ "$test" == \#* ]] || only_testing+=("-only-testing:$test")
done
if xcodebuild test -project UniSpace.xcodeproj -scheme UniSpace \
    -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath .build/sanity/DerivedData "${only_testing[@]}" \
    > "$results_dir/regression-tests.log" 2>&1; then
  passed=$(grep -cE "Test Case .*passed" "$results_dir/regression-tests.log")
  record PASS "regression tests" "$passed test cases"
else
  failed=$(grep -E "Test Case .*failed|error: -\[| error: " "$results_dir/regression-tests.log" | head -3 | cut -c1-160)
  record FAIL "regression tests" "see $results_dir/regression-tests.log"
  [[ -n "$failed" ]] && echo "$failed"
fi

# 3. Short two-process simulation (latency, clipboard, file load, recovery).
if ./Scripts/simulate.sh run-two --samples "$samples" > "$results_dir/simulation.json" 2> "$results_dir/simulation.err"; then
  record PASS "two-process simulation" "$samples samples"
else
  summary=$(tail -1 "$results_dir/simulation.json" 2>/dev/null | python3 -c 'import json,sys
try: print("; ".join(json.load(sys.stdin).get("failures", []))[:200])
except Exception: print("no report")' 2>/dev/null)
  record FAIL "two-process simulation" "${summary:-see $results_dir/simulation.err}"
fi

# 4. Linux receiver crate (only runnable on Linux).
if [[ "$(uname)" == "Linux" ]]; then
  if cargo test --locked --manifest-path Linux/Cargo.toml > "$results_dir/linux-tests.log" 2>&1; then
    record PASS "linux receiver tests" ""
  else
    record FAIL "linux receiver tests" "see $results_dir/linux-tests.log"
  fi
else
  record NOT_TESTED "linux receiver tests" "runs in CI (Linux receiver workflow)"
fi

if [[ $live == 1 ]]; then
  echo "== Live checks against installed apps (this Mac <-> $peer)"
  installed_build() { defaults read /Applications/UniSpace.app/Contents/Info.plist CFBundleVersion 2>/dev/null; }
  local_build=$(installed_build)
  peer_build=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$peer" \
    'defaults read /Applications/UniSpace.app/Contents/Info.plist CFBundleVersion 2>/dev/null; pgrep -x UniSpace | wc -l' 2>/dev/null | tr '\n' ' ')
  local_running=$(pgrep -x UniSpace | wc -l | tr -d ' ')
  read -r peer_build_number peer_running <<< "$peer_build"
  if [[ "$local_build" == "$expected_build" && "$peer_build_number" == "$expected_build" \
        && "$local_running" == 1 && "${peer_running:-0}" == 1 ]]; then
    record PASS "installed build on both Macs" "build $expected_build running once on each"
  else
    record FAIL "installed build on both Macs" \
      "local=${local_build:-none}(${local_running} running) peer=${peer_build_number:-unreachable}(${peer_running:-?} running) expected=$expected_build"
  fi
  for mode in clipboard finder-files; do
    extra=()
    [[ "$mode" == finder-files ]] && extra=(--timeout 30)
    if python3 Scripts/verify-live-continuity.py "$mode" --peer "$peer" \
        --expected-build "$expected_build" --output "$results_dir/live-$mode" "${extra[@]}" \
        > "$results_dir/live-$mode.log" 2>&1; then
      record PASS "live $mode (both directions)" ""
    else
      record FAIL "live $mode (both directions)" "see $results_dir/live-$mode.log"
    fi
  done
else
  record NOT_TESTED "live installed-app checks" "pass --live --peer user@host --expected-build N"
fi

echo
failures=0
for entry in "${statuses[@]}"; do [[ "$entry" == FAIL\|* ]] && failures=$((failures + 1)); done
printf '%s\n' "${statuses[@]}" > "$results_dir/summary.txt"
if [[ $failures -gt 0 ]]; then
  echo "SANITY: FAIL ($failures failing check(s)); summary in $results_dir/summary.txt"
  exit 1
fi
echo "SANITY: PASS (NOT_TESTED rows are not covered); summary in $results_dir/summary.txt"
