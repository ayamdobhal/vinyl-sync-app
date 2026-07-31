#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p .build/debug
swiftc \
  -target arm64-apple-macosx14.0 \
  Sources/VinylSyncCoordinator/*.swift \
  -framework AVFoundation \
  -framework ShazamKit \
  -o .build/debug/vinyl-sync-coordinator

app_dir=".build/debug/Vinyl Sync Coordinator.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier ${VINYL_SYNC_BUNDLE_ID:-dev.iamdobhal.vinyl-sync}" \
  "$app_dir/Contents/Info.plist"
cp .build/debug/vinyl-sync-coordinator "$app_dir/Contents/MacOS/vinyl-sync-coordinator"

echo "$app_dir"
