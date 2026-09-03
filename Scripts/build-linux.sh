#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${UNISPACE_VERSION:-1.2.0}"
case "$(uname -m)" in
  x86_64) nfpm_arch=amd64 ;;
  aarch64|arm64) nfpm_arch=arm64 ;;
  *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 2 ;;
esac
cargo build --manifest-path Linux/Cargo.toml --release --target-dir .build/linux
mkdir -p dist
if command -v nfpm >/dev/null 2>&1; then
  for package in deb rpm; do
    (cd Linux && NFPM_ARCH="$nfpm_arch" UNISPACE_VERSION="$version" nfpm package --packager "$package" --target "../dist/")
  done
else
  echo "Built .build/linux/release/unispace-linux (install nfpm to produce deb/rpm packages)"
fi
