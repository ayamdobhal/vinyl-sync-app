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
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleExecutable vinyl-sync-coordinator" \
  -c "Set :CFBundleIdentifier ${VINYL_SYNC_BUNDLE_ID:-dev.iamdobhal.vinylsync}" \
  -c "Set :CFBundleShortVersionString 0.3.0" \
  -c "Set :CFBundleVersion 6" \
  "$app_dir/Contents/Info.plist"
cp .build/debug/vinyl-sync-coordinator "$app_dir/Contents/MacOS/vinyl-sync-coordinator"
cp Sources/VinylSyncCoordinator/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
