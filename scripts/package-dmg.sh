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
runtime_dir="$app/Contents/Resources/AgentRuntime"
zsh "$root/scripts/prepare-agent-runtime.sh" "$runtime_dir"

# Preserve the application and team identities required by App Intents, and
# remove Xcode's debugger access before signing the distribution bundles.
signing_entitlements="$(mktemp -d "$output_dir/entitlements.XXXXXX")"
trap 'rm -rf "$signing_entitlements"' EXIT
codesign -d --entitlements :- "$app" > "$signing_entitlements/app.plist" 2>/dev/null
codesign -d --entitlements :- "$widget_bundle" > "$signing_entitlements/widget.plist" 2>/dev/null
python3 - "$signing_entitlements/app.plist" "$signing_entitlements/widget.plist" <<'PY'
import plistlib
import sys
from pathlib import Path
for filename in sys.argv[1:]:
    path = Path(filename)
    entitlements = plistlib.loads(path.read_bytes())
    entitlements.pop("com.apple.security.get-task-allow", None)
    path.write_bytes(plistlib.dumps(entitlements))
PY

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

timestamp_mode="${CODESIGN_TIMESTAMP:-}"
if [[ -z "$timestamp_mode" ]]; then
  if [[ "$signing_mode" == "developer-id" ]]; then
    timestamp_mode="required"
  else
    timestamp_mode="none"
  fi
elif [[ "$timestamp_mode" == "auto" ]]; then
  if [[ "$signing_mode" == "developer-id" ]]; then
    timestamp_mode="required"
  else
    timestamp_mode="none"
  fi
fi

timestamp_args=()
if [[ "$timestamp_mode" == "none" ]]; then
  timestamp_args+=(--timestamp=none)
elif [[ "$timestamp_mode" == "required" ]]; then
  timestamp_args+=(--timestamp)
else
  echo "CODESIGN_TIMESTAMP must be required, none, or auto." >&2
  exit 1
fi

if [[ "$signing_mode" == "developer-id" && -n "${NOTARY_KEYCHAIN_PROFILE:-}" &&
      "$timestamp_mode" == "none" ]]; then
  echo "Notarization requires CODESIGN_TIMESTAMP=required." >&2
  exit 1
fi

sign_with_retry() {
  local target="$1"
  shift
  local attempt
  for attempt in 1 2 3; do
    if codesign "$@" "$target"; then
      return 0
    fi
    if (( attempt < 3 )); then
      echo "Code signing failed for $(basename "$target"); retrying in $((attempt * 5)) seconds." >&2
      sleep $((attempt * 5))
    fi
  done
  return 1
}

# Sign the embedded executables and native modules before sealing the app.
for native_module in "$runtime_dir"/node_modules/**/*.node(N); do
  sign_with_retry "$native_module" --force --options runtime --sign "$sign_identity" "${timestamp_args[@]}"
done
for node in "$runtime_dir/bin/node-arm64" "$runtime_dir/bin/node-x86_64"; do
  sign_with_retry "$node" --force --options runtime --sign "$sign_identity" \
    "${timestamp_args[@]}" --entitlements "$root/scripts/AgentRuntime.entitlements"
done

sign_with_retry "$widget_bundle" \
  --force \
  --options runtime \
  --sign "$sign_identity" \
  "${timestamp_args[@]}" \
  --entitlements "$signing_entitlements/widget.plist"
sign_with_retry "$app" \
  --force \
  --options runtime \
  --sign "$sign_identity" \
  "${timestamp_args[@]}" \
  --entitlements "$signing_entitlements/app.plist"
codesign --verify --deep --strict --verbose=2 "$app"

verification_args=("$app")
if [[ "$signing_mode" == "developer-id" ]]; then
  verification_args+=(--developer-id)
fi
python3 "$root/scripts/verify-bundle.py" "${verification_args[@]}"

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
  sign_with_retry "$dmg" \
    --force \
    --sign "$sign_identity" \
    "${timestamp_args[@]}"
  codesign --verify --verbose=2 "$dmg"

  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    echo "Submitting DMG for notarization."
    notary_result="$output_dir/notarization.json"
    notary_exit=0
    xcrun notarytool submit \
      "$dmg" \
      --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
      --wait \
      --output-format json > "$notary_result" || notary_exit=$?
    cat "$notary_result"
    notary_status="$(plutil -extract status raw -o - "$notary_result" 2>/dev/null || true)"
    if (( notary_exit != 0 )) || [[ "$notary_status" != "Accepted" ]]; then
      submission_id="$(plutil -extract id raw -o - "$notary_result" 2>/dev/null || true)"
      if [[ -n "$submission_id" ]]; then
        notary_log="$output_dir/notarization-log.json"
        if xcrun notarytool log "$submission_id" \
            --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" "$notary_log"; then
          cat "$notary_log"
        fi
      fi
      echo "Apple notarization failed: ${notary_status:-submission error}." >&2
      exit 1
    fi
    zsh "$root/scripts/staple-with-retry.sh" "$dmg"
    zsh scripts/staple-with-retry.sh "$dmg" validate
  fi
fi

echo "DMG=$dmg"
echo "SHA256=$(shasum -a 256 "$dmg" | awk '{ print $1 }')"
