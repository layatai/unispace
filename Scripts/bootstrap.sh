#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null 2>&1 || {
  echo "xcodegen is required: brew install xcodegen" >&2
  exit 1
}
xcodegen generate
