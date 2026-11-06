#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/trendingtab-staple-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/xcrun" <<'SH'
#!/bin/sh
count=0
test ! -f "$TEST_COUNTER" || count=$(cat "$TEST_COUNTER")
count=$((count + 1))
printf '%s' "$count" > "$TEST_COUNTER"
test "$1" = stapler && test "$2" = "$TEST_ACTION" && test "$3" = 'test target' || exit 1
test "$count" -gt "$TEST_FAILURES"
SH
cat > "$tmp/bin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$tmp/bin/xcrun" "$tmp/bin/sleep"
export PATH="$tmp/bin:$PATH" TEST_COUNTER="$tmp/count"
for TEST_ACTION in staple validate; do
  export TEST_ACTION TEST_FAILURES=5
  zsh "$root/scripts/staple-with-retry.sh" 'test target' "$TEST_ACTION"
  [[ "$(cat "$TEST_COUNTER")" == 6 ]]
  rm "$TEST_COUNTER"
  export TEST_FAILURES=6
  if zsh "$root/scripts/staple-with-retry.sh" 'test target' "$TEST_ACTION"; then
    echo "Expected $TEST_ACTION failure after retries" >&2
    exit 1
  fi
  [[ "$(cat "$TEST_COUNTER")" == 6 ]]
  rm "$TEST_COUNTER"
done
