#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/trendingtab-architectures.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
runtime="$temporary/runtime"
prebuilds="$runtime/node_modules/@earendil-works/pi-tui/native/darwin/prebuilds"
mkdir -p "$runtime/bin" "$prebuilds/darwin-arm64" "$prebuilds/darwin-x64"
printf 'int main(void) { return 0; }\n' > "$temporary/main.c"
printf 'int trendingtab_fixture(void) { return 1; }\n' > "$temporary/module.c"
for architecture in arm64 x86_64; do
  clang -target "$architecture-apple-macos14" "$temporary/main.c" -o "$runtime/bin/node-$architecture"
  if [[ "$architecture" == arm64 ]]; then target=arm64; else target=x64; fi
  clang -target "$architecture-apple-macos14" -bundle "$temporary/module.c" -o "$prebuilds/darwin-$target/darwin-platform.node"
done
if python3 "$root/scripts/verify-native-architectures.py" "$runtime" > "$temporary/validation.log" 2>&1; then
  echo 'Architecture validation accepted thin executables' >&2; exit 1
fi
grep -F 'Native architecture missing:' "$temporary/validation.log"
zsh "$root/scripts/universalize-agent-runtime.sh" "$runtime"
test ! -e "$runtime/bin/node-arm64"
test ! -e "$runtime/bin/node-x86_64"
test -x "$runtime/bin/node"
"$runtime/bin/node"
cmp "$prebuilds/darwin-arm64/darwin-platform.node" "$prebuilds/darwin-x64/darwin-platform.node"
# An unexpected Intel-only dependency must fail even with a Universal Node.
clang -target x86_64-apple-macos14 -bundle "$temporary/module.c" -o "$runtime/extra.node"
if python3 "$root/scripts/verify-native-architectures.py" "$runtime" > "$temporary/validation.log" 2>&1; then
  echo 'Architecture validation accepted an Intel-only dependency' >&2; exit 1
fi
grep -F 'extra.node' "$temporary/validation.log"
echo 'Runtime native architecture regression passed'
