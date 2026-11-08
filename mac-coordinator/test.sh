#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/tests
swiftc Sources/VinylSyncCoordinator/PlaybackOffsetTracker.swift \
  Tests/PlaybackTimingTests.swift -o .build/tests/playback-timing
.build/tests/playback-timing
swiftc Sources/VinylSyncCoordinator/SpotifyAlbumPreference.swift \
  Tests/SpotifyAlbumPreferenceTests.swift -o .build/tests/album-preference
.build/tests/album-preference
