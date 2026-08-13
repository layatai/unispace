#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/bootstrap.sh >/dev/null
architectures="arm64"
if [[ "${1:-}" == "--universal" ]]; then
  architectures="arm64 x86_64"
fi
build_root="$(pwd)/.build/xcode"
xcodebuild build \
  -project UniSpace.xcodeproj \
  -scheme UniSpace \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_root" \
  ARCHS="$architectures" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO
mkdir -p dist
rm -rf dist/UniSpace.app
cp -R "$build_root/Build/Products/Release/UniSpace.app" dist/UniSpace.app
echo "Built dist/UniSpace.app ($architectures)"
