#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <codesign identity> <macOS provisioning profile>" >&2
  echo 'example: ./sign.sh "Apple Development: Name (TEAMID)" ~/Downloads/VinylSync.provisionprofile' >&2
  exit 64
fi

identity="$1"
profile="$2"
app_dir=".build/debug/Vinyl Sync Coordinator.app"

if [[ ! -d "$app_dir" ]]; then
  echo "Build the app first with ./build.sh." >&2
  exit 66
fi

if [[ ! -f "$profile" ]]; then
  echo "Provisioning profile not found: $profile" >&2
  exit 66
fi

cp "$profile" "$app_dir/Contents/embedded.provisionprofile"
codesign \
  --force \
  --timestamp=none \
  --options runtime \
  --sign "$identity" \
  "$app_dir"

codesign --verify --deep --strict --verbose=2 "$app_dir"
codesign --display --verbose=2 "$app_dir"
