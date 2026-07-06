#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p .build/debug
swiftc \
  -target arm64-apple-macosx14.0 \
  Sources/VinylSyncCoordinator/main.swift \
  -o .build/debug/vinyl-sync-coordinator

echo ".build/debug/vinyl-sync-coordinator"
