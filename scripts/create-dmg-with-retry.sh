#!/bin/zsh
set -euo pipefail
source_folder="${1:?Pass the source folder}"
image="${2:?Pass the output image}"
volume_name="${3:?Pass the volume name}"
image="${image:A}"
temporary_dir="$(mktemp -d "$image:h/.dmg-create.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
candidate="$temporary_dir/image.dmg"
error_log="$temporary_dir/error.log"
for attempt in 1 2 3; do
  rm -f "$candidate"
  if hdiutil create -volname "$volume_name" -srcfolder "$source_folder" -ov -format UDZO "$candidate" 2>"$error_log"; then
    mv -f "$candidate" "$image"
    exit 0
  else
    failure_code=$?
  fi
  message="$(cat "$error_log")"
  print -r -- "$message" >&2
  if [[ "${(L)message}" != *"resource busy"* ]] || (( attempt == 3 )); then
    exit "$failure_code"
  fi
  echo "Disk image creation is busy; retrying in $((attempt * 3)) seconds." >&2
  sleep $((attempt * 3))
done
