#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${UNISPACE_SIGNING_IDENTITY:-Developer ID Application: TUYEN HO (Y69F3DRK44)}"
version="$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Base.xcconfig)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Could not read a semantic MARKETING_VERSION from Config/Base.xcconfig." >&2
  exit 2
fi
dmg_path="dist/UniSpace-$version.dmg"
notary_profile="${UNISPACE_NOTARY_PROFILE:-}"
notary_arguments=()
if [[ -n "$notary_profile" ]]; then
  notary_arguments=(--keychain-profile "$notary_profile")
elif [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
  notary_arguments=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  notary_arguments=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
  echo "Configure UNISPACE_NOTARY_PROFILE or the APPLE_* notarization variables." >&2
  exit 2
fi
unset APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID APPLE_API_KEY APPLE_API_ISSUER APPLE_API_KEY_PATH

./Scripts/bootstrap.sh >/dev/null
release_root="$(pwd)/.build/release"
archive_path="$release_root/UniSpace.xcarchive"
app_path="$archive_path/Products/Applications/UniSpace.app"
rm -rf "$release_root"
mkdir -p "$release_root" dist

xcodebuild archive \
  -project UniSpace.xcodeproj \
  -scheme UniSpace \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=Y69F3DRK44 \
  CODE_SIGN_IDENTITY="$identity"

codesign --verify --deep --strict --verbose=2 "$app_path"
work_dir="$(mktemp -d /tmp/unispace-notary.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
app_zip="$work_dir/UniSpace.zip"
ditto -c -k --keepParent "$app_path" "$app_zip"
xcrun notarytool submit "$app_zip" "${notary_arguments[@]}" --wait --output-format json > "$work_dir/app-notary.json"
app_status="$(plutil -extract status raw -o - "$work_dir/app-notary.json")"
app_submission_id="$(plutil -extract id raw -o - "$work_dir/app-notary.json")"
echo "App notarization: $app_status ($app_submission_id)"
[[ "$app_status" == "Accepted" ]]
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

dmg_root="$work_dir/dmg"
mkdir -p "$dmg_root"
ditto "$app_path" "$dmg_root/UniSpace.app"
ln -s /Applications "$dmg_root/Applications"
rm -f "$dmg_path"
hdiutil create -volname UniSpace -srcfolder "$dmg_root" -ov -format UDZO "$dmg_path"
codesign --force --sign "$identity" --timestamp "$dmg_path"
xcrun notarytool submit "$dmg_path" "${notary_arguments[@]}" --wait --output-format json > "$work_dir/dmg-notary.json"
dmg_status="$(plutil -extract status raw -o - "$work_dir/dmg-notary.json")"
dmg_submission_id="$(plutil -extract id raw -o - "$work_dir/dmg-notary.json")"
echo "DMG notarization: $dmg_status ($dmg_submission_id)"
[[ "$dmg_status" == "Accepted" ]]
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"
codesign --verify --verbose=2 "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
echo "Created notarized $dmg_path"
