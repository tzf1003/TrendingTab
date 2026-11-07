#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/trendingtab-dmg-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/source folder"
cat > "$tmp/bin/hdiutil" <<'SH'
#!/bin/sh
count=0
test ! -f "$TEST_COUNTER" || count=$(cat "$TEST_COUNTER")
count=$((count + 1))
printf '%s' "$count" > "$TEST_COUNTER"
test "$1" = create || exit 64
for image do :; done
case "$TEST_MODE" in
  busy)
    if test "$count" -le 2; then
      printf partial > "$image"
      echo 'hdiutil: create failed - Resource busy' >&2
      exit 16
    fi
    printf complete > "$image"
    ;;
  persistent)
    printf partial > "$image"
    echo 'hdiutil: create failed - Resource busy' >&2
    exit 16
    ;;
  terminal)
    echo 'hdiutil: create failed - Invalid argument' >&2
    exit 64
    ;;
esac
SH
cat > "$tmp/bin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$tmp/bin/hdiutil" "$tmp/bin/sleep"
export PATH="$tmp/bin:$PATH" TEST_COUNTER="$tmp/count"
export TEST_MODE=busy
zsh "$root/scripts/create-dmg-with-retry.sh" "$tmp/source folder" "$tmp/result image.dmg" 'Test Volume'
[[ "$(cat "$TEST_COUNTER")" == 3 && "$(cat "$tmp/result image.dmg")" == complete ]]
rm "$TEST_COUNTER"
for TEST_MODE in persistent terminal; do
  export TEST_MODE
  printf previous > "$tmp/result image.dmg"
  if zsh "$root/scripts/create-dmg-with-retry.sh" "$tmp/source folder" "$tmp/result image.dmg" 'Test Volume'; then
    echo "Expected $TEST_MODE creation failure" >&2
    exit 1
  fi
  [[ "$(cat "$tmp/result image.dmg")" == previous ]]
  expected=3
  [[ "$TEST_MODE" != terminal ]] || expected=1
  [[ "$(cat "$TEST_COUNTER")" == "$expected" ]]
  rm "$TEST_COUNTER"
done
[[ -z "$(find "$tmp" -name '.dmg-create.*' -print)" ]]
echo 'DMG creation retry tests passed.'
