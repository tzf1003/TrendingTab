#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
destination="${1:?Pass an empty destination for the Agent runtime}"
if [[ -e "$destination" ]]; then
  echo "Runtime destination already exists: $destination" >&2
  exit 1
fi
if [[ -d /Volumes/TrendingTabBuild ]]; then
  default_cache=/Volumes/TrendingTabBuild/cache/agent-distribution
else
  default_cache="${TMPDIR:-/tmp}/trendingtab-agent-cache"
fi
cache="${TRENDINGTAB_RUNTIME_CACHE:-$default_cache}"
mkdir -p "$cache" "${destination:h}"
staging="$(mktemp -d "${destination:h}/.agent-runtime.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

version=22.19.0
for arch in arm64 x64; do
  archive="node-v${version}-darwin-${arch}.tar.gz"
  case "$arch" in
    arm64) digest=c59006db713c770d6ec63ae16cb3edc11f49ee093b5c415d667bb4f436c6526d ;;
    x64) digest=3cfed4795cd97277559763c5f56e711852d2cc2420bda1cea30c8aa9ac77ce0c ;;
  esac
  if [[ ! -f "$cache/$archive" ]] || [[ "$(shasum -a 256 "$cache/$archive" | awk '{print $1}')" != "$digest" ]]; then
    curl --fail --location --retry 2 --output "$cache/$archive.download" "https://nodejs.org/dist/v${version}/${archive}"
    [[ "$(shasum -a 256 "$cache/$archive.download" | awk '{print $1}')" == "$digest" ]]
    mv "$cache/$archive.download" "$cache/$archive"
  fi
  tar -xzf "$cache/$archive" -C "$staging" "node-v${version}-darwin-${arch}/bin/node" "node-v${version}-darwin-${arch}/LICENSE"
  mkdir -p "$staging/bin"
  if [[ "$arch" == x64 ]]; then target=x86_64; else target=arm64; fi
  mv "$staging/node-v${version}-darwin-${arch}/bin/node" "$staging/bin/node-$target"
  if [[ "$arch" == arm64 ]]; then
    mv "$staging/node-v${version}-darwin-${arch}/LICENSE" "$staging/NODE-LICENSE"
  else
    cmp -s "$staging/NODE-LICENSE" "$staging/node-v${version}-darwin-${arch}/LICENSE"
  fi
  rm -rf "$staging/node-v${version}-darwin-${arch}"
done

cp "$root/AgentRuntime/package.json" "$root/AgentRuntime/package-lock.json" "$root/AgentRuntime/runtime.mjs" \
  "$root/AgentRuntime/mcp-client.mjs" "$root/AgentRuntime/runtime-selftest.mjs" "$root/AgentRuntime/tool-catalog.mjs" \
  "$root/AgentRuntime/runtime-resource-loader.mjs" "$root/AgentRuntime/runtime-health.mjs" "$staging/"
cp -R "$root/AgentRuntime/LICENSES" "$staging/LICENSES"
(cd "$staging" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
# Native modules for other operating systems cannot run on macOS and are not shipped.
rm -rf "$staging/node_modules/@earendil-works/pi-tui/native/linux" \
       "$staging/node_modules/@earendil-works/pi-tui/native/win32"
mv "$staging" "$destination"
trap - EXIT
