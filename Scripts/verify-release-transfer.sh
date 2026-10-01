#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 2 ]]; then
  echo "Usage: Scripts/verify-release-transfer.sh <frameworks-with-swift-modules> <runtime-frameworks>" >&2
  exit 2
fi
modules=$(cd "$1" && pwd -P)
runtime=$(cd "$2" && pwd -P)
mkdir -p .build/feature-baseline
probe=$(mktemp -d "$(pwd)/.build/feature-baseline/release-probe.XXXXXX")
trap 'rm -rf "$probe"' EXIT
swiftc -parse-as-library -swift-version 6 -O \
  Tools/FeatureBaseline/ReleaseTransferProbe.swift \
  -F "$modules" -framework UniSpaceDomain -framework UniSpaceApplication -framework UniSpaceInfrastructure \
  -Xlinker -rpath -Xlinker "$runtime" -o "$probe/ReleaseTransferProbe"
env -u DYLD_FRAMEWORK_PATH -u DYLD_LIBRARY_PATH "$probe/ReleaseTransferProbe" "$runtime"
