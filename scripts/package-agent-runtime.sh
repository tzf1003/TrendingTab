#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
version="${MARKETING_VERSION:?Set MARKETING_VERSION to a three-part version}"
output_dir="${OUTPUT_DIR:?Set OUTPUT_DIR}"
signing_mode="${SIGNING_MODE:-ad-hoc}"
team="${DEVELOPMENT_TEAM:-GJUT2BVM7R}"
identity="${SIGN_IDENTITY:-}"
[[ "$version" =~ '^[0-9]{1,7}\.[0-9]{1,7}\.[0-9]{1,7}$' ]] || { echo "Invalid runtime version" >&2; exit 1; }
pi_version="$(node - "$root/AgentRuntime/package.json" "$root/AgentRuntime/package-lock.json" "$version" <<'JS'
const fs = require('node:fs');
const [packagePath, lockPath, version] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
const dependency = '@earendil-works/pi-coding-agent';
const pi = pkg.dependencies?.[dependency];
if (pkg.name !== 'trendingtab-agent-runtime' || pkg.version !== version ||
    lock.version !== version || lock.packages?.['']?.version !== version ||
    typeof pi !== 'string' || !/^[0-9]{1,7}\.[0-9]{1,7}\.[0-9]{1,7}$/.test(pi) ||
    lock.packages?.['']?.dependencies?.[dependency] !== pi ||
    lock.packages?.[`node_modules/${dependency}`]?.version !== pi) {
  console.error('Runtime version must match package.json and package-lock.json.');
  process.exit(1);
}
process.stdout.write(pi);
JS
)"
if [[ "$signing_mode" == developer-id ]]; then
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ {print $2; exit}')"
  fi
  [[ -n "$identity" ]] || { echo "Developer ID identity is required" >&2; exit 1; }
  timestamp=(--timestamp)
elif [[ "$signing_mode" == ad-hoc ]]; then
  identity="-"
  timestamp=(--timestamp=none)
else
  echo "Unsupported signing mode" >&2; exit 1
fi
mkdir -p "$output_dir"
staging="$(mktemp -d "$output_dir/.runtime-component.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/AgentRuntime.app"
mkdir -p "$app/Contents/MacOS"
zsh "$root/scripts/prepare-agent-runtime.sh" "$app/Contents/Resources"
runtime="$app/Contents/Resources"
mv "$runtime/bin/node" "$app/Contents/MacOS/node"
rm -rf "$runtime/bin"
python3 - "$app/Contents/Info.plist" "$version" "$pi_version" <<'PY'
import plistlib
import sys
metadata = {
    "CFBundleIdentifier": "dev.trendingtab.runtime",
    "CFBundleName": "TrendingTab Agent Runtime",
    "CFBundleExecutable": "node",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": sys.argv[2],
    "CFBundleVersion": sys.argv[2],
    "LSMinimumSystemVersion": "14.0.0",
    "LSBackgroundOnly": True,
    "TrendingTabPiVersion": sys.argv[3],
    "TrendingTabMinimumAppVersion": "0.2.44",
    "TrendingTabMaximumAppVersion": "99.0.0",
    "TrendingTabMinimumProtocol": 1,
    "TrendingTabMaximumProtocol": 1,
    "TrendingTabArchitectures": ["arm64", "x86_64"],
}
with open(sys.argv[1], "wb") as output:
    plistlib.dump(metadata, output)
PY
for module in "$runtime"/node_modules/**/*.node(N); do
  codesign --force --options runtime --sign "$identity" "${timestamp[@]}" "$module"
done
codesign --force --options runtime --sign "$identity" "${timestamp[@]}" \
  --entitlements "$root/scripts/AgentRuntime.entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
python3 "$root/scripts/verify-native-architectures.py" "$app"
lipo "$app/Contents/MacOS/node" -verify_arch arm64
lipo "$app/Contents/MacOS/node" -verify_arch x86_64
"$app/Contents/MacOS/node" "$runtime/runtime-health.mjs" | python3 -c \
  'import json, sys; r = json.load(sys.stdin); assert r["protocol"] == 1 and r["streaming"] and r["tools"] and r["piVersion"] == sys.argv[1] and "open_current_story" in r["toolNames"]' "$pi_version"
if [[ "$signing_mode" == developer-id ]]; then
  details="$(codesign -dv --verbose=4 "$app" 2>&1)"
  [[ "$details" == *"TeamIdentifier=$team"* ]] || { echo "Runtime Team ID mismatch" >&2; exit 1; }
fi
if [[ "$signing_mode" == developer-id && -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  archive="$staging/.runtime-notary.zip"
  ditto -c -k --keepParent "$app" "$archive"
  xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  rm -f "$archive"
  zsh "$root/scripts/staple-with-retry.sh" "$app"
  zsh "$root/scripts/staple-with-retry.sh" "$app" validate
  codesign --verify --deep --strict "$app"
fi
image="$output_dir/TrendingTab-AgentRuntime-$version.dmg"
[[ ! -e "$image" ]] || { echo "Runtime image already exists" >&2; exit 1; }
zsh "$root/scripts/create-dmg-with-retry.sh" "$app:h" "$image" "TrendingTab Agent Runtime"
if [[ "$signing_mode" == developer-id ]]; then
  codesign --force --sign "$identity" "${timestamp[@]}" "$image"
  codesign --verify --strict "$image"
  if [[ -n "${SIGNED_UNNOTARIZED_IMAGE:-}" ]]; then
    [[ ! -e "$SIGNED_UNNOTARIZED_IMAGE" ]] || { echo "Signed test image already exists" >&2; exit 1; }
    mkdir -p "${SIGNED_UNNOTARIZED_IMAGE:h}"
    cp "$image" "$SIGNED_UNNOTARIZED_IMAGE"
  fi
fi
if [[ "$signing_mode" == developer-id && -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  xcrun notarytool submit "$image" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  zsh "$root/scripts/staple-with-retry.sh" "$image"
  zsh "$root/scripts/staple-with-retry.sh" "$image" validate
fi
hdiutil verify "$image"
echo "Created $image"
