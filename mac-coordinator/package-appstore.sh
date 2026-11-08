#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <app signing identity> <installer signing identity> <Mac App Store provisioning profile>" >&2
  echo 'example: ./package-appstore.sh "Apple Distribution: Name (TEAMID)" "3rd Party Mac Developer Installer: Name (TEAMID)" ~/Downloads/VinylSyncAppStore.provisionprofile' >&2
  exit 64
fi

app_identity="$1"
installer_identity="$2"
profile="$3"

if [[ ! -f "$profile" ]]; then
  echo "Provisioning profile not found: $profile" >&2
  exit 66
fi

mkdir -p .build/release
swiftc -O \
  -target arm64-apple-macosx14.0 \
  Sources/VinylSyncCoordinator/*.swift \
  -framework AVFoundation \
  -framework ShazamKit \
  -o .build/release/vinyl-sync-coordinator

app_dir=".build/release/Vinyl Sync Coordinator.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleExecutable vinyl-sync-coordinator" \
  -c "Set :CFBundleIdentifier dev.iamdobhal.vinylsync" \
  -c "Set :CFBundleShortVersionString 0.3.0" \
  -c "Set :CFBundleVersion 12" \
  "$app_dir/Contents/Info.plist"
cp .build/release/vinyl-sync-coordinator "$app_dir/Contents/MacOS/vinyl-sync-coordinator"
cp Sources/VinylSyncCoordinator/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
cp "$profile" "$app_dir/Contents/embedded.provisionprofile"

codesign \
  --force \
  --timestamp \
  --entitlements Resources/VinylSync.entitlements \
  --sign "$app_identity" \
  "$app_dir"

codesign --verify --deep --strict --verbose=2 "$app_dir"

productbuild \
  --component "$app_dir" /Applications \
  --sign "$installer_identity" \
  .build/release/VinylSyncCoordinator.pkg

echo ".build/release/VinylSyncCoordinator.pkg"
