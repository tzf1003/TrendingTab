#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

configuration="${CONFIGURATION:-Release}"
derived="${DERIVED_DATA_PATH:-$root/build/DerivedData}"
output_dir="${OUTPUT_DIR:-$root/build/release}"
app_name="TrendingTab"
project_version="$(
  xcodebuild -project TrendingTab.xcodeproj -scheme TrendingTab -configuration "$configuration" -showBuildSettings 2>/dev/null |
    awk -F ' = ' '/ MARKETING_VERSION / { print $2; exit }'
)"
version="${MARKETING_VERSION:-$project_version}"
version="${version:-0.2.0}"
build_number="${CURRENT_PROJECT_VERSION:-2}"
team_id="${DEVELOPMENT_TEAM:-GJUT2BVM7R}"
app_profile_id="${TRENDINGTAB_APP_PROFILE_ID:-}"
widget_profile_id="${TRENDINGTAB_WIDGET_PROFILE_ID:-}"
signing_mode="${SIGNING_MODE:-auto}"
sign_identity="${SIGN_IDENTITY:-}"

if [[ "$signing_mode" == auto ]]; then
  if [[ -z "$sign_identity" ]]; then
    sign_identity="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ { print $2; exit }')"
  fi
  if [[ -n "$sign_identity" && -n "$app_profile_id" && -n "$widget_profile_id" ]]; then
    signing_mode="developer-id"
  else
    signing_mode="ad-hoc"
  fi
fi

if [[ "$signing_mode" != "developer-id" && "$signing_mode" != "ad-hoc" ]]; then
  echo "SIGNING_MODE must be auto, developer-id, or ad-hoc." >&2
  exit 1
fi

if [[ "$signing_mode" == "developer-id" ]]; then
  if [[ -z "$sign_identity" ]]; then
    sign_identity="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ { print $2; exit }')"
  fi
  if [[ -z "$sign_identity" || -z "$app_profile_id" || -z "$widget_profile_id" ]]; then
    echo "Developer ID packaging requires a signing identity and both provisioning profile IDs." >&2
    exit 1
  fi
  echo "Signing mode: Developer ID"
  echo "Signing identity: $sign_identity"
else
  sign_identity="-"
  echo "Signing mode: ad-hoc"
fi

mkdir -p "$output_dir"
products="$derived/Build/Products/$configuration"
rm -rf "$products/$app_name.app"

build_args=(
  -project TrendingTab.xcodeproj
  -scheme TrendingTab
  -configuration "$configuration"
  -destination 'platform=macOS'
  -derivedDataPath "$derived"
  build
  MARKETING_VERSION="$version"
  CURRENT_PROJECT_VERSION="$build_number"
  CODE_SIGN_STYLE=Manual
  CODE_SIGNING_REQUIRED=YES
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_IDENTITY="$sign_identity"
)

if [[ "$signing_mode" == "developer-id" ]]; then
  build_args+=(
    DEVELOPMENT_TEAM="$team_id"
    TRENDINGTAB_APP_PROFILE_ID="$app_profile_id"
    TRENDINGTAB_WIDGET_PROFILE_ID="$widget_profile_id"
  )
else
  build_args+=(
    DEVELOPMENT_TEAM=
    TRENDINGTAB_APP_PROFILE_ID=
    TRENDINGTAB_WIDGET_PROFILE_ID=
  )
fi

if [[ -n "${ARCHS:-}" ]]; then
  build_args+=(ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO)
fi

xcodebuild "${build_args[@]}" -quiet

app="$products/$app_name.app"
widget_bundle="$app/Contents/PlugIns/TrendingTabWidget.appex"
widget_info="$widget_bundle/Contents/Info.plist"
test -d "$app"
test -d "$widget_bundle"

# Keep the extension point in the generated Info.plist, then sign the final
# nested code and the containing app in order.
/usr/libexec/PlistBuddy -c 'Delete :NSExtension' "$widget_info" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :NSExtension dict' "$widget_info"
/usr/libexec/PlistBuddy -c 'Add :NSExtension:NSExtensionPointIdentifier string com.apple.widgetkit-extension' "$widget_info"

extension_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$widget_info")"
if [[ "$extension_point" != "com.apple.widgetkit-extension" ]]; then
  echo "Widget extension point is missing after packaging." >&2
  exit 1
fi

timestamp_mode="${CODESIGN_TIMESTAMP:-auto}"
if [[ "$sign_identity" == "-" ]]; then
  timestamp_mode="none"
elif [[ "$timestamp_mode" == auto ]]; then
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

if [[ "$signing_mode" == "developer-id" && -n "${NOTARY_KEYCHAIN_PROFILE:-}" &&
      "$timestamp_mode" == "none" ]]; then
  echo "Notarization requires a secure timestamp, but Apple's timestamp service was unavailable." >&2
  exit 1
fi

codesign \
  --force \
  --options runtime \
  --sign "$sign_identity" \
  "${timestamp_args[@]}" \
  --entitlements "$root/Widget/TrendingTabWidget.entitlements" \
  "$widget_bundle"
codesign \
  --force \
  --options runtime \
  --sign "$sign_identity" \
  "${timestamp_args[@]}" \
  --entitlements "$root/App/TrendingTab.entitlements" \
  "$app"
codesign --verify --deep --strict --verbose=2 "$app"

app_signature="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
widget_signature="$(codesign -d --entitlements :- "$widget_bundle" 2>/dev/null)"
if [[ "$app_signature" != *"group.dev.trendingtab.shared"* ]]; then
  echo "Main app App Group entitlement is missing from the signature." >&2
  exit 1
fi
if [[ "$widget_signature" != *"com.apple.security.app-sandbox"* ||
      "$widget_signature" != *"group.dev.trendingtab.shared"* ]]; then
  echo "Widget sandbox or App Group entitlement is missing from the signature." >&2
  exit 1
fi

if [[ "$signing_mode" == "developer-id" ]]; then
  test -f "$app/Contents/embedded.provisionprofile"
  test -f "$widget_bundle/Contents/embedded.provisionprofile"
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
hdiutil verify "$dmg"

if [[ "$signing_mode" == "developer-id" ]]; then
  codesign --force --sign "$sign_identity" "${timestamp_args[@]}" "$dmg"
  codesign --verify --verbose=2 "$dmg"

  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    echo "Submitting DMG for notarization."
    xcrun notarytool submit \
      "$dmg" \
      --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
      --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
  fi
fi

echo "DMG=$dmg"
echo "SHA256=$(shasum -a 256 "$dmg" | awk '{ print $1 }')"
