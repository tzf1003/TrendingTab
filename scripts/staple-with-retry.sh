#!/bin/zsh
set -euo pipefail
target="${1:?Pass the notarized item}"
action="${2:-staple}"
[[ "$action" == staple || "$action" == validate ]] || { echo 'Invalid stapler action.' >&2; exit 1; }
for attempt in 1 2 3 4 5 6; do
  if xcrun stapler "$action" "$target"; then
    exit 0
  fi
  if (( attempt < 6 )); then
    echo "Stapler $action failed; retrying in $((attempt * 5)) seconds." >&2
    sleep $((attempt * 5))
  fi
done
echo "Stapler $action failed after six attempts." >&2
exit 1
