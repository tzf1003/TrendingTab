#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

configuration="${CONFIGURATION:-Release}"
derived="${DERIVED_DATA_PATH:-$root/build/DerivedData}"
output_dir="${OUTPUT_DIR:-$root/build/release}"
app_name="TrendingTab"
version="$(xcodebuild -project TrendingTab.xcodeproj -scheme TrendingTab -configuration "$configuration" -showBuildSettings | awk -F ' = ' '/ MARKETING_VERSION / { print $2; exit }')"
version="${version:-0.1.0}"

mkdir -p "$output_dir"
products="$derived/Build/Products/$configuration"
rm -rf "$products/$app_name.app"

sign_identity="${SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  sign_identity="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ { print $2; exit }')"
fi

build_args=(
  -project TrendingTab.xcodeproj
  -scheme TrendingTab
  -configuration "$configuration"
  -destination 'platform=macOS'
  -derivedDataPath "$derived"
  build
  CODE_SIGN_STYLE=Manual
  CODE_SIGNING_REQUIRED=YES
  CODE_SIGNING_ALLOWED=YES
)

if [[ -n "$sign_identity" ]]; then
  echo "Signing with: $sign_identity"
  build_args+=(CODE_SIGN_IDENTITY="$sign_identity")
else
  echo "No Developer ID found; creating an ad-hoc signed DMG."
  sign_identity="-"
  build_args+=(CODE_SIGN_IDENTITY="-")
fi

xcodebuild "${build_args[@]}"

app="$products/$app_name.app"
test -d "$app"
timestamp_mode="${CODESIGN_TIMESTAMP:-auto}"
if [[ "$timestamp_mode" == auto ]]; then
  if curl --silent --show-error --head --max-time 8 https://timestamp.apple.com/ts01 >/dev/null; then
    timestamp_mode="required"
  else
    echo "Apple timestamp service is unreachable; signing without a timestamp."
    timestamp_mode="none"
  fi
fi
timestamp_args=()
if [[ "$timestamp_mode" == none ]]; then
  timestamp_args+=(--timestamp=none)
else
  timestamp_args+=(--timestamp)
fi
codesign --force --deep --sign "$sign_identity" "${timestamp_args[@]}" "$app"
codesign --verify --deep --verbose=2 "$app"

if [[ "$sign_identity" != "-" && -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  zip_path="$output_dir/$app_name.zip"
  ditto -c -k --keepParent "$app" "$zip_path"
  xcrun notarytool submit "$zip_path" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$app"
fi

dmg="$output_dir/$app_name-$version.dmg"
staging="$output_dir/dmg-root"
rm -rf "$staging" "$dmg"
mkdir -p "$staging"
ditto "$app" "$staging/$app_name.app"
ln -s /Applications "$staging/Applications"

hdiutil create \
  -volname "$app_name" \
  -srcfolder "$staging" \
  -ov \
  -format UDZO \
  "$dmg"

if [[ "$sign_identity" != "-" ]]; then
  codesign --sign "$sign_identity" "${timestamp_args[@]}" "$dmg"
  codesign --verify --verbose=2 "$dmg"
fi

echo "DMG=$dmg"
