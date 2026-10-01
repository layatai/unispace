#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Always run the complete unit/coverage/simulation gate. A narrow protocol slice
# is insufficient to detect continuity and other cross-feature regressions.
python3 -m unittest discover -s Tools/FeatureBaseline -v
python3 -m unittest discover -s Tools/LiveControlObserver -v
./Scripts/test.sh --unit
