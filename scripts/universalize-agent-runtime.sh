#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
runtime="${1:?Pass the prepared Agent runtime directory}"
lipo -create "$runtime/bin/node-arm64" "$runtime/bin/node-x86_64" -output "$runtime/bin/node"
chmod 755 "$runtime/bin/node"
rm "$runtime/bin/node-arm64" "$runtime/bin/node-x86_64"

# Pi selects its native helper by process.arch. Keep the upstream lookup paths,
# with a Universal helper at each path so neither contains Intel-only code.
prebuilds="$runtime/node_modules/@earendil-works/pi-tui/native/darwin/prebuilds"
arm="$prebuilds/darwin-arm64/darwin-platform.node"
intel="$prebuilds/darwin-x64/darwin-platform.node"
lipo -create "$arm" "$intel" -output "$prebuilds/darwin-platform.node"
mv "$prebuilds/darwin-platform.node" "$arm"
cp "$arm" "$intel"
python3 "$root/scripts/verify-native-architectures.py" "$runtime"
